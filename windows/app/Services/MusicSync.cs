using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Microsoft.UI.Dispatching;
using OmniCast.Engine;

namespace OmniCast.Services;

// "Muze follows the music": Muze Auto Key listens to the music app's channel
// and hands its key to Muze (Muze's Key Link: Follow); OmniCast tracks the
// beat on the same channel and gives Muze (and every mic plugin) the tempo.
// The music app is the one on stream (Settings › Music); it needs its own
// mixer channel.
public sealed class MusicSync
{
    public static MusicSync Current { get; } = new();

    private DispatcherQueueTimer? _timer;
    private int _following = -2; // engine channel, -1 none, -2 unknown (re-apply)
    private readonly List<double> _readings = new();
    private string _lastTrack = "";

    public double Bpm { get; private set; }
    public string Key { get; private set; } = "";
    public event Action? Changed;

    private static EngineHost Host => EngineHost.Current;

    public void Start()
    {
        var dq = DispatcherQueue.GetForCurrentThread();
        _timer = dq.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(2);
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
        Host.EngineStopping += () => _following = -2;
        Host.MixerChanged += Apply;
        Host.EngineStarted += Apply;
        Host.MicPluginsChanged += () => Changed?.Invoke();
        NowPlaying.Current.Changed += t =>
        {
            // A new song: start listening for the beat afresh.
            string id = t?.Id ?? "";
            if (id == _lastTrack) return;
            _lastTrack = id;
            SongChanged();
        };
    }

    // The music app's channel, when following is on and it has one.
    public int TargetChannel()
    {
        if (!Host.IsRunning || !Host.Settings.Music.Follow) return -1;
        bool untitled = Host.Settings.Music.Source == "untitled";
        foreach (var (ch, app) in Host.AppChannels.OrderBy(a => a.Key))
            if (untitled ? EngineHost.IsBrowserExe(app.Exe) : app.Exe == "spotify.exe")
                return ch;
        return -1;
    }

    public void Apply()
    {
        if (!Host.IsRunning) return;
        int target = TargetChannel();
        if (target == _following) return; // already there: don't reload Auto Key
        _following = target;
        Native.oc_music_follow(target);
        if (target < 0) Native.oc_music_set_tempo(120);
        _readings.Clear();
        Bpm = 0;
        Changed?.Invoke();
    }

    public void SongChanged()
    {
        _readings.Clear();
        if (Host.IsRunning) Native.oc_music_tempo_reset();
    }

    private void Tick()
    {
        if (!Host.IsRunning) return;
        var buf = new byte[64];
        string key = Native.oc_music_muze_key(buf, buf.Length) != 0 ? Native.Err(buf) : "";
        bool changed = key != Key;
        Key = key;
        if (_following >= 0)
        {
            double bpm = Native.oc_music_tempo(out double confidence);
            if (bpm > 0 && confidence > 8)
            {
                _readings.Add(bpm);
                if (_readings.Count > 5) _readings.RemoveAt(0);
                var sorted = _readings.OrderBy(x => x).ToList();
                double value = sorted[sorted.Count / 2];
                if (Math.Abs(value - Math.Round(value)) < 0.35) value = Math.Round(value);
                // Small wobble: keep the current tempo rather than re-timing Muze.
                if (Bpm <= 0 || Math.Abs(Bpm - value) >= 0.9)
                {
                    Bpm = value;
                    Native.oc_music_set_tempo(value);
                    changed = true;
                }
            }
        }
        if (changed) Changed?.Invoke();
    }

    public string Status
    {
        get
        {
            var m = Host.Settings.Music;
            string app = m.Source == "untitled" ? "your browser" : "Spotify";
            if (!m.Follow) return "Off";
            if (!EngineHost.AppAudioSupported) return "Needs Windows 10 version 2004 or later";
            if (TargetChannel() < 0) return $"Give {app} a channel with + in Studio › Audio";
            if (!Host.Settings.MicPlugins.Any(p => p.Name.Equals("Muze", StringComparison.OrdinalIgnoreCase)))
                return "Add Muze to the mic (FX in Studio › Audio)";
            string k = Key.Length > 0 ? Key : "listening…";
            string t = Bpm > 0 ? $"{Bpm:0} BPM" : "finding the beat…";
            return $"{k} · {t}";
        }
    }

    public bool Locked => Host.Settings.Music.Follow && _following >= 0 && Bpm > 0;
}
