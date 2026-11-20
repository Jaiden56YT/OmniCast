// Shared state inside OmniCore. Not part of the public API.
#pragma once

#define OMNICORE_BUILD
#include "omnicore.h"

#include <obs.h>
#include <atomic>
#include <string>

namespace oc {

struct Engine {
	bool running = false;
	oc_video_config video{};
	uint32_t wide_w = 0, wide_h = 0; // 16:9 canvas size
	uint32_t tall_w = 0, tall_h = 0; // 9:16 canvas size

	obs_canvas_t *tall_canvas = nullptr;

	obs_source_t *mic = nullptr;
	obs_source_t *desktop = nullptr;

	std::string encoder_id;   // H.264 encoder type for this PC
	std::string encoder_name; // shown in the app
	bool encoder_gpu = false;
	std::string gpu_name;
	obs_encoder_t *venc[2] = {}; // one stream encode per canvas
	obs_encoder_t *aenc = nullptr;

	std::string app_dir;
	std::string config_dir;
};

extern Engine engine;

// Audio mixes: 1 = everything (stream and recording track 1), 2 = desktop
// audio and the capture card (track 2), 3 = mic (track 3).
constexpr uint32_t MIX_ALL = 1 << 0, MIX_DESKTOP = 1 << 1, MIX_MIC = 1 << 2;
// App channel c plays on libobs output channel APP_OUTPUT_BASE + c.
constexpr uint32_t APP_OUTPUT_BASE = 8;

// engine.cpp
video_t *canvas_video(int canvas);
obs_encoder_t *create_record_encoder(const char *name, int quality);
// Property lists of a never-shown source of a type (for device/window lists).
obs_properties_t *probe_properties(const char *type, const char *setting = nullptr, const char *value = nullptr);
std::string primary_monitor_id();

// scenes.cpp
void scenes_init();    // transitions on both canvases' output channels
void scenes_release(); // every scene, shared source and transition

// audio_out.cpp
void discord_outputs_stop();
void list_loopback_outputs(std::string &json, bool &first);

// audio.cpp
void audio_attach(int channel, obs_source_t *source);
void audio_detach_all();

// preview.cpp
void preview_register();
void preview_unregister();
void preview_detach_all();

// proc_audio.cpp
void proc_audio_register();
bool proc_audio_supported();
obs_source_t *create_system_audio();
bool is_discord_exe(const std::string &exe);
void app_channels_release();
void list_audio_apps(std::string &json, bool &first);

// monitor.cpp
void monitor_attach(int channel, obs_source_t *source);
void monitor_start();
void monitor_stop();

// overlay.cpp
void overlays_init();
void overlays_release();

// vst3.cpp
void vst3_register();
void vst3_release();
void list_vst3(std::string &json, bool &first);

// tempo.cpp
void tempo_listen(obs_source_t *source); // nullptr stops
void music_forget(obs_source_t *source);  // vst3.cpp
obs_source_t *audio_channel_source(int channel); // audio.cpp

// vcam.cpp
void vcam_stop();

// outputs.cpp
void outputs_stop_all_and_wait();
bool outputs_active();

// util
void set_err(char *err, int32_t len, const char *msg);
std::string json_escape(const char *s);
std::wstring widen(const char *utf8);
std::string narrow(const wchar_t *w);

} // namespace oc
