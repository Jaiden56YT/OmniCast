// Overlays: pre-rendered images (chat, the now-playing card, the Discord call
// and your PNGtuber) on top of whatever scene is on air, on either canvas.
//
// Each canvas has one overlay scene on its own output channel, above the
// scene transition, so overlays stay put while scenes change. A layer is a
// private image_source with a colour filter for fading, as an item in the
// overlay scene of each canvas it's placed on. The app draws the PNGs; the
// engine only re-reads a file when the app says it changed, never per frame.
// A layer that's hidden or fully faded costs nothing to render.
#include "internal.h"

#include <cstring>
#include <map>
#include <string>

namespace oc {

static constexpr uint32_t OVERLAY_CHANNEL = 6;

struct Layer {
	obs_source_t *image = nullptr;
	obs_source_t *fade = nullptr;
	obs_sceneitem_t *item[2] = {};
	bool placed[2] = {};
	float opacity = 0.0f;
	int order = 0;
};

static obs_scene_t *overlay_scene[2] = {};
static std::map<std::string, Layer> layers;
static int next_order = 0;

static void set_overlay_channel(int canvas, obs_source_t *src)
{
	if (canvas == OC_WIDE)
		obs_set_output_source(OVERLAY_CHANNEL, src);
	else if (engine.tall_canvas)
		obs_canvas_set_channel(engine.tall_canvas, OVERLAY_CHANNEL, src);
}

void overlays_init()
{
	overlay_scene[OC_WIDE] = obs_scene_create_private("Overlays 16:9");
	overlay_scene[OC_TALL] = obs_canvas_scene_create(engine.tall_canvas, "Overlays 9:16");
	for (int c = 0; c < 2; c++)
		if (overlay_scene[c])
			set_overlay_channel(c, obs_scene_get_source(overlay_scene[c]));
}

static void update_visibility(Layer &l)
{
	for (int c = 0; c < 2; c++)
		if (l.item[c])
			obs_sceneitem_set_visible(l.item[c], l.placed[c] && l.opacity > 0.001f);
}

void overlays_release()
{
	for (auto &[key, l] : layers) {
		for (auto *item : l.item)
			if (item)
				obs_sceneitem_remove(item);
		if (l.fade)
			obs_source_release(l.fade);
		obs_source_release(l.image);
	}
	layers.clear();
	for (int c = 0; c < 2; c++) {
		set_overlay_channel(c, nullptr);
		if (overlay_scene[c]) {
			obs_source_remove(obs_scene_get_source(overlay_scene[c]));
			obs_scene_release(overlay_scene[c]);
		}
		overlay_scene[c] = nullptr;
	}
}

static Layer *find_layer(const char *key)
{
	auto it = key ? layers.find(key) : layers.end();
	return it == layers.end() ? nullptr : &it->second;
}

} // namespace oc

using namespace oc;

OC_API int32_t oc_layer_set_image(const char *key, const char *png_path)
{
	if (!engine.running || !key || !*key || !png_path)
		return 0;
	Layer *l = find_layer(key);
	obs_data_t *s = obs_data_create();
	obs_data_set_string(s, "file", png_path);
	obs_data_set_bool(s, "unload", false);
	obs_data_set_bool(s, "linear_alpha", true);
	if (l) {
		obs_source_update(l->image, s); // re-reads the file, even at the same path
		obs_data_release(s);
		return 1;
	}
	obs_source_t *img = obs_source_create_private("image_source", key, s);
	obs_data_release(s);
	if (!img)
		return 0;
	Layer nl;
	nl.image = img;
	nl.order = next_order++;
	obs_data_t *fs = obs_data_create();
	obs_data_set_double(fs, "opacity", 0.0);
	nl.fade = obs_source_create_private("color_filter_v2", "Fade", fs);
	if (!nl.fade)
		nl.fade = obs_source_create_private("color_filter", "Fade", fs);
	obs_data_release(fs);
	if (nl.fade)
		obs_source_filter_add(img, nl.fade);
	for (int c = 0; c < 2; c++) {
		if (!overlay_scene[c])
			continue;
		nl.item[c] = obs_scene_add(overlay_scene[c], img);
		obs_sceneitem_set_bounds_type(nl.item[c], OBS_BOUNDS_SCALE_INNER);
		obs_sceneitem_set_bounds_alignment(nl.item[c], OBS_ALIGN_CENTER);
		obs_sceneitem_set_visible(nl.item[c], false);
	}
	layers[key] = nl;
	return 1;
}

OC_API void oc_layer_place(const char *key, int32_t canvas, int32_t show, float x, float y, float w, float h)
{
	Layer *l = find_layer(key);
	if (!l || canvas < 0 || canvas > 1 || !l->item[canvas])
		return;
	vec2 pos{x, y}, bounds{w > 1 ? w : 1, h > 1 ? h : 1};
	obs_sceneitem_set_pos(l->item[canvas], &pos);
	obs_sceneitem_set_bounds(l->item[canvas], &bounds);
	l->placed[canvas] = show != 0;
	update_visibility(*l);
}

OC_API void oc_layer_set_opacity(const char *key, float opacity)
{
	Layer *l = find_layer(key);
	if (!l)
		return;
	l->opacity = opacity < 0 ? 0 : opacity > 1 ? 1 : opacity;
	if (l->fade) {
		obs_data_t *s = obs_data_create();
		if (!strcmp(obs_source_get_id(l->fade), "color_filter"))
			obs_data_set_int(s, "opacity", (long long)(l->opacity * 100.0f + 0.5f)); // the old filter: 0-100
		else
			obs_data_set_double(s, "opacity", l->opacity);
		obs_source_update(l->fade, s);
		obs_data_release(s);
	}
	update_visibility(*l);
}

OC_API void oc_layer_remove(const char *key)
{
	auto it = key ? layers.find(key) : layers.end();
	if (it == layers.end())
		return;
	Layer &l = it->second;
	for (auto *item : l.item)
		if (item)
			obs_sceneitem_remove(item);
	if (l.fade)
		obs_source_release(l.fade);
	obs_source_release(l.image);
	layers.erase(it);
}
