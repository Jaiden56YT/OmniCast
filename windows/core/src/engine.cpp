// Engine start/stop, encoders, sources, scenes, device lists, stats.
#include "internal.h"

#include <windows.h>
#include <dxgi.h>
#include <d3d11.h>
#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <vector>

#pragma warning(disable : 4996) // obs_add_data_path is deprecated but still how libobs finds its effects

namespace oc {

Engine engine;

void set_err(char *err, int32_t len, const char *msg)
{
	if (err && len > 0)
		snprintf(err, (size_t)len, "%s", msg);
}

std::wstring widen(const char *s)
{
	if (!s || !*s)
		return {};
	int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
	std::wstring w((size_t)n, L'\0');
	MultiByteToWideChar(CP_UTF8, 0, s, -1, w.data(), n);
	w.resize((size_t)n - 1);
	return w;
}

std::string narrow(const wchar_t *w)
{
	if (!w || !*w)
		return {};
	int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
	std::string s((size_t)n, '\0');
	WideCharToMultiByte(CP_UTF8, 0, w, -1, s.data(), n, nullptr, nullptr);
	s.resize((size_t)n - 1);
	return s;
}

std::string json_escape(const char *s)
{
	std::string out;
	for (const unsigned char *p = (const unsigned char *)(s ? s : ""); *p; p++) {
		switch (*p) {
		case '"': out += "\\\""; break;
		case '\\': out += "\\\\"; break;
		case '\n': out += "\\n"; break;
		case '\r': out += "\\r"; break;
		case '\t': out += "\\t"; break;
		default:
			if (*p < 0x20) {
				char buf[8];
				snprintf(buf, sizeof(buf), "\\u%04x", *p);
				out += buf;
			} else {
				out += (char)*p;
			}
		}
	}
	return out;
}

// ---------------------------------------------------------------------------
// Video

static void canvas_sizes(const oc_video_config &v)
{
	uint32_t h = v.height >= 1080 ? 1080 : 720;
	engine.wide_h = h;
	engine.wide_w = h * 16 / 9;
	engine.tall_w = h;
	engine.tall_h = engine.wide_w;
}

static void fill_ovi(obs_video_info &ovi, uint32_t w, uint32_t h, uint32_t fps, const char *module)
{
	memset(&ovi, 0, sizeof(ovi));
	ovi.graphics_module = module;
	ovi.fps_num = fps;
	ovi.fps_den = 1;
	// Sources are composited at the output size: no extra rescale pass.
	ovi.base_width = ovi.output_width = w;
	ovi.base_height = ovi.output_height = h;
	// NV12 converted on the GPU: what every encoder takes without another copy.
	ovi.output_format = VIDEO_FORMAT_NV12;
	ovi.gpu_conversion = true;
	ovi.colorspace = VIDEO_CS_709;
	ovi.range = VIDEO_RANGE_PARTIAL;
	// Bilinear is enough for the screen slot (usually scaled by a whole step,
	// e.g. 1080p -> 720p) and is the cheapest on low-end GPUs.
	ovi.scale_type = OBS_SCALE_BILINEAR;
	ovi.adapter = 0;
}

// ---------------------------------------------------------------------------
// Encoders

enum class Family { X264, NVENC, AMF, QSV };

static Family family_of(const std::string &id)
{
	if (id.find("nvenc") != std::string::npos)
		return Family::NVENC;
	if (id.find("amf") != std::string::npos)
		return Family::AMF;
	if (id.find("qsv") != std::string::npos)
		return Family::QSV;
	return Family::X264;
}

// The best H.264 encoder on this PC. GPU encoders only register when the GPU
// actually has one (OBS tests that at load), so a GT 710 or an old Radeon falls
// through to x264.
static void pick_encoder()
{
	const char *id;
	int best = 0;
	std::string pick = "obs_x264";
	for (size_t i = 0; obs_enum_encoder_types(i, &id); i++) {
		const char *codec = obs_get_encoder_codec(id);
		uint32_t caps = obs_get_encoder_caps(id);
		if (!codec || strcmp(codec, "h264") != 0 || (caps & OBS_ENCODER_CAP_DEPRECATED))
			continue;
		std::string s = id;
		int score = 0;
		Family f = family_of(s);
		if (f == Family::NVENC)
			score = 30;
		else if (f == Family::AMF)
			score = 20;
		else if (f == Family::QSV)
			score = 10;
		if (score && (caps & OBS_ENCODER_CAP_PASS_TEXTURE))
			score += 5; // frames never leave the GPU
		blog(LOG_INFO, "[OmniCast] H.264 encoder available: %s (caps 0x%x)", id, caps);
		if (score > best) {
			best = score;
			pick = s;
		}
	}
	engine.encoder_id = pick;
	engine.encoder_gpu = family_of(pick) != Family::X264;
	const char *name = obs_encoder_get_display_name(pick.c_str());
	engine.encoder_name = engine.encoder_gpu ? (name ? name : pick.c_str()) : "x264 (CPU)";
}

// CBR stream encode. Settings per encoder family.
static obs_encoder_t *create_stream_encoder(const char *name, int kbps)
{
	obs_data_t *s = obs_data_create();
	obs_data_set_int(s, "bitrate", kbps);
	obs_data_set_int(s, "keyint_sec", 2);
	obs_data_set_string(s, "profile", "high");
	switch (family_of(engine.encoder_id)) {
	case Family::NVENC:
		obs_data_set_string(s, "rate_control", "cbr");
		obs_data_set_string(s, "preset", "p4");
		obs_data_set_string(s, "tune", "hq");
		obs_data_set_string(s, "multipass", "qres");
		obs_data_set_int(s, "bf", 2);
		break;
	case Family::AMF:
		obs_data_set_string(s, "rate_control", "CBR");
		obs_data_set_string(s, "preset", "balanced");
		break;
	case Family::QSV:
		obs_data_set_string(s, "rate_control", "CBR");
		obs_data_set_string(s, "target_usage", "TU4");
		break;
	case Family::X264:
		obs_data_set_string(s, "rate_control", "CBR");
		// Both canvases share the CPU. veryfast is OBS's default; at 1080p two
		// 60 fps encodes need superfast to stay real-time on a 6-core CPU.
		obs_data_set_string(s, "preset", engine.wide_h >= 1080 ? "superfast" : "veryfast");
		obs_data_set_string(s, "tune", "");
		break;
	}
	obs_encoder_t *enc = obs_video_encoder_create(engine.encoder_id.c_str(), name, s, nullptr);
	obs_data_release(s);
	return enc;
}

// Constant-quality recording encode (GPU only; see oc_record_start).
obs_encoder_t *create_record_encoder(const char *name, int quality)
{
	if (quality < 1 || quality > 51)
		quality = 20;
	obs_data_t *s = obs_data_create();
	obs_data_set_int(s, "keyint_sec", 2);
	obs_data_set_string(s, "profile", "high");
	switch (family_of(engine.encoder_id)) {
	case Family::NVENC:
		obs_data_set_string(s, "rate_control", "cqp");
		obs_data_set_int(s, "cqp", quality);
		obs_data_set_string(s, "preset", "p5");
		obs_data_set_int(s, "bf", 2);
		break;
	case Family::AMF:
		obs_data_set_string(s, "rate_control", "CQP");
		obs_data_set_int(s, "cqp", quality);
		break;
	case Family::QSV:
		obs_data_set_string(s, "rate_control", "CQP");
		obs_data_set_int(s, "cqp", quality);
		obs_data_set_int(s, "qpi", quality);
		obs_data_set_int(s, "qpp", quality);
		obs_data_set_int(s, "qpb", quality);
		break;
	case Family::X264:
		obs_data_release(s);
		return nullptr;
	}
	obs_encoder_t *enc = obs_video_encoder_create(engine.encoder_id.c_str(), name, s, nullptr);
	obs_data_release(s);
	return enc;
}

video_t *canvas_video(int canvas)
{
	if (canvas == OC_TALL)
		return engine.tall_canvas ? obs_canvas_get_video(engine.tall_canvas) : nullptr;
	return obs_get_video();
}

static bool create_canvas_and_encoders(char *err, int32_t err_len)
{
	obs_video_info ovi;
	fill_ovi(ovi, engine.tall_w, engine.tall_h, (uint32_t)engine.video.fps, nullptr);
	engine.tall_canvas = obs_canvas_create("Tall", &ovi, ACTIVATE | SCENE_REF | EPHEMERAL);
	if (!engine.tall_canvas || !obs_canvas_has_video(engine.tall_canvas)) {
		set_err(err, err_len, "Could not create the 9:16 canvas");
		return false;
	}

	engine.venc[OC_WIDE] = create_stream_encoder("16:9 H.264", engine.video.wide_kbps);
	engine.venc[OC_TALL] = create_stream_encoder("9:16 H.264", engine.video.tall_kbps);
	if (!engine.venc[OC_WIDE] || !engine.venc[OC_TALL]) {
		set_err(err, err_len, "Could not create the video encoders");
		return false;
	}
	obs_encoder_set_video(engine.venc[OC_WIDE], canvas_video(OC_WIDE));
	obs_encoder_set_video(engine.venc[OC_TALL], canvas_video(OC_TALL));
	return true;
}

static void release_canvas_and_encoders()
{
	for (auto &e : engine.venc) {
		obs_encoder_release(e);
		e = nullptr;
	}
	if (engine.tall_canvas) {
		obs_canvas_set_channel(engine.tall_canvas, 0, nullptr);
		obs_canvas_remove(engine.tall_canvas);
		obs_canvas_release(engine.tall_canvas);
		engine.tall_canvas = nullptr;
	}
}

// ---------------------------------------------------------------------------
// Mic and desktop audio (not part of any scene: always on the stream)

static obs_source_t *make_audio(const char *type, const char *name, const char *device, uint32_t mixers)
{
	obs_data_t *s = obs_data_create();
	obs_data_set_string(s, "device_id", device && *device ? device : "default");
	obs_source_t *src = obs_source_create(type, name, s, nullptr);
	obs_data_release(s);
	if (src)
		obs_source_set_audio_mixers(src, mixers);
	return src;
}

// Desktop audio: on the default output (Windows 10 2004+) it's everything but
// OmniCast and the apps with their own channel; on a chosen device, that
// device's whole output.
static obs_source_t *make_desktop(const char *id)
{
	bool follow = !id || !*id || !strcmp(id, "default");
	obs_source_t *src = follow && proc_audio_supported() ? create_system_audio() : nullptr;
	if (src)
		obs_source_set_audio_mixers(src, MIX_ALL | MIX_DESKTOP);
	else
		src = make_audio("wasapi_output_capture", "Desktop Audio", id, MIX_ALL | MIX_DESKTOP);
	return src;
}

static void create_audio_sources()
{
	proc_audio_register();
	vst3_register();
	engine.mic = make_audio("wasapi_input_capture", "Mic", "default", MIX_ALL | MIX_MIC);
	engine.desktop = make_desktop("default");
	if (engine.desktop)
		obs_set_output_source(1, engine.desktop);
	if (engine.mic)
		obs_set_output_source(3, engine.mic);
	audio_attach(OC_CH_MIC, engine.mic);
	audio_attach(OC_CH_DESKTOP, engine.desktop);
	monitor_start();
}

} // namespace oc

using namespace oc;

// ---------------------------------------------------------------------------
// Public: engine

static void add_dll_dirs(const std::string &app_dir)
{
	std::wstring bin = widen((app_dir + "\\obs\\bin\\64bit").c_str());
	// OBS Studio's own exe sits in bin\64bit, so its plugins find FFmpeg, curl,
	// etc. in the exe's folder. Ours doesn't: add bin\64bit to the safe DLL
	// search (app folder, System32, added folders) for obs.dll, its renderer
	// and every plugin's dependencies.
	SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
	AddDllDirectory(bin.c_str());
	// libobs finds its plugins (../../obs-plugins/64bit) and their data
	// (../../data) relative to the working directory, the way OBS runs from
	// bin\64bit, so match that.
	SetCurrentDirectoryW(bin.c_str());
}

// libobs's log goes to <config>\logs\<date time>.txt (the newest 10 are kept),
// so a bug report can include it. Settings > About > Open logs.
static FILE *log_file = nullptr;
static CRITICAL_SECTION log_lock;

static void log_handler(int level, const char *format, va_list args, void *)
{
	if (level > LOG_INFO)
		return; // debug noise
	char line[4096];
	vsnprintf(line, sizeof(line), format, args);
	EnterCriticalSection(&log_lock);
	if (log_file) {
		SYSTEMTIME t;
		GetLocalTime(&t);
		fprintf(log_file, "%02d:%02d:%02d.%03d: %s\n", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, line);
		fflush(log_file);
	}
	LeaveCriticalSection(&log_lock);
	OutputDebugStringA(line);
	OutputDebugStringA("\n");
}

static void open_log(const std::string &config_dir)
{
	static bool init = false;
	if (!init) {
		InitializeCriticalSection(&log_lock);
		init = true;
	}
	std::wstring dir = widen((config_dir + "\\logs").c_str());
	CreateDirectoryW(widen(config_dir.c_str()).c_str(), nullptr);
	CreateDirectoryW(dir.c_str(), nullptr);

	// Keep the newest 9 old logs (names sort by date).
	std::vector<std::wstring> logs;
	WIN32_FIND_DATAW fd;
	HANDLE h = FindFirstFileW((dir + L"\\*.txt").c_str(), &fd);
	if (h != INVALID_HANDLE_VALUE) {
		do
			logs.push_back(fd.cFileName);
		while (FindNextFileW(h, &fd));
		FindClose(h);
	}
	std::sort(logs.begin(), logs.end());
	for (size_t i = 0; i + 9 < logs.size(); i++)
		DeleteFileW((dir + L"\\" + logs[i]).c_str());

	SYSTEMTIME t;
	GetLocalTime(&t);
	wchar_t name[64];
	swprintf(name, 64, L"\\%04d-%02d-%02d %02d-%02d-%02d.txt", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
	EnterCriticalSection(&log_lock);
	if (log_file)
		fclose(log_file);
	log_file = _wfopen((dir + name).c_str(), L"w");
	LeaveCriticalSection(&log_lock);
	base_set_log_handler(log_handler, nullptr);
}

static void read_gpu_name()
{
	obs_enter_graphics();
	auto *dev = (ID3D11Device *)gs_get_device_obj();
	IDXGIDevice *dxgi = nullptr;
	IDXGIAdapter *adapter = nullptr;
	if (dev && SUCCEEDED(dev->QueryInterface(__uuidof(IDXGIDevice), (void **)&dxgi)) &&
	    SUCCEEDED(dxgi->GetAdapter(&adapter))) {
		DXGI_ADAPTER_DESC desc;
		if (SUCCEEDED(adapter->GetDesc(&desc)))
			engine.gpu_name = narrow(desc.Description);
	}
	if (adapter)
		adapter->Release();
	if (dxgi)
		dxgi->Release();
	obs_leave_graphics();
}

OC_API int32_t oc_start(const char *app_dir, const char *config_dir, const oc_video_config *video, char *err,
			int32_t err_len)
{
	if (engine.running)
		return 1;
	if (!app_dir || !config_dir || !video) {
		set_err(err, err_len, "Missing arguments");
		return 0;
	}
	engine.app_dir = app_dir;
	engine.config_dir = config_dir;
	engine.video = *video;
	if (engine.video.fps != 30 && engine.video.fps != 60)
		engine.video.fps = 60;
	canvas_sizes(engine.video);
	add_dll_dirs(engine.app_dir);

	// obs.dll is delay-loaded, so this is the first call into it: check it's
	// there instead of crashing.
	std::wstring obsdll = widen((engine.app_dir + "\\obs\\bin\\64bit\\obs.dll").c_str());
	if (GetFileAttributesW(obsdll.c_str()) == INVALID_FILE_ATTRIBUTES) {
		set_err(err, err_len, "libobs is missing (obs\\bin\\64bit\\obs.dll next to OmniCast.exe). Rebuild with windows\\build.ps1.");
		return 0;
	}

	std::string cfgdir = config_dir;
	while (!cfgdir.empty() && (cfgdir.back() == '\\' || cfgdir.back() == '/'))
		cfgdir.pop_back();
	open_log(cfgdir);
	blog(LOG_INFO, "[OmniCast] OmniCast for Windows starting, libobs %s", obs_get_version_string());

	if (!obs_startup("en-US", config_dir, nullptr)) {
		set_err(err, err_len, "libobs failed to start");
		return 0;
	}
	obs_add_data_path((engine.app_dir + "\\obs\\data\\libobs\\").c_str());

	obs_audio_info oai{};
	oai.samples_per_sec = 48000;
	oai.speakers = SPEAKERS_STEREO;
	if (!obs_reset_audio(&oai)) {
		set_err(err, err_len, "Audio setup failed");
		obs_shutdown();
		return 0;
	}

	obs_video_info ovi;
	fill_ovi(ovi, engine.wide_w, engine.wide_h, (uint32_t)engine.video.fps, "libobs-d3d11");
	int rv = obs_reset_video(&ovi);
	if (rv != OBS_VIDEO_SUCCESS) {
		set_err(err, err_len,
			rv == OBS_VIDEO_NOT_SUPPORTED ? "This GPU doesn't support Direct3D 11 feature level 10 or later"
						      : "Direct3D 11 failed to start (update the graphics driver)");
		obs_shutdown();
		return 0;
	}

	obs_load_all_modules();
	obs_log_loaded_modules();
	obs_post_load_modules();

	read_gpu_name();
	pick_encoder();

	if (!create_canvas_and_encoders(err, err_len)) {
		oc_shutdown();
		return 0;
	}
	obs_data_t *as = obs_data_create();
	obs_data_set_int(as, "bitrate", 160);
	engine.aenc = obs_audio_encoder_create("ffmpeg_aac", "AAC", as, 0, nullptr);
	obs_data_release(as);
	if (!engine.aenc) {
		set_err(err, err_len, "Could not create the AAC audio encoder");
		oc_shutdown();
		return 0;
	}
	obs_encoder_set_audio(engine.aenc, obs_get_audio());

	create_audio_sources();
	scenes_init();
	overlays_init();
	preview_register();

	blog(LOG_INFO, "[OmniCast] %ux%u + %ux%u at %d fps, GPU %s, encoder %s", engine.wide_w, engine.wide_h,
	     engine.tall_w, engine.tall_h, engine.video.fps, engine.gpu_name.c_str(), engine.encoder_id.c_str());
	engine.running = true;
	return 1;
}

static void probes_release();

OC_API void oc_shutdown(void)
{
	discord_outputs_stop();
	vcam_stop();
	outputs_stop_all_and_wait();
	probes_release();
	preview_detach_all();
	preview_unregister();
	app_channels_release();
	vst3_release();
	monitor_stop();
	audio_detach_all();
	overlays_release();
	scenes_release();
	obs_encoder_release(engine.aenc);
	engine.aenc = nullptr;
	release_canvas_and_encoders();
	for (uint32_t ch = 0; ch < APP_OUTPUT_BASE + OC_CH_COUNT; ch++)
		obs_set_output_source(ch, nullptr);
	for (obs_source_t **s : {&engine.mic, &engine.desktop}) {
		obs_source_release(*s);
		*s = nullptr;
	}
	obs_wait_for_destroy_queue();
	if (obs_initialized())
		obs_shutdown();
	std::string app = engine.app_dir, cfg = engine.config_dir;
	engine = Engine{};
	engine.app_dir = app;
	engine.config_dir = cfg;
}

OC_API int32_t oc_reset_video(const oc_video_config *video, char *err, int32_t err_len)
{
	if (!engine.running || !video) {
		set_err(err, err_len, "The engine isn't running");
		return 0;
	}
	if (outputs_active()) {
		set_err(err, err_len, "Stop streaming and recording first");
		return 0;
	}
	// Every canvas, encoder and preview depends on the video settings, so a
	// clean restart is the simplest correct change. The app re-attaches its
	// previews and re-applies its sources afterwards.
	std::string app = engine.app_dir, cfg = engine.config_dir;
	oc_shutdown();
	return oc_start(app.c_str(), cfg.c_str(), video, err, err_len);
}

OC_API const char *oc_encoder_name(void)
{
	return engine.encoder_name.c_str();
}

OC_API int32_t oc_encoder_is_gpu(void)
{
	return engine.encoder_gpu ? 1 : 0;
}

OC_API const char *oc_gpu_name(void)
{
	return engine.gpu_name.c_str();
}

static double process_cpu_percent()
{
	static ULONGLONG last_wall = 0, last_cpu = 0;
	FILETIME c, e, k, u, now;
	GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u);
	GetSystemTimeAsFileTime(&now);
	auto ft = [](FILETIME f) { return ((ULONGLONG)f.dwHighDateTime << 32) | f.dwLowDateTime; };
	ULONGLONG cpu = ft(k) + ft(u), wall = ft(now);
	double pct = 0;
	if (last_wall && wall > last_wall) {
		SYSTEM_INFO si;
		GetSystemInfo(&si);
		pct = 100.0 * (double)(cpu - last_cpu) / (double)(wall - last_wall) / (double)si.dwNumberOfProcessors;
	}
	last_wall = wall;
	last_cpu = cpu;
	return pct;
}

OC_API void oc_get_stats(oc_stats *st)
{
	if (!st)
		return;
	memset(st, 0, sizeof(*st));
	st->cpu_percent = process_cpu_percent();
	if (!engine.running)
		return;
	st->fps = obs_get_active_fps();
	st->render_ms = (double)obs_get_average_frame_time_ns() / 1e6;
	st->total_frames = obs_get_total_frames();
	st->lagged_frames = obs_get_lagged_frames();
	if (video_t *v = canvas_video(OC_WIDE))
		st->skipped_wide = video_output_get_skipped_frames(v);
	if (video_t *v = canvas_video(OC_TALL))
		st->skipped_tall = video_output_get_skipped_frames(v);
}

OC_API void oc_set_busy(int32_t busy)
{
	// Keep the PC awake (the display may still turn off).
	SetThreadExecutionState(busy ? (ES_CONTINUOUS | ES_SYSTEM_REQUIRED) : ES_CONTINUOUS);
	SetPriorityClass(GetCurrentProcess(), busy ? ABOVE_NORMAL_PRIORITY_CLASS : NORMAL_PRIORITY_CLASS);
	// EcoQoS off while busy, so Windows never parks the render/encode threads
	// on efficiency cores or at low clocks; back to Windows' choice when idle.
	PROCESS_POWER_THROTTLING_STATE pt{};
	pt.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
	pt.ControlMask = busy ? PROCESS_POWER_THROTTLING_EXECUTION_SPEED : 0;
	pt.StateMask = 0;
	SetProcessInformation(GetCurrentProcess(), ProcessPowerThrottling, &pt, sizeof(pt));
}

// ---------------------------------------------------------------------------
// Public: lists

static void append_list(std::string &out, obs_properties_t *props, const char *prop, bool &first)
{
	obs_property_t *p = props ? obs_properties_get(props, prop) : nullptr;
	if (!p)
		return;
	for (size_t i = 0; i < obs_property_list_item_count(p); i++) {
		const char *id = obs_property_list_item_string(p, i);
		const char *name = obs_property_list_item_name(p, i);
		if (!id || !*id || obs_property_list_item_disabled(p, i))
			continue;
		if (!first)
			out += ',';
		first = false;
		out += "{\"id\":\"" + json_escape(id) + "\",\"name\":\"" + json_escape(name) + "\"}";
	}
}

// A private, never-shown source of a type, just to read its property lists
// (some plugins need an instance to fill them). Not shown, so it captures nothing.
static obs_source_t *probes[8] = {};
static const char *probe_types[8] = {};

static void probes_release()
{
	for (int i = 0; i < 8; i++) {
		obs_source_release(probes[i]);
		probes[i] = nullptr;
		probe_types[i] = nullptr;
	}
}

obs_properties_t *oc::probe_properties(const char *type, const char *setting, const char *value)
{
	const char **types = probe_types;
	for (int i = 0; i < 8; i++) {
		if (types[i] && strcmp(types[i], type) == 0)
			return obs_source_properties(probes[i]);
		if (!types[i]) {
			obs_data_t *s = obs_data_create();
			if (setting)
				obs_data_set_string(s, setting, value);
			probes[i] = obs_source_create_private(type, "OmniCast probe", s);
			obs_data_release(s);
			if (!probes[i])
				return nullptr;
			types[i] = type;
			return obs_source_properties(probes[i]);
		}
	}
	return obs_get_source_properties(type);
}

OC_API char *oc_list(const char *what)
{
	std::string out = "[";
	bool first = true;
	if (engine.running && what) {
		obs_properties_t *props = nullptr;
		const char *prop = nullptr;
		if (!strcmp(what, "monitors")) {
			props = probe_properties("monitor_capture");
			prop = "monitor_id";
		} else if (!strcmp(what, "windows")) {
			props = probe_properties("window_capture");
			prop = "window";
		} else if (!strcmp(what, "games")) {
			props = probe_properties("game_capture");
			prop = "window";
		} else if (!strcmp(what, "video_devices")) {
			props = probe_properties("dshow_input", "video_device_id", "");
			prop = "video_device_id";
		} else if (!strcmp(what, "audio_inputs")) {
			props = obs_get_source_properties("wasapi_input_capture");
			prop = "device_id";
		} else if (!strcmp(what, "audio_outputs")) {
			props = obs_get_source_properties("wasapi_output_capture");
			prop = "device_id";
		} else if (!strcmp(what, "loopback_outputs")) {
			list_loopback_outputs(out, first);
		} else if (!strcmp(what, "vst3")) {
			list_vst3(out, first);
		} else if (!strcmp(what, "audio_apps")) {
			list_audio_apps(out, first);
		}
		append_list(out, props, prop, first);
		obs_properties_destroy(props);
	}
	out += "]";
	char *mem = (char *)CoTaskMemAlloc(out.size() + 1);
	if (mem)
		memcpy(mem, out.c_str(), out.size() + 1);
	return mem;
}

OC_API void oc_free(void *p)
{
	CoTaskMemFree(p);
}

// The id of the monitor Windows calls primary (OBS marks it in the list), or
// the first one.
std::string oc::primary_monitor_id()
{
	std::string first, primary;
	obs_properties_t *props = probe_properties("monitor_capture");
	obs_property_t *p = props ? obs_properties_get(props, "monitor_id") : nullptr;
	for (size_t i = 0; p && i < obs_property_list_item_count(p); i++) {
		const char *id = obs_property_list_item_string(p, i);
		const char *name = obs_property_list_item_name(p, i);
		if (!id || !*id || !strcmp(id, "DUMMY"))
			continue;
		if (first.empty())
			first = id;
		if (name && strstr(name, "Primary") && primary.empty())
			primary = id;
	}
	obs_properties_destroy(props);
	return primary.empty() ? first : primary;
}

// ---------------------------------------------------------------------------
// Public: sources

static void set_audio_device(obs_source_t *src, const char *id)
{
	if (!src)
		return;
	obs_data_t *s = obs_data_create();
	obs_data_set_string(s, "device_id", id && *id ? id : "default");
	obs_source_update(src, s);
	obs_data_release(s);
}

OC_API void oc_mic_set_device(const char *id)
{
	set_audio_device(engine.mic, id);
}

OC_API void oc_desktop_set_device(const char *id)
{
	if (!engine.running)
		return;
	bool follow = !id || !*id || !strcmp(id, "default");
	bool is_system = engine.desktop && !strcmp(obs_source_get_id(engine.desktop), "omni_proc_audio");
	if (engine.desktop && !is_system && !(follow && proc_audio_supported())) {
		set_audio_device(engine.desktop, id); // device to device
		return;
	}
	if (engine.desktop && is_system && follow)
		return;
	audio_attach(OC_CH_DESKTOP, nullptr);
	obs_set_output_source(1, nullptr);
	obs_source_release(engine.desktop);
	engine.desktop = make_desktop(id);
	if (engine.desktop)
		obs_set_output_source(1, engine.desktop);
	audio_attach(OC_CH_DESKTOP, engine.desktop);
}
