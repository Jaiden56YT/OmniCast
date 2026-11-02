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

/* Starts libobs, loads the OBS.app plugins and builds both canvases with a default
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

/* Camera source device, by AVCaptureDevice uniqueID. */
void omni_camera_set_device(const char *unique_id);
const char *omni_camera_device(void);

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
/* Audio mixer */

typedef enum {
	OMNI_AUDIO_DESKTOP = 0,
	OMNI_AUDIO_MIC = 1,
} omni_audio_source;

/* Latest peak per channel in dBFS (-INFINITY when silent). Safe from any thread. */
void omni_audio_levels(omni_audio_source src, float *left_db, float *right_db);
/* Linear gain, 1.0 = unity. */
void omni_audio_set_volume(omni_audio_source src, float mul);
void omni_audio_set_muted(omni_audio_source src, bool muted);

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
 * Feeds one canvas, either one, to the "OBS Virtual Camera" device that OBS.app
 * installs, so Zoom, Discord, FaceTime etc. can pick it as a camera. The device is
 * fixed at 1920x1080, so the vertical canvas is centred with black side bars. */

/* True when the OBS camera extension is installed and its device is visible. */
bool omni_virtualcam_available(void);
bool omni_virtualcam_start(omni_canvas canvas, char *err, size_t err_len);
void omni_virtualcam_stop(void);
bool omni_virtualcam_active(void);

#ifdef __cplusplus
}
#endif
