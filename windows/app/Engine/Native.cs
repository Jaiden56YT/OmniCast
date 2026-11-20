using System;
using System.Runtime.InteropServices;

namespace OmniCast.Engine;

// P/Invoke declarations for OmniCore.dll (windows/core/include/omnicore.h).
// Strings cross as UTF-8.
public static class Native
{
    private const string Dll = "OmniCore.dll";

    public const int Wide = 0, Tall = 1;
    public const int ChMic = 0, ChDesktop = 1, ChCapture = 2, ChAppFirst = 3, ChCount = 16;

    public enum OutputState { Idle = 0, Connecting = 1, Live = 2, Reconnecting = 3, Failed = 4 }
    public enum ScreenKind { Monitor = 0, Window = 1, Game = 2, Device = 3 }

    [StructLayout(LayoutKind.Sequential)]
    public struct VideoConfig
    {
        public int Height, Fps, WideKbps, TallKbps;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Stats
    {
        public double Fps, RenderMs;
        public uint TotalFrames, LaggedFrames, SkippedWide, SkippedTall;
        public double CpuPercent;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Destination
    {
        public IntPtr Name, Server, Key; // UTF-8, CoTaskMem
        public int Canvas;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RecordConfig
    {
        public IntPtr Folder; // UTF-8, CoTaskMem
        public int Wide, Tall, SplitAudio, Quality;
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void StatusCallback(int index, int state, IntPtr message);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void RecordCallback(int canvas, int active, IntPtr message);

    // Engine
    [DllImport(Dll)] public static extern int oc_start([MarshalAs(UnmanagedType.LPUTF8Str)] string appDir,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string configDir, ref VideoConfig video, byte[] err, int errLen);
    [DllImport(Dll)] public static extern void oc_shutdown();
    [DllImport(Dll)] public static extern int oc_reset_video(ref VideoConfig video, byte[] err, int errLen);
    [DllImport(Dll)] public static extern IntPtr oc_encoder_name();
    [DllImport(Dll)] public static extern int oc_encoder_is_gpu();
    [DllImport(Dll)] public static extern IntPtr oc_gpu_name();
    [DllImport(Dll)] public static extern void oc_get_stats(out Stats stats);
    [DllImport(Dll)] public static extern void oc_set_busy(int busy);

    // Lists
    [DllImport(Dll)] public static extern IntPtr oc_list([MarshalAs(UnmanagedType.LPUTF8Str)] string what);
    [DllImport(Dll)] public static extern void oc_free(IntPtr p);

    // Scenes. Mirrors oc_scene_desc field for field (strings are UTF-8 CoTaskMem).
    [StructLayout(LayoutKind.Sequential)]
    private struct SceneDescC
    {
        public IntPtr Key;
        public int ScreenKind;
        public IntPtr ScreenId;
        public IntPtr CameraId;
        public int WideLayout, CameraCorner, TallLayout;
    }

    [DllImport(Dll, EntryPoint = "oc_scene_set")] private static extern void oc_scene_set_c(ref SceneDescC scene);
    [DllImport(Dll)] public static extern int oc_scene_remove([MarshalAs(UnmanagedType.LPUTF8Str)] string key);
    [DllImport(Dll)] public static extern int oc_scene_activate([MarshalAs(UnmanagedType.LPUTF8Str)] string key, int transition, int durationMs);
    [DllImport(Dll)] public static extern IntPtr oc_scene_active();

    public static void SceneSet(string key, int screenKind, string screenId, string cameraId, int wideLayout, int corner, int tallLayout)
    {
        var d = new SceneDescC
        {
            Key = Marshal.StringToCoTaskMemUTF8(key),
            ScreenKind = screenKind,
            ScreenId = Marshal.StringToCoTaskMemUTF8(screenId ?? ""),
            CameraId = Marshal.StringToCoTaskMemUTF8(cameraId ?? ""),
            WideLayout = wideLayout,
            CameraCorner = corner,
            TallLayout = tallLayout,
        };
        try { oc_scene_set_c(ref d); }
        finally
        {
            Marshal.FreeCoTaskMem(d.Key);
            Marshal.FreeCoTaskMem(d.ScreenId);
            Marshal.FreeCoTaskMem(d.CameraId);
        }
    }

    // Discord outputs (into a virtual cable such as VB-CABLE)
    public const int DiscordVoice = 0, DiscordStreamAudio = 1;
    [DllImport(Dll)] public static extern int oc_discord_output_set(int output, [MarshalAs(UnmanagedType.LPUTF8Str)] string deviceId);
    [DllImport(Dll)] public static extern int oc_discord_output_running(int output);

    // Audio devices
    [DllImport(Dll)] public static extern void oc_mic_set_device([MarshalAs(UnmanagedType.LPUTF8Str)] string id);
    [DllImport(Dll)] public static extern void oc_desktop_set_device([MarshalAs(UnmanagedType.LPUTF8Str)] string id);

    // Audio
    [DllImport(Dll)] public static extern void oc_audio_set(int channel, float gain, int muted);
    [DllImport(Dll)] public static extern void oc_audio_levels(int channel, out float left, out float right);
    [DllImport(Dll)] public static extern int oc_audio_present(int channel);
    [DllImport(Dll)] public static extern float oc_audio_level(int channel);
    [DllImport(Dll)] public static extern int oc_app_audio_supported();
    [DllImport(Dll)] public static extern int oc_app_channel_add([MarshalAs(UnmanagedType.LPUTF8Str)] string exe);
    [DllImport(Dll)] public static extern void oc_app_channel_remove(int channel);
    [DllImport(Dll)] public static extern void oc_monitor_set(int channel, float gain, int muted);
    [DllImport(Dll)] public static extern void oc_monitor_set_device([MarshalAs(UnmanagedType.LPUTF8Str)] string id);

    // Preview
    [DllImport(Dll)] public static extern int oc_preview_attach(int canvas, IntPtr panel, float width, float height, float scaleX, float scaleY);
    [DllImport(Dll)] public static extern void oc_preview_resize(int canvas, float width, float height, float scaleX, float scaleY);
    [DllImport(Dll)] public static extern void oc_preview_set_enabled(int canvas, int enabled);
    [DllImport(Dll)] public static extern void oc_preview_detach(int canvas);

    // Streaming
    [DllImport(Dll)] public static extern void oc_set_status_callback(StatusCallback? cb);
    [DllImport(Dll)] public static extern int oc_stream_start([In] Destination[] dests, int count, byte[] err, int errLen);
    [DllImport(Dll)] public static extern void oc_stream_stop();
    [DllImport(Dll)] public static extern int oc_stream_active();
    [DllImport(Dll)] public static extern int oc_stream_output_stats(int index, out int dropped, out ulong bytes);

    // Recording
    [DllImport(Dll)] public static extern void oc_set_record_callback(RecordCallback? cb);
    [DllImport(Dll)] public static extern int oc_record_start(ref RecordConfig cfg, byte[] err, int errLen);
    [DllImport(Dll)] public static extern void oc_record_stop();
    [DllImport(Dll)] public static extern int oc_record_active();
    [DllImport(Dll)] public static extern IntPtr oc_record_path(int canvas);

    // Mic plugins (VST3)
    [DllImport(Dll)] public static extern int oc_mic_plugin_set(int slot, [MarshalAs(UnmanagedType.LPUTF8Str)] string path, byte[]? err, int errLen);
    [DllImport(Dll)] public static extern void oc_mic_plugin_open_editor(int slot);
    [DllImport(Dll)] public static extern IntPtr oc_mic_plugin_get_state(int slot);
    [DllImport(Dll)] public static extern void oc_mic_plugin_set_state(int slot, [MarshalAs(UnmanagedType.LPUTF8Str)] string state);
    [DllImport(Dll)] public static extern void oc_mic_plugin_bypass(int slot, int bypass);

    // Overlay layers
    [DllImport(Dll)] public static extern int oc_layer_set_image([MarshalAs(UnmanagedType.LPUTF8Str)] string key, [MarshalAs(UnmanagedType.LPUTF8Str)] string path);
    [DllImport(Dll)] public static extern void oc_layer_place([MarshalAs(UnmanagedType.LPUTF8Str)] string key, int canvas, int show, float x, float y, float w, float h);
    [DllImport(Dll)] public static extern void oc_layer_set_opacity([MarshalAs(UnmanagedType.LPUTF8Str)] string key, float opacity);
    [DllImport(Dll)] public static extern void oc_layer_remove([MarshalAs(UnmanagedType.LPUTF8Str)] string key);

    // Virtual camera
    [DllImport(Dll)] public static extern int oc_vcam_installed();
    [DllImport(Dll)] public static extern int oc_vcam_install();
    [DllImport(Dll)] public static extern int oc_vcam_start(int canvas, byte[] err, int errLen);
    [DllImport(Dll)] public static extern void oc_vcam_stop();
    [DllImport(Dll)] public static extern int oc_vcam_active();

    public static string Str(IntPtr p) => p == IntPtr.Zero ? "" : Marshal.PtrToStringUTF8(p) ?? "";

    public static string Err(byte[] buf)
    {
        int n = Array.IndexOf(buf, (byte)0);
        return System.Text.Encoding.UTF8.GetString(buf, 0, n < 0 ? buf.Length : n);
    }

    public static string TakeString(IntPtr p)
    {
        try { return Str(p); } finally { if (p != IntPtr.Zero) oc_free(p); }
    }
}
