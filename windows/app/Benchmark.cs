using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using OmniCast.Engine;

namespace OmniCast;

// OmniCast.exe --benchmark-record <seconds> [--folder <dir>] [--target wide|tall|both] [--height 720|1080] [--fps 30|60]
//
// Records the main display for that long, without the window, and writes
// benchmark.json next to the recordings: frame rate, render time, and frames
// skipped or late on each canvas. Exit code 0 = 60 fps with nothing skipped.
internal static class Benchmark
{
    public static bool Requested(string[] args) => args.Contains("--benchmark-record");

    public static int Run(string[] args)
    {
        AttachConsole(-1); // print to the terminal it was started from
        string Arg(string name, string def)
        {
            int i = Array.IndexOf(args, name);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : def;
        }
        int seconds = int.TryParse(Arg("--benchmark-record", "30"), out int s) ? Math.Clamp(s, 5, 3600) : 30;
        string folder = Path.GetFullPath(Arg("--folder", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "OmniCast benchmark")));
        string target = Arg("--target", "both").ToLowerInvariant();
        int height = Arg("--height", "720") == "1080" ? 1080 : 720;
        int fps = Arg("--fps", "60") == "30" ? 30 : 60;

        var video = new Native.VideoConfig { Height = height, Fps = fps, WideKbps = 6000, TallKbps = 6000 };
        var err = new byte[512];
        Directory.CreateDirectory(EngineHost.ObsConfigDir);
        if (Native.oc_start(EngineHost.AppDir, EngineHost.ObsConfigDir + "\\", ref video, err, err.Length) == 0)
        {
            Console.Error.WriteLine("Engine failed to start: " + Native.Err(err));
            return 1;
        }
        // One scene: the main display, full frame on both canvases.
        Native.SceneSet("benchmark", (int)Native.ScreenKind.Monitor, "", "", 1, 0, 1);
        Native.oc_scene_activate("benchmark", 0, 0);
        Thread.Sleep(2000); // let capture settle

        IntPtr f = Marshal.StringToCoTaskMemUTF8(folder);
        var cfg = new Native.RecordConfig
        {
            Folder = f,
            Wide = target is "wide" or "both" ? 1 : 0,
            Tall = target is "tall" or "both" ? 1 : 0,
            SplitAudio = 1,
            Quality = 20,
        };
        int ok = Native.oc_record_start(ref cfg, err, err.Length);
        Marshal.FreeCoTaskMem(f);
        if (ok == 0)
        {
            Console.Error.WriteLine("Recording failed to start: " + Native.Err(err));
            Native.oc_shutdown();
            return 1;
        }
        Native.oc_set_busy(1);

        Console.WriteLine($"Recording {target} at {height}p{fps} for {seconds} s with {Native.Str(Native.oc_encoder_name())} on {Native.Str(Native.oc_gpu_name())}…");
        Thread.Sleep(1000); // skip encoder start-up
        Native.oc_get_stats(out var start);
        var renderMs = new List<double>();
        var cpu = new List<double>();
        var fpsSamples = new List<double>();
        for (int i = 0; i < seconds; i++)
        {
            Thread.Sleep(1000);
            Native.oc_get_stats(out var now);
            renderMs.Add(now.RenderMs);
            cpu.Add(now.CpuPercent);
            fpsSamples.Add(now.Fps);
        }
        Native.oc_get_stats(out var end);
        Native.oc_record_stop();
        Thread.Sleep(1500);
        string wideFile = Native.Str(Native.oc_record_path(Native.Wide));
        string tallFile = Native.Str(Native.oc_record_path(Native.Tall));
        string encoder = Native.Str(Native.oc_encoder_name());
        string gpu = Native.Str(Native.oc_gpu_name());
        Native.oc_set_busy(0);
        Native.oc_shutdown();

        uint frames = end.TotalFrames - start.TotalFrames;
        uint lagged = end.LaggedFrames - start.LaggedFrames;
        uint skippedWide = end.SkippedWide - start.SkippedWide;
        uint skippedTall = end.SkippedTall - start.SkippedTall;
        double avgFps = fpsSamples.Average();
        bool pass = avgFps >= fps - 0.5 && lagged == 0 && skippedWide == 0 && skippedTall == 0;

        using var buffer = new MemoryStream();
        using (var w = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true }))
        {
            w.WriteStartObject();
            w.WriteBoolean("pass", pass);
            w.WriteNumber("seconds", seconds);
            w.WriteString("target", target);
            w.WriteString("resolution", $"{height}p{fps}");
            w.WriteString("encoder", encoder);
            w.WriteString("gpu", gpu);
            w.WriteNumber("fps_average", Math.Round(avgFps, 2));
            w.WriteNumber("fps_min", Math.Round(fpsSamples.Min(), 2));
            w.WriteNumber("frames_rendered", frames);
            w.WriteNumber("frames_lagged", lagged);
            w.WriteNumber("frames_skipped_16x9", skippedWide);
            w.WriteNumber("frames_skipped_9x16", skippedTall);
            w.WriteNumber("render_ms_average", Math.Round(renderMs.Average(), 3));
            w.WriteNumber("render_ms_max", Math.Round(renderMs.Max(), 3));
            w.WriteNumber("cpu_percent_average", Math.Round(cpu.Average(), 1));
            w.WriteNumber("cpu_percent_max", Math.Round(cpu.Max(), 1));
            w.WriteStartArray("files");
            foreach (var file in new[] { wideFile, tallFile }.Where(p => p.Length > 0))
                w.WriteStringValue(file);
            w.WriteEndArray();
            w.WriteString("date", DateTime.Now.ToString("s", CultureInfo.InvariantCulture));
            w.WriteEndObject();
        }
        Directory.CreateDirectory(folder);
        string json = System.Text.Encoding.UTF8.GetString(buffer.ToArray());
        File.WriteAllText(Path.Combine(folder, "benchmark.json"), json);
        Console.WriteLine(json);
        Console.WriteLine(pass ? "PASS" : "FAIL");
        return pass ? 0 : 2;
    }

    [DllImport("kernel32.dll")]
    private static extern bool AttachConsole(int pid);
}
