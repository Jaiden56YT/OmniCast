// Per-app audio and system audio, from WASAPI process loopback (Windows 10
// 2004+). One libobs source type, "omni_proc_audio":
//
//   app     every process tree whose root is <exe> (Chrome, Discord and
//           Spotify play from child processes, which the tree includes).
//   system  everything except OmniCast and the apps that have their own
//           channel, so nothing is heard twice on stream and OmniCast never
//           hears its own headphones mix. With no app channels that's one
//           capture of "all but OmniCast". With app channels it's one capture
//           per other process that has an audio session (Windows can only
//           exclude one process tree per capture).
//
// Windows can't silence an app at its source while still letting a loopback
// hear it (muting the app's session silences the capture too), so apps keep
// playing through the speakers as usual; the monitor mix is for what you
// can't otherwise hear.
//
// Each process capture runs on its own thread into a ring; the source's
// worker thread mixes the rings every 10 ms into the source.
#include "internal.h"
#include "ring.h"

#include <util/platform.h>

#include <windows.h>
#include <tlhelp32.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <audiopolicy.h>
#include <wrl/implements.h>

#include <algorithm>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <thread>
#include <unordered_map>
#include <unordered_set>

using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::FtmBase;
using Microsoft::WRL::Make;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;

namespace oc {

static constexpr uint32_t RATE = 48000;
static constexpr size_t PRIME = 960, DRIFT_MAX = 4800, DRIFT_TARGET = 1024, MAX_CAPTURES = 32;

static std::string lower(std::string s)
{
	for (auto &c : s)
		c = (char)tolower((unsigned char)c);
	return s;
}

// Exes of the apps that have their own channel (lower case); system audio leaves them out.
static std::mutex claimed_mx;
static std::multiset<std::string> claimed_exes;
static std::atomic<uint32_t> claimed_gen{0};

// ---------------------------------------------------------------- one process capture

struct ActivateHandler : RuntimeClass<RuntimeClassFlags<ClassicCom>, FtmBase, IActivateAudioInterfaceCompletionHandler> {
	HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
	IAudioClient *client = nullptr;
	~ActivateHandler() { CloseHandle(done); }
	STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation *op) override
	{
		HRESULT hr = E_FAIL;
		IUnknown *unk = nullptr;
		if (SUCCEEDED(op->GetActivateResult(&hr, &unk)) && SUCCEEDED(hr) && unk)
			unk->QueryInterface(IID_PPV_ARGS(&client));
		if (unk)
			unk->Release();
		SetEvent(done);
		return S_OK;
	}
};

struct Capture {
	DWORD pid = 0;
	bool exclude = false; // capture everything except this tree
	Ring ring;
	bool primed = false;
	std::thread thread;
	std::atomic<bool> stop{false};
	std::atomic<bool> alive{true};

	void run()
	{
		CoInitializeEx(nullptr, COINIT_MULTITHREADED);
		AUDIOCLIENT_ACTIVATION_PARAMS ap{};
		ap.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
		ap.ProcessLoopbackParams.TargetProcessId = pid;
		ap.ProcessLoopbackParams.ProcessLoopbackMode = exclude ? PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE
								       : PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
		PROPVARIANT pv{};
		pv.vt = VT_BLOB;
		pv.blob.cbSize = sizeof(ap);
		pv.blob.pBlobData = (BYTE *)&ap;

		auto handler = Make<ActivateHandler>();
		IActivateAudioInterfaceAsyncOperation *op = nullptr;
		IAudioClient *client = nullptr;
		IAudioCaptureClient *cap = nullptr;
		HANDLE ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
		WAVEFORMATEX wf{WAVE_FORMAT_IEEE_FLOAT, 2, RATE, RATE * 8, 8, 32, 0};

		if (SUCCEEDED(ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient), &pv,
							  handler.Get(), &op)) &&
		    WaitForSingleObject(handler->done, 5000) == WAIT_OBJECT_0)
			client = handler->client;
		bool ok = client &&
			  SUCCEEDED(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
						       AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 200000, 0,
						       &wf, nullptr)) &&
			  SUCCEEDED(client->SetEventHandle(ev)) && SUCCEEDED(client->GetService(IID_PPV_ARGS(&cap))) &&
			  SUCCEEDED(client->Start());
		if (!ok) {
			blog(LOG_WARNING, "[OmniCast] process audio: couldn't capture pid %lu", pid);
		} else {
			while (!stop.load()) {
				if (WaitForSingleObject(ev, 100) != WAIT_OBJECT_0)
					continue;
				UINT32 packet = 0;
				while (SUCCEEDED(cap->GetNextPacketSize(&packet)) && packet) {
					BYTE *data = nullptr;
					UINT32 frames = 0;
					DWORD flags = 0;
					if (FAILED(cap->GetBuffer(&data, &frames, &flags, nullptr, nullptr)))
						break;
					if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
						static const float zeros[2 * 1024] = {};
						for (UINT32 done = 0; done < frames;) {
							UINT32 n = std::min<UINT32>(frames - done, 1024);
							ring.push(zeros, n);
							done += n;
						}
					} else {
						ring.push((const float *)data, frames);
					}
					cap->ReleaseBuffer(frames);
				}
			}
			client->Stop();
		}
		alive = false;
		if (cap) cap->Release();
		if (client) client->Release();
		if (op) op->Release();
		CloseHandle(ev);
		CoUninitialize();
	}
};

// ---------------------------------------------------------------- process snapshot

struct Proc {
	DWORD ppid;
	std::string exe;
};
using ProcMap = std::unordered_map<DWORD, Proc>;

static ProcMap snapshot()
{
	ProcMap m;
	HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
	if (snap == INVALID_HANDLE_VALUE)
		return m;
	PROCESSENTRY32W pe{sizeof(pe)};
	for (BOOL ok = Process32FirstW(snap, &pe); ok; ok = Process32NextW(snap, &pe))
		m[pe.th32ProcessID] = {pe.th32ParentProcessID, lower(narrow(pe.szExeFile))};
	CloseHandle(snap);
	return m;
}

// The process and everything it started (by parent id; pid reuse can make loops).
static void add_tree(const ProcMap &procs, const std::unordered_multimap<DWORD, DWORD> &kids, DWORD root,
		     std::unordered_set<DWORD> &out)
{
	std::vector<DWORD> todo{root};
	while (!todo.empty()) {
		DWORD p = todo.back();
		todo.pop_back();
		if (!out.insert(p).second)
			continue;
		auto range = kids.equal_range(p);
		for (auto it = range.first; it != range.second; ++it)
			todo.push_back(it->second);
	}
	(void)procs;
}

static std::unordered_multimap<DWORD, DWORD> children(const ProcMap &procs)
{
	std::unordered_multimap<DWORD, DWORD> kids;
	for (auto &[pid, p] : procs)
		if (p.ppid != pid && p.ppid != 0)
			kids.emplace(p.ppid, pid);
	return kids;
}

// Roots of every running copy of exe: processes named exe whose parent isn't.
static std::vector<DWORD> roots_of(const ProcMap &procs, const std::string &exe)
{
	std::vector<DWORD> out;
	for (auto &[pid, p] : procs) {
		if (p.exe != exe || pid == GetCurrentProcessId())
			continue;
		auto parent = procs.find(p.ppid);
		if (parent == procs.end() || parent->second.exe != exe)
			out.push_back(pid);
	}
	return out;
}

// Processes with an audio session on any active output device.
static std::set<DWORD> session_pids()
{
	std::set<DWORD> out;
	IMMDeviceEnumerator *en = nullptr;
	IMMDeviceCollection *all = nullptr;
	if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&en))))
		return out;
	UINT count = 0;
	if (SUCCEEDED(en->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &all)))
		all->GetCount(&count);
	for (UINT i = 0; i < count; i++) {
		IMMDevice *dev = nullptr;
		IAudioSessionManager2 *mgr = nullptr;
		IAudioSessionEnumerator *se = nullptr;
		int n = 0;
		if (SUCCEEDED(all->Item(i, &dev)) &&
		    SUCCEEDED(dev->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr, (void **)&mgr)) &&
		    SUCCEEDED(mgr->GetSessionEnumerator(&se)) && SUCCEEDED(se->GetCount(&n))) {
			for (int k = 0; k < n; k++) {
				IAudioSessionControl *c = nullptr;
				IAudioSessionControl2 *c2 = nullptr;
				DWORD pid = 0;
				AudioSessionState state = AudioSessionStateExpired;
				if (SUCCEEDED(se->GetSession(k, &c)) && SUCCEEDED(c->QueryInterface(IID_PPV_ARGS(&c2))) &&
				    SUCCEEDED(c2->GetProcessId(&pid)) && SUCCEEDED(c->GetState(&state)) && pid &&
				    state != AudioSessionStateExpired)
					out.insert(pid);
				if (c2) c2->Release();
				if (c) c->Release();
			}
		}
		if (se) se->Release();
		if (mgr) mgr->Release();
		if (dev) dev->Release();
	}
	if (all) all->Release();
	en->Release();
	return out;
}

// ---------------------------------------------------------------- the source

struct ProcAudio {
	obs_source_t *source = nullptr;
	std::string exe; // lower case; "" for system
	bool system = false;
	std::thread worker;
	std::atomic<bool> stop{false};
	HANDLE wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
	std::map<std::pair<DWORD, bool>, std::unique_ptr<Capture>> caps; // (pid, exclude)

	~ProcAudio() { CloseHandle(wake); }

	std::set<std::pair<DWORD, bool>> targets()
	{
		std::set<std::pair<DWORD, bool>> want;
		ProcMap procs = snapshot();
		if (!system) {
			// Never a tree OmniCast is inside (that would capture our own monitor mix).
			auto kids = children(procs);
			for (DWORD pid : roots_of(procs, exe)) {
				std::unordered_set<DWORD> tree;
				add_tree(procs, kids, pid, tree);
				if (!tree.count(GetCurrentProcessId()))
					want.insert({pid, false});
			}
			return want;
		}
		std::vector<std::string> claimed;
		{
			std::lock_guard<std::mutex> lock(claimed_mx);
			claimed.assign(claimed_exes.begin(), claimed_exes.end());
		}
		DWORD self = GetCurrentProcessId();
		if (claimed.empty()) {
			want.insert({self, true}); // everything but OmniCast
			return want;
		}
		auto kids = children(procs);
		std::unordered_set<DWORD> taken;
		add_tree(procs, kids, self, taken);
		for (auto &e : claimed)
			for (DWORD root : roots_of(procs, e))
				add_tree(procs, kids, root, taken);
		std::vector<DWORD> cands;
		for (DWORD pid : session_pids()) {
			if (taken.count(pid) || !procs.count(pid))
				continue;
			// A launcher whose children have their own channel (e.g. a game
			// started from Steam): capturing its tree would include them.
			std::unordered_set<DWORD> tree;
			add_tree(procs, kids, pid, tree);
			bool clash = false;
			for (DWORD t : tree)
				if (taken.count(t)) {
					clash = true;
					break;
				}
			if (!clash)
				cands.push_back(pid);
		}
		// Drop candidates already inside another candidate's tree.
		std::unordered_set<DWORD> covered;
		for (DWORD c : cands) {
			std::unordered_set<DWORD> tree;
			add_tree(procs, kids, c, tree);
			tree.erase(c);
			covered.insert(tree.begin(), tree.end());
		}
		for (DWORD c : cands)
			if (!covered.count(c) && want.size() < MAX_CAPTURES)
				want.insert({c, false});
		return want;
	}

	void rescan()
	{
		auto want = targets();
		for (auto it = caps.begin(); it != caps.end();) {
			if (!want.count(it->first) || !it->second->alive) {
				it->second->stop = true;
				if (it->second->thread.joinable())
					it->second->thread.join();
				it = caps.erase(it);
			} else {
				++it;
			}
		}
		for (auto &key : want) {
			if (caps.count(key))
				continue;
			blog(LOG_INFO, "[OmniCast] %s audio: capturing %s pid %lu", system ? "desktop" : exe.c_str(),
			     key.second ? "everything except" : "", key.first);
			auto c = std::make_unique<Capture>();
			c->pid = key.first;
			c->exclude = key.second;
			c->ring.reset(RATE / 3);
			Capture *raw = c.get();
			c->thread = std::thread([raw] { raw->run(); });
			caps[key] = std::move(c);
		}
	}

	void run()
	{
		CoInitializeEx(nullptr, COINIT_MULTITHREADED);
		HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
		if (!timer)
			timer = CreateWaitableTimerW(nullptr, FALSE, nullptr);
		LARGE_INTEGER due{};
		due.QuadPart = -100000; // 10 ms
		SetWaitableTimer(timer, &due, 10, nullptr, nullptr, FALSE);

		std::vector<float> mix;
		uint64_t t0 = os_gettime_ns(), produced = 0, last_scan = 0;
		uint32_t seen_gen = claimed_gen.load() - 1;
		HANDLE waits[2] = {timer, wake};
		while (!stop.load()) {
			WaitForMultipleObjects(2, waits, FALSE, 100);
			uint64_t now = os_gettime_ns();
			if (now - last_scan > 1000000000ULL || seen_gen != claimed_gen.load()) {
				seen_gen = claimed_gen.load();
				rescan();
				last_scan = now;
			}
			uint64_t want = (now - t0) * RATE / 1000000000ULL;
			if (want < produced + 240)
				continue;
			size_t frames = (size_t)(want - produced);
			if (frames > DRIFT_MAX) { // we were held up: start the clock again
				t0 = now - 10000000ULL;
				produced = 0;
				frames = RATE / 100;
			}
			if (caps.empty()) {
				produced += frames;
				continue;
			}
			mix.assign(frames * 2, 0.0f);
			for (auto &[key, c] : caps) {
				size_t avail = c->ring.available();
				if (!c->primed && avail >= PRIME)
					c->primed = true;
				if (!c->primed)
					continue;
				if (avail > DRIFT_MAX)
					c->ring.skip(avail - DRIFT_TARGET);
				if (c->ring.mix_into(mix.data(), frames, 1.0f, 1.0f) < frames)
					c->primed = false; // ran dry: wait for a cushion again
			}
			obs_source_audio a{};
			a.data[0] = (const uint8_t *)mix.data();
			a.frames = (uint32_t)frames;
			a.speakers = SPEAKERS_STEREO;
			a.format = AUDIO_FORMAT_FLOAT;
			a.samples_per_sec = RATE;
			a.timestamp = t0 + produced * 1000000000ULL / RATE;
			obs_source_output_audio(source, &a);
			produced += frames;
		}
		for (auto &[key, c] : caps) {
			c->stop = true;
			if (c->thread.joinable())
				c->thread.join();
		}
		caps.clear();
		CancelWaitableTimer(timer);
		CloseHandle(timer);
		CoUninitialize();
	}
};

static const char *pa_name(void *)
{
	return "OmniCast process audio";
}

static void *pa_create(obs_data_t *settings, obs_source_t *source)
{
	auto *pa = new ProcAudio;
	pa->source = source;
	pa->exe = lower(obs_data_get_string(settings, "exe"));
	pa->system = obs_data_get_bool(settings, "system");
	pa->worker = std::thread([pa] { pa->run(); });
	return pa;
}

static void pa_destroy(void *data)
{
	auto *pa = (ProcAudio *)data;
	pa->stop = true;
	SetEvent(pa->wake);
	if (pa->worker.joinable())
		pa->worker.join();
	delete pa;
}

void proc_audio_register()
{
	static obs_source_info info = {};
	info.id = "omni_proc_audio";
	info.type = OBS_SOURCE_TYPE_INPUT;
	info.output_flags = OBS_SOURCE_AUDIO | OBS_SOURCE_DO_NOT_DUPLICATE;
	info.get_name = pa_name;
	info.create = pa_create;
	info.destroy = pa_destroy;
	obs_register_source(&info);
}

bool proc_audio_supported()
{
	// Process loopback arrived in Windows 10 2004 (build 19041).
	OSVERSIONINFOEXW v{sizeof(v)};
	v.dwBuildNumber = 19041;
	DWORDLONG mask = VerSetConditionMask(0, VER_BUILDNUMBER, VER_GREATER_EQUAL);
	return VerifyVersionInfoW(&v, VER_BUILDNUMBER, mask) != FALSE;
}

obs_source_t *create_system_audio()
{
	obs_data_t *s = obs_data_create();
	obs_data_set_bool(s, "system", true);
	obs_source_t *src = obs_source_create("omni_proc_audio", "Desktop Audio", s, nullptr);
	obs_data_release(s);
	return src;
}

// ---------------------------------------------------------------- app channels

static const char *DISCORD_EXES[] = {"discord.exe", "discordcanary.exe", "discordptb.exe", "vesktop.exe", "legcord.exe"};

bool is_discord_exe(const std::string &exe)
{
	std::string e = lower(exe);
	for (const char *d : DISCORD_EXES)
		if (e == d)
			return true;
	return false;
}

struct AppChannel {
	obs_source_t *source = nullptr;
	std::string exe;
};
static AppChannel apps[OC_CH_COUNT];

void app_channels_release()
{
	for (int i = OC_CH_APP_FIRST; i < OC_CH_COUNT; i++)
		oc_app_channel_remove(i);
}

// Running apps with a window, for the "+" menu: [{"id":exe,"name":...,"path":...}].
static BOOL CALLBACK add_window_app(HWND hwnd, LPARAM param)
{
	auto *found = (std::map<std::string, std::pair<std::string, std::string>> *)param;
	if (!IsWindowVisible(hwnd) || GetWindow(hwnd, GW_OWNER) || GetWindowTextLengthW(hwnd) == 0)
		return TRUE;
	LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
	if (ex & WS_EX_TOOLWINDOW)
		return TRUE;
	DWORD pid = 0;
	GetWindowThreadProcessId(hwnd, &pid);
	if (pid == GetCurrentProcessId())
		return TRUE;
	HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
	if (!h)
		return TRUE;
	wchar_t path[MAX_PATH * 2];
	DWORD len = MAX_PATH * 2;
	if (QueryFullProcessImageNameW(h, 0, path, &len)) {
		std::wstring wp(path, len);
		std::wstring file = wp.substr(wp.find_last_of(L'\\') + 1);
		std::string exe = lower(narrow(file.c_str()));
		static const char *skip[] = {"explorer.exe", "applicationframehost.exe", "textinputhost.exe",
					     "systemsettings.exe", "shellexperiencehost.exe", "searchhost.exe"};
		bool skipped = false;
		for (const char *s : skip)
			skipped |= exe == s;
		if (!skipped && !found->count(exe)) {
			// The app's own name from its version info ("Google Chrome"), else the exe.
			std::string name;
			DWORD vlen = GetFileVersionInfoSizeW(wp.c_str(), nullptr);
			if (vlen) {
				std::vector<BYTE> ver(vlen);
				struct Lang {
					WORD lang, cp;
				} *langs = nullptr;
				UINT n = 0;
				if (GetFileVersionInfoW(wp.c_str(), 0, vlen, ver.data()) &&
				    VerQueryValueW(ver.data(), L"\\VarFileInfo\\Translation", (void **)&langs, &n) && n >= sizeof(Lang)) {
					wchar_t key[64];
					wchar_t *val = nullptr;
					UINT vl = 0;
					for (const wchar_t *field : {L"FileDescription", L"ProductName"}) {
						swprintf(key, 64, L"\\StringFileInfo\\%04x%04x\\%s", langs[0].lang, langs[0].cp, field);
						if (VerQueryValueW(ver.data(), key, (void **)&val, &vl) && vl > 1 && val[0]) {
							name = narrow(val);
							break;
						}
					}
				}
			}
			if (name.empty())
				name = narrow(file.substr(0, file.size() > 4 ? file.size() - 4 : file.size()).c_str());
			(*found)[exe] = {name, narrow(wp.c_str())};
		}
	}
	CloseHandle(h);
	return TRUE;
}

void list_audio_apps(std::string &json, bool &first)
{
	std::map<std::string, std::pair<std::string, std::string>> found;
	EnumWindows(add_window_app, (LPARAM)&found);
	std::vector<std::pair<std::string, std::pair<std::string, std::string>>> sorted(found.begin(), found.end());
	std::sort(sorted.begin(), sorted.end(), [](auto &a, auto &b) { return lower(a.second.first) < lower(b.second.first); });
	for (auto &[exe, np] : sorted) {
		if (!first)
			json += ',';
		first = false;
		json += "{\"id\":\"" + json_escape(exe.c_str()) + "\",\"name\":\"" + json_escape(np.first.c_str()) +
			"\",\"path\":\"" + json_escape(np.second.c_str()) + "\"}";
	}
}

} // namespace oc

using namespace oc;

OC_API int32_t oc_app_channel_add(const char *exe)
{
	if (!engine.running || !exe || !*exe || !proc_audio_supported())
		return -1;
	std::string e = lower(exe);
	for (int i = OC_CH_APP_FIRST; i < OC_CH_COUNT; i++)
		if (apps[i].source && apps[i].exe == e)
			return i;
	int slot = -1;
	for (int i = OC_CH_APP_FIRST; i < OC_CH_COUNT && slot < 0; i++)
		if (!apps[i].source)
			slot = i;
	if (slot < 0)
		return -1;
	obs_data_t *s = obs_data_create();
	obs_data_set_string(s, "exe", e.c_str());
	obs_source_t *src = obs_source_create("omni_proc_audio", ("App: " + e).c_str(), s, nullptr);
	obs_data_release(s);
	if (!src)
		return -1;
	// Discord's own audio stays off the Go Live mix, or the call hears itself.
	obs_source_set_audio_mixers(src, is_discord_exe(e) ? MIX_ALL : (MIX_ALL | MIX_DESKTOP));
	obs_set_output_source(APP_OUTPUT_BASE + slot, src);
	apps[slot] = {src, e};
	{
		std::lock_guard<std::mutex> lock(claimed_mx);
		claimed_exes.insert(e);
	}
	claimed_gen++;
	audio_attach(slot, src);
	blog(LOG_INFO, "[OmniCast] app channel %d: %s", slot, e.c_str());
	return slot;
}

OC_API void oc_app_channel_remove(int32_t channel)
{
	if (channel < OC_CH_APP_FIRST || channel >= OC_CH_COUNT || !apps[channel].source)
		return;
	music_forget(apps[channel].source);
	audio_attach(channel, nullptr);
	obs_set_output_source(APP_OUTPUT_BASE + channel, nullptr);
	obs_source_release(apps[channel].source);
	{
		std::lock_guard<std::mutex> lock(claimed_mx);
		auto it = claimed_exes.find(apps[channel].exe);
		if (it != claimed_exes.end())
			claimed_exes.erase(it);
	}
	claimed_gen++;
	apps[channel] = {};
}

OC_API int32_t oc_app_audio_supported(void)
{
	return proc_audio_supported() ? 1 : 0;
}
