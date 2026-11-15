using System;
using System.Collections.Generic;
using System.Windows.Interop;
using Mukker.Core.Settings;

namespace Mukker.App.Interop;

/// <summary>A hidden message-only window that receives WM_HOTKEY and WM_CLIPBOARDUPDATE.</summary>
internal sealed class MessageWindow : IDisposable
{
    private readonly HwndSource _source;
    public IntPtr Handle => _source.Handle;

    public event Action<int>? HotKeyPressed;
    public event Action? ClipboardUpdated;

    public MessageWindow()
    {
        var p = new HwndSourceParameters("MukkerMessageWindow")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0,
            ParentWindow = new IntPtr(-3), // HWND_MESSAGE
        };
        _source = new HwndSource(p);
        _source.AddHook(WndProc);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        switch (msg)
        {
            case Native.WM_HOTKEY:
                HotKeyPressed?.Invoke(wParam.ToInt32());
                handled = true;
                break;
            case Native.WM_CLIPBOARDUPDATE:
                ClipboardUpdated?.Invoke();
                handled = true;
                break;
        }
        return IntPtr.Zero;
    }

    public void Dispose() => _source.Dispose();
}

/// <summary>
/// Registers every global shortcut. A switched-off feature's combos are not registered at all,
/// so other apps can use those keys. Re-registers everything whenever a combo changes.
/// </summary>
internal sealed class HotKeyManager
{
    public sealed record HotKeyAction(string Name, Func<KeyCombo?> Combo, Func<bool> IsEnabled, Action Run);

    private readonly MessageWindow _window;
    private readonly List<HotKeyAction> _actions = new();
    private readonly Dictionary<int, HotKeyAction> _registered = new();
    private int _nextId = 1;

    /// <summary>Names of actions whose combo could not be registered (taken by another app).</summary>
    public HashSet<string> Failures { get; } = new();
    public event Action? FailuresChanged;

    /// <summary>While set (e.g. the shortcut recorder is focused) hotkeys are unregistered.</summary>
    public bool Suspended { get; private set; }

    public HotKeyManager(MessageWindow window)
    {
        _window = window;
        _window.HotKeyPressed += id =>
        {
            if (_registered.TryGetValue(id, out var a)) a.Run();
        };
    }

    public void Add(HotKeyAction action) => _actions.Add(action);

    public void Suspend(bool suspended)
    {
        Suspended = suspended;
        ReRegister();
    }

    public void ReRegister()
    {
        foreach (var id in _registered.Keys) Native.UnregisterHotKey(_window.Handle, id);
        _registered.Clear();
        Failures.Clear();
        if (!Suspended)
        {
            foreach (var a in _actions)
            {
                if (!a.IsEnabled() || a.Combo() is not { } combo) continue;
                var id = _nextId++;
                if (Native.RegisterHotKey(_window.Handle, id, ToNative(combo.Modifiers) | Native.MOD_NOREPEAT, (uint)combo.VirtualKey))
                    _registered[id] = a;
                else
                    Failures.Add(a.Name);
            }
        }
        FailuresChanged?.Invoke();
    }

    private static uint ToNative(KeyModifiers m)
    {
        uint r = 0;
        if (m.HasFlag(KeyModifiers.Alt)) r |= Native.MOD_ALT;
        if (m.HasFlag(KeyModifiers.Control)) r |= Native.MOD_CONTROL;
        if (m.HasFlag(KeyModifiers.Shift)) r |= Native.MOD_SHIFT;
        if (m.HasFlag(KeyModifiers.Win)) r |= Native.MOD_WIN;
        return r;
    }
}
