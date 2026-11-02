#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreMediaIO/CMIOHardware.h>
#import <CoreVideo/CoreVideo.h>

#include "OmniEngine.h"
#include "OmniAudio.h"

#include <obs.h>
#include <util/platform.h>

#include <math.h>
#include <stdatomic.h>
#include <sys/stat.h>

#define MAX_OUTPUTS 16
#define RECORD_AUDIO_TRACKS 3

/* Modules in OBS.app that need the OBS frontend (Qt UI / frontend API) or are
 * not useful here. Loading them without the OBS frontend would crash or waste
 * startup time. */
static const char *disabled_modules[] = {
	"frontend-tools", "decklink-output-ui", "aja-output-ui", "obs-websocket", "obs-vst",
	"mac-virtualcam", "decklink", "decklink-captions", "aja", "obs-browser", "vlc-video",
};

struct output_ctx {
	int index;
	uint64_t generation;
};

struct record_slot {
	obs_output_t *output;
	obs_encoder_t *venc;
	struct output_ctx ctx; /* index is the omni_canvas */
	char path[1024];
};

static struct {
	bool running;
	const char *renderer;
	char video_encoder_id[256];
	char hevc_encoder_id[256]; /* "" when there is no hardware HEVC */

	omni_canvas_config horizontal;
	omni_canvas_config vertical;

	obs_canvas_t *vertical_canvas;
	obs_scene_t *scene_h;
	obs_scene_t *scene_v;

	obs_source_t *display;
	obs_source_t *camera;
	/* The screen slot shows either `display` (screen_capture: a display, window
	 * or app) or `capture_dev` (a capture card), never both; the other's scene
	 * items are hidden and the source disabled so it doesn't render. */
	obs_source_t *capture_dev;
	obs_sceneitem_t *screen_items[2]; /* omni_canvas */
	obs_sceneitem_t *device_items[2];
	bool screen_on_device;
	bool screen_visible;
	obs_source_t *desktop_audio;
	obs_source_t *mic;

	obs_encoder_t *venc_h;
	obs_encoder_t *venc_v;
	obs_encoder_t *aenc;

	obs_display_t *previews[2];

	obs_output_t *outputs[MAX_OUTPUTS];
	obs_service_t *services[MAX_OUTPUTS];
	struct output_ctx output_ctx[MAX_OUTPUTS];
	int output_count;
	uint64_t generation;

	omni_status_callback status_cb;
	void *status_ctx;

	/* Track 1 is the full mix (what the stream gets), 2 desktop only, 3 mic only. */
	obs_encoder_t *aenc_rec[RECORD_AUDIO_TRACKS];
	struct record_slot rec[2]; /* omni_canvas */
	uint64_t rec_generation;
	omni_record_callback record_cb;
	void *record_ctx;
} engine;

static void set_err(char *err, size_t err_len, const char *msg)
{
	if (err && err_len)
		snprintf(err, err_len, "%s", msg);
}

/* ------------------------------------------------------------------------- */
/* Startup */

static void register_vcam_output(void);

static NSString *frameworks_path(void)
{
	/* The app bundle's Frameworks folder links to OBS.app's, which holds libobs
	 * and both graphics modules. */
	return [[NSBundle mainBundle] privateFrameworksPath];
}

static void fill_video_info(struct obs_video_info *ovi, const char *module, const omni_canvas_config *cfg,
			    uint32_t fps)
{
	memset(ovi, 0, sizeof(*ovi));
	ovi->graphics_module = module;
	ovi->fps_num = fps;
	ovi->fps_den = 1;
	ovi->base_width = cfg->width;
	ovi->base_height = cfg->height;
	ovi->output_width = cfg->width;
	ovi->output_height = cfg->height;
	/* NV12 straight from the GPU is what VideoToolbox takes without a copy. */
	ovi->output_format = VIDEO_FORMAT_NV12;
	ovi->gpu_conversion = true;
	ovi->colorspace = VIDEO_CS_709;
	ovi->range = VIDEO_RANGE_PARTIAL;
	ovi->scale_type = OBS_SCALE_BICUBIC;
}

static bool reset_video(bool prefer_metal)
{
	NSString *dir = frameworks_path();
	NSString *metal = [dir stringByAppendingPathComponent:@"libobs-metal.dylib"];
	NSString *opengl = [dir stringByAppendingPathComponent:@"libobs-opengl.dylib"];

	struct obs_video_info ovi;
	if (prefer_metal) {
		fill_video_info(&ovi, metal.UTF8String, &engine.horizontal, engine.horizontal.fps);
		if (obs_reset_video(&ovi) == OBS_VIDEO_SUCCESS) {
			engine.renderer = "Metal";
			return true;
		}
		blog(LOG_WARNING, "[OmniCast] Metal renderer failed, falling back to OpenGL");
	}

	fill_video_info(&ovi, opengl.UTF8String, &engine.horizontal, engine.horizontal.fps);
	if (obs_reset_video(&ovi) == OBS_VIDEO_SUCCESS) {
		engine.renderer = "OpenGL";
		return true;
	}
	return false;
}

/* Finds a VideoToolbox encoder for the codec. Prefers the Apple Silicon media
 * engine with texture input, so frames go from the compositor to the encoder
 * without leaving the GPU; with allow_software, falls back to VideoToolbox's
 * software encoder. Leaves out empty when there is none. */
static void find_videotoolbox_encoder(const char *codec_name, bool allow_software, char *out, size_t len)
{
	const char *id;
	const char *hardware = NULL;
	const char *any = NULL;
	out[0] = 0;

	for (size_t i = 0; obs_enum_encoder_types(i, &id); i++) {
		const char *codec = obs_get_encoder_codec(id);
		uint32_t caps = obs_get_encoder_caps(id);
		if (!codec || strcmp(codec, codec_name) != 0 || (caps & OBS_ENCODER_CAP_DEPRECATED))
			continue;
		if (!strstr(id, "videotoolbox"))
			continue;

		blog(LOG_INFO, "[OmniCast] %s encoder available: %s (caps 0x%x)", codec_name, id, caps);
		bool software = strstr(id, "software") || strstr(id, "SW");
		if (!software && (caps & OBS_ENCODER_CAP_PASS_TEXTURE)) {
			snprintf(out, len, "%s", id);
			return;
		}
		if (!software && !hardware)
			hardware = id;
		if (!any)
			any = id;
	}

	const char *pick = hardware ? hardware : allow_software ? any : NULL;
	if (pick)
		snprintf(out, len, "%s", pick);
}

static void pick_video_encoders(void)
{
	find_videotoolbox_encoder("h264", true, engine.video_encoder_id, sizeof(engine.video_encoder_id));
	if (!engine.video_encoder_id[0])
		snprintf(engine.video_encoder_id, sizeof(engine.video_encoder_id), "obs_x264");
	find_videotoolbox_encoder("hevc", false, engine.hevc_encoder_id, sizeof(engine.hevc_encoder_id));
}

static obs_encoder_t *create_video_encoder(const char *name, uint32_t bitrate)
{
	obs_data_t *s = obs_data_create();
	obs_data_set_string(s, "rate_control", "CBR");
	obs_data_set_int(s, "bitrate", bitrate);
	obs_data_set_int(s, "keyint_sec", 2);
	obs_data_set_string(s, "profile", "high");
	obs_encoder_t *enc = obs_video_encoder_create(engine.video_encoder_id, name, s, NULL);
	obs_data_release(s);
	return enc;
}

/* Constant quality (VideoToolbox CRF, Apple Silicon only): static screens cost
 * almost nothing on disk and motion gets the bits it needs. */
static obs_encoder_t *create_record_encoder(const char *name, omni_codec codec, uint32_t quality)
{
	bool hevc = codec == OMNI_CODEC_HEVC && engine.hevc_encoder_id[0];
	obs_data_t *s = obs_data_create();
	obs_data_set_string(s, "rate_control", "CRF");
	obs_data_set_int(s, "quality", quality < 1 ? 1 : quality > 100 ? 100 : quality);
	obs_data_set_int(s, "keyint_sec", 2);
	obs_data_set_string(s, "profile", hevc ? "main" : "high");
	obs_data_set_bool(s, "bframes", true);
	obs_encoder_t *enc =
		obs_video_encoder_create(hevc ? engine.hevc_encoder_id : engine.video_encoder_id, name, s, NULL);
	obs_data_release(s);
	return enc;
}

static NSString *main_display_uuid(void)
{
	CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID());
	if (!uuid)
		return @"";
	NSString *str = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, uuid);
	CFRelease(uuid);
	return str;
}

/* The system default can be a virtual camera (OBS's, Streamlabs'), which would
 * feed OmniCast's own virtual camera back into the scene. Without a default the
 * built-in camera wins over external devices, which may be capture cards; the
 * app's camera picker overrides this. */
static AVCaptureDevice *pick_camera(void)
{
	AVCaptureDevice *def = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
	if (def && ![def.localizedName.lowercaseString containsString:@"virtual"])
		return def;
	NSArray *types = @[
		AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeContinuityCamera,
		AVCaptureDeviceTypeExternal
	];
	AVCaptureDeviceDiscoverySession *session =
		[AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
								      mediaType:AVMediaTypeVideo
								       position:AVCaptureDevicePositionUnspecified];
	for (AVCaptureDeviceType type in types) {
		for (AVCaptureDevice *d in session.devices) {
			if (d.deviceType == type && ![d.localizedName.lowercaseString containsString:@"virtual"])
				return d;
		}
	}
	return nil;
}

void omni_camera_set_device(const char *unique_id)
{
	if (!engine.camera || !unique_id || !*unique_id)
		return;
	obs_data_t *s = obs_data_create();
	obs_data_set_string(s, "device", unique_id);
	obs_source_update(engine.camera, s);
	obs_data_release(s);
}

const char *omni_camera_device(void)
{
	static char current[256];
	current[0] = 0;
	if (!engine.camera)
		return current;
	obs_data_t *s = obs_source_get_settings(engine.camera);
	snprintf(current, sizeof(current), "%s", obs_data_get_string(s, "device"));
	obs_data_release(s);
	return current;
}

static void create_sources(void)
{
	obs_data_t *s = obs_data_create();
	obs_data_set_int(s, "type", 0); /* whole display */
	obs_data_set_string(s, "display_uuid", main_display_uuid().UTF8String);
	obs_data_set_bool(s, "show_cursor", true);
	engine.display = obs_source_create("screen_capture", "Display", s, NULL);
	obs_data_release(s);

	s = obs_data_create();
	AVCaptureDevice *cam = pick_camera();
	if (cam)
		obs_data_set_string(s, "device", cam.uniqueID.UTF8String);
	obs_data_set_bool(s, "use_preset", true);
	obs_data_set_string(s, "preset", AVCaptureSessionPreset1280x720.UTF8String);
	engine.camera = obs_source_create("macos-avcapture", "Camera", s, NULL);
	obs_data_release(s);

	s = obs_data_create();
	if (omni_audio_taps_supported()) {
		/* A process tap, so apps with their own mixer channel can be left out. */
		engine.desktop_audio = omni_audio_create_system_source("Desktop Audio");
	} else {
		obs_data_set_int(s, "type", 0); /* all desktop audio */
		engine.desktop_audio = obs_source_create("sck_audio_capture", "Desktop Audio", s, NULL);
	}
	obs_data_release(s);

	s = obs_data_create();
	obs_data_set_string(s, "device_id", "default");
	engine.mic = obs_source_create("coreaudio_input_capture", "Mic", s, NULL);
	obs_data_release(s);

	/* Channels 1 and 3 are where OBS itself puts desktop audio and the mic. */
	if (engine.desktop_audio)
		obs_set_output_source(1, engine.desktop_audio);
	if (engine.mic)
		obs_set_output_source(3, engine.mic);

	/* Mix 1 has everything; mixes 2 and 3 hold each source alone for the
	 * recording's extra tracks. */
	if (engine.desktop_audio)
		obs_source_set_audio_mixers(engine.desktop_audio, (1 << 0) | (1 << 1));
	if (engine.mic)
		obs_source_set_audio_mixers(engine.mic, (1 << 0) | (1 << 2));
}

static obs_sceneitem_t *place(obs_scene_t *scene, obs_source_t *source, float x, float y, float cx, float cy,
			      enum obs_bounds_type type, bool crop)
{
	if (!source)
		return NULL;
	obs_sceneitem_t *item = obs_scene_add(scene, source);
	struct vec2 pos = {.x = x, .y = y};
	struct vec2 bounds = {.x = cx, .y = cy};
	obs_sceneitem_set_pos(item, &pos);
	obs_sceneitem_set_bounds_type(item, type);
	obs_sceneitem_set_bounds(item, &bounds);
	obs_sceneitem_set_bounds_crop(item, crop);
	return item;
}

/* Where the screen slot sits on each canvas: full frame on 16:9, top half on 9:16. */
static obs_sceneitem_t *place_screen(omni_canvas canvas, obs_source_t *source)
{
	if (canvas == OMNI_CANVAS_HORIZONTAL)
		return place(engine.scene_h, source, 0, 0, (float)engine.horizontal.width,
			     (float)engine.horizontal.height, OBS_BOUNDS_SCALE_INNER, false);
	return place(engine.scene_v, source, 0, 0, (float)engine.vertical.width, engine.vertical.height * 0.5f,
		     OBS_BOUNDS_SCALE_INNER, false);
}

static void build_scenes(void)
{
	float w = (float)engine.horizontal.width, h = (float)engine.horizontal.height;
	engine.scene_h = obs_scene_create("Horizontal");
	engine.screen_items[OMNI_CANVAS_HORIZONTAL] = place_screen(OMNI_CANVAS_HORIZONTAL, engine.display);
	float cam_w = w * 0.25f, cam_h = h * 0.25f, margin = h * 0.025f;
	place(engine.scene_h, engine.camera, w - cam_w - margin, h - cam_h - margin, cam_w, cam_h,
	      OBS_BOUNDS_SCALE_INNER, false);
	obs_set_output_source(0, obs_scene_get_source(engine.scene_h));

	/* Vertical: screen on the top half, camera filling the bottom half. */
	w = (float)engine.vertical.width;
	h = (float)engine.vertical.height;
	engine.scene_v = obs_canvas_scene_create(engine.vertical_canvas, "Vertical");
	engine.screen_items[OMNI_CANVAS_VERTICAL] = place_screen(OMNI_CANVAS_VERTICAL, engine.display);
	place(engine.scene_v, engine.camera, 0, h * 0.5f, w, h * 0.5f, OBS_BOUNDS_SCALE_OUTER, true);
	obs_canvas_set_channel(engine.vertical_canvas, 0, obs_scene_get_source(engine.scene_v));
}

bool omni_engine_start(const char *config_dir, bool prefer_metal, const omni_canvas_config *horizontal,
		       const omni_canvas_config *vertical, char *err, size_t err_len)
{
	if (engine.running)
		return true;

	engine.horizontal = *horizontal;
	engine.vertical = *vertical;
	/* Every mix runs on the one libobs video clock. */
	engine.vertical.fps = engine.horizontal.fps;

	if (!obs_startup("en-US", config_dir, NULL)) {
		set_err(err, err_len, "libobs failed to start");
		return false;
	}

	struct obs_audio_info oai = {.samples_per_sec = 48000, .speakers = SPEAKERS_STEREO};
	if (!obs_reset_audio(&oai)) {
		set_err(err, err_len, "Audio setup failed");
		obs_shutdown();
		return false;
	}

	if (!reset_video(prefer_metal)) {
		set_err(err, err_len, "Video setup failed (neither Metal nor OpenGL started)");
		obs_shutdown();
		return false;
	}

	for (size_t i = 0; i < sizeof(disabled_modules) / sizeof(disabled_modules[0]); i++)
		obs_add_disabled_module(disabled_modules[i]);
	obs_load_all_modules();
	obs_log_loaded_modules();
	obs_post_load_modules();
	register_vcam_output();
	omni_audio_register();

	struct obs_video_info vovi;
	fill_video_info(&vovi, NULL, &engine.vertical, engine.vertical.fps);
	engine.vertical_canvas = obs_canvas_create("Vertical", &vovi, ACTIVATE | SCENE_REF | EPHEMERAL);
	if (!engine.vertical_canvas || !obs_canvas_has_video(engine.vertical_canvas)) {
		set_err(err, err_len, "Could not create the vertical canvas");
		omni_engine_shutdown();
		return false;
	}

	create_sources();
	engine.screen_visible = true;
	omni_audio_start(config_dir, engine.mic, engine.desktop_audio);
	build_scenes();

	pick_video_encoders();
	blog(LOG_INFO, "[OmniCast] Renderer %s, video encoder %s, HEVC encoder %s", engine.renderer,
	     engine.video_encoder_id, engine.hevc_encoder_id[0] ? engine.hevc_encoder_id : "(none)");

	engine.venc_h = create_video_encoder("Horizontal H.264", engine.horizontal.bitrate_kbps);
	engine.venc_v = create_video_encoder("Vertical H.264", engine.vertical.bitrate_kbps);
	obs_data_t *as = obs_data_create();
	obs_data_set_int(as, "bitrate", 160);
	engine.aenc = obs_audio_encoder_create("CoreAudio_AAC", "AAC", as, 0, NULL);
	/* Recordings get a higher audio bitrate than the stream. Encoders cost
	 * nothing until an output uses them. */
	obs_data_set_int(as, "bitrate", 256);
	bool rec_audio_ok = true;
	for (size_t t = 0; t < RECORD_AUDIO_TRACKS; t++) {
		char name[32];
		snprintf(name, sizeof(name), "Recording AAC %zu", t + 1);
		engine.aenc_rec[t] = obs_audio_encoder_create("CoreAudio_AAC", name, as, t, NULL);
		if (engine.aenc_rec[t])
			obs_encoder_set_audio(engine.aenc_rec[t], obs_get_audio());
		else
			rec_audio_ok = false;
	}
	obs_data_release(as);
	if (!engine.venc_h || !engine.venc_v || !engine.aenc || !rec_audio_ok) {
		set_err(err, err_len, "Could not create the encoders");
		omni_engine_shutdown();
		return false;
	}
	obs_encoder_set_video(engine.venc_h, obs_get_video());
	obs_encoder_set_video(engine.venc_v, obs_canvas_get_video(engine.vertical_canvas));
	obs_encoder_set_audio(engine.aenc, obs_get_audio());

	engine.running = true;
	return true;
}

static void release_record_slots(void);

static void overlay_clear(void);

void omni_engine_shutdown(void)
{
	omni_virtualcam_stop();
	overlay_clear();
	omni_stream_stop();
	/* Give the recordings a moment to write their final index. */
	omni_record_stop();
	for (int i = 0; i < 100 && omni_record_active(); i++)
		usleep(50 * 1000);
	release_record_slots();
	for (int c = 0; c < 2; c++)
		omni_preview_detach((omni_canvas)c);

	obs_encoder_release(engine.venc_h);
	obs_encoder_release(engine.venc_v);
	obs_encoder_release(engine.aenc);
	for (size_t t = 0; t < RECORD_AUDIO_TRACKS; t++)
		obs_encoder_release(engine.aenc_rec[t]);
	omni_audio_stop();

	for (uint32_t ch = 0; ch < 6; ch++)
		obs_set_output_source(ch, NULL);
	if (engine.vertical_canvas) {
		obs_canvas_set_channel(engine.vertical_canvas, 0, NULL);
		obs_canvas_remove(engine.vertical_canvas);
		obs_canvas_release(engine.vertical_canvas);
	}
	/* The canvases hold their own reference to each scene, so releasing ours
	 * isn't enough: the 16:9 scene would only die inside obs_shutdown, on a task
	 * thread, after its sources were freed (crash in obs_sceneitem_release on
	 * quit). Removing the scenes drops the canvas references now, and waiting on
	 * the destroy queue lets them finish before shutdown. */
	if (engine.scene_h)
		obs_source_remove(obs_scene_get_source(engine.scene_h));
	if (engine.scene_v)
		obs_source_remove(obs_scene_get_source(engine.scene_v));
	obs_scene_release(engine.scene_h);
	obs_scene_release(engine.scene_v);
	obs_source_release(engine.display);
	obs_source_release(engine.capture_dev);
	obs_source_release(engine.camera);
	obs_source_release(engine.desktop_audio);
	obs_source_release(engine.mic);
	obs_wait_for_destroy_queue();
	memset(&engine, 0, sizeof(engine));
	obs_shutdown();
}

const char *omni_engine_renderer(void)
{
	return engine.renderer ? engine.renderer : "";
}

const char *omni_engine_video_encoder(void)
{
	return engine.video_encoder_id;
}

/* ------------------------------------------------------------------------- */
/* Preview */

static void draw_preview(void *param, uint32_t cx, uint32_t cy)
{
	omni_canvas canvas = (omni_canvas)(uintptr_t)param;
	const omni_canvas_config *cfg = canvas == OMNI_CANVAS_HORIZONTAL ? &engine.horizontal : &engine.vertical;

	float scale = fminf((float)cx / cfg->width, (float)cy / cfg->height);
	int w = (int)(cfg->width * scale), h = (int)(cfg->height * scale);
	int x = ((int)cx - w) / 2, y = ((int)cy - h) / 2;

	gs_viewport_push();
	gs_projection_push();
	gs_ortho(0.0f, (float)cfg->width, 0.0f, (float)cfg->height, -100.0f, 100.0f);
	gs_set_viewport(x, y, w, h);

	/* Draw each canvas's finished frame. obs_canvas_render would composite the
	 * whole scene a second time per preview, which cost ~4 ms a frame. The
	 * frame is opaque, so blending is skipped too. */
	if (canvas == OMNI_CANVAS_HORIZONTAL)
		obs_render_main_texture_src_color_only();
	else if (engine.vertical_canvas)
		obs_render_canvas_texture_src_color_only(engine.vertical_canvas);

	gs_projection_pop();
	gs_viewport_pop();
}

void omni_preview_attach(omni_canvas canvas, void *view, uint32_t cx, uint32_t cy)
{
	if (!engine.running || engine.previews[canvas])
		return;

	struct gs_init_data info = {0};
	info.window.view = (__bridge id)view;
	info.cx = cx;
	info.cy = cy;
	info.format = GS_BGRA;
	info.zsformat = GS_ZS_NONE;

	engine.previews[canvas] = obs_display_create(&info, 0x111111);
	if (engine.previews[canvas])
		obs_display_add_draw_callback(engine.previews[canvas], draw_preview, (void *)(uintptr_t)canvas);
}

void omni_preview_resize(omni_canvas canvas, uint32_t cx, uint32_t cy)
{
	if (engine.previews[canvas] && cx && cy)
		obs_display_resize(engine.previews[canvas], cx, cy);
}

void omni_preview_set_enabled(omni_canvas canvas, bool enabled)
{
	if (engine.previews[canvas])
		obs_display_set_enabled(engine.previews[canvas], enabled);
}

void omni_preview_detach(omni_canvas canvas)
{
	if (!engine.previews[canvas])
		return;
	obs_display_remove_draw_callback(engine.previews[canvas], draw_preview, (void *)(uintptr_t)canvas);
	obs_display_destroy(engine.previews[canvas]);
	engine.previews[canvas] = NULL;
}

/* ------------------------------------------------------------------------- */
/* Sources */

static void apply_screen(void)
{
	bool dev = engine.screen_on_device;
	for (int c = 0; c < 2; c++) {
		if (engine.screen_items[c])
			obs_sceneitem_set_visible(engine.screen_items[c], !dev);
		if (engine.device_items[c])
			obs_sceneitem_set_visible(engine.device_items[c], dev);
	}
	if (engine.display)
		obs_source_set_enabled(engine.display, engine.screen_visible && !dev);
	if (engine.capture_dev)
		obs_source_set_enabled(engine.capture_dev, engine.screen_visible && dev);
}

void omni_screen_set_target(omni_screen_kind kind, const char *id)
{
	if (!engine.running || !id || !*id)
		return;

	obs_data_t *s = obs_data_create();
	if (kind == OMNI_SCREEN_DEVICE) {
		obs_data_set_string(s, "device", id);
		obs_data_set_bool(s, "use_preset", true);
		obs_data_set_string(s, "preset", AVCaptureSessionPresetHigh.UTF8String);
		/* Capture cards carry the console's or camera's sound. */
		obs_data_set_bool(s, "enable_audio", true);
		if (engine.capture_dev) {
			obs_source_update(engine.capture_dev, s);
		} else {
			engine.capture_dev = obs_source_create("macos-avcapture", "Capture Device", s, NULL);
			for (int c = 0; c < 2; c++) {
				engine.device_items[c] = place_screen((omni_canvas)c, engine.capture_dev);
				/* Under the camera, like the screen it stands in for. */
				if (engine.device_items[c])
					obs_sceneitem_set_order(engine.device_items[c], OBS_ORDER_MOVE_BOTTOM);
			}
		}
		engine.screen_on_device = engine.capture_dev != NULL;
	} else {
		/* screen_capture's own type values: 0 display, 1 window, 2 application. */
		obs_data_set_int(s, "type", kind);
		if (kind == OMNI_SCREEN_DISPLAY) {
			obs_data_set_string(s, "display_uuid", id);
		} else if (kind == OMNI_SCREEN_WINDOW) {
			obs_data_set_int(s, "window", strtoll(id, NULL, 10));
		} else {
			obs_data_set_string(s, "application", id);
			obs_data_set_string(s, "display_uuid", main_display_uuid().UTF8String);
		}
		obs_source_update(engine.display, s);
		engine.screen_on_device = false;
	}
	obs_data_release(s);
	apply_screen();
}

void omni_source_set_enabled(const char *name, bool enabled)
{
	if (strcmp(name, "Display") == 0) {
		engine.screen_visible = enabled;
		apply_screen();
		return;
	}
	obs_source_t *sources[] = {engine.camera, engine.desktop_audio, engine.mic};
	for (size_t i = 0; i < sizeof(sources) / sizeof(sources[0]); i++) {
		if (sources[i] && strcmp(obs_source_get_name(sources[i]), name) == 0)
			obs_source_set_enabled(sources[i], enabled);
	}
}

/* ------------------------------------------------------------------------- */
/* Streaming */

void omni_set_status_callback(omni_status_callback cb, void *ctx)
{
	engine.status_cb = cb;
	engine.status_ctx = ctx;
}

static void report(struct output_ctx *ctx, omni_output_state state, const char *msg)
{
	if (ctx->generation != engine.generation || !engine.status_cb)
		return;
	engine.status_cb(ctx->index, state, msg ? msg : "", engine.status_ctx);
}

static void on_start(void *data, calldata_t *cd)
{
	UNUSED_PARAMETER(cd);
	report(data, OMNI_OUTPUT_LIVE, NULL);
}

static void on_reconnect(void *data, calldata_t *cd)
{
	UNUSED_PARAMETER(cd);
	report(data, OMNI_OUTPUT_RECONNECTING, "Connection dropped, reconnecting");
}

static void on_reconnect_success(void *data, calldata_t *cd)
{
	UNUSED_PARAMETER(cd);
	report(data, OMNI_OUTPUT_LIVE, NULL);
}

static const char *stop_message(int code)
{
	switch (code) {
	case OBS_OUTPUT_SUCCESS:
		return "";
	case OBS_OUTPUT_BAD_PATH:
		return "Bad server URL";
	case OBS_OUTPUT_CONNECT_FAILED:
		return "Could not connect to the server";
	case OBS_OUTPUT_INVALID_STREAM:
		return "Server rejected the stream key";
	case OBS_OUTPUT_DISCONNECTED:
		return "Disconnected";
	case OBS_OUTPUT_ENCODE_ERROR:
		return "Encoder error";
	case OBS_OUTPUT_UNSUPPORTED:
		return "Unsupported by the server";
	case OBS_OUTPUT_NO_SPACE:
		return "Out of space";
	default:
		return "Stream stopped with an error";
	}
}

static void on_stop(void *data, calldata_t *cd)
{
	int code = (int)calldata_int(cd, "code");
	const char *last = calldata_string(cd, "last_error");
	const char *msg = last && *last ? last : stop_message(code);
	report(data, code == OBS_OUTPUT_SUCCESS ? OMNI_OUTPUT_IDLE : OMNI_OUTPUT_FAILED, msg);
}

bool omni_stream_start(const omni_destination *dests, int count, char *err, size_t err_len)
{
	if (!engine.running) {
		set_err(err, err_len, "Engine is not running");
		return false;
	}
	if (count <= 0) {
		set_err(err, err_len, "No destinations are turned on");
		return false;
	}
	if (count > MAX_OUTPUTS)
		count = MAX_OUTPUTS;

	omni_stream_stop();
	engine.generation++;

	for (int i = 0; i < count; i++) {
		const omni_destination *d = &dests[i];
		struct output_ctx *ctx = &engine.output_ctx[i];
		ctx->index = i;
		ctx->generation = engine.generation;

		obs_data_t *ss = obs_data_create();
		obs_data_set_string(ss, "server", d->server);
		obs_data_set_string(ss, "key", d->key);
		engine.services[i] = obs_service_create_private("rtmp_custom", d->name, ss);
		obs_data_release(ss);

		obs_output_t *out = obs_output_create("rtmp_output", d->name, NULL, NULL);
		engine.outputs[i] = out;
		engine.output_count = i + 1;
		if (!out || !engine.services[i]) {
			report(ctx, OMNI_OUTPUT_FAILED, "Could not create the RTMP output");
			continue;
		}

		obs_output_set_video_encoder(out, d->canvas == OMNI_CANVAS_VERTICAL ? engine.venc_v : engine.venc_h);
		obs_output_set_audio_encoder(out, engine.aenc, 0);
		obs_output_set_service(out, engine.services[i]);
		obs_output_set_reconnect_settings(out, 25, 3);

		signal_handler_t *sh = obs_output_get_signal_handler(out);
		signal_handler_connect(sh, "start", on_start, ctx);
		signal_handler_connect(sh, "stop", on_stop, ctx);
		signal_handler_connect(sh, "reconnect", on_reconnect, ctx);
		signal_handler_connect(sh, "reconnect_success", on_reconnect_success, ctx);

		report(ctx, OMNI_OUTPUT_CONNECTING, NULL);
		if (!obs_output_start(out)) {
			const char *last = obs_output_get_last_error(out);
			report(ctx, OMNI_OUTPUT_FAILED, last && *last ? last : "Output failed to start");
		}
	}
	return true;
}

void omni_stream_stop(void)
{
	for (int i = 0; i < engine.output_count; i++) {
		if (engine.outputs[i]) {
			obs_output_stop(engine.outputs[i]);
			obs_output_release(engine.outputs[i]);
		}
		obs_service_release(engine.services[i]);
		engine.outputs[i] = NULL;
		engine.services[i] = NULL;
	}
	engine.output_count = 0;
}

bool omni_stream_active(void)
{
	for (int i = 0; i < engine.output_count; i++) {
		if (engine.outputs[i] && obs_output_active(engine.outputs[i]))
			return true;
	}
	return false;
}

bool omni_stream_output_stats(int index, int *dropped, uint64_t *bytes)
{
	if (index < 0 || index >= engine.output_count || !engine.outputs[index])
		return false;
	*dropped = obs_output_get_frames_dropped(engine.outputs[index]);
	*bytes = obs_output_get_total_bytes(engine.outputs[index]);
	return true;
}

void omni_get_stats(omni_stats *stats)
{
	memset(stats, 0, sizeof(*stats));
	if (!engine.running)
		return;
	stats->fps = obs_get_active_fps();
	stats->render_ms = (double)obs_get_average_frame_time_ns() / 1000000.0;
	stats->lagged_frames = obs_get_lagged_frames();
	stats->total_frames = obs_get_total_frames();
	stats->skipped_frames_h = video_output_get_skipped_frames(obs_get_video());
	if (engine.vertical_canvas)
		stats->skipped_frames_v = video_output_get_skipped_frames(obs_canvas_get_video(engine.vertical_canvas));
}

/* ------------------------------------------------------------------------- */
/* Recording */

void omni_set_record_callback(omni_record_callback cb, void *ctx)
{
	engine.record_cb = cb;
	engine.record_ctx = ctx;
}

static void report_record(struct output_ctx *ctx, bool active, const char *msg)
{
	if (ctx->generation != engine.rec_generation || !engine.record_cb)
		return;
	engine.record_cb((omni_canvas)ctx->index, active, msg ? msg : "", engine.record_ctx);
}

static void on_record_start(void *data, calldata_t *cd)
{
	UNUSED_PARAMETER(cd);
	report_record(data, true, NULL);
}

static void on_record_stop(void *data, calldata_t *cd)
{
	int code = (int)calldata_int(cd, "code");
	const char *last = calldata_string(cd, "last_error");
	const char *msg = code == OBS_OUTPUT_SUCCESS ? "" : last && *last ? last : stop_message(code);
	report_record(data, false, msg);
}

/* Outputs are kept after stopping so the muxer can finish the file; they are
 * released before the next recording or at shutdown. */
static void release_record_slots(void)
{
	for (int c = 0; c < 2; c++) {
		struct record_slot *slot = &engine.rec[c];
		if (slot->output) {
			signal_handler_t *sh = obs_output_get_signal_handler(slot->output);
			signal_handler_disconnect(sh, "start", on_record_start, &slot->ctx);
			signal_handler_disconnect(sh, "stop", on_record_stop, &slot->ctx);
			obs_output_release(slot->output);
		}
		obs_encoder_release(slot->venc);
		slot->output = NULL;
		slot->venc = NULL;
	}
}

bool omni_codec_available(omni_codec codec)
{
	return codec == OMNI_CODEC_H264 ? engine.video_encoder_id[0] != 0 : engine.hevc_encoder_id[0] != 0;
}

/* Hybrid MP4 (OBS 30.2+) stays playable if the app is killed mid-recording;
 * the FFmpeg muxer is the fallback for older libobs. */
static const char *record_output_id(void)
{
	return obs_get_output_flags("mp4_output") ? "mp4_output" : "ffmpeg_muxer";
}

static NSString *record_file_path(NSString *dir, NSString *stamp, omni_canvas canvas)
{
	NSString *suffix = canvas == OMNI_CANVAS_VERTICAL ? @" Vertical" : @"";
	NSString *base = [NSString stringWithFormat:@"OmniCast %@%@", stamp, suffix];
	NSString *path = [dir stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"mp4"]];
	for (int n = 2; [[NSFileManager defaultManager] fileExistsAtPath:path]; n++) {
		NSString *numbered = [NSString stringWithFormat:@"%@ %d", base, n];
		path = [dir stringByAppendingPathComponent:[numbered stringByAppendingPathExtension:@"mp4"]];
	}
	return path;
}

bool omni_record_start(const omni_record_config *cfg, char *err, size_t err_len)
{
	if (!engine.running) {
		set_err(err, err_len, "Engine is not running");
		return false;
	}
	if (!cfg->horizontal && !cfg->vertical) {
		set_err(err, err_len, "Pick a canvas to record");
		return false;
	}
	if (omni_record_active()) {
		set_err(err, err_len, "Still finishing the last recording");
		return false;
	}
	release_record_slots();

	NSString *dir = [@(cfg->directory) stringByExpandingTildeInPath];
	NSError *ferr = nil;
	if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
				       withIntermediateDirectories:YES
							attributes:nil
							     error:&ferr]) {
		set_err(err, err_len, "Can't write to the recording folder");
		return false;
	}
	NSURL *dirURL = [NSURL fileURLWithPath:dir];
	NSNumber *free_bytes = nil;
	[dirURL getResourceValue:&free_bytes forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
	if (free_bytes && free_bytes.longLongValue < 2LL * 1000 * 1000 * 1000) {
		set_err(err, err_len, "Less than 2 GB free on the recording disk");
		return false;
	}

	NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
	fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
	fmt.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
	NSString *stamp = [fmt stringFromDate:[NSDate date]];

	const char *output_id = record_output_id();
	bool multitrack = cfg->split_audio && (obs_get_output_flags(output_id) & OBS_OUTPUT_MULTI_TRACK);
	engine.rec_generation++;

	bool want[2] = {cfg->horizontal, cfg->vertical};
	int started = 0;
	for (int c = 0; c < 2; c++) {
		if (!want[c])
			continue;
		struct record_slot *slot = &engine.rec[c];
		slot->ctx.index = c;
		slot->ctx.generation = engine.rec_generation;
		NSString *path = record_file_path(dir, stamp, (omni_canvas)c);
		snprintf(slot->path, sizeof(slot->path), "%s", path.fileSystemRepresentation);

		bool vertical = c == OMNI_CANVAS_VERTICAL;
		slot->venc = create_record_encoder(vertical ? "Vertical recording" : "Horizontal recording", cfg->codec,
						   cfg->quality);
		if (!slot->venc) {
			set_err(err, err_len, "Could not create the recording encoder");
			continue;
		}
		obs_encoder_set_video(slot->venc,
				      vertical ? obs_canvas_get_video(engine.vertical_canvas) : obs_get_video());

		obs_data_t *s = obs_data_create();
		obs_data_set_string(s, "path", slot->path);
		slot->output = obs_output_create(output_id, vertical ? "Vertical recording" : "Horizontal recording", s,
						 NULL);
		obs_data_release(s);
		if (!slot->output) {
			set_err(err, err_len, "Could not create the recording output");
			continue;
		}

		obs_output_set_video_encoder(slot->output, slot->venc);
		size_t tracks = multitrack ? RECORD_AUDIO_TRACKS : 1;
		for (size_t t = 0; t < tracks; t++)
			obs_output_set_audio_encoder(slot->output, engine.aenc_rec[t], t);

		signal_handler_t *sh = obs_output_get_signal_handler(slot->output);
		signal_handler_connect(sh, "start", on_record_start, &slot->ctx);
		signal_handler_connect(sh, "stop", on_record_stop, &slot->ctx);

		if (obs_output_start(slot->output)) {
			started++;
		} else {
			const char *last = obs_output_get_last_error(slot->output);
			set_err(err, err_len, last && *last ? last : "Recording failed to start");
		}
	}

	if (!started) {
		release_record_slots();
		return false;
	}
	return true;
}

void omni_record_stop(void)
{
	for (int c = 0; c < 2; c++) {
		if (engine.rec[c].output)
			obs_output_stop(engine.rec[c].output);
	}
}

bool omni_record_active(void)
{
	for (int c = 0; c < 2; c++) {
		if (engine.rec[c].output && obs_output_active(engine.rec[c].output))
			return true;
	}
	return false;
}

const char *omni_record_path(omni_canvas canvas)
{
	return engine.rec[canvas].path;
}

uint64_t omni_record_bytes(omni_canvas canvas)
{
	struct record_slot *slot = &engine.rec[canvas];
	if (!slot->output)
		return 0;
	uint64_t bytes = obs_output_get_total_bytes(slot->output);
	struct stat st;
	if (!bytes && slot->path[0] && stat(slot->path, &st) == 0)
		bytes = (uint64_t)st.st_size;
	return bytes;
}

/* ------------------------------------------------------------------------- */
/* Virtual camera
 *
 * OBS's own mac-virtualcam output can't be used here: it only activates the
 * camera extension from inside OBS.app and always sends the main canvas. The
 * extension's sink stream takes frames from any app, so this feeds it directly,
 * the same way that plugin does: NV12 CVPixelBuffers into the CMIO sink queue. */

#define VCAM_WIDTH 1920
#define VCAM_HEIGHT 1080

static struct {
	bool active;
	omni_canvas canvas;
	obs_output_t *output;
	CMIOObjectID device;
	CMIOStreamID stream;
	CMSimpleQueueRef queue;
	CVPixelBufferPoolRef pool;
	CMVideoFormatDescriptionRef format;
	/* Set when the chosen canvas isn't 1920x1080 (the vertical one): a 1920x1080
	 * canvas whose scene holds that canvas's scene, centred with black bars. */
	obs_canvas_t *fit_canvas;
	obs_scene_t *fit_scene;
	uint32_t fps;
	uint32_t frame_width; /* size of the frames libobs hands over */
	uint32_t frame_height;
	/* Logged every 10 s so a camera that shows nothing says why. */
	uint64_t frames, sent, queue_full, failed;
	uint64_t work_ns, work_max_ns; /* time spent per frame in vcam_frame */
} vcam;

static bool cmio_get(CMIOObjectID obj, CMIOObjectPropertySelector sel, void *data, UInt32 size, UInt32 *used)
{
	CMIOObjectPropertyAddress addr = {sel, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
	return CMIOObjectGetPropertyData(obj, &addr, 0, NULL, size, used, data) == kCMIOHardwareNoError;
}

static UInt32 cmio_size(CMIOObjectID obj, CMIOObjectPropertySelector sel)
{
	CMIOObjectPropertyAddress addr = {sel, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
	UInt32 size = 0;
	CMIOObjectGetPropertyDataSize(obj, &addr, 0, NULL, &size);
	return size;
}

/* The device UID comes from the OBS plugin's Info.plist (it matches the
 * extension's); the device name is the fallback. */
static CMIOObjectID find_vcam_device(bool log_missing)
{
	NSString *plugin = [[[NSBundle mainBundle] builtInPlugInsPath]
		stringByAppendingPathComponent:@"mac-virtualcam.plugin"];
	NSString *uid = [[NSBundle bundleWithPath:plugin] objectForInfoDictionaryKey:@"OBSCameraDeviceUUID"];

	UInt32 size = cmio_size(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices);
	UInt32 count = size / sizeof(CMIOObjectID);
	if (!count)
		return kCMIOObjectUnknown;
	CMIOObjectID *ids = calloc(count, sizeof(CMIOObjectID));
	UInt32 used = 0;
	CMIOObjectID found = kCMIOObjectUnknown;
	if (cmio_get(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices, ids, size, &used)) {
		count = used / sizeof(CMIOObjectID);
		for (UInt32 i = 0; i < count && found == kCMIOObjectUnknown; i++) {
			CFStringRef value = NULL;
			if (uid && cmio_get(ids[i], kCMIODevicePropertyDeviceUID, &value, sizeof(value), &used) && value) {
				if ([(__bridge NSString *)value isEqualToString:uid])
					found = ids[i];
				CFRelease(value);
				value = NULL;
			}
			if (found == kCMIOObjectUnknown &&
			    cmio_get(ids[i], kCMIOObjectPropertyName, &value, sizeof(value), &used) && value) {
				if ([(__bridge NSString *)value isEqualToString:@"OBS Virtual Camera"])
					found = ids[i];
				else if (log_missing)
					blog(LOG_INFO, "[OmniCast] Camera device seen: %s", [(__bridge NSString *)value UTF8String]);
				CFRelease(value);
			}
		}
	}
	free(ids);
	if (found == kCMIOObjectUnknown && log_missing)
		blog(LOG_INFO, "[OmniCast] OBS Virtual Camera not among %u camera devices", count);
	return found;
}

bool omni_virtualcam_available(void)
{
	return vcam.active || find_vcam_device(false) != kCMIOObjectUnknown;
}

bool omni_virtualcam_active(void)
{
	return vcam.active;
}

static void queue_altered(CMIOStreamID stream, void *token, void *refcon)
{
	UNUSED_PARAMETER(stream);
	UNUSED_PARAMETER(token);
	UNUSED_PARAMETER(refcon);
}

static void copy_plane(uint8_t *dst, size_t dst_stride, const uint8_t *src, size_t src_stride, size_t row_bytes,
		       size_t rows)
{
	if (dst_stride == src_stride) {
		memcpy(dst, src, src_stride * rows);
		return;
	}
	for (size_t y = 0; y < rows; y++)
		memcpy(dst + y * dst_stride, src + y * src_stride, row_bytes);
}

/* NV12: plane 0 is luma, plane 1 interleaved chroma at half height (same byte width). */
static void copy_frame(CVPixelBufferRef pb, const struct video_data *frame)
{
	CVPixelBufferLockBaseAddress(pb, 0);
	copy_plane(CVPixelBufferGetBaseAddressOfPlane(pb, 0), CVPixelBufferGetBytesPerRowOfPlane(pb, 0), frame->data[0],
		   frame->linesize[0], vcam.frame_width, vcam.frame_height);
	copy_plane(CVPixelBufferGetBaseAddressOfPlane(pb, 1), CVPixelBufferGetBytesPerRowOfPlane(pb, 1), frame->data[1],
		   frame->linesize[1], vcam.frame_width, vcam.frame_height / 2);
	CVPixelBufferUnlockBaseAddress(pb, 0);
}

static void vcam_send(struct video_data *frame);

/* Runs on the libobs video thread for every frame of the chosen canvas. */
static void vcam_frame(void *param, struct video_data *frame)
{
	UNUSED_PARAMETER(param);
	if (++vcam.frames % (10 * vcam.fps) == 0) {
		video_t *v = vcam.canvas == OMNI_CANVAS_VERTICAL ? obs_canvas_get_video(engine.vertical_canvas)
								  : obs_get_video();
		/* Skips on the chosen canvas are what would show up in a recording of it. */
		blog(LOG_INFO,
		     "[OmniCast] Virtual camera: %llu frames, %llu sent, %llu dropped (queue full), %llu failed, "
		     "work avg %.2f ms max %.2f ms, canvas skipped %u",
		     vcam.frames, vcam.sent, vcam.queue_full, vcam.failed,
		     (double)vcam.work_ns / (double)vcam.frames / 1e6, (double)vcam.work_max_ns / 1e6,
		     video_output_get_skipped_frames(v));
		vcam.work_max_ns = 0;
	}
	uint64_t t0 = os_gettime_ns();
	vcam_send(frame);
	uint64_t dt = os_gettime_ns() - t0;
	vcam.work_ns += dt;
	if (dt > vcam.work_max_ns)
		vcam.work_max_ns = dt;
}

static void vcam_send(struct video_data *frame)
{

	/* Drop rather than queue up when the camera's consumer is slow. */
	if (CMSimpleQueueGetCount(vcam.queue) >= CMSimpleQueueGetCapacity(vcam.queue)) {
		vcam.queue_full++;
		return;
	}

	CVPixelBufferRef pb = NULL;
	if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, vcam.pool, &pb) != kCVReturnSuccess) {
		vcam.failed++;
		return;
	}

	copy_frame(pb, frame);

	CMSampleTimingInfo timing = {
		.duration = CMTimeMake(1, (int32_t)vcam.fps),
		.presentationTimeStamp = CMTimeMake((int64_t)frame->timestamp, 1000000000),
		.decodeTimeStamp = kCMTimeInvalid,
	};
	CMSampleBufferRef sample = NULL;
	OSStatus st = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pb, true, NULL, NULL, vcam.format,
							 &timing, &sample);
	CVPixelBufferRelease(pb);
	if (st != noErr || !sample) {
		if (vcam.failed++ == 0)
			blog(LOG_WARNING, "[OmniCast] Virtual camera: CMSampleBufferCreateForImageBuffer failed (%d)", (int)st);
		return;
	}
	/* The queue takes ownership of the sample on success. */
	if (CMSimpleQueueEnqueue(vcam.queue, sample) == noErr) {
		vcam.sent++;
	} else {
		CFRelease(sample);
		vcam.failed++;
	}
}

/* A minimal raw-video output. Going through an output (rather than connecting
 * to the canvas's video_t directly) is what makes libobs download frames from
 * the GPU at all: it raises the canvas's raw_active count, which a bare
 * video_output_connect doesn't, so the callback never ran. */
static const char *vcam_output_name(void *type_data)
{
	UNUSED_PARAMETER(type_data);
	return "OmniCast Virtual Camera";
}

static void *vcam_output_create(obs_data_t *settings, obs_output_t *output)
{
	UNUSED_PARAMETER(settings);
	return output;
}

static void vcam_output_destroy(void *data)
{
	UNUSED_PARAMETER(data);
}

static bool vcam_output_start(void *data)
{
	obs_output_t *output = data;
	return obs_output_can_begin_data_capture(output, 0) && obs_output_begin_data_capture(output, 0);
}

static void vcam_output_stop(void *data, uint64_t ts)
{
	UNUSED_PARAMETER(ts);
	obs_output_end_data_capture(data);
}

static void vcam_output_raw_video(void *data, struct video_data *frame)
{
	UNUSED_PARAMETER(data);
	vcam_frame(NULL, frame);
}

static struct obs_output_info vcam_output_info = {
	.id = "omnicast_virtualcam",
	.flags = OBS_OUTPUT_VIDEO,
	.get_name = vcam_output_name,
	.create = vcam_output_create,
	.destroy = vcam_output_destroy,
	.start = vcam_output_start,
	.stop = vcam_output_stop,
	.raw_video = vcam_output_raw_video,
};

static void register_vcam_output(void)
{
	obs_register_output(&vcam_output_info);
}

static void vcam_release(void)
{
	if (vcam.device && vcam.stream)
		CMIODeviceStopStream(vcam.device, vcam.stream);
	if (vcam.queue)
		CFRelease(vcam.queue);
	if (vcam.pool)
		CVPixelBufferPoolRelease(vcam.pool);
	if (vcam.format)
		CFRelease(vcam.format);
	if (vcam.fit_canvas) {
		obs_canvas_set_channel(vcam.fit_canvas, 0, NULL);
		if (vcam.fit_scene)
			obs_source_remove(obs_scene_get_source(vcam.fit_scene));
		obs_scene_release(vcam.fit_scene);
		obs_canvas_remove(vcam.fit_canvas);
		obs_canvas_release(vcam.fit_canvas);
	}
	memset(&vcam, 0, sizeof(vcam));
}

bool omni_virtualcam_start(omni_canvas canvas, char *err, size_t err_len)
{
	if (!engine.running) {
		set_err(err, err_len, "Engine is not running");
		return false;
	}
	omni_virtualcam_stop();

	vcam.device = find_vcam_device(true);
	if (vcam.device == kCMIOObjectUnknown) {
		set_err(err, err_len,
			"OBS Virtual Camera isn't installed. Open OBS once and click Start Virtual Camera to install it.");
		return false;
	}

	/* The extension publishes a source stream (what apps read) and then a sink
	 * stream (what we write). */
	UInt32 size = cmio_size(vcam.device, kCMIODevicePropertyStreams);
	CMIOStreamID streams[4] = {0};
	UInt32 used = 0;
	if (size < 2 * sizeof(CMIOStreamID) ||
	    !cmio_get(vcam.device, kCMIODevicePropertyStreams, streams, sizeof(streams), &used) ||
	    used < 2 * sizeof(CMIOStreamID)) {
		set_err(err, err_len, "OBS Virtual Camera didn't start. Restarting the Mac usually fixes this.");
		vcam_release();
		return false;
	}
	vcam.stream = streams[1];

	if (CMIOStreamCopyBufferQueue(vcam.stream, queue_altered, NULL, &vcam.queue) != kCMIOHardwareNoError ||
	    !vcam.queue) {
		set_err(err, err_len, "Couldn't connect to OBS Virtual Camera");
		vcam_release();
		return false;
	}

	NSDictionary *attrs = @{
		(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
		(id)kCVPixelBufferWidthKey: @(VCAM_WIDTH),
		(id)kCVPixelBufferHeightKey: @(VCAM_HEIGHT),
		(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
	};
	/* A bare description, as OBS's plugin uses. One built from a buffer carries
	 * that buffer's attachments, and every later buffer without them then fails
	 * CMSampleBufferCreateForImageBuffer, so no frame ever reached the camera. */
	if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &vcam.pool) !=
		    kCVReturnSuccess ||
	    CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
					   VCAM_WIDTH, VCAM_HEIGHT, NULL, &vcam.format) != noErr) {
		set_err(err, err_len, "Couldn't allocate virtual camera frames");
		vcam_release();
		return false;
	}

	if (CMIODeviceStartStream(vcam.device, vcam.stream) != kCMIOHardwareNoError) {
		set_err(err, err_len, "OBS Virtual Camera didn't start");
		vcam.stream = 0; /* nothing to stop */
		vcam_release();
		return false;
	}

	/* A 1920x1080 canvas is copied straight in. Any other size (the vertical
	 * canvas) is fitted on the GPU: a 1920x1080 canvas renders that canvas's
	 * scene centred with black bars, so each frame is again a plain copy.
	 * Scaling on the CPU (libobs) or with VideoToolbox's pixel transfer ran
	 * 5-7 ms a frame with stalls of over a second on the canvas's video thread,
	 * which made the canvas skip frames, recordings included. */
	bool vertical = canvas == OMNI_CANVAS_VERTICAL;
	const omni_canvas_config *cfg = vertical ? &engine.vertical : &engine.horizontal;
	vcam.canvas = canvas;
	vcam.fps = cfg->fps ? cfg->fps : 60;
	vcam.frame_width = VCAM_WIDTH;
	vcam.frame_height = VCAM_HEIGHT;
	video_t *video = vertical ? obs_canvas_get_video(engine.vertical_canvas) : obs_get_video();
	if (cfg->width != VCAM_WIDTH || cfg->height != VCAM_HEIGHT) {
		omni_canvas_config fit = {VCAM_WIDTH, VCAM_HEIGHT, vcam.fps, 0};
		struct obs_video_info ovi;
		fill_video_info(&ovi, NULL, &fit, vcam.fps);
		vcam.fit_canvas = obs_canvas_create("Virtual Camera", &ovi, ACTIVATE | SCENE_REF | EPHEMERAL);
		if (!vcam.fit_canvas || !obs_canvas_has_video(vcam.fit_canvas)) {
			set_err(err, err_len, "Couldn't set up the virtual camera canvas");
			vcam_release();
			return false;
		}
		vcam.fit_scene = obs_canvas_scene_create(vcam.fit_canvas, "Virtual Camera");
		place(vcam.fit_scene, obs_scene_get_source(vertical ? engine.scene_v : engine.scene_h), 0, 0, VCAM_WIDTH,
		      VCAM_HEIGHT, OBS_BOUNDS_SCALE_INNER, false);
		obs_canvas_set_channel(vcam.fit_canvas, 0, obs_scene_get_source(vcam.fit_scene));
		video = obs_canvas_get_video(vcam.fit_canvas);
	}

	struct video_scale_info conv = {
		.format = VIDEO_FORMAT_NV12,
		.width = vcam.frame_width,
		.height = vcam.frame_height,
		.range = VIDEO_RANGE_PARTIAL,
		.colorspace = VIDEO_CS_709,
	};
	vcam.output = obs_output_create("omnicast_virtualcam", "Virtual Camera", NULL, NULL);
	if (vcam.output) {
		obs_output_set_media(vcam.output, video, obs_get_audio());
		obs_output_set_video_conversion(vcam.output, &conv);
	}
	if (!vcam.output || !obs_output_start(vcam.output)) {
		set_err(err, err_len, "Couldn't read frames from the canvas");
		obs_output_release(vcam.output);
		vcam.output = NULL;
		vcam_release();
		return false;
	}
	vcam.active = true;
	blog(LOG_INFO, "[OmniCast] Virtual camera started (%s canvas, %ux%u, %s)", vertical ? "vertical" : "horizontal",
	     cfg->width, cfg->height, vcam.fit_canvas ? "fitted into 1920x1080 on the GPU" : "copied as is");
	return true;
}

void omni_virtualcam_stop(void)
{
	if (vcam.output) {
		obs_output_stop(vcam.output);
		/* Destroying the output waits for its capture to end, so no frame
		 * callback is running when the buffers below are freed. */
		obs_output_release(vcam.output);
		vcam.output = NULL;
	}
	vcam_release();
}

/* ------------------------------------------------------------------------- */
/* Call overlay */

#define MAX_OVERLAY 32

struct overlay_layer {
	char key[64];
	obs_source_t *idle;
	obs_source_t *talk;
	obs_sceneitem_t *idle_item;
	obs_sceneitem_t *talk_item;
	bool speaking;
};

static struct {
	struct overlay_layer layers[MAX_OVERLAY];
	bool hidden;
} overlay;

static struct overlay_layer *overlay_find(const char *key, bool create)
{
	struct overlay_layer *free_slot = NULL;
	for (int i = 0; i < MAX_OVERLAY; i++) {
		struct overlay_layer *l = &overlay.layers[i];
		if (l->key[0] && strcmp(l->key, key) == 0)
			return l;
		if (!l->key[0] && !free_slot)
			free_slot = l;
	}
	if (create && free_slot)
		snprintf(free_slot->key, sizeof(free_slot->key), "%s", key);
	return create ? free_slot : NULL;
}

static void overlay_apply_visibility(struct overlay_layer *l)
{
	if (l->idle_item)
		obs_sceneitem_set_visible(l->idle_item, !overlay.hidden && !l->speaking);
	if (l->talk_item)
		obs_sceneitem_set_visible(l->talk_item, !overlay.hidden && l->speaking);
}

static void overlay_load(obs_source_t **source, obs_sceneitem_t **item, const char *name, const char *path)
{
	obs_data_t *s = obs_data_create();
	obs_data_set_string(s, "file", path);
	if (*source) {
		obs_source_update(*source, s);
	} else {
		*source = obs_source_create_private("image_source", name, s);
		*item = *source ? obs_scene_add(engine.scene_h, *source) : NULL;
		if (*item) {
			/* Centre-aligned, so flipping mirrors in place. */
			obs_sceneitem_set_alignment(*item, OBS_ALIGN_CENTER);
			obs_sceneitem_set_bounds_type(*item, OBS_BOUNDS_SCALE_INNER);
			obs_sceneitem_set_bounds_alignment(*item, OBS_ALIGN_CENTER);
		}
	}
	obs_data_release(s);
}

void omni_overlay_set_images(const char *key, const char *idle_png, const char *talk_png)
{
	if (!engine.running || !key || !*key)
		return;
	struct overlay_layer *l = overlay_find(key, true);
	if (!l)
		return;
	overlay_load(&l->idle, &l->idle_item, "Call member", idle_png);
	overlay_load(&l->talk, &l->talk_item, "Call member talking", talk_png);
	overlay_apply_visibility(l);
}

void omni_overlay_place(const char *key, float cx, float cy, float width, float height, bool flip, float lift)
{
	struct overlay_layer *l = overlay_find(key, false);
	if (!l)
		return;
	struct vec2 bounds = {.x = width, .y = height};
	struct vec2 scale = {.x = flip ? -1.0f : 1.0f, .y = 1.0f};
	obs_sceneitem_t *items[2] = {l->idle_item, l->talk_item};
	for (int i = 0; i < 2; i++) {
		if (!items[i])
			continue;
		struct vec2 pos = {.x = cx, .y = i == 1 ? cy - lift : cy};
		obs_sceneitem_set_pos(items[i], &pos);
		obs_sceneitem_set_bounds(items[i], &bounds);
		obs_sceneitem_set_scale(items[i], &scale);
	}
}

void omni_overlay_set_speaking(const char *key, bool speaking)
{
	struct overlay_layer *l = overlay_find(key, false);
	if (!l || l->speaking == speaking)
		return;
	l->speaking = speaking;
	overlay_apply_visibility(l);
}

static void overlay_free(struct overlay_layer *l)
{
	if (l->idle_item)
		obs_sceneitem_remove(l->idle_item);
	if (l->talk_item)
		obs_sceneitem_remove(l->talk_item);
	obs_source_release(l->idle);
	obs_source_release(l->talk);
	memset(l, 0, sizeof(*l));
}

void omni_overlay_remove(const char *key)
{
	struct overlay_layer *l = overlay_find(key, false);
	if (l)
		overlay_free(l);
}

void omni_overlay_set_visible(bool visible)
{
	overlay.hidden = !visible;
	for (int i = 0; i < MAX_OVERLAY; i++) {
		if (overlay.layers[i].key[0])
			overlay_apply_visibility(&overlay.layers[i]);
	}
}

static void overlay_clear(void)
{
	for (int i = 0; i < MAX_OVERLAY; i++) {
		if (overlay.layers[i].key[0])
			overlay_free(&overlay.layers[i]);
	}
	overlay.hidden = false;
}
