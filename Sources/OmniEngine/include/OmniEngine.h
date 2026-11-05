#pragma once

/*
 * OmniEngine: a small C API over libobs for the Swift app.
 *
 * Two canvases share one set of sources:
 *   OMNI_CANVAS_HORIZONTAL  16:9, the libobs main canvas (YouTube, Twitch, Kick)
 *   OMNI_CANVAS_VERTICAL    9:16, a second libobs canvas (TikTok, Instagram, Shorts)
 *
 * Each canvas is encoded once with the hardware VideoToolbox H.264 encoder and
 * that one encode is shared by every destination on the canvas.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
	OMNI_CANVAS_HORIZONTAL = 0,
	OMNI_CANVAS_VERTICAL = 1,
} omni_canvas;

typedef enum {
	OMNI_OUTPUT_IDLE = 0,
	OMNI_OUTPUT_CONNECTING = 1,
	OMNI_OUTPUT_LIVE = 2,
	OMNI_OUTPUT_RECONNECTING = 3,
	OMNI_OUTPUT_FAILED = 4,
} omni_output_state;

typedef struct {
	uint32_t width;
	uint32_t height;
	uint32_t fps;
	uint32_t bitrate_kbps;
} omni_canvas_config;

typedef struct {
	const char *name;   /* shown in logs, e.g. "Twitch" */
	const char *server; /* rtmp:// or rtmps:// ingest URL */
	const char *key;    /* stream key */
	omni_canvas canvas;
} omni_destination;

typedef struct {
	double fps;
	double render_ms;
	uint32_t lagged_frames;
	uint32_t total_frames;
	uint32_t skipped_frames_h;
	uint32_t skipped_frames_v;
} omni_stats;

typedef void (*omni_status_callback)(int index, omni_output_state state, const char *message, void *ctx);

/* Starts libobs, loads the bundled OBS plugins and builds both canvases with a default
 * scene (display, camera, desktop audio, mic). Must run on the main thread. */
bool omni_engine_start(const char *config_dir, bool prefer_metal, const omni_canvas_config *horizontal,
		       const omni_canvas_config *vertical, char *err, size_t err_len);
void omni_engine_shutdown(void);

/* "Metal" or "OpenGL" once the engine is running. */
const char *omni_engine_renderer(void);
/* Encoder id chosen for video, e.g. com.apple.videotoolbox.videoencoder.ave.avc. */
const char *omni_engine_video_encoder(void);

/* Preview: view is an NSView*. Pass the size in pixels (backing size). */
void omni_preview_attach(omni_canvas canvas, void *view, uint32_t cx, uint32_t cy);
void omni_preview_resize(omni_canvas canvas, uint32_t cx, uint32_t cy);
void omni_preview_set_enabled(omni_canvas canvas, bool enabled);
void omni_preview_detach(omni_canvas canvas);

/* Default source toggles: "Display", "Camera", "Desktop Audio", "Mic". */
void omni_source_set_enabled(const char *name, bool enabled);

/* What the screen slot (the "Display" source) shows. */
typedef enum {
	OMNI_SCREEN_DISPLAY = 0, /* id: display UUID */
	OMNI_SCREEN_WINDOW = 1,  /* id: CGWindowID in decimal */
	OMNI_SCREEN_APP = 2,     /* id: bundle identifier; all of the app's windows */
	OMNI_SCREEN_DEVICE = 3,  /* id: AVCaptureDevice uniqueID, e.g. a capture card */
} omni_screen_kind;

void omni_screen_set_target(omni_screen_kind kind, const char *id);

/* ------------------------------------------------------------------------- */
/* Call overlay
 *
 * One layer per person in the Discord call, drawn over the 16:9 canvas. Each
 * layer holds an idle and a talking image (both stay loaded, so switching is
 * instant); positions are in canvas pixels. */

/* Creates the layer if needed and loads its images (PNG paths). */
void omni_overlay_set_images(const char *key, const char *idle_png, const char *talk_png);
/* Same, with animations: frame PNGs and each frame's delay in seconds. Frames
 * loop; the talking animation restarts from its first frame on each new burst
 * of talking. All frames should be the same size. */
void omni_overlay_set_frames(const char *key, const char *const *idle, const float *idle_delays, int idle_count,
			     const char *const *talk, const float *talk_delays, int talk_count);
/* Centre point and box size in canvas pixels; the image keeps its aspect inside
 * the box. lift moves the talking image up by that many pixels. */
void omni_overlay_place(const char *key, float cx, float cy, float width, float height, bool flip, float lift);
void omni_overlay_set_speaking(const char *key, bool speaking);
void omni_overlay_remove(const char *key);
/* Shows or hides every layer at once. */
void omni_overlay_set_visible(bool visible);
/* Shows or hides one layer (on top of the switch above). */
void omni_overlay_set_layer_visible(const char *key, bool visible);

/* ------------------------------------------------------------------------- */
/* Image layers
 *
 * A PNG drawn on top of both canvases, with its own position on each and one
 * opacity for fading (e.g. the Spotify now-playing card). Positions are the
 * top-left corner in canvas pixels; the image keeps its aspect inside the box. */

void omni_layer_set_image(const char *key, const char *png);
void omni_layer_place(const char *key, omni_canvas canvas, bool show, float x, float y, float width, float height);
/* 0 hides the layer entirely (nothing is rendered). */
void omni_layer_set_opacity(const char *key, float opacity);
void omni_layer_remove(const char *key);

/* Camera source device, by AVCaptureDevice uniqueID. The camera starts closed;
 * omni_source_set_enabled("Camera", true) opens it. */
void omni_camera_set_device(const char *unique_id);
const char *omni_camera_device(void);
/* Where the camera sits on a canvas: top-left and box size in canvas pixels. On
 * 16:9 it fits inside the box; on 9:16 it fills the box, cropped. */
void omni_camera_place(omni_canvas canvas, float x, float y, float width, float height);

void omni_set_status_callback(omni_status_callback cb, void *ctx);

/* Starts one RTMP output per destination. index in the status callback matches
 * the position in dests. */
bool omni_stream_start(const omni_destination *dests, int count, char *err, size_t err_len);
void omni_stream_stop(void);
bool omni_stream_active(void);
/* Per-destination dropped frames and bytes sent; returns false for a bad index. */
bool omni_stream_output_stats(int index, int *dropped, uint64_t *bytes);

void omni_get_stats(omni_stats *stats);

/* ------------------------------------------------------------------------- */
/* Audio mixer
 *
 * Every channel has two levels: the stream level (what the streams and recordings
 * get) and the monitor level (what plays on the monitor output, e.g. headphones).
 * Channel 0 is the mic, 1 is system audio, app channels take the rest.
 *
 * App and system audio come from Core Audio process taps, which also silence the
 * tapped app's own output while OmniCast runs, so it's heard only through the
 * monitor mix. Quitting OmniCast gives every app its normal output back. */

#define OMNI_MIXER_MAX_CHANNELS 16
#define OMNI_CHANNEL_MIC 0
#define OMNI_CHANNEL_SYSTEM 1

/* False before macOS 14.2: no app channels, and the monitor mix has the mic only. */
bool omni_mixer_apps_supported(void);
/* Adds a channel for an app (and its helper processes) by bundle identifier.
 * Returns the channel, or -1 when all channels are taken. */
int omni_mixer_add_app(const char *bundle_id);
void omni_mixer_remove_app(int channel);

/* Peak per side in dBFS since the last call, before either fader (-INFINITY when
 * silent). Safe from any thread. */
void omni_mixer_levels(int channel, float *left_db, float *right_db);
/* Peak of the most recent audio packet in dBFS, after the plugins, before the
 * faders. Unlike omni_mixer_levels it doesn't reset, so it can be read alongside
 * the meters (the PNGtuber's voice detection uses it). */
float omni_mixer_level(int channel);
/* Linear gain, 1.0 = unity. */
void omni_mixer_set_stream(int channel, float mul, bool muted);
void omni_mixer_set_monitor(int channel, float mul, bool muted);

typedef struct {
	char uid[256];
	char name[256];
} omni_audio_device;

/* Channel for the capture card's audio (the screen slot's capture device), or -1
 * until a capture device has been picked. */
int omni_mixer_capture_channel(void);

/* Output devices for the monitor mix; returns how many were written. */
int omni_monitor_devices(omni_audio_device *out, int max);
/* Device UID, or "" to follow the system default output. */
void omni_monitor_set_device(const char *uid);

/* Virtual mic: plays the mic, or the whole stream mix (each channel after its
 * plugins, at its stream level, silent while muted on stream), into a loopback
 * device, so Discord or any other app can pick that device's input as its
 * microphone. The devices offered are loopbacks such as BlackHole: virtual, with
 * both an output and an input. */
int omni_virtual_mic_devices(omni_audio_device *out, int max);
/* Device UID, or "" for off. Returns whether the output is running. */
bool omni_virtual_mic_set_device(const char *uid);

typedef enum {
	OMNI_VIRTUAL_MIC_MIC = 0,    /* the mic alone */
	OMNI_VIRTUAL_MIC_STREAM = 1, /* every channel at its stream level, like the stream hears */
} omni_virtual_mic_mode;

/* What the virtual mic carries. excluded_channels is a bit per channel left out of
 * the stream mix: Discord's own channel, so a call doesn't hear itself back. */
void omni_virtual_mic_set_mix(omni_virtual_mic_mode mode, uint32_t excluded_channels);

/* Which input of the mic's device is the mic. Interfaces such as the Volt 2 have
 * two inputs; the chosen one is sent to both sides, before the plugins. */
typedef enum {
	OMNI_MIC_INPUT_1 = 0,
	OMNI_MIC_INPUT_2 = 1,
	OMNI_MIC_STEREO = 2,
} omni_mic_input;

void omni_mic_set_input(omni_mic_input input);

/* Mic plugins. Only these Audio Units are ever loaded (by component ID, no plugin
 * scan), and only while turned on. They run in this order. */
typedef enum {
	OMNI_PLUGIN_STACKS = 0,
	OMNI_PLUGIN_MUZE = 1,
	OMNI_PLUGIN_COUNT = 2,
} omni_plugin;

bool omni_plugin_installed(omni_plugin plugin);

/* Music follow: runs Muze Auto Key on a mixer channel (e.g. Spotify) so Muze,
 * set to Key Link: Follow, takes that music's key, and tracks the channel's beat
 * so its tempo can be given to Muze. -1 stops. */
void omni_music_follow(int channel);
bool omni_music_auto_key_installed(void);
/* The followed channel's tempo in BPM from the last ~11 s, or 0 when unsure;
 * confidence is higher for a clearer beat. */
double omni_music_tempo(double *confidence);
/* Forget the beat history (on a song change). */
void omni_music_tempo_reset(void);
/* Tempo the plugins see as the host's. */
void omni_music_set_tempo(double bpm);
/* Muze's current key and scale, e.g. "A Natural Minor"; false if Muze isn't loaded. */
bool omni_music_muze_key(char *out, size_t len);
void omni_plugin_set_enabled(omni_plugin plugin, bool enabled);
/* Opens the plugin's own window; it opens once the plugin has loaded. */
void omni_plugin_show_editor(omni_plugin plugin);

/* ------------------------------------------------------------------------- */
/* Recording
 *
 * Each recorded canvas gets its own constant-quality encoder on the media engine,
 * separate from the stream encode, so a recording looks good even while the stream
 * runs at a low CBR bitrate. Files are Hybrid MP4: playable even if the app quits
 * mid-recording. */

typedef enum {
	OMNI_CODEC_H264 = 0,
	OMNI_CODEC_HEVC = 1,
} omni_codec;

typedef struct {
	const char *directory; /* folder for the files; created if missing */
	omni_codec codec;
	uint32_t quality;  /* VideoToolbox constant quality, 1-100 */
	bool horizontal;   /* record the 16:9 canvas */
	bool vertical;     /* record the 9:16 canvas */
	bool split_audio;  /* add track 2 (desktop audio only) and track 3 (mic only) */
} omni_record_config;

/* active is true once the file is being written and false when it is closed;
 * message is empty unless the recording stopped with an error. */
typedef void (*omni_record_callback)(omni_canvas canvas, bool active, const char *message, void *ctx);

void omni_set_record_callback(omni_record_callback cb, void *ctx);
bool omni_record_start(const omni_record_config *cfg, char *err, size_t err_len);
/* Finishes the files in the background; the callback reports when each is closed. */
void omni_record_stop(void);
bool omni_record_active(void);
/* File being written (or last written) for a canvas; "" if none. */
const char *omni_record_path(omni_canvas canvas);
uint64_t omni_record_bytes(omni_canvas canvas);
/* True when a hardware encoder exists for the codec. */
bool omni_codec_available(omni_codec codec);

/* ------------------------------------------------------------------------- */
/* Virtual camera
 *
 * Feeds one canvas, either one, to the "OBS Virtual Camera" device of the camera
 * extension OBS.app installed (it stays after OBS.app is deleted), so Zoom, Discord,
 * FaceTime etc. can pick it as a camera. The device is fixed at 1920x1080, so the
 * vertical canvas is centred with black side bars. */

/* True when the OBS camera extension is installed and its device is visible. */
bool omni_virtualcam_available(void);
bool omni_virtualcam_start(omni_canvas canvas, char *err, size_t err_len);
void omni_virtualcam_stop(void);
bool omni_virtualcam_active(void);

#ifdef __cplusplus
}
#endif
