// Streaming (one RTMP output per destination, sharing its canvas's encoder) and
// recording (an MP4 per canvas).
#include "internal.h"

#include <windows.h>
#include <shlobj.h>
#include <cstdio>
#include <ctime>
#include <string>
#include <vector>

namespace oc {

static oc_status_cb status_cb = nullptr;
static oc_record_cb record_cb = nullptr;

// ---------------------------------------------------------------------------
// Streaming

struct Stream {
	obs_output_t *output = nullptr;
	obs_service_t *service = nullptr;
	int index = 0;
};

static std::vector<Stream *> streams;

static void report(int index, int state, const char *msg)
{
	if (status_cb)
		status_cb(index, state, msg ? msg : "");
}

static void on_starting(void *data, calldata_t *) { report(((Stream *)data)->index, OC_OUTPUT_CONNECTING, ""); }
static void on_start(void *data, calldata_t *) { report(((Stream *)data)->index, OC_OUTPUT_LIVE, ""); }
static void on_reconnect(void *data, calldata_t *) { report(((Stream *)data)->index, OC_OUTPUT_RECONNECTING, ""); }
static void on_reconnected(void *data, calldata_t *) { report(((Stream *)data)->index, OC_OUTPUT_LIVE, ""); }

static const char *stop_reason(int code)
{
	switch (code) {
	case OBS_OUTPUT_BAD_PATH: return "The server address is wrong";
	case OBS_OUTPUT_CONNECT_FAILED: return "Couldn't connect to the server";
	case OBS_OUTPUT_INVALID_STREAM: return "The server refused the stream key";
	case OBS_OUTPUT_DISCONNECTED: return "Disconnected";
	case OBS_OUTPUT_NO_SPACE: return "The disk is full";
	case OBS_OUTPUT_ENCODE_ERROR: return "The encoder failed";
	case OBS_OUTPUT_HDR_DISABLED: return "HDR isn't supported here";
	default: return "Stopped with an error";
	}
}

static void on_stop(void *data, calldata_t *cd)
{
	int code = (int)calldata_int(cd, "code");
	const char *last = calldata_string(cd, "last_error");
	std::string msg;
	if (code != OBS_OUTPUT_SUCCESS) {
		msg = stop_reason(code);
		if (last && *last)
			msg += std::string(": ") + last;
	}
	report(((Stream *)data)->index, code == OBS_OUTPUT_SUCCESS ? OC_OUTPUT_IDLE : OC_OUTPUT_FAILED, msg.c_str());
}

static void connect_stream_signals(Stream *s, bool on)
{
	signal_handler_t *sh = obs_output_get_signal_handler(s->output);
	auto f = on ? signal_handler_connect : signal_handler_disconnect;
	f(sh, "starting", on_starting, s);
	f(sh, "start", on_start, s);
	f(sh, "reconnect", on_reconnect, s);
	f(sh, "reconnect_success", on_reconnected, s);
	f(sh, "stop", on_stop, s);
}

static void release_streams()
{
	for (Stream *s : streams) {
		if (s->output) {
			connect_stream_signals(s, false);
			obs_output_release(s->output);
		}
		obs_service_release(s->service);
		delete s;
	}
	streams.clear();
}

// ---------------------------------------------------------------------------
// Recording

struct Recording {
	obs_output_t *output = nullptr;
	obs_encoder_t *venc = nullptr;       // own encoder (GPU), or nullptr when sharing the stream's
	obs_encoder_t *aenc[3] = {};
	std::string path;
	std::atomic<bool> active{false};
};

static Recording recordings[2];

static void on_record_start(void *data, calldata_t *)
{
	Recording *r = (Recording *)data;
	r->active = true;
	if (record_cb)
		record_cb(r == &recordings[OC_TALL] ? OC_TALL : OC_WIDE, 1, "");
}

static void on_record_stop(void *data, calldata_t *cd)
{
	Recording *r = (Recording *)data;
	r->active = false;
	int code = (int)calldata_int(cd, "code");
	std::string msg = code == OBS_OUTPUT_SUCCESS ? "" : stop_reason(code);
	if (record_cb)
		record_cb(r == &recordings[OC_TALL] ? OC_TALL : OC_WIDE, 0, msg.c_str());
}

static void release_recording(Recording &r)
{
	if (r.output) {
		signal_handler_t *sh = obs_output_get_signal_handler(r.output);
		signal_handler_disconnect(sh, "start", on_record_start, &r);
		signal_handler_disconnect(sh, "stop", on_record_stop, &r);
		obs_output_release(r.output);
		r.output = nullptr;
	}
	obs_encoder_release(r.venc);
	r.venc = nullptr;
	for (auto &a : r.aenc) {
		obs_encoder_release(a);
		a = nullptr;
	}
	r.active = false;
}

static bool any_recording()
{
	return recordings[0].active || recordings[1].active ||
	       (recordings[0].output && obs_output_active(recordings[0].output)) ||
	       (recordings[1].output && obs_output_active(recordings[1].output));
}

static void update_busy()
{
	oc_set_busy(oc_stream_active() || any_recording() ? 1 : 0);
}

bool outputs_active()
{
	return oc_stream_active() || any_recording();
}

void outputs_stop_all_and_wait()
{
	for (Stream *s : streams)
		if (s->output)
			obs_output_force_stop(s->output);
	release_streams();
	for (auto &r : recordings)
		if (r.output && obs_output_active(r.output))
			obs_output_stop(r.output);
	// Give the MP4s a moment to write their final index (they're playable anyway).
	for (int i = 0; i < 100 && any_recording(); i++)
		Sleep(50);
	for (auto &r : recordings)
		release_recording(r);
	oc_set_busy(0);
}

static std::string unique_path(const std::string &folder, const char *suffix)
{
	time_t t = time(nullptr);
	tm lt;
	localtime_s(&lt, &t);
	char stamp[64];
	strftime(stamp, sizeof(stamp), "%Y-%m-%d %H-%M-%S", &lt);
	std::string base = folder + "\\OmniCast " + stamp + " " + suffix;
	std::string path = base + ".mp4";
	for (int n = 2; GetFileAttributesW(widen(path.c_str()).c_str()) != INVALID_FILE_ATTRIBUTES; n++)
		path = base + " (" + std::to_string(n) + ").mp4";
	return path;
}

} // namespace oc

using namespace oc;

// ---------------------------------------------------------------------------
// Public: streaming

OC_API void oc_set_status_callback(oc_status_cb cb)
{
	status_cb = cb;
}

OC_API int32_t oc_stream_start(const oc_destination *dests, int32_t count, char *err, int32_t err_len)
{
	if (!engine.running) {
		set_err(err, err_len, "The engine isn't running");
		return 0;
	}
	if (oc_stream_active()) {
		set_err(err, err_len, "Already live");
		return 0;
	}
	if (!dests || count <= 0) {
		set_err(err, err_len, "Turn on at least one destination");
		return 0;
	}
	release_streams();
	int started = 0;
	for (int i = 0; i < count; i++) {
		const oc_destination &d = dests[i];
		Stream *s = new Stream();
		s->index = i;
		streams.push_back(s);

		obs_data_t *ss = obs_data_create();
		obs_data_set_string(ss, "server", d.server ? d.server : "");
		obs_data_set_string(ss, "key", d.key ? d.key : "");
		s->service = obs_service_create("rtmp_custom", d.name, ss, nullptr);
		obs_data_release(ss);

		s->output = obs_output_create("rtmp_output", d.name, nullptr, nullptr);
		if (!s->service || !s->output) {
			report(i, OC_OUTPUT_FAILED, "Couldn't create the RTMP output");
			continue;
		}
		int canvas = d.canvas == OC_TALL ? OC_TALL : OC_WIDE;
		// Every destination on a canvas shares its one encoder: a third 16:9
		// platform costs upload bandwidth, not CPU or GPU.
		obs_output_set_video_encoder(s->output, engine.venc[canvas]);
		obs_output_set_audio_encoder(s->output, engine.aenc, 0);
		obs_output_set_service(s->output, s->service);
		obs_output_set_reconnect_settings(s->output, 20, 3);
		connect_stream_signals(s, true);
		if (obs_output_start(s->output)) {
			started++;
		} else {
			const char *e = obs_output_get_last_error(s->output);
			report(i, OC_OUTPUT_FAILED, e && *e ? e : "Couldn't start");
		}
	}
	update_busy();
	if (!started) {
		set_err(err, err_len, "No destination could start");
		release_streams();
		update_busy();
		return 0;
	}
	return 1;
}

OC_API void oc_stream_stop(void)
{
	for (Stream *s : streams)
		if (s->output)
			obs_output_stop(s->output);
	// Outputs finish sending in the background; they're released on the next
	// start or at shutdown.
	update_busy();
}

OC_API int32_t oc_stream_active(void)
{
	for (Stream *s : streams)
		if (s->output && (obs_output_active(s->output) || obs_output_reconnecting(s->output)))
			return 1;
	return 0;
}

OC_API int32_t oc_stream_output_stats(int32_t index, int32_t *dropped, uint64_t *bytes)
{
	if (index < 0 || index >= (int)streams.size() || !streams[(size_t)index]->output)
		return 0;
	obs_output_t *o = streams[(size_t)index]->output;
	if (dropped)
		*dropped = obs_output_get_frames_dropped(o);
	if (bytes)
		*bytes = obs_output_get_total_bytes(o);
	return 1;
}

// ---------------------------------------------------------------------------
// Public: recording

OC_API void oc_set_record_callback(oc_record_cb cb)
{
	record_cb = cb;
}

OC_API int32_t oc_record_start(const oc_record_config *cfg, char *err, int32_t err_len)
{
	if (!engine.running || !cfg) {
		set_err(err, err_len, "The engine isn't running");
		return 0;
	}
	if (any_recording()) {
		set_err(err, err_len, "Already recording");
		return 0;
	}
	if (!cfg->wide && !cfg->tall) {
		set_err(err, err_len, "Choose 16:9, 9:16 or both to record");
		return 0;
	}
	std::string folder = cfg->folder ? cfg->folder : "";
	while (!folder.empty() && (folder.back() == '\\' || folder.back() == '/'))
		folder.pop_back();
	if (folder.empty()) {
		set_err(err, err_len, "Choose a folder for recordings");
		return 0;
	}
	int rc = SHCreateDirectoryExW(nullptr, widen(folder.c_str()).c_str(), nullptr);
	if (rc != ERROR_SUCCESS && rc != ERROR_ALREADY_EXISTS && rc != ERROR_FILE_EXISTS) {
		set_err(err, err_len, "Couldn't create the recordings folder");
		return 0;
	}

	const char *muxer = obs_get_output_flags("mp4_output") ? "mp4_output" : "ffmpeg_muxer";
	int tracks = cfg->split_audio ? 3 : 1;
	int started = 0;
	for (int c = 0; c < 2; c++) {
		if (!(c == OC_WIDE ? cfg->wide : cfg->tall))
			continue;
		Recording &r = recordings[c];
		release_recording(r);
		r.path = unique_path(folder, c == OC_WIDE ? "16x9" : "9x16");

		obs_data_t *s = obs_data_create();
		obs_data_set_string(s, "path", r.path.c_str());
		r.output = obs_output_create(muxer, c == OC_WIDE ? "16:9 recording" : "9:16 recording", s, nullptr);
		obs_data_release(s);
		if (!r.output)
			continue;

		// GPU: a separate constant-quality encode, sharp even if the stream is
		// at a low bitrate. CPU (x264): share the stream's encode, so recording
		// while live costs nothing extra on a low-end PC.
		obs_encoder_t *venc = engine.venc[c];
		if (engine.encoder_gpu) {
			r.venc = create_record_encoder(c == OC_WIDE ? "16:9 recording H.264" : "9:16 recording H.264",
						       cfg->quality);
			if (r.venc) {
				obs_encoder_set_video(r.venc, canvas_video(c));
				venc = r.venc;
			}
		}
		obs_output_set_video_encoder(r.output, venc);

		for (int t = 0; t < tracks; t++) {
			obs_data_t *as = obs_data_create();
			obs_data_set_int(as, "bitrate", 256);
			char name[48];
			snprintf(name, sizeof(name), "%s AAC track %d", c == OC_WIDE ? "16:9" : "9:16", t + 1);
			r.aenc[t] = obs_audio_encoder_create("ffmpeg_aac", name, as, (size_t)t, nullptr);
			obs_data_release(as);
			if (r.aenc[t]) {
				obs_encoder_set_audio(r.aenc[t], obs_get_audio());
				obs_output_set_audio_encoder(r.output, r.aenc[t], (size_t)t);
			}
		}

		signal_handler_t *sh = obs_output_get_signal_handler(r.output);
		signal_handler_connect(sh, "start", on_record_start, &r);
		signal_handler_connect(sh, "stop", on_record_stop, &r);
		if (obs_output_start(r.output)) {
			started++;
		} else {
			const char *e = obs_output_get_last_error(r.output);
			set_err(err, err_len, e && *e ? e : "Couldn't start the recording");
			release_recording(r);
		}
	}
	update_busy();
	return started > 0 ? 1 : 0;
}

OC_API void oc_record_stop(void)
{
	for (auto &r : recordings)
		if (r.output && obs_output_active(r.output))
			obs_output_stop(r.output);
	update_busy();
}

OC_API int32_t oc_record_active(void)
{
	return any_recording() ? 1 : 0;
}

OC_API const char *oc_record_path(int32_t canvas)
{
	if (canvas != OC_WIDE && canvas != OC_TALL)
		return "";
	return recordings[canvas].path.c_str();
}
