// Scenes: presets of what the screen slot shows, which camera, and the layout
// on each canvas. One scene is on air at a time on both canvases, reached
// through a transition.
//
// Each OmniCast scene is a pair of libobs scenes (one per canvas). Each canvas's
// output channel 0 holds a transition, and the on-air scene is that
// transition's source, so switching is obs_transition_start on both.
//
// Sources are shared between scenes and reference-counted: two scenes showing
// the same monitor or camera use one capture. libobs only runs a capture while
// it's shown, so captures in scenes that aren't on air stop (and DirectShow
// devices are released, light off).
#include "internal.h"

#include <cstring>
#include <map>
#include <memory>
#include <vector>

namespace oc {

// ---------------------------------------------------------------------------
// Shared sources

struct Shared {
	obs_source_t *source = nullptr;
	int refs = 0;
};

static std::map<std::string, Shared> shared;

static obs_source_t *acquire(const std::string &key, obs_source_t *(*make)(const std::string &, int, void *), int kind,
			     void *arg)
{
	auto it = shared.find(key);
	if (it != shared.end()) {
		it->second.refs++;
		return it->second.source;
	}
	obs_source_t *src = make(key, kind, arg);
	if (!src)
		return nullptr;
	shared[key] = Shared{src, 1};
	return src;
}

static void release_shared(const std::string &key)
{
	auto it = shared.find(key);
	if (it == shared.end())
		return;
	if (--it->second.refs <= 0) {
		obs_source_release(it->second.source);
		shared.erase(it);
	}
}

// A capture card often shows up as a video device plus an audio device with the
// same name (Elgato HD60 X). Finds that audio device's id, or "".
static std::string matching_audio_device(obs_source_t *dshow, const std::string &video_id)
{
	std::string vname = video_id;
	size_t colon = vname.find(':');
	if (colon != std::string::npos)
		vname.resize(colon);
	if (vname.empty())
		return {};
	std::string found;
	obs_properties_t *props = obs_source_properties(dshow);
	obs_property_t *p = props ? obs_properties_get(props, "audio_device_id") : nullptr;
	for (size_t i = 0; p && i < obs_property_list_item_count(p); i++) {
		const char *id = obs_property_list_item_string(p, i);
		const char *name = obs_property_list_item_name(p, i);
		if (id && name && *id && strstr(name, vname.c_str())) {
			found = id;
			break;
		}
	}
	obs_properties_destroy(props);
	return found;
}

// key is "screen:<kind>:<id>"; arg is the id.
static obs_source_t *make_screen(const std::string &, int kind, void *arg)
{
	const std::string &id = *(const std::string *)arg;
	obs_data_t *s = obs_data_create();
	const char *type = "monitor_capture";
	switch (kind) {
	case OC_SCREEN_WINDOW:
		type = "window_capture";
		obs_data_set_string(s, "window", id.c_str());
		obs_data_set_int(s, "method", 0); // automatic: Windows Graphics Capture when it's needed
		obs_data_set_bool(s, "cursor", true);
		break;
	case OC_SCREEN_GAME:
		type = "game_capture";
		obs_data_set_string(s, "capture_mode", "window");
		obs_data_set_string(s, "window", id.c_str());
		obs_data_set_bool(s, "capture_cursor", true);
		break;
	case OC_SCREEN_DEVICE:
		type = "dshow_input";
		obs_data_set_string(s, "video_device_id", id.c_str());
		obs_data_set_int(s, "res_type", 0);
		obs_data_set_bool(s, "deactivate_when_not_showing", true);
		obs_data_set_int(s, "audio_output_mode", 0); // the card's sound comes through this source
		break;
	default:
		obs_data_set_string(s, "monitor_id", id.c_str());
		obs_data_set_int(s, "method", 0); // automatic: DXGI duplication or Windows Graphics Capture
		obs_data_set_bool(s, "capture_cursor", true);
		break;
	}
	obs_source_t *src = obs_source_create(type, "Screen", s, nullptr);
	obs_data_release(s);
	if (!src)
		return nullptr;

	if (kind == OC_SCREEN_DEVICE) {
		std::string audio = matching_audio_device(src, id);
		if (!audio.empty()) {
			obs_data_t *u = obs_data_create();
			obs_data_set_bool(u, "use_custom_audio_device", true);
			obs_data_set_string(u, "audio_device_id", audio.c_str());
			obs_source_update(src, u);
			obs_data_release(u);
		}
		obs_source_set_audio_mixers(src, MIX_ALL | MIX_DESKTOP);
	} else {
		obs_source_set_audio_mixers(src, 0);
	}
	return src;
}

// The camera is a DirectShow source that's only opened while it's shown.
static obs_source_t *make_camera(const std::string &, int, void *arg)
{
	const std::string &id = *(const std::string *)arg;
	obs_data_t *s = obs_data_create();
	obs_data_set_string(s, "video_device_id", id.c_str());
	obs_data_set_bool(s, "deactivate_when_not_showing", true);
	obs_data_set_int(s, "res_type", 0); // the device's preferred format
	obs_source_t *src = obs_source_create("dshow_input", "Camera", s, nullptr);
	obs_data_release(s);
	if (src)
		obs_source_set_audio_mixers(src, 0); // webcam mics stay out of the mix
	return src;
}

// ---------------------------------------------------------------------------
// Scenes

struct Scene {
	std::string key;
	int screen_kind = OC_SCREEN_MONITOR;
	std::string screen_id; // resolved (never "" for a monitor)
	std::string camera_id;
	int wide_layout = OC_WIDE_SCREEN_CAMERA;
	int corner = OC_CORNER_BOTTOM_RIGHT;
	int tall_layout = OC_TALL_SPLIT;

	obs_scene_t *scene[2] = {};
	std::vector<obs_sceneitem_t *> items;
	std::string screen_key, camera_key; // shared sources held
	obs_source_t *screen = nullptr, *camera = nullptr;
};

static std::map<std::string, std::unique_ptr<Scene>> scenes;

// Where the camera goes when the user has arranged it (canvas pixels), per
// canvas; w <= 0 = the layout's own place.
struct CamBox {
	float x = 0, y = 0, w = 0, h = 0;
};
static CamBox cam_box[2];
static std::string on_air;

static obs_source_t *transition[2] = {};
static std::string transition_id;

static void place(Scene &s, int canvas, obs_source_t *src, float x, float y, float w, float h, obs_bounds_type type,
		  bool crop)
{
	if (!src)
		return;
	obs_sceneitem_t *item = obs_scene_add(s.scene[canvas], src);
	vec2 pos{x, y}, bounds{w, h};
	obs_sceneitem_set_pos(item, &pos);
	obs_sceneitem_set_bounds_type(item, type);
	obs_sceneitem_set_bounds(item, &bounds);
	obs_sceneitem_set_bounds_crop(item, crop);
	s.items.push_back(item);
}

static void clear_items(Scene &s)
{
	for (obs_sceneitem_t *item : s.items)
		obs_sceneitem_remove(item);
	s.items.clear();
}

// Lays the scene's screen and camera out on both canvases. Layouts that need
// a camera fall back to the screen when the scene has none.
static void lay_out(Scene &s)
{
	clear_items(s);
	const float ww = (float)engine.wide_w, wh = (float)engine.wide_h;
	const float tw = (float)engine.tall_w, th = (float)engine.tall_h;
	obs_source_t *cam = s.camera;

	// 16:9. Items are added bottom to top: screen, then camera.
	int wide = s.wide_layout;
	if (!cam && wide != OC_WIDE_SCREEN)
		wide = OC_WIDE_SCREEN;
	if (wide == OC_WIDE_CAMERA) {
		place(s, OC_WIDE, cam, 0, 0, ww, wh, OBS_BOUNDS_SCALE_OUTER, true);
	} else {
		place(s, OC_WIDE, s.screen, 0, 0, ww, wh, OBS_BOUNDS_SCALE_INNER, false);
		if (wide == OC_WIDE_SCREEN_CAMERA && cam_box[OC_WIDE].w > 0) {
			const CamBox &b = cam_box[OC_WIDE];
			place(s, OC_WIDE, cam, b.x, b.y, b.w, b.h, OBS_BOUNDS_SCALE_INNER, false);
		} else if (wide == OC_WIDE_SCREEN_CAMERA) {
			float cw = ww * 0.25f, ch = wh * 0.25f, m = wh * 0.025f;
			bool right = s.corner == OC_CORNER_BOTTOM_RIGHT || s.corner == OC_CORNER_TOP_RIGHT;
			bool bottom = s.corner == OC_CORNER_BOTTOM_RIGHT || s.corner == OC_CORNER_BOTTOM_LEFT;
			place(s, OC_WIDE, cam, right ? ww - cw - m : m, bottom ? wh - ch - m : m, cw, ch,
			      OBS_BOUNDS_SCALE_INNER, false);
		}
	}

	// 9:16
	int tall = s.tall_layout;
	if (!cam && tall != OC_TALL_SCREEN)
		tall = OC_TALL_SCREEN;
	if (tall == OC_TALL_CAMERA) {
		place(s, OC_TALL, cam, 0, 0, tw, th, OBS_BOUNDS_SCALE_OUTER, true);
	} else if (tall == OC_TALL_SCREEN) {
		// Fill the frame; the sides of a 16:9 screen are cropped (centre kept).
		place(s, OC_TALL, s.screen, 0, 0, tw, th, OBS_BOUNDS_SCALE_OUTER, true);
	} else {
		place(s, OC_TALL, s.screen, 0, 0, tw, th * 0.5f, OBS_BOUNDS_SCALE_INNER, false);
		if (cam_box[OC_TALL].w > 0) {
			const CamBox &b = cam_box[OC_TALL];
			place(s, OC_TALL, cam, b.x, b.y, b.w, b.h, OBS_BOUNDS_SCALE_OUTER, true);
		} else {
			place(s, OC_TALL, cam, 0, th * 0.5f, tw, th * 0.5f, OBS_BOUNDS_SCALE_OUTER, true);
		}
	}
}

static void update_capture_channel()
{
	auto it = scenes.find(on_air);
	Scene *s = it == scenes.end() ? nullptr : it->second.get();
	audio_attach(OC_CH_CAPTURE, s && s->screen_kind == OC_SCREEN_DEVICE ? s->screen : nullptr);
}

static void destroy_scene(Scene &s)
{
	clear_items(s);
	for (auto &sc : s.scene) {
		if (sc) {
			// The tall canvas holds its own reference; removing drops it now.
			obs_source_remove(obs_scene_get_source(sc));
			obs_scene_release(sc);
		}
		sc = nullptr;
	}
	if (!s.screen_key.empty())
		release_shared(s.screen_key);
	if (!s.camera_key.empty())
		release_shared(s.camera_key);
}

// ---------------------------------------------------------------------------
// Transitions

static const char *transition_type(int kind)
{
	switch (kind) {
	case OC_TRANSITION_FADE_BLACK: return "fade_to_color_transition";
	case OC_TRANSITION_SLIDE: return "slide_transition";
	case OC_TRANSITION_SWIPE: return "swipe_transition";
	default: return "fade_transition"; // a cut is an instant switch on any transition
	}
}

static void set_channel(int canvas, obs_source_t *src)
{
	if (canvas == OC_WIDE)
		obs_set_output_source(0, src);
	else if (engine.tall_canvas)
		obs_canvas_set_channel(engine.tall_canvas, 0, src);
}

// Makes the canvases' transitions the given type, keeping what's on air.
static void use_transition(int kind)
{
	const char *type = transition_type(kind);
	if (transition[0] && transition_id == type)
		return;
	for (int c = 0; c < 2; c++) {
		obs_data_t *s = obs_data_create();
		if (kind == OC_TRANSITION_FADE_BLACK)
			obs_data_set_int(s, "color", 0xFF000000);
		if (kind == OC_TRANSITION_SLIDE || kind == OC_TRANSITION_SWIPE)
			obs_data_set_string(s, "direction", "left");
		obs_source_t *tr = obs_source_create_private(type, c == OC_WIDE ? "16:9 transition" : "9:16 transition", s);
		obs_data_release(s);
		if (!tr)
			continue;
		uint32_t w = c == OC_WIDE ? engine.wide_w : engine.tall_w;
		uint32_t h = c == OC_WIDE ? engine.wide_h : engine.tall_h;
		obs_transition_set_size(tr, w, h);
		obs_transition_set_alignment(tr, OBS_ALIGN_CENTER);
		obs_transition_set_scale_type(tr, OBS_TRANSITION_SCALE_ASPECT);
		if (transition[c]) {
			obs_source_t *current = obs_transition_get_active_source(transition[c]);
			obs_transition_set(tr, current);
			obs_source_release(current);
		}
		set_channel(c, tr);
		obs_source_release(transition[c]);
		transition[c] = tr;
	}
	transition_id = type;
}

void scenes_init()
{
	use_transition(OC_TRANSITION_FADE);
}

void scenes_release()
{
	for (int c = 0; c < 2; c++)
		set_channel(c, nullptr);
	for (auto &tr : transition) {
		obs_source_release(tr);
		tr = nullptr;
	}
	transition_id.clear();
	audio_attach(OC_CH_CAPTURE, nullptr);
	for (auto &kv : scenes)
		destroy_scene(*kv.second);
	scenes.clear();
	on_air.clear();
	for (auto &kv : shared)
		obs_source_release(kv.second.source);
	shared.clear();
}

} // namespace oc

using namespace oc;

// ---------------------------------------------------------------------------
// Public

OC_API void oc_scene_set(const oc_scene_desc *d)
{
	if (!engine.running || !d || !d->key || !*d->key)
		return;
	auto &slot = scenes[d->key];
	bool created = !slot;
	if (created) {
		slot = std::make_unique<Scene>();
		slot->key = d->key;
		std::string wide_name = std::string("16:9 ") + d->key, tall_name = std::string("9:16 ") + d->key;
		slot->scene[OC_WIDE] = obs_scene_create_private(wide_name.c_str());
		slot->scene[OC_TALL] = obs_canvas_scene_create(engine.tall_canvas, tall_name.c_str());
	}
	Scene &s = *slot;

	s.screen_kind = d->screen_kind >= OC_SCREEN_MONITOR && d->screen_kind <= OC_SCREEN_DEVICE ? d->screen_kind
												   : OC_SCREEN_MONITOR;
	s.screen_id = d->screen_id ? d->screen_id : "";
	// "" means the main display to OmniCast (and "no monitor" to OBS).
	if (s.screen_kind == OC_SCREEN_MONITOR && s.screen_id.empty())
		s.screen_id = primary_monitor_id();
	s.camera_id = d->camera_id ? d->camera_id : "";
	s.wide_layout = d->wide_layout;
	s.corner = d->camera_corner;
	s.tall_layout = d->tall_layout;

	// Take the new sources before letting go of the old ones, so a source both
	// versions use (the usual case) stays open instead of restarting.
	std::string screen_key = "screen:" + std::to_string(s.screen_kind) + ":" + s.screen_id;
	std::string camera_key = s.camera_id.empty() ? "" : "camera:" + s.camera_id;
	obs_source_t *screen = acquire(screen_key, make_screen, s.screen_kind, &s.screen_id);
	obs_source_t *camera = camera_key.empty() ? nullptr : acquire(camera_key, make_camera, 0, &s.camera_id);
	clear_items(s);
	if (!s.screen_key.empty())
		release_shared(s.screen_key);
	if (!s.camera_key.empty())
		release_shared(s.camera_key);
	s.screen_key = screen ? screen_key : "";
	s.camera_key = camera ? camera_key : "";
	s.screen = screen;
	s.camera = camera;

	lay_out(s);
	if (s.key == on_air)
		update_capture_channel();
}

OC_API int32_t oc_scene_remove(const char *key)
{
	if (!key)
		return 0;
	auto it = scenes.find(key);
	if (it == scenes.end())
		return 1;
	if (on_air == key)
		return 0;
	destroy_scene(*it->second);
	scenes.erase(it);
	return 1;
}

OC_API int32_t oc_scene_activate(const char *key, int32_t kind, int32_t duration_ms)
{
	if (!engine.running || !key)
		return 0;
	auto it = scenes.find(key);
	if (it == scenes.end())
		return 0;
	Scene &s = *it->second;
	bool instant = on_air.empty() || kind == OC_TRANSITION_CUT || duration_ms <= 0;
	if (!instant)
		use_transition(kind);
	if (duration_ms > 10000)
		duration_ms = 10000;

	for (int c = 0; c < 2; c++) {
		if (!transition[c])
			continue;
		obs_source_t *dest = obs_scene_get_source(s.scene[c]);
		if (instant)
			obs_transition_set(transition[c], dest);
		else
			obs_transition_start(transition[c], OBS_TRANSITION_MODE_AUTO, (uint32_t)duration_ms, dest);
	}
	on_air = key;
	update_capture_channel();
	blog(LOG_INFO, "[OmniCast] scene '%s' on air (%s, %d ms)", key, instant ? "cut" : transition_id.c_str(),
	     instant ? 0 : duration_ms);
	return 1;
}

OC_API const char *oc_scene_active(void)
{
	return on_air.c_str();
}

// The camera's box on one canvas, in canvas pixels; w <= 0 puts it back in
// the layout's own place. Used by the 16:9 "screen + camera" layout and the
// 9:16 split layout, in every scene.
OC_API void oc_camera_box(int32_t canvas, float x, float y, float w, float h)
{
	if (canvas < 0 || canvas > 1)
		return;
	cam_box[canvas] = w > 0 && h > 0 ? CamBox{x, y, w, h} : CamBox{};
	for (auto &kv : scenes)
		lay_out(*kv.second);
}
