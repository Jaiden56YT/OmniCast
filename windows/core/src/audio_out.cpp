// Discord outputs: a mix played into a virtual audio cable (VB-CABLE,
// Voicemeeter), whose other end Discord picks as a microphone.
//
//   Voice    mix 3: the mic alone, after its level and mute (and later its
//            plugins). Discord's input device = CABLE Output.
//   Go Live  mix 2: desktop audio and the capture card, without the mic, so
//            friends watching don't hear you twice.
//
// libobs hands each mix to a raw audio callback on its audio thread (48 kHz
// stereo float). That callback only copies into a lock-free ring; a WASAPI
// render thread per output feeds the device from the ring, ~20-40 ms behind.
#include "internal.h"
#include "ring.h"

#include <windows.h>
#include <initguid.h> // defines the WASAPI and property-key GUIDs used below, once
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <ksmedia.h>
#include <functiondiscoverykeys_devpkey.h>
#include <thread>
#include <vector>

namespace oc {

static constexpr uint32_t RATE = 48000, CHANNELS = 2;

struct Output {
	size_t mix = 0;
	std::string device;
	Ring ring;
	std::thread thread;
	std::atomic<bool> stop{false};
	std::atomic<bool> running{false};
	bool hooked = false;
};

static Output outputs[2];

static void on_mix(void *param, size_t, struct audio_data *data)
{
	Output *o = (Output *)param;
	if (data && data->data[0] && o->running.load(std::memory_order_relaxed))
		o->ring.push((const float *)data->data[0], data->frames);
}

static void render(Output *o)
{
	CoInitializeEx(nullptr, COINIT_MULTITHREADED);
	IMMDeviceEnumerator *en = nullptr;
	IMMDevice *dev = nullptr;
	IAudioClient *client = nullptr;
	IAudioRenderClient *rc = nullptr;
	HANDLE ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
	std::wstring id = widen(o->device.c_str());
	UINT32 frames = 0;

	WAVEFORMATEXTENSIBLE fmt{};
	fmt.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
	fmt.Format.nChannels = CHANNELS;
	fmt.Format.nSamplesPerSec = RATE;
	fmt.Format.wBitsPerSample = 32;
	fmt.Format.nBlockAlign = CHANNELS * 4;
	fmt.Format.nAvgBytesPerSec = RATE * fmt.Format.nBlockAlign;
	fmt.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
	fmt.Samples.wValidBitsPerSample = 32;
	fmt.dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
	fmt.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;

	// Shared mode with Windows converting to the device's own format, so any
	// cable setting (44.1/48 kHz, 2-16 channels) works.
	bool ok = SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), (void **)&en)) &&
		  SUCCEEDED(en->GetDevice(id.c_str(), &dev)) &&
		  SUCCEEDED(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void **)&client)) &&
		  SUCCEEDED(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
					       AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
						       AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
					       200000 /* 20 ms */, 0, (WAVEFORMATEX *)&fmt, nullptr)) &&
		  SUCCEEDED(client->SetEventHandle(ev)) && SUCCEEDED(client->GetBufferSize(&frames)) &&
		  SUCCEEDED(client->GetService(__uuidof(IAudioRenderClient), (void **)&rc)) && SUCCEEDED(client->Start());

	if (!ok) {
		blog(LOG_WARNING, "[OmniCast] Discord output: couldn't open %s", o->device.c_str());
	} else {
		blog(LOG_INFO, "[OmniCast] Discord output on mix %zu -> %s (%u-frame buffer)", o->mix + 1, o->device.c_str(), frames);
		const size_t max_backlog = RATE / 10; // keep it under 100 ms behind
		while (!o->stop.load()) {
			if (WaitForSingleObject(ev, 200) != WAIT_OBJECT_0)
				continue;
			UINT32 padding = 0;
			if (FAILED(client->GetCurrentPadding(&padding)))
				break; // device unplugged or disabled
			UINT32 room = frames - padding;
			if (!room)
				continue;
			size_t backlog = o->ring.available();
			if (backlog > max_backlog)
				o->ring.skip(backlog - max_backlog / 2);
			BYTE *out = nullptr;
			if (FAILED(rc->GetBuffer(room, &out)))
				break;
			size_t got = o->ring.pop((float *)out, room);
			// Not enough audio yet (start-up, or libobs is a tick behind): fill with silence.
			if (got < room)
				memset((float *)out + got * CHANNELS, 0, (room - got) * CHANNELS * sizeof(float));
			rc->ReleaseBuffer(room, 0);
		}
		client->Stop();
	}
	o->running = false;
	if (rc) rc->Release();
	if (client) client->Release();
	if (dev) dev->Release();
	if (en) en->Release();
	CloseHandle(ev);
	CoUninitialize();
}

static void stop_output(int which)
{
	Output &o = outputs[which];
	if (o.hooked) {
		obs_remove_raw_audio_callback(o.mix, on_mix, &o);
		o.hooked = false;
	}
	o.stop = true;
	if (o.thread.joinable())
		o.thread.join();
	o.running = false;
	o.device.clear();
}

void discord_outputs_stop()
{
	stop_output(OC_DISCORD_VOICE);
	stop_output(OC_DISCORD_GO_LIVE);
}

// Render devices that are virtual cables: VB-CABLE (all versions) and
// Voicemeeter's inputs. Ordinary speakers aren't offered: Discord can't hear them.
void list_loopback_outputs(std::string &json, bool &first)
{
	IMMDeviceEnumerator *en = nullptr;
	IMMDeviceCollection *all = nullptr;
	if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), (void **)&en)))
		return;
	UINT count = 0;
	if (SUCCEEDED(en->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &all)))
		all->GetCount(&count);
	for (UINT i = 0; i < count; i++) {
		IMMDevice *dev = nullptr;
		IPropertyStore *props = nullptr;
		LPWSTR id = nullptr;
		if (FAILED(all->Item(i, &dev)) || FAILED(dev->GetId(&id)) || FAILED(dev->OpenPropertyStore(STGM_READ, &props))) {
			if (dev) dev->Release();
			continue;
		}
		PROPVARIANT name, driver;
		PropVariantInit(&name);
		PropVariantInit(&driver);
		props->GetValue(PKEY_Device_FriendlyName, &name);
		props->GetValue(PKEY_DeviceInterface_FriendlyName, &driver);
		std::string n = name.vt == VT_LPWSTR ? narrow(name.pwszVal) : "";
		std::string d = driver.vt == VT_LPWSTR ? narrow(driver.pwszVal) : "";
		auto has = [](const std::string &s, const char *what) {
			std::string a = s, b = what;
			for (auto &c : a) c = (char)tolower((unsigned char)c);
			for (auto &c : b) c = (char)tolower((unsigned char)c);
			return a.find(b) != std::string::npos;
		};
		if (has(d, "vb-audio") || has(d, "voicemeeter") || has(n, "vb-audio") || has(n, "voicemeeter")) {
			if (!first)
				json += ',';
			first = false;
			json += "{\"id\":\"" + json_escape(narrow(id).c_str()) + "\",\"name\":\"" + json_escape(n.c_str()) + "\"}";
		}
		PropVariantClear(&name);
		PropVariantClear(&driver);
		CoTaskMemFree(id);
		props->Release();
		dev->Release();
	}
	if (all) all->Release();
	en->Release();
}

} // namespace oc

using namespace oc;

OC_API int32_t oc_discord_output_set(int32_t which, const char *device_id)
{
	if (which != OC_DISCORD_VOICE && which != OC_DISCORD_GO_LIVE)
		return 0;
	std::string dev = device_id ? device_id : "";
	Output &o = outputs[which];
	if (dev == o.device && (dev.empty() || o.running))
		return o.running ? 1 : 0;
	stop_output(which);
	if (dev.empty() || !engine.running)
		return 0;

	// One device can't be both: Discord would get the mic and the game mixed.
	Output &other = outputs[which == OC_DISCORD_VOICE ? OC_DISCORD_GO_LIVE : OC_DISCORD_VOICE];
	if (other.device == dev)
		stop_output(which == OC_DISCORD_VOICE ? OC_DISCORD_GO_LIVE : OC_DISCORD_VOICE);

	o.mix = which == OC_DISCORD_VOICE ? 2 : 1; // track 3 = mic, track 2 = desktop + capture card
	o.device = dev;
	o.ring.reset(RATE / 4); // 250 ms of room
	o.stop = false;
	o.running = true;
	audio_convert_info conv{};
	conv.samples_per_sec = RATE;
	conv.format = AUDIO_FORMAT_FLOAT;
	conv.speakers = SPEAKERS_STEREO;
	obs_add_raw_audio_callback(o.mix, &conv, on_mix, &o);
	o.hooked = true;
	o.thread = std::thread(render, &o);
	// Give the device a moment to open, so the answer means something.
	for (int i = 0; i < 20 && o.running; i++)
		Sleep(10);
	return o.running ? 1 : 0;
}

OC_API int32_t oc_discord_output_running(int32_t which)
{
	if (which != OC_DISCORD_VOICE && which != OC_DISCORD_GO_LIVE)
		return 0;
	return outputs[which].running ? 1 : 0;
}
