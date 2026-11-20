// Previews: each canvas's finished frame, drawn into a WinUI SwapChainPanel.
//
// The swap chain lives on libobs's own D3D11 device. libobs calls us right
// after it renders each canvas (obs_add_main_rendered_callback runs once per
// canvas, with that canvas's texture still bound as the render target), so we
// scale that texture into the panel on the GPU and present. No CPU copy, no
// second composite of the scene, no extra frame of latency.
#include "internal.h"

#include <windows.h>
#include <d3d11.h>
#include <dxgi1_3.h>
#include <cmath>
#include <mutex>

// From microsoft.ui.xaml.media.dxinterop.h (Windows App SDK).
MIDL_INTERFACE("63aad0b8-7c24-40ff-85a8-640d944cc325")
ISwapChainPanelNative : public IUnknown
{
	virtual HRESULT STDMETHODCALLTYPE SetSwapChain(IDXGISwapChain * swapChain) = 0;
};

namespace oc {

struct Preview {
	IDXGISwapChain1 *swap = nullptr;
	ISwapChainPanelNative *panel = nullptr;
	ID3D11Texture2D *back = nullptr;
	gs_texture_t *target = nullptr; // what we draw into; copied to the back buffer
	uint32_t cx = 0, cy = 0;
	std::atomic<bool> enabled{true};
	bool logged = false;
};

static Preview previews[2];
static bool registered = false;

static void release_buffers(Preview &p)
{
	if (p.target) {
		gs_texture_destroy(p.target);
		p.target = nullptr;
	}
	if (p.back) {
		p.back->Release();
		p.back = nullptr;
	}
}

// Graphics context must be entered.
static bool make_buffers(Preview &p)
{
	if (FAILED(p.swap->GetBuffer(0, __uuidof(ID3D11Texture2D), (void **)&p.back)))
		return false;
	// GS_BGRA, not GS_BGRA_UNORM: libobs draws the canvas in linear light and
	// relies on an sRGB view of the target to encode it back. A plain UNORM
	// target has no sRGB view, so the preview came out much darker than the
	// stream. (Same format family as the swap chain's buffer, so the copy works.)
	p.target = gs_texture_create(p.cx, p.cy, GS_BGRA, 1, nullptr, GS_RENDER_TARGET);
	return p.target != nullptr;
}

static void pixel_size(float w, float h, float sx, float sy, uint32_t &cx, uint32_t &cy)
{
	cx = (uint32_t)fmaxf(1.0f, ceilf(w * (sx > 0 ? sx : 1.0f)));
	cy = (uint32_t)fmaxf(1.0f, ceilf(h * (sy > 0 ? sy : 1.0f)));
}

// The panel scales its swap chain by the display's scale; undo that so one
// swap-chain pixel is one screen pixel (sharp at 125%, 150%, ...).
static void set_transform(Preview &p, float sx, float sy)
{
	IDXGISwapChain2 *sc2 = nullptr;
	if (SUCCEEDED(p.swap->QueryInterface(__uuidof(IDXGISwapChain2), (void **)&sc2))) {
		DXGI_MATRIX_3X2_F m{};
		m._11 = 1.0f / (sx > 0 ? sx : 1.0f);
		m._22 = 1.0f / (sy > 0 ? sy : 1.0f);
		sc2->SetMatrixTransform(&m);
		sc2->Release();
	}
}

static void draw(int canvas, Preview &p, gs_texture_t *frame)
{
	uint32_t fw = gs_texture_get_width(frame), fh = gs_texture_get_height(frame);
	gs_texture_t *prev_rt = gs_get_render_target();
	gs_zstencil_t *prev_zs = gs_get_zstencil_target();
	enum gs_color_space prev_space = gs_get_color_space();

	gs_set_render_target(p.target, nullptr);
	gs_viewport_push();
	gs_projection_push();
	gs_blend_state_push();
	gs_enable_blending(false);
	const bool prev_srgb = gs_framebuffer_srgb_enabled();
	gs_enable_framebuffer_srgb(false);

	vec4 black;
	vec4_set(&black, 0.0f, 0.0f, 0.0f, 1.0f);
	gs_set_viewport(0, 0, (int)p.cx, (int)p.cy);
	gs_clear(GS_CLEAR_COLOR, &black, 0.0f, 0);

	// Letterbox: fit the frame inside the panel.
	float scale = fminf((float)p.cx / fw, (float)p.cy / fh);
	int w = (int)(fw * scale), h = (int)(fh * scale);
	gs_set_viewport(((int)p.cx - w) / 2, ((int)p.cy - h) / 2, w, h);
	gs_ortho(0.0f, (float)fw, 0.0f, (float)fh, -100.0f, 100.0f);

	// libobs's own helpers draw the canvas's finished texture with the right
	// colour-space handling, opaque (no blending).
	if (canvas == OC_WIDE)
		obs_render_main_texture_src_color_only();
	else
		obs_render_canvas_texture_src_color_only(engine.tall_canvas);

	gs_enable_framebuffer_srgb(prev_srgb);
	gs_blend_state_pop();
	gs_projection_pop();
	gs_viewport_pop();
	gs_set_render_target_with_color_space(prev_rt, prev_zs, prev_space);

	// Copy into the back buffer and present without ever blocking libobs's
	// render thread: if the compositor still holds the last frame, skip one.
	auto *dev = (ID3D11Device *)gs_get_device_obj();
	ID3D11DeviceContext *ctx = nullptr;
	dev->GetImmediateContext(&ctx);
	ctx->CopyResource(p.back, (ID3D11Resource *)gs_texture_get_obj(p.target));
	ctx->Release();
	HRESULT hr = p.swap->Present(0, DXGI_PRESENT_DO_NOT_WAIT);
	if (!p.logged) {
		blog(LOG_INFO, "[OmniCast] preview: first frame %ux%u -> %ux%u, Present 0x%08lx", fw, fh, p.cx, p.cy,
		     (unsigned long)hr);
		p.logged = true;
	}
}

static void on_rendered(void *)
{
	gs_texture_t *frame = gs_get_render_target();
	if (!frame)
		return;
	int canvas = -1;
	if (frame == obs_get_main_texture())
		canvas = OC_WIDE;
	else if (gs_texture_get_width(frame) == engine.tall_w && gs_texture_get_height(frame) == engine.tall_h)
		canvas = OC_TALL;
	static int unmatched_logs = 0;
	if (canvas < 0) {
		if (unmatched_logs < 4) {
			unmatched_logs++;
			blog(LOG_INFO, "[OmniCast] preview: rendered callback for an unknown %ux%u texture",
			     gs_texture_get_width(frame), gs_texture_get_height(frame));
		}
		return;
	}
	Preview &p = previews[canvas];
	if (!p.swap || !p.target || !p.enabled.load(std::memory_order_relaxed))
		return;
	draw(canvas, p, frame);
}

void preview_register()
{
	if (!registered) {
		obs_add_main_rendered_callback(on_rendered, nullptr);
		registered = true;
	}
}

void preview_unregister()
{
	if (registered) {
		obs_remove_main_rendered_callback(on_rendered, nullptr);
		registered = false;
	}
}

void preview_detach_all()
{
	oc_preview_detach(OC_WIDE);
	oc_preview_detach(OC_TALL);
}

} // namespace oc

using namespace oc;

OC_API int32_t oc_preview_attach(int32_t canvas, void *panel, float width, float height, float sx, float sy)
{
	if (!engine.running || (canvas != OC_WIDE && canvas != OC_TALL) || !panel)
		return 0;
	oc_preview_detach(canvas);
	Preview &p = previews[canvas];
	pixel_size(width, height, sx, sy, p.cx, p.cy);

	HRESULT hr = ((IUnknown *)panel)->QueryInterface(__uuidof(ISwapChainPanelNative), (void **)&p.panel);
	if (FAILED(hr)) {
		blog(LOG_WARNING, "[OmniCast] preview %d: the panel has no ISwapChainPanelNative (0x%08lx)", canvas,
		     (unsigned long)hr);
		return 0;
	}

	bool ok = false;
	obs_enter_graphics();
	auto *dev = (ID3D11Device *)gs_get_device_obj();
	IDXGIDevice *dxgi = nullptr;
	IDXGIAdapter *adapter = nullptr;
	IDXGIFactory2 *factory = nullptr;
	if (dev && SUCCEEDED(dev->QueryInterface(__uuidof(IDXGIDevice), (void **)&dxgi)) &&
	    SUCCEEDED(dxgi->GetAdapter(&adapter)) &&
	    SUCCEEDED(adapter->GetParent(__uuidof(IDXGIFactory2), (void **)&factory))) {
		DXGI_SWAP_CHAIN_DESC1 d{};
		d.Width = p.cx;
		d.Height = p.cy;
		d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
		d.SampleDesc.Count = 1;
		d.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
		d.BufferCount = 2;
		d.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
		d.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
		d.Scaling = DXGI_SCALING_STRETCH;
		hr = factory->CreateSwapChainForComposition(dev, &d, nullptr, &p.swap);
		ok = SUCCEEDED(hr) && make_buffers(p);
		if (!ok)
			blog(LOG_WARNING, "[OmniCast] preview %d: swap chain %ux%u failed (0x%08lx)", canvas, p.cx, p.cy,
			     (unsigned long)hr);
	}
	if (factory)
		factory->Release();
	if (adapter)
		adapter->Release();
	if (dxgi)
		dxgi->Release();
	obs_leave_graphics();

	if (ok) {
		hr = p.panel->SetSwapChain(p.swap);
		if (FAILED(hr)) {
			blog(LOG_WARNING, "[OmniCast] preview %d: SetSwapChain failed (0x%08lx)", canvas, (unsigned long)hr);
			ok = false;
		}
	}
	if (!ok) {
		oc_preview_detach(canvas);
		return 0;
	}
	set_transform(p, sx, sy);
	p.enabled = true;
	p.logged = false;
	blog(LOG_INFO, "[OmniCast] preview %d attached at %ux%u (scale %.2f)", canvas, p.cx, p.cy, sx);
	return 1;
}

OC_API void oc_preview_resize(int32_t canvas, float width, float height, float sx, float sy)
{
	if (canvas != OC_WIDE && canvas != OC_TALL)
		return;
	Preview &p = previews[canvas];
	if (!p.swap)
		return;
	uint32_t cx, cy;
	pixel_size(width, height, sx, sy, cx, cy);
	if (cx != p.cx || cy != p.cy) {
		obs_enter_graphics();
		release_buffers(p);
		p.cx = cx;
		p.cy = cy;
		if (SUCCEEDED(p.swap->ResizeBuffers(2, cx, cy, DXGI_FORMAT_B8G8R8A8_UNORM, 0)))
			make_buffers(p);
		obs_leave_graphics();
	}
	set_transform(p, sx, sy);
}

OC_API void oc_preview_set_enabled(int32_t canvas, int32_t enabled)
{
	if (canvas == OC_WIDE || canvas == OC_TALL)
		previews[canvas].enabled = enabled != 0;
}

OC_API void oc_preview_detach(int32_t canvas)
{
	if (canvas != OC_WIDE && canvas != OC_TALL)
		return;
	Preview &p = previews[canvas];
	if (p.panel) {
		p.panel->SetSwapChain(nullptr);
		p.panel->Release();
		p.panel = nullptr;
	}
	if (p.swap) {
		obs_enter_graphics();
		release_buffers(p);
		p.swap->Release();
		p.swap = nullptr;
		obs_leave_graphics();
	}
	p.cx = p.cy = 0;
}
