// OmniCore: the OmniCast for Windows engine, a C++ DLL over libobs.
//
// The C# app calls these flat C functions through P/Invoke. Strings are UTF-8.
// Lists (devices, windows) come back as JSON from oc_list(); free them with
// oc_free().
//
// Two canvases share one set of sources:
//   OC_WIDE  16:9 (YouTube, Twitch, Kick)
//   OC_TALL  9:16 (TikTok, Instagram, Shorts)
// Each canvas is encoded once, and that encode is shared by every destination on
// it. The encoder is picked for this PC: a GPU texture encoder (NVIDIA NVENC,
// AMD AMF, Intel Quick Sync) when there is one, otherwise x264 on the CPU.
#pragma once

#include <stdint.h>

#ifdef OMNICORE_BUILD
#define OC_API extern "C" __declspec(dllexport)
#else
#define OC_API extern "C" __declspec(dllimport)
#endif

enum oc_canvas { OC_WIDE = 0, OC_TALL = 1 };

enum oc_output_state {
	OC_OUTPUT_IDLE = 0,
	OC_OUTPUT_CONNECTING = 1,
	OC_OUTPUT_LIVE = 2,
	OC_OUTPUT_RECONNECTING = 3,
	OC_OUTPUT_FAILED = 4,
};

// Video settings. height is the wide canvas's height: 720 or 1080 (the wide
// canvas is 16:9 of it, the tall canvas is the same size turned on its side).
struct oc_video_config {
	int32_t height;
	int32_t fps;
	int32_t wide_kbps;
	int32_t tall_kbps;
};

struct oc_stats {
	double fps;
	double render_ms;           // GPU compositing time per frame
	uint32_t total_frames;
	uint32_t lagged_frames;     // frames the compositor was late for
	uint32_t skipped_wide;      // frames the 16:9 encoder had to skip
	uint32_t skipped_tall;
	double cpu_percent;         // OmniCast's own CPU use, all cores = 100
};

// index is the destination's position in oc_stream_start's list.
typedef void(__stdcall *oc_status_cb)(int32_t index, int32_t state, const char *message);
// canvas, active (1 = file open), message is empty unless it stopped with an error.
typedef void(__stdcall *oc_record_cb)(int32_t canvas, int32_t active, const char *message);

// ---------------------------------------------------------------------------
// Engine

// app_dir: the folder with OmniCast.exe (libobs lives in its obs\ subfolder).
// config_dir: where libobs keeps its logs and plugin settings.
OC_API int32_t oc_start(const char *app_dir, const char *config_dir, const oc_video_config *video, char *err,
			int32_t err_len);
OC_API void oc_shutdown(void);
// Changes resolution / frame rate / bitrates. Fails while live or recording.
OC_API int32_t oc_reset_video(const oc_video_config *video, char *err, int32_t err_len);

// Human-readable name of the encoder in use, e.g. "NVIDIA NVENC H.264" or "x264 (CPU)".
OC_API const char *oc_encoder_name(void);
// 1 for a GPU encoder, 0 for x264.
OC_API int32_t oc_encoder_is_gpu(void);
OC_API const char *oc_gpu_name(void);
OC_API void oc_get_stats(oc_stats *stats);
// Keeps the PC awake, raises priority and turns off power throttling while
// live or recording; the engine calls it itself, exposed for the benchmark.
OC_API void oc_set_busy(int32_t busy);

// ---------------------------------------------------------------------------
// Lists, as a JSON array of {"id":..., "name":...}. what is one of:
//   "monitors", "windows", "games" (windows a game capture can hook),
//   "video_devices" (cameras and capture cards), "audio_inputs", "audio_outputs"
OC_API char *oc_list(const char *what);
OC_API void oc_free(void *p);

// ---------------------------------------------------------------------------
// Sources

enum oc_screen_kind {
	OC_SCREEN_MONITOR = 0, // id: monitor id from oc_list("monitors")
	OC_SCREEN_WINDOW = 1,  // id: window string from oc_list("windows")
	OC_SCREEN_GAME = 2,    // id: window string; game capture (DirectX/OpenGL/Vulkan games)
	OC_SCREEN_DEVICE = 3,  // id: video device id, e.g. a capture card
};

// Mic and desktop audio devices ("default" follows Windows). They aren't part
// of any scene: they're always on the stream.
OC_API void oc_mic_set_device(const char *id);
OC_API void oc_desktop_set_device(const char *id);

// ---------------------------------------------------------------------------
// Scenes
//
// A scene is a preset: what the screen slot shows, which camera, and how
// they're laid out on each canvas. One scene is on air at a time, on both
// canvases. Sources are shared: two scenes showing the same monitor or
// camera use one capture, and captures in scenes that aren't on air stop
// (a camera's light goes off). Each scene is identified by a key the app picks.

enum oc_wide_layout {
	OC_WIDE_SCREEN_CAMERA = 0, // screen full frame, camera in a corner
	OC_WIDE_SCREEN = 1,        // screen only
	OC_WIDE_CAMERA = 2,        // camera fills the frame
};

enum oc_corner { OC_CORNER_BOTTOM_RIGHT = 0, OC_CORNER_BOTTOM_LEFT = 1, OC_CORNER_TOP_RIGHT = 2, OC_CORNER_TOP_LEFT = 3 };

enum oc_tall_layout {
	OC_TALL_SPLIT = 0,  // screen on the top half, camera on the bottom half
	OC_TALL_SCREEN = 1, // screen fills the frame (sides cropped)
	OC_TALL_CAMERA = 2, // camera fills the frame
};

struct oc_scene_desc {
	const char *key;
	int32_t screen_kind;   // oc_screen_kind
	const char *screen_id; // "" with OC_SCREEN_MONITOR = the main display
	const char *camera_id; // video device id, "" = no camera
	int32_t wide_layout;   // oc_wide_layout
	int32_t camera_corner; // oc_corner, for OC_WIDE_SCREEN_CAMERA
	int32_t tall_layout;   // oc_tall_layout
};

enum oc_transition {
	OC_TRANSITION_CUT = 0,
	OC_TRANSITION_FADE = 1,
	OC_TRANSITION_FADE_BLACK = 2, // fade out to black, then in
	OC_TRANSITION_SLIDE = 3,
	OC_TRANSITION_SWIPE = 4,
};

// Creates the scene, or updates it if the key exists (on air too).
OC_API void oc_scene_set(const oc_scene_desc *scene);
// Removes a scene. The scene on air can't be removed.
OC_API int32_t oc_scene_remove(const char *key);
// Puts a scene on air on both canvases with a transition (duration_ms is
// ignored for a cut). Switching again mid-transition is fine.
OC_API int32_t oc_scene_activate(const char *key, int32_t transition, int32_t duration_ms);
// Key of the scene on air, "" if none.
OC_API const char *oc_scene_active(void);

// ---------------------------------------------------------------------------
// Audio
//
// Channels: 0 = mic, 1 = desktop audio, 2 = capture card (the on-air scene's
// screen slot, when it's a capture device).

enum { OC_CH_MIC = 0, OC_CH_DESKTOP = 1, OC_CH_CAPTURE = 2, OC_CH_COUNT = 3 };

// Linear gain, 1.0 = unity.
OC_API void oc_audio_set(int32_t channel, float gain, int32_t muted);
// Peak dBFS per side since the last call (-INF when silent). Lock-free.
OC_API void oc_audio_levels(int32_t channel, float *left_db, float *right_db);
// 1 when the channel has a source right now (the capture card only does while picked).
OC_API int32_t oc_audio_present(int32_t channel);

// ---------------------------------------------------------------------------
// Preview
//
// panel is the IUnknown* of a WinUI SwapChainPanel. The engine makes a swap
// chain on libobs's own D3D11 device and draws the canvas's finished frame into
// it on the GPU each frame: no CPU copy, no second composite. Call from the UI
// thread. width/height are in DIPs; scale is the panel's composition scale.

OC_API int32_t oc_preview_attach(int32_t canvas, void *panel, float width, float height, float scale_x,
				 float scale_y);
OC_API void oc_preview_resize(int32_t canvas, float width, float height, float scale_x, float scale_y);
// Disabled previews cost nothing (use it when the window is minimised or hidden).
OC_API void oc_preview_set_enabled(int32_t canvas, int32_t enabled);
OC_API void oc_preview_detach(int32_t canvas);

// ---------------------------------------------------------------------------
// Streaming

struct oc_destination {
	const char *name;   // shown in logs, e.g. "Twitch"
	const char *server; // rtmp:// or rtmps:// ingest URL
	const char *key;    // stream key
	int32_t canvas;
};

OC_API void oc_set_status_callback(oc_status_cb cb);
OC_API int32_t oc_stream_start(const oc_destination *dests, int32_t count, char *err, int32_t err_len);
OC_API void oc_stream_stop(void);
OC_API int32_t oc_stream_active(void);
OC_API int32_t oc_stream_output_stats(int32_t index, int32_t *dropped, uint64_t *bytes);

// ---------------------------------------------------------------------------
// Recording
//
// With a GPU encoder, each recorded canvas gets its own constant-quality
// encode, so it looks good even while the stream is at a low bitrate. With
// x264 (no GPU encoder), a recording shares its canvas's stream encode instead,
// so recording while live costs no extra CPU. Files are MP4s that stay playable
// if the app is killed (hybrid MP4).

struct oc_record_config {
	const char *folder;
	int32_t wide;        // record the 16:9 canvas
	int32_t tall;        // record the 9:16 canvas
	int32_t split_audio; // track 2 = desktop audio only, track 3 = mic only
	int32_t quality;     // GPU constant quality, 1 (best) - 51; 20 is a good default
};

OC_API void oc_set_record_callback(oc_record_cb cb);
OC_API int32_t oc_record_start(const oc_record_config *cfg, char *err, int32_t err_len);
OC_API void oc_record_stop(void);
OC_API int32_t oc_record_active(void);
// UTF-8 path of the file being (or last) written for a canvas, "" if none.
OC_API const char *oc_record_path(int32_t canvas);
