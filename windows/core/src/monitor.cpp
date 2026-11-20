// The monitor (headphones) mix: every channel at its own Monitor level, played
// on one output device. Separate from the stream: each channel's audio is
// taken after its filters (so the mic includes its plugins) and before its
// Stream level, into a ring per channel; a WASAPI render thread sums the rings.
//
// Rings: 16384 frames each. A ring is read once it holds 20 ms (960 frames);
// past 100 ms (4800) it skips ahead to ~21 ms (1024); when it runs dry it
// plays what it has and waits for 20 ms again. Gain changes ramp over one
// buffer. libobs's audio thread only touches atomics and the rings.
#include "internal.h"
#include "ring.h"

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <ksmedia.h>

#include <mutex>
#include <thread>

namespace oc {

static constexpr uint32_t RATE = 48000;
static constexpr size_t RING = 16384, PRIME = 960, DRIFT_MAX = 4800, DRIFT_TARGET = 1024;

struct MonitorChannel {
	obs_source_t *source = nullptr; // not owned
	std::atomic<float> gain{0.0f};
	float last = 0.0f;
	bool primed = false;
	std::atomic<bool> flush{false};
	Ring ring;
};

static MonitorChannel mon[OC_CH_COUNT];
static std::string device; // "" = the Windows default output
static std::thread thread;
static std::atomic<bool> stop{false};
static std::atomic<bool> running{false};
static std::mutex control;

static void on_audio(void *param, obs_source_t *, const struct audio_data *audio, bool)
{
	auto *ch = (MonitorChannel *)param;
	if (!running.load(std::memory_order_relaxed) || ch->gain.load(std::memory_order_relaxed) <= 0.0f && ch->last <= 0.0f)
		return;
	if (audio && audio->data[0])
		ch->ring.push_planar((const float *)audio->data[0], (const float *)audio->data[1], audio->frames);
}

void monitor_attach(int channel, obs_source_t *source)
{
	if (channel < 0 || channel >= OC_CH_COUNT)
		return;
	MonitorChannel &ch = mon[channel];
	if (ch.source)
		obs_source_remove_audio_capture_callback(ch.source, on_audio, &ch);
	ch.source = source;
	ch.flush = true;
	if (source)
		obs_source_add_audio_capture_callback(source, on_audio, &ch);
}

static std::wstring default_output_id(IMMDeviceEnumerator *en)
{
	IMMDevice *dev = nullptr;
	LPWSTR id = nullptr;
	std::wstring out;
	if (SUCCEEDED(en->GetDefaultAudioEndpoint(eRender, eConsole, &dev)) && SUCCEEDED(dev->GetId(&id)))
		out = id;
	CoTaskMemFree(id);
	if (dev)
		dev->Release();
	return out;
}

static void render(std::string want)
{
	CoInitializeEx(nullptr, COINIT_MULTITHREADED);
	IMMDeviceEnumerator *en = nullptr;
	CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&en));
	HANDLE ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);

	WAVEFORMATEXTENSIBLE fmt{};
	fmt.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
	fmt.Format.nChannels = 2;
	fmt.Format.nSamplesPerSec = RATE;
	fmt.Format.wBitsPerSample = 32;
	fmt.Format.nBlockAlign = 8;
	fmt.Format.nAvgBytesPerSec = RATE * 8;
	fmt.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
	fmt.Samples.wValidBitsPerSample = 32;
	fmt.dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
	fmt.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;

	// Reopens when the device goes away or, when following Windows, the default changes.
	while (en && !stop.load()) {
		std::wstring id = want.empty() ? default_output_id(en) : widen(want.c_str());
		IMMDevice *dev = nullptr;
		IAudioClient *client = nullptr;
		IAudioRenderClient *rc = nullptr;
		UINT32 frames = 0;
		bool ok = !id.empty() && SUCCEEDED(en->GetDevice(id.c_str(), &dev)) &&
			  SUCCEEDED(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void **)&client)) &&
			  SUCCEEDED(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
						       AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
							       AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
						       200000, 0, (WAVEFORMATEX *)&fmt, nullptr)) &&
			  SUCCEEDED(client->SetEventHandle(ev)) && SUCCEEDED(client->GetBufferSize(&frames)) &&
			  SUCCEEDED(client->GetService(IID_PPV_ARGS(&rc))) && SUCCEEDED(client->Start());
		if (!ok) {
			if (!want.empty()) {
				blog(LOG_WARNING, "[OmniCast] monitor: %s isn't available; using the default output", want.c_str());
				want.clear();
			} else {
				Sleep(1000); // no output device at all; try again
			}
		} else {
			blog(LOG_INFO, "[OmniCast] monitor output on %s", want.empty() ? "the default device" : want.c_str());
			for (auto &ch : mon)
				ch.flush = true;
			running = true;
			ULONGLONG last_check = GetTickCount64();
			while (!stop.load()) {
				if (WaitForSingleObject(ev, 200) != WAIT_OBJECT_0)
					continue;
				if (want.empty() && GetTickCount64() - last_check > 1000) {
					last_check = GetTickCount64();
					if (default_output_id(en) != id)
						break; // Windows switched outputs: follow it
				}
				UINT32 padding = 0;
				if (FAILED(client->GetCurrentPadding(&padding)))
					break;
				UINT32 room = frames - padding;
				if (!room)
					continue;
				BYTE *buf = nullptr;
				if (FAILED(rc->GetBuffer(room, &buf)))
					break;
				float *out = (float *)buf;
				memset(out, 0, room * 8);
				bool audible = false;
				for (auto &ch : mon) {
					if (ch.flush.exchange(false)) {
						ch.ring.clear();
						ch.primed = false;
					}
					float g = ch.gain.load(std::memory_order_relaxed);
					if (g <= 0.0f && ch.last <= 0.0f) {
						ch.ring.clear();
						ch.primed = false;
						continue;
					}
					size_t avail = ch.ring.available();
					if (!ch.primed && avail >= PRIME)
						ch.primed = true;
					if (!ch.primed)
						continue;
					if (avail > DRIFT_MAX)
						ch.ring.skip(avail - DRIFT_TARGET);
					if (ch.ring.mix_into(out, room, ch.last, g) < room)
						ch.primed = false;
					ch.last = g;
					audible = true;
				}
				rc->ReleaseBuffer(room, audible ? 0 : AUDCLNT_BUFFERFLAGS_SILENT);
			}
			running = false;
			client->Stop();
		}
		if (rc) rc->Release();
		if (client) client->Release();
		if (dev) dev->Release();
	}
	if (en)
		en->Release();
	CloseHandle(ev);
	CoUninitialize();
}

void monitor_start()
{
	for (auto &ch : mon)
		if (!ch.ring.capacity())
			ch.ring.reset(RING);
	stop = false;
	thread = std::thread(render, device);
}

void monitor_stop()
{
	stop = true;
	if (thread.joinable())
		thread.join();
	running = false;
	for (int i = 0; i < OC_CH_COUNT; i++)
		monitor_attach(i, nullptr);
}

} // namespace oc

using namespace oc;

OC_API void oc_monitor_set(int32_t channel, float gain, int32_t muted)
{
	if (channel < 0 || channel >= OC_CH_COUNT)
		return;
	mon[channel].gain = muted || gain < 0 ? 0.0f : gain;
}

OC_API void oc_monitor_set_device(const char *id)
{
	std::lock_guard<std::mutex> lock(control);
	std::string want = id ? id : "";
	if (want == device && thread.joinable())
		return;
	device = want;
	if (!engine.running)
		return;
	stop = true;
	if (thread.joinable())
		thread.join();
	stop = false;
	thread = std::thread(render, device);
}

OC_API int32_t oc_monitor_running(void)
{
	return running ? 1 : 0;
}
