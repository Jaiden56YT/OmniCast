// Mic plugins: VST3 effects (STACKS, Muze, or any other) on the mic, as libobs
// audio filters. A plugin is loaded only when it's turned on, runs on libobs's
// audio thread at 48 kHz stereo, and opens its own editor window. Its state
// (getState/setState) is saved by the app.
//
// A minimal VST3 host written against Steinberg's interface headers only
// (MIT): module loading, component + controller (connected when they're
// separate), parameter changes from the editor delivered to the processor, a
// steady transport (120 BPM, playing) so tempo-synced plugins run, and editor
// windows on one UI thread.
#define INIT_CLASS_IID
#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstattributes.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivsthostapplication.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/ivstevents.h"

// INIT_CLASS_IID makes DECLARE_CLASS_IID in the headers above define the ids here.

#include "internal.h"

#include <windows.h>
#include <atomic>
#include <functional>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace oc {

// ---------------------------------------------------------------- COM-ish helpers

#define OC_FUNKNOWN(Iface)                                                                    \
	std::atomic<uint32> refs_{1};                                                             \
	uint32 PLUGIN_API addRef() override { return ++refs_; }                                    \
	uint32 PLUGIN_API release() override                                                      \
	{                                                                                         \
		uint32 r = --refs_;                                                                   \
		if (!r)                                                                               \
			delete this;                                                                      \
		return r;                                                                             \
	}                                                                                         \
	tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override                    \
	{                                                                                         \
		if (FUnknownPrivate::iidEqual(iid, FUnknown::iid) || FUnknownPrivate::iidEqual(iid, Iface::iid)) { \
			addRef();                                                                         \
			*obj = static_cast<Iface *>(this);                                                \
			return kResultOk;                                                                 \
		}                                                                                     \
		*obj = nullptr;                                                                       \
		return kNoInterface;                                                                  \
	}

class MemoryStream : public IBStream {
public:
	std::vector<uint8_t> data;
	int64 pos = 0;
	OC_FUNKNOWN(IBStream)
	tresult PLUGIN_API read(void *buffer, int32 n, int32 *got) override
	{
		int64 avail = (int64)data.size() - pos;
		int32 k = (int32)(n < avail ? n : (avail > 0 ? avail : 0));
		if (k)
			memcpy(buffer, data.data() + pos, k);
		pos += k;
		if (got)
			*got = k;
		return kResultOk;
	}
	tresult PLUGIN_API write(void *buffer, int32 n, int32 *wrote) override
	{
		if (pos + n > (int64)data.size())
			data.resize((size_t)(pos + n));
		memcpy(data.data() + pos, buffer, n);
		pos += n;
		if (wrote)
			*wrote = n;
		return kResultOk;
	}
	tresult PLUGIN_API seek(int64 p, int32 mode, int64 *result) override
	{
		int64 base = mode == kIBSeekSet ? 0 : mode == kIBSeekCur ? pos : (int64)data.size();
		pos = base + p;
		if (pos < 0)
			pos = 0;
		if (result)
			*result = pos;
		return kResultOk;
	}
	tresult PLUGIN_API tell(int64 *p) override
	{
		*p = pos;
		return kResultOk;
	}
};

class AttributeList : public IAttributeList {
	struct Value {
		int type = 0; // 0 int, 1 float, 2 string, 3 binary
		int64 i = 0;
		double f = 0;
		std::u16string s;
		std::vector<uint8_t> b;
	};
	std::map<std::string, Value> values_;

public:
	OC_FUNKNOWN(IAttributeList)
	tresult PLUGIN_API setInt(AttrID id, int64 v) override { values_[id] = {0, v}; return kResultOk; }
	tresult PLUGIN_API getInt(AttrID id, int64 &v) override
	{
		auto it = values_.find(id);
		if (it == values_.end() || it->second.type != 0) return kResultFalse;
		v = it->second.i;
		return kResultOk;
	}
	tresult PLUGIN_API setFloat(AttrID id, double v) override { Value x; x.type = 1; x.f = v; values_[id] = x; return kResultOk; }
	tresult PLUGIN_API getFloat(AttrID id, double &v) override
	{
		auto it = values_.find(id);
		if (it == values_.end() || it->second.type != 1) return kResultFalse;
		v = it->second.f;
		return kResultOk;
	}
	tresult PLUGIN_API setString(AttrID id, const TChar *s) override
	{
		Value x;
		x.type = 2;
		x.s = (const char16_t *)s;
		values_[id] = x;
		return kResultOk;
	}
	tresult PLUGIN_API getString(AttrID id, TChar *s, uint32 sizeInBytes) override
	{
		auto it = values_.find(id);
		if (it == values_.end() || it->second.type != 2 || !sizeInBytes) return kResultFalse;
		size_t max = sizeInBytes / sizeof(TChar) - 1, n = it->second.s.size() < max ? it->second.s.size() : max;
		memcpy(s, it->second.s.data(), n * sizeof(TChar));
		s[n] = 0;
		return kResultOk;
	}
	tresult PLUGIN_API setBinary(AttrID id, const void *d, uint32 size) override
	{
		Value x;
		x.type = 3;
		x.b.assign((const uint8_t *)d, (const uint8_t *)d + size);
		values_[id] = x;
		return kResultOk;
	}
	tresult PLUGIN_API getBinary(AttrID id, const void *&d, uint32 &size) override
	{
		auto it = values_.find(id);
		if (it == values_.end() || it->second.type != 3) return kResultFalse;
		d = it->second.b.data();
		size = (uint32)it->second.b.size();
		return kResultOk;
	}
};

class Message : public IMessage {
	std::string id_;
	AttributeList *attrs_ = new AttributeList;

public:
	~Message() { attrs_->release(); }
	OC_FUNKNOWN(IMessage)
	FIDString PLUGIN_API getMessageID() override { return id_.c_str(); }
	void PLUGIN_API setMessageID(FIDString id) override { id_ = id ? id : ""; }
	IAttributeList *PLUGIN_API getAttributes() override { return attrs_; }
};

class HostApp : public IHostApplication {
public:
	OC_FUNKNOWN(IHostApplication)
	tresult PLUGIN_API getName(String128 name) override
	{
		const char16_t *n = u"OmniCast";
		memcpy(name, n, 9 * sizeof(char16_t));
		return kResultOk;
	}
	tresult PLUGIN_API createInstance(TUID cid, TUID iid, void **obj) override
	{
		if (FUnknownPrivate::iidEqual(cid, IMessage::iid) && FUnknownPrivate::iidEqual(iid, IMessage::iid)) {
			*obj = static_cast<IMessage *>(new Message);
			return kResultOk;
		}
		if (FUnknownPrivate::iidEqual(cid, IAttributeList::iid) && FUnknownPrivate::iidEqual(iid, IAttributeList::iid)) {
			*obj = static_cast<IAttributeList *>(new AttributeList);
			return kResultOk;
		}
		*obj = nullptr;
		return kResultFalse;
	}
};

static HostApp *host_app()
{
	static HostApp *h = new HostApp; // lives for the process
	return h;
}

// Parameter changes for one process call: one point per parameter (the latest value).
class ParamQueue : public IParamValueQueue {
public:
	ParamID id = 0;
	ParamValue value = 0;
	OC_FUNKNOWN(IParamValueQueue)
	ParamID PLUGIN_API getParameterId() override { return id; }
	int32 PLUGIN_API getPointCount() override { return 1; }
	tresult PLUGIN_API getPoint(int32 index, int32 &offset, ParamValue &v) override
	{
		if (index != 0) return kResultFalse;
		offset = 0;
		v = value;
		return kResultOk;
	}
	tresult PLUGIN_API addPoint(int32, ParamValue v, int32 &index) override
	{
		value = v;
		index = 0;
		return kResultOk;
	}
};

class ParamChanges : public IParameterChanges {
public:
	std::vector<ParamQueue *> queues;
	int32 used = 0;
	OC_FUNKNOWN(IParameterChanges)
	~ParamChanges()
	{
		for (auto *q : queues) q->release();
	}
	int32 PLUGIN_API getParameterCount() override { return used; }
	IParamValueQueue *PLUGIN_API getParameterData(int32 i) override { return i >= 0 && i < used ? queues[i] : nullptr; }
	IParamValueQueue *PLUGIN_API addParameterData(const ParamID &id, int32 &index) override
	{
		for (int32 i = 0; i < used; i++)
			if (queues[i]->id == id) {
				index = i;
				return queues[i];
			}
		if (used == (int32)queues.size()) queues.push_back(new ParamQueue);
		queues[used]->id = id;
		index = used;
		return queues[used++];
	}
};

// ---------------------------------------------------------------- one plugin

struct Plugin;

// Edits from the plugin's editor, for the processor (when they're separate objects).
class Handler : public IComponentHandler {
public:
	std::mutex mx;
	std::vector<std::pair<ParamID, ParamValue>> pending;
	OC_FUNKNOWN(IComponentHandler)
	tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
	tresult PLUGIN_API performEdit(ParamID id, ParamValue v) override
	{
		std::lock_guard<std::mutex> lock(mx);
		pending.emplace_back(id, v);
		return kResultOk;
	}
	tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
	tresult PLUGIN_API restartComponent(int32) override { return kResultOk; }
};

struct Plugin {
	std::string path;
	HMODULE module = nullptr;
	IPluginFactory *factory = nullptr;
	IComponent *component = nullptr;
	IAudioProcessor *processor = nullptr;
	IEditController *controller = nullptr;
	bool separate = false; // controller is its own object
	IConnectionPoint *cp_component = nullptr, *cp_controller = nullptr;
	Handler *handler = new Handler;
	ParamChanges *changes = new ParamChanges;
	ProcessContext context{};
	std::vector<float> in[2], out[2];
	std::mutex audio; // held while processing; load/unload/state take it too
	bool active = false;
	std::string name;

	static constexpr int32 MAX_BLOCK = 1024;

	bool load(const std::string &dll_path, std::string &error);
	void unload();
	void process(float **planar, uint32_t frames);
	std::vector<uint8_t> get_state();
	void set_state(const std::vector<uint8_t> &state);
};

using GetFactoryProc = IPluginFactory *(PLUGIN_API *)();
using InitDllProc = bool (*)();
using ExitDllProc = bool (*)();

bool Plugin::load(const std::string &dll_path, std::string &error)
{
	path = dll_path;
	std::wstring w = widen(dll_path.c_str());
	// A .vst3 bundle is a folder: the DLL is inside for 64-bit Windows.
	DWORD attrs = GetFileAttributesW(w.c_str());
	if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY)) {
		std::wstring file = w.substr(w.find_last_of(L"\\/") + 1);
		w += L"\\Contents\\x86_64-win\\" + file;
	}
	module = LoadLibraryExW(w.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
	if (!module) {
		error = "Couldn't load the plugin's DLL";
		return false;
	}
	if (auto init = (InitDllProc)GetProcAddress(module, "InitDll"))
		init();
	auto get = (GetFactoryProc)GetProcAddress(module, "GetPluginFactory");
	factory = get ? get() : nullptr;
	if (!factory) {
		error = "Not a VST3 plugin";
		return false;
	}
	// The first audio effect in the module.
	PClassInfo info{};
	TUID cid{};
	bool found = false;
	for (int32 i = 0; i < factory->countClasses() && !found; i++)
		if (factory->getClassInfo(i, &info) == kResultOk && !strcmp(info.category, kVstAudioEffectClass)) {
			memcpy(cid, info.cid, sizeof(TUID));
			name = info.name;
			found = true;
		}
	if (!found || factory->createInstance(cid, IComponent::iid, (void **)&component) != kResultOk || !component) {
		error = "The plugin has no audio effect";
		return false;
	}
	if (component->initialize(host_app()) != kResultOk) {
		error = "The plugin didn't start";
		return false;
	}
	if (component->queryInterface(IAudioProcessor::iid, (void **)&processor) != kResultOk || !processor) {
		error = "The plugin can't process audio";
		return false;
	}
	if (component->queryInterface(IEditController::iid, (void **)&controller) != kResultOk || !controller) {
		TUID ccid{};
		if (component->getControllerClassId(ccid) == kResultOk &&
		    factory->createInstance(ccid, IEditController::iid, (void **)&controller) == kResultOk && controller) {
			separate = true;
			controller->initialize(host_app());
		}
	}
	if (controller) {
		controller->setComponentHandler(handler);
		if (separate) {
			component->queryInterface(IConnectionPoint::iid, (void **)&cp_component);
			controller->queryInterface(IConnectionPoint::iid, (void **)&cp_controller);
			if (cp_component && cp_controller) {
				cp_component->connect(cp_controller);
				cp_controller->connect(cp_component);
			}
			// The controller starts from the component's state.
			MemoryStream *s = new MemoryStream;
			if (component->getState(s) == kResultOk) {
				s->pos = 0;
				controller->setComponentState(s);
			}
			s->release();
		}
	}

	// Stereo in, stereo out, 48 kHz, up to 1024 frames per call.
	SpeakerArrangement stereo = SpeakerArr::kStereo;
	processor->setBusArrangements(&stereo, 1, &stereo, 1);
	component->activateBus(kAudio, kInput, 0, true);
	component->activateBus(kAudio, kOutput, 0, true);
	ProcessSetup setup{kRealtime, kSample32, MAX_BLOCK, 48000.0};
	if (processor->setupProcessing(setup) != kResultOk) {
		error = "The plugin doesn't support 48 kHz stereo";
		return false;
	}
	component->setActive(true);
	processor->setProcessing(true);
	active = true;
	for (int c = 0; c < 2; c++) {
		in[c].assign(MAX_BLOCK, 0.0f);
		out[c].assign(MAX_BLOCK, 0.0f);
	}
	// A running transport at 120 BPM in 4/4, for plugins with tempo-synced effects.
	context.sampleRate = 48000.0;
	context.tempo = 120.0;
	context.timeSigNumerator = 4;
	context.timeSigDenominator = 4;
	context.state = ProcessContext::kPlaying | ProcessContext::kTempoValid | ProcessContext::kTimeSigValid |
			ProcessContext::kProjectTimeMusicValid | ProcessContext::kBarPositionValid;
	blog(LOG_INFO, "[OmniCast] plugin '%s' loaded (%s)", name.c_str(), separate ? "separate controller" : "single object");
	return true;
}

void Plugin::unload()
{
	std::lock_guard<std::mutex> lock(audio);
	if (active) {
		processor->setProcessing(false);
		component->setActive(false);
		active = false;
	}
	if (cp_component && cp_controller) {
		cp_component->disconnect(cp_controller);
		cp_controller->disconnect(cp_component);
	}
	if (cp_component) cp_component->release();
	if (cp_controller) cp_controller->release();
	cp_component = cp_controller = nullptr;
	if (controller) {
		controller->setComponentHandler(nullptr);
		if (separate) controller->terminate();
		controller->release();
		controller = nullptr;
	}
	if (processor) processor->release();
	processor = nullptr;
	if (component) {
		component->terminate();
		component->release();
		component = nullptr;
	}
	if (factory) factory->release();
	factory = nullptr;
	if (module) {
		if (auto exit = (ExitDllProc)GetProcAddress(module, "ExitDll"))
			exit();
		FreeLibrary(module);
		module = nullptr;
	}
}

void Plugin::process(float **planar, uint32_t frames)
{
	std::unique_lock<std::mutex> lock(audio, std::try_to_lock);
	if (!lock.owns_lock() || !active)
		return; // loading or saving right now: pass the audio through
	for (uint32_t done = 0; done < frames;) {
		int32 n = (int32)(frames - done < (uint32_t)MAX_BLOCK ? frames - done : MAX_BLOCK);
		for (int c = 0; c < 2; c++)
			memcpy(in[c].data(), planar[c] + done, n * sizeof(float));
		float *ins[2] = {in[0].data(), in[1].data()}, *outs[2] = {out[0].data(), out[1].data()};
		AudioBusBuffers ib{}, ob{};
		ib.numChannels = 2;
		ib.channelBuffers32 = ins;
		ob.numChannels = 2;
		ob.channelBuffers32 = outs;

		changes->used = 0;
		if (separate) {
			std::unique_lock<std::mutex> h(handler->mx, std::try_to_lock);
			if (h.owns_lock()) {
				for (auto &[id, v] : handler->pending) {
					int32 idx;
					changes->addParameterData(id, idx)->addPoint(0, v, idx);
				}
				handler->pending.clear();
			}
		}

		ProcessData data{};
		data.processMode = kRealtime;
		data.symbolicSampleSize = kSample32;
		data.numSamples = n;
		data.numInputs = 1;
		data.numOutputs = 1;
		data.inputs = &ib;
		data.outputs = &ob;
		data.inputParameterChanges = changes;
		data.processContext = &context;
		if (processor->process(data) == kResultOk)
			for (int c = 0; c < 2; c++)
				memcpy(planar[c] + done, out[c].data(), n * sizeof(float));

		context.projectTimeSamples += n;
		context.projectTimeMusic = (double)context.projectTimeSamples / 48000.0 * context.tempo / 60.0;
		context.barPositionMusic = (double)((int64)(context.projectTimeMusic / 4.0)) * 4.0;
		done += n;
	}
}

std::vector<uint8_t> Plugin::get_state()
{
	// Saved as [u32 component size][component state][controller state].
	std::lock_guard<std::mutex> lock(audio);
	std::vector<uint8_t> out;
	MemoryStream *c = new MemoryStream, *e = new MemoryStream;
	if (component) component->getState(c);
	if (controller && separate) controller->getState(e);
	uint32_t n = (uint32_t)c->data.size();
	out.resize(4);
	memcpy(out.data(), &n, 4);
	out.insert(out.end(), c->data.begin(), c->data.end());
	out.insert(out.end(), e->data.begin(), e->data.end());
	c->release();
	e->release();
	return out;
}

void Plugin::set_state(const std::vector<uint8_t> &state)
{
	if (state.size() < 4)
		return;
	std::lock_guard<std::mutex> lock(audio);
	uint32_t n = 0;
	memcpy(&n, state.data(), 4);
	if (4 + (size_t)n > state.size())
		return;
	MemoryStream *c = new MemoryStream, *e = new MemoryStream;
	c->data.assign(state.begin() + 4, state.begin() + 4 + n);
	e->data.assign(state.begin() + 4 + n, state.end());
	if (component) component->setState(c);
	if (controller && separate) {
		c->pos = 0;
		controller->setComponentState(c);
		if (!e->data.empty()) controller->setState(e);
	}
	c->release();
	e->release();
}

// ---------------------------------------------------------------- editor windows (one UI thread)

class Frame : public IPlugFrame {
public:
	HWND hwnd = nullptr;
	OC_FUNKNOWN(IPlugFrame)
	tresult PLUGIN_API resizeView(IPlugView *view, ViewRect *r) override
	{
		RECT rc{0, 0, r->getWidth(), r->getHeight()};
		AdjustWindowRectEx(&rc, (DWORD)GetWindowLongPtrW(hwnd, GWL_STYLE), FALSE, (DWORD)GetWindowLongPtrW(hwnd, GWL_EXSTYLE));
		SetWindowPos(hwnd, nullptr, 0, 0, rc.right - rc.left, rc.bottom - rc.top, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
		view->onSize(r);
		return kResultOk;
	}
};

struct Editor {
	HWND hwnd = nullptr;
	IPlugView *view = nullptr;
	Frame *frame = nullptr;
};

static std::thread ui_thread;
static DWORD ui_thread_id = 0;
static std::map<Plugin *, Editor> editors; // UI thread only
static const UINT WM_OPEN_EDITOR = WM_APP + 1, WM_CLOSE_EDITOR = WM_APP + 2, WM_RUN = WM_APP + 3;

static void close_editor(Plugin *p)
{
	auto it = editors.find(p);
	if (it == editors.end())
		return;
	Editor e = it->second;
	editors.erase(it);
	if (e.view) {
		e.view->setFrame(nullptr);
		e.view->removed();
		e.view->release();
	}
	if (e.frame) e.frame->release();
	if (e.hwnd) DestroyWindow(e.hwnd);
}

static LRESULT CALLBACK editor_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
	if (msg == WM_CLOSE) {
		for (auto &[p, e] : editors)
			if (e.hwnd == hwnd) {
				e.hwnd = nullptr; // DefWindowProc destroys it below
				close_editor(p);
				break;
			}
	}
	return DefWindowProcW(hwnd, msg, wp, lp);
}

static void open_editor(Plugin *p)
{
	auto it = editors.find(p);
	if (it != editors.end()) {
		ShowWindow(it->second.hwnd, SW_SHOWNORMAL);
		SetForegroundWindow(it->second.hwnd);
		return;
	}
	if (!p->controller)
		return;
	IPlugView *view = p->controller->createView(ViewType::kEditor);
	if (!view || view->isPlatformTypeSupported(kPlatformTypeHWND) != kResultTrue) {
		if (view) view->release();
		blog(LOG_WARNING, "[OmniCast] plugin '%s' has no editor", p->name.c_str());
		return;
	}
	ViewRect r{0, 0, 600, 400};
	view->getSize(&r);
	DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
	RECT rc{0, 0, r.getWidth(), r.getHeight()};
	AdjustWindowRectEx(&rc, style, FALSE, 0);
	std::wstring title = widen(p->name.c_str()) + L" · OmniCast";
	HWND hwnd = CreateWindowExW(0, L"OmniCastPluginEditor", title.c_str(), style, CW_USEDEFAULT, CW_USEDEFAULT,
				    rc.right - rc.left, rc.bottom - rc.top, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
	Frame *frame = new Frame;
	frame->hwnd = hwnd;
	view->setFrame(frame);
	if (view->attached(hwnd, kPlatformTypeHWND) != kResultOk) {
		view->setFrame(nullptr);
		view->release();
		frame->release();
		DestroyWindow(hwnd);
		return;
	}
	editors[p] = {hwnd, view, frame};
	ShowWindow(hwnd, SW_SHOWNORMAL);
	SetForegroundWindow(hwnd);
}

static void ui_loop()
{
	CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED); // editors expect an STA thread, like a host's UI thread
	WNDCLASSW wc{};
	wc.lpfnWndProc = editor_proc;
	wc.hInstance = GetModuleHandleW(nullptr);
	wc.lpszClassName = L"OmniCastPluginEditor";
	wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
	wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
	RegisterClassW(&wc);
	MSG msg;
	PeekMessageW(&msg, nullptr, 0, 0, PM_NOREMOVE); // create the queue
	while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
		if (msg.hwnd == nullptr && msg.message == WM_OPEN_EDITOR) {
			open_editor((Plugin *)msg.lParam);
			continue;
		}
		if (msg.hwnd == nullptr && msg.message == WM_RUN) {
			(*(std::function<void()> *)msg.lParam)();
			SetEvent((HANDLE)msg.wParam);
			continue;
		}
		if (msg.hwnd == nullptr && msg.message == WM_CLOSE_EDITOR) {
			close_editor((Plugin *)msg.lParam);
			SetEvent((HANDLE)msg.wParam);
			continue;
		}
		TranslateMessage(&msg);
		DispatchMessageW(&msg);
	}
	for (auto it = editors.begin(); it != editors.end(); it = editors.begin())
		close_editor(it->first);
	CoUninitialize();
}

static void ensure_ui_thread()
{
	if (ui_thread.joinable())
		return;
	HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
	ui_thread = std::thread([ready] {
		ui_thread_id = GetCurrentThreadId();
		SetEvent(ready);
		ui_loop();
	});
	WaitForSingleObject(ready, 5000);
	CloseHandle(ready);
	Sleep(10); // let the loop create its queue
}

// Runs fn on the plugin UI thread and waits: plugins are created, shown and
// destroyed on one thread that pumps messages, as in a DAW.
static void run_on_ui(const std::function<void()> &fn)
{
	ensure_ui_thread();
	if (GetCurrentThreadId() == ui_thread_id) {
		fn();
		return;
	}
	HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
	if (PostThreadMessageW(ui_thread_id, WM_RUN, (WPARAM)done, (LPARAM)&fn))
		WaitForSingleObject(done, INFINITE);
	CloseHandle(done);
}

static void editor_close_sync(Plugin *p)
{
	if (!ui_thread.joinable())
		return;
	HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
	if (PostThreadMessageW(ui_thread_id, WM_CLOSE_EDITOR, (WPARAM)done, (LPARAM)p))
		WaitForSingleObject(done, 5000);
	CloseHandle(done);
}

// ---------------------------------------------------------------- the libobs filter

struct Filter {
	obs_source_t *source = nullptr;
	Plugin *plugin = nullptr;
};

static const char *vf_name(void *) { return "OmniCast VST3"; }

static void *vf_create(obs_data_t *settings, obs_source_t *source)
{
	auto *f = new Filter;
	f->source = source;
	(void)settings;
	return f;
}

static void vf_destroy(void *data)
{
	auto *f = (Filter *)data;
	if (f->plugin) {
		Plugin *p = f->plugin;
		f->plugin = nullptr;
		run_on_ui([p] {
			close_editor(p);
			p->unload();
			delete p;
		});
	}
	delete f;
}

static obs_audio_data *vf_audio(void *data, obs_audio_data *audio)
{
	auto *f = (Filter *)data;
	if (f->plugin && audio->data[0] && audio->data[1])
		f->plugin->process((float **)audio->data, audio->frames);
	return audio;
}

void vst3_register()
{
	static obs_source_info info = {};
	info.id = "omni_vst3_filter";
	info.type = OBS_SOURCE_TYPE_FILTER;
	info.output_flags = OBS_SOURCE_AUDIO;
	info.get_name = vf_name;
	info.create = vf_create;
	info.destroy = vf_destroy;
	info.filter_audio = vf_audio;
	obs_register_source(&info);
}

// Mic plugin slots, in chain order.
static constexpr int SLOTS = 4;
static obs_source_t *slot_filter[SLOTS] = {};

static Filter *slot(int i)
{
	return i >= 0 && i < SLOTS && slot_filter[i] ? (Filter *)obs_obj_get_data(slot_filter[i]) : nullptr;
}

void vst3_release()
{
	for (int i = 0; i < SLOTS; i++)
		oc_mic_plugin_set(i, "", nullptr, 0);
	obs_wait_for_destroy_queue(); // plugins unload on their UI thread, before it stops
	if (ui_thread.joinable()) {
		PostThreadMessageW(ui_thread_id, WM_QUIT, 0, 0);
		ui_thread.join();
	}
}

// Installed VST3 plugins (Common Files\VST3, recursively), for the app's picker.
static void scan(const std::wstring &dir, std::string &json, bool &first, int depth)
{
	if (depth > 4)
		return;
	WIN32_FIND_DATAW fd;
	HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
	if (h == INVALID_HANDLE_VALUE)
		return;
	do {
		std::wstring name = fd.cFileName;
		if (name == L"." || name == L"..")
			continue;
		std::wstring full = dir + L"\\" + name;
		bool is_vst3 = name.size() > 5 && _wcsicmp(name.c_str() + name.size() - 5, L".vst3") == 0;
		if (is_vst3) {
			if (!first) json += ',';
			first = false;
			std::string n = narrow(name.substr(0, name.size() - 5).c_str());
			json += "{\"id\":\"" + json_escape(narrow(full.c_str()).c_str()) + "\",\"name\":\"" + json_escape(n.c_str()) + "\"}";
		} else if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
			scan(full, json, first, depth + 1);
		}
	} while (FindNextFileW(h, &fd));
	FindClose(h);
}

void list_vst3(std::string &json, bool &first)
{
	wchar_t common[MAX_PATH];
	if (GetEnvironmentVariableW(L"CommonProgramFiles", common, MAX_PATH))
		scan(std::wstring(common) + L"\\VST3", json, first, 0);
}

} // namespace oc

using namespace oc;

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static std::string b64(const std::vector<uint8_t> &in)
{
	std::string out;
	for (size_t i = 0; i < in.size(); i += 3) {
		uint32_t v = in[i] << 16 | (i + 1 < in.size() ? in[i + 1] << 8 : 0) | (i + 2 < in.size() ? in[i + 2] : 0);
		out += B64[v >> 18 & 63];
		out += B64[v >> 12 & 63];
		out += i + 1 < in.size() ? B64[v >> 6 & 63] : '=';
		out += i + 2 < in.size() ? B64[v & 63] : '=';
	}
	return out;
}

static std::vector<uint8_t> unb64(const char *s)
{
	std::vector<uint8_t> out;
	uint32_t v = 0;
	int bits = 0;
	for (; s && *s; s++) {
		const char *p = strchr(B64, *s);
		if (!p || *s == '=')
			continue;
		v = v << 6 | (uint32_t)(p - B64);
		bits += 6;
		if (bits >= 8) {
			bits -= 8;
			out.push_back((uint8_t)(v >> bits & 0xFF));
		}
	}
	return out;
}

OC_API int32_t oc_mic_plugin_set(int32_t index, const char *path, char *err, int32_t err_len)
{
	if (index < 0 || index >= SLOTS)
		return 0;
	if (slot_filter[index]) {
		if (engine.mic)
			obs_source_filter_remove(engine.mic, slot_filter[index]);
		obs_source_release(slot_filter[index]);
		slot_filter[index] = nullptr;
	}
	if (!path || !*path || !engine.running || !engine.mic)
		return 1;
	obs_source_t *filter = obs_source_create_private("omni_vst3_filter", "Mic plugin", nullptr);
	if (!filter)
		return 0;
	auto *f = (Filter *)obs_obj_get_data(filter);
	Plugin *p = nullptr;
	std::string error, file = path;
	run_on_ui([&] {
		p = new Plugin;
		if (!p->load(file, error)) {
			p->unload();
			delete p;
			p = nullptr;
		}
	});
	if (!p) {
		blog(LOG_WARNING, "[OmniCast] plugin %s: %s", path, error.c_str());
		set_err(err, err_len, error.c_str());
		obs_source_release(filter);
		return 0;
	}
	f->plugin = p;
	slot_filter[index] = filter;
	// Chain order = slot order: re-add the later slots after this one.
	obs_source_filter_add(engine.mic, filter);
	for (int i = index + 1; i < SLOTS; i++)
		if (slot_filter[i]) {
			obs_source_filter_remove(engine.mic, slot_filter[i]);
			obs_source_filter_add(engine.mic, slot_filter[i]);
		}
	return 1;
}

OC_API void oc_mic_plugin_open_editor(int32_t index)
{
	Filter *f = slot(index);
	if (!f || !f->plugin)
		return;
	ensure_ui_thread();
	PostThreadMessageW(ui_thread_id, WM_OPEN_EDITOR, 0, (LPARAM)f->plugin);
}

OC_API char *oc_mic_plugin_get_state(int32_t index)
{
	Filter *f = slot(index);
	std::string s;
	if (f && f->plugin)
		run_on_ui([&] { s = b64(f->plugin->get_state()); });
	char *mem = (char *)CoTaskMemAlloc(s.size() + 1);
	if (mem)
		memcpy(mem, s.c_str(), s.size() + 1);
	return mem;
}

OC_API void oc_mic_plugin_set_state(int32_t index, const char *state)
{
	Filter *f = slot(index);
	if (f && f->plugin) {
		auto bytes = unb64(state);
		run_on_ui([&] { f->plugin->set_state(bytes); });
	}
}

OC_API void oc_mic_plugin_bypass(int32_t index, int32_t bypass)
{
	if (index >= 0 && index < SLOTS && slot_filter[index])
		obs_source_set_enabled(slot_filter[index], bypass == 0);
}
