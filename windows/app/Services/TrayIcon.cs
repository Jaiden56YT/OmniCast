using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace OmniCast.Services;

public enum TrayState { Idle, Live, Recording }

public enum HotkeyAction { GoLive, Record, MuteMic }

// The notification-area icon (with live/recording state and a menu) and the
// global hotkeys. Both need a Win32 window to receive messages; WinUI has
// neither, so this owns a small hidden one.
public sealed class TrayIcon : IDisposable
{
    public event Action? OpenRequested;
    public event Action? QuitRequested;
    public event Action<HotkeyAction>? Action;

    // Ctrl+Alt+L / R / M. (Ctrl+Shift+R would steal the browsers' hard reload.)
    public static readonly (HotkeyAction Action, string Label, uint Key)[] Hotkeys =
    {
        (HotkeyAction.GoLive, "Ctrl+Alt+L", 0x4C),
        (HotkeyAction.Record, "Ctrl+Alt+R", 0x52),
        (HotkeyAction.MuteMic, "Ctrl+Alt+M", 0x4D),
    };
    // Hotkeys another app already owns.
    public List<string> HotkeyConflicts { get; } = new();

    private const int WM_APP_TRAY = 0x8000 + 1;
    private const int WM_HOTKEY = 0x0312, WM_COMMAND = 0x0111, WM_CONTEXTMENU = 0x007B;
    private const int WM_LBUTTONUP = 0x0202, WM_RBUTTONUP = 0x0205, NIN_SELECT = 0x0400, NIN_KEYSELECT = 0x0401;
    private const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETVERSION = 4;
    private const uint NIF_MESSAGE = 1, NIF_ICON = 2, NIF_TIP = 4, NIF_SHOWTIP = 0x80;
    private const uint MOD_ALT = 1, MOD_CONTROL = 2, MOD_NOREPEAT = 0x4000;
    private const int CMD_OPEN = 1, CMD_LIVE = 2, CMD_RECORD = 3, CMD_MUTE = 4, CMD_QUIT = 5;

    private readonly WndProc _proc;
    private readonly IntPtr _hwnd;
    private readonly uint _taskbarCreated;
    private readonly IntPtr[] _icons = new IntPtr[3];
    private TrayState _state = TrayState.Idle;
    private bool _live, _recording, _micMuted;

    public TrayIcon(string assetsDir)
    {
        _proc = WindowProc;
        var wc = new WNDCLASSEX
        {
            cbSize = Marshal.SizeOf<WNDCLASSEX>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_proc),
            hInstance = GetModuleHandle(null),
            lpszClassName = "OmniCastTrayWindow",
        };
        RegisterClassEx(ref wc);
        _hwnd = CreateWindowEx(0, wc.lpszClassName, "OmniCast", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
        _taskbarCreated = RegisterWindowMessage("TaskbarCreated");

        int size = GetSystemMetrics(49); // SM_CXSMICON, DPI-aware
        string[] files = { "OmniCast.ico", "OmniCast-live.ico", "OmniCast-rec.ico" };
        for (int i = 0; i < 3; i++)
            _icons[i] = LoadImage(IntPtr.Zero, Path.Combine(assetsDir, files[i]), 1, size, size, 0x10);

        AddIcon();
        for (int i = 0; i < Hotkeys.Length; i++)
            if (!RegisterHotKey(_hwnd, i + 1, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, Hotkeys[i].Key))
                HotkeyConflicts.Add(Hotkeys[i].Label);
        // Ctrl+Alt+1..9: put scene 1..9 on air.
        for (int n = 1; n <= 9; n++)
            if (!RegisterHotKey(_hwnd, SceneHotkeyBase + n, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, (uint)(0x30 + n)))
                HotkeyConflicts.Add($"Ctrl+Alt+{n}");
    }

    // Scene number (1-based) from a hotkey or the tray menu.
    public event Action<int>? SceneRequested;
    // The scenes to list in the menu: name and whether it's on air.
    public Func<IReadOnlyList<(string Name, bool OnAir)>>? ScenesProvider { get; set; }

    private const int SceneHotkeyBase = 100, CMD_SCENE_BASE = 1000;

    public void Update(bool live, bool recording, bool micMuted)
    {
        _live = live;
        _recording = recording;
        _micMuted = micMuted;
        _state = live ? TrayState.Live : recording ? TrayState.Recording : TrayState.Idle;
        var nid = NewData(NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        Modify(ref nid);
    }

    private NOTIFYICONDATA NewData(uint flags)
    {
        string tip = _state switch
        {
            TrayState.Live => _recording ? "OmniCast: live and recording" : "OmniCast: live",
            TrayState.Recording => "OmniCast: recording",
            _ => "OmniCast",
        };
        return new NOTIFYICONDATA
        {
            cbSize = Marshal.SizeOf<NOTIFYICONDATA>(),
            hWnd = _hwnd,
            uID = 1,
            uFlags = flags,
            uCallbackMessage = WM_APP_TRAY,
            hIcon = _icons[(int)_state] != IntPtr.Zero ? _icons[(int)_state] : _icons[0],
            szTip = tip,
        };
    }

    private void AddIcon()
    {
        var nid = NewData(NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        Shell_NotifyIcon(NIM_ADD, ref nid);
        nid.uVersion = 4; // NOTIFYICON_VERSION_4
        Shell_NotifyIcon(NIM_SETVERSION, ref nid);
    }

    private void Modify(ref NOTIFYICONDATA nid) => Shell_NotifyIcon(NIM_MODIFY, ref nid);

    private void ShowMenu()
    {
        IntPtr menu = CreatePopupMenu();
        AppendMenu(menu, 0, CMD_OPEN, "Open OmniCast");
        AppendMenu(menu, 0x800, 0, null); // separator
        AppendMenu(menu, 0, CMD_LIVE, _live ? "End stream\tCtrl+Alt+L" : "Go live\tCtrl+Alt+L");
        AppendMenu(menu, 0, CMD_RECORD, _recording ? "Stop recording\tCtrl+Alt+R" : "Start recording\tCtrl+Alt+R");
        AppendMenu(menu, _micMuted ? 8u : 0u, CMD_MUTE, "Mute mic\tCtrl+Alt+M"); // 8 = MF_CHECKED
        var scenes = ScenesProvider?.Invoke();
        if (scenes is { Count: > 1 })
        {
            AppendMenu(menu, 0x800, 0, null);
            for (int i = 0; i < scenes.Count; i++)
            {
                string text = scenes[i].Name.Replace("&", "&&") + (i < 9 ? $"\tCtrl+Alt+{i + 1}" : "");
                // A radio-style check (MFT_RADIOCHECK = 0x200) on the scene on air.
                AppendMenu(menu, scenes[i].OnAir ? 0x208u : 0u, CMD_SCENE_BASE + i + 1, text);
            }
        }
        AppendMenu(menu, 0x800, 0, null);
        AppendMenu(menu, 0, CMD_QUIT, "Quit OmniCast");
        SetMenuDefaultItem(menu, CMD_OPEN, 0);
        GetCursorPos(out POINT pt);
        SetForegroundWindow(_hwnd); // so the menu closes when you click elsewhere
        TrackPopupMenuEx(menu, 0, pt.X, pt.Y, _hwnd, IntPtr.Zero);
        DestroyMenu(menu);
    }

    private IntPtr WindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_APP_TRAY)
        {
            int ev = (int)((long)lParam & 0xFFFF);
            if (ev is WM_LBUTTONUP or NIN_SELECT or NIN_KEYSELECT)
                OpenRequested?.Invoke();
            else if (ev is WM_CONTEXTMENU or WM_RBUTTONUP)
                ShowMenu();
            return IntPtr.Zero;
        }
        if (msg == WM_HOTKEY)
        {
            int raw = (int)wParam;
            int id = raw - 1;
            if (id >= 0 && id < Hotkeys.Length)
                Action?.Invoke(Hotkeys[id].Action);
            else if (raw > SceneHotkeyBase && raw <= SceneHotkeyBase + 9)
                SceneRequested?.Invoke(raw - SceneHotkeyBase);
            return IntPtr.Zero;
        }
        if (msg == WM_COMMAND)
        {
            int cmd = (int)((long)wParam & 0xFFFF);
            if (cmd > CMD_SCENE_BASE)
            {
                SceneRequested?.Invoke(cmd - CMD_SCENE_BASE);
                return IntPtr.Zero;
            }
            switch (cmd)
            {
                case CMD_OPEN: OpenRequested?.Invoke(); break;
                case CMD_LIVE: Action?.Invoke(HotkeyAction.GoLive); break;
                case CMD_RECORD: Action?.Invoke(HotkeyAction.Record); break;
                case CMD_MUTE: Action?.Invoke(HotkeyAction.MuteMic); break;
                case CMD_QUIT: QuitRequested?.Invoke(); break;
            }
            return IntPtr.Zero;
        }
        if (msg == _taskbarCreated)
        {
            AddIcon(); // Explorer restarted
            return IntPtr.Zero;
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    public void Dispose()
    {
        for (int i = 0; i < Hotkeys.Length; i++)
            UnregisterHotKey(_hwnd, i + 1);
        for (int n = 1; n <= 9; n++)
            UnregisterHotKey(_hwnd, SceneHotkeyBase + n);
        var nid = NewData(0);
        Shell_NotifyIcon(NIM_DELETE, ref nid);
        foreach (var icon in _icons)
            if (icon != IntPtr.Zero) DestroyIcon(icon);
        DestroyWindow(_hwnd);
    }

    // ---------------------------------------------------------------- Win32

    private delegate IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEX
    {
        public int cbSize;
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra, cbWndExtra;
        public IntPtr hInstance, hIcon, hCursor, hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NOTIFYICONDATA
    {
        public int cbSize;
        public IntPtr hWnd;
        public uint uID, uFlags, uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState, dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern ushort RegisterClassEx(ref WNDCLASSEX wc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr CreateWindowEx(uint exStyle, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern IntPtr DefWindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string? name);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern bool Shell_NotifyIcon(uint msg, ref NOTIFYICONDATA data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr LoadImage(IntPtr inst, string name, uint type, int cx, int cy, uint load);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hwnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    [DllImport("user32.dll")] private static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool AppendMenu(IntPtr menu, uint flags, int id, string? text);
    [DllImport("user32.dll")] private static extern bool SetMenuDefaultItem(IntPtr menu, int item, int byPos);
    [DllImport("user32.dll")] private static extern bool TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr tpm);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT pt);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
}
