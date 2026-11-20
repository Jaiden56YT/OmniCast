// Virtual camera: OBS's Windows virtual camera (a DirectShow filter, shown to
// apps as "OBS Virtual Camera"), fed straight from one canvas through win-dshow's
// virtualcam_output and its shared-memory queue. Zoom, Discord, Teams and the
// browser see whatever that canvas shows. OBS Studio doesn't need to be running
// or installed; the filter only needs registering once (needs admin).

#include "internal.h"

#include <windows.h>
#include <shellapi.h>

namespace oc {

static obs_output_t *vcam = nullptr;
static int vcam_canvas = OC_WIDE;

// The filter's class id, fixed by OBS (virtualcam-guid.h).
static const wchar_t *VCAM_CLSID = L"CLSID\\{A3FCE0F5-3493-419F-958A-ABA1250EC20B}\\InprocServer32";

static std::wstring registered_path()
{
	wchar_t buf[MAX_PATH * 2] = {};
	DWORD size = sizeof(buf);
	if (RegGetValueW(HKEY_CLASSES_ROOT, VCAM_CLSID, nullptr, RRF_RT_REG_SZ, nullptr, buf, &size) != ERROR_SUCCESS)
		return L"";
	return buf;
}

static std::wstring module_path(int bits)
{
	return widen(engine.app_dir.c_str()) + L"\\obs\\data\\obs-plugins\\win-dshow\\obs-virtualcam-module" +
	       (bits == 64 ? L"64" : L"32") + L".dll";
}

void vcam_stop()
{
	if (!vcam)
		return;
	if (obs_output_active(vcam))
		obs_output_stop(vcam);
	// The output closes its queue on the next frame after stop.
	for (int i = 0; i < 40 && obs_output_active(vcam); i++)
		Sleep(25);
	obs_output_release(vcam);
	vcam = nullptr;
	blog(LOG_INFO, "[OmniCast] virtual camera off");
}

} // namespace oc

using namespace oc;

OC_API int32_t oc_vcam_installed(void)
{
	std::wstring path = registered_path();
	return path.empty() ? 0 : (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES ? 1 : 0);
}

OC_API int32_t oc_vcam_install(void)
{
	// One UAC prompt registers both the 64-bit and 32-bit filters (32-bit apps
	// such as some meeting clients look for the 32-bit one).
	std::wstring params = L"/c regsvr32 /s \"" + module_path(64) + L"\" & regsvr32 /s \"" + module_path(32) + L"\"";
	SHELLEXECUTEINFOW sei{sizeof(sei)};
	sei.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NO_CONSOLE;
	sei.lpVerb = L"runas";
	sei.lpFile = L"cmd.exe";
	sei.lpParameters = params.c_str();
	sei.nShow = SW_HIDE;
	if (!ShellExecuteExW(&sei) || !sei.hProcess)
		return oc_vcam_installed(); // the user said no to the prompt
	WaitForSingleObject(sei.hProcess, 30000);
	CloseHandle(sei.hProcess);
	int32_t ok = oc_vcam_installed();
	blog(LOG_INFO, "[OmniCast] virtual camera install: %s", ok ? "ok" : "failed");
	return ok;
}

OC_API int32_t oc_vcam_start(int32_t canvas, char *err, int32_t err_len)
{
	if (!engine.running) {
		set_err(err, err_len, "The engine isn't running");
		return 0;
	}
	if (!oc_vcam_installed()) {
		set_err(err, err_len, "The virtual camera isn't set up yet");
		return 0;
	}
	if (vcam && canvas == vcam_canvas && obs_output_active(vcam))
		return 1;
	vcam_stop();

	video_t *video = canvas_video(canvas);
	if (!video) {
		set_err(err, err_len, "That canvas isn't running");
		return 0;
	}
	vcam = obs_output_create("virtualcam_output", "OmniCast virtual camera", nullptr, nullptr);
	if (!vcam) {
		set_err(err, err_len, "The virtual camera output isn't available (win-dshow didn't load)");
		return 0;
	}
	obs_output_set_media(vcam, video, nullptr);
	vcam_canvas = canvas;
	if (!obs_output_start(vcam)) {
		const char *why = obs_output_get_last_error(vcam);
		set_err(err, err_len, why && *why ? why : "The virtual camera didn't start");
		obs_output_release(vcam);
		vcam = nullptr;
		return 0;
	}
	blog(LOG_INFO, "[OmniCast] virtual camera on (%s canvas)", canvas == OC_TALL ? "9:16" : "16:9");
	return 1;
}

OC_API void oc_vcam_stop(void)
{
	vcam_stop();
}

OC_API int32_t oc_vcam_active(void)
{
	return vcam && obs_output_active(vcam) ? 1 : 0;
}
