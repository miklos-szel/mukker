using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;
using Mukker.App.Interop;
using Mukker.Core.Dictation;
using Mukker.Core.Settings;

namespace Mukker.App.Dictation;

/// <summary>
/// The WH_KEYBOARD_LL hook behind Dictation's triggers. RegisterHotKey can't see key-ups or a modifier-only
/// chord (Ctrl+Win), so every key event goes through a <see cref="DictationTriggerTracker"/> instead.
/// <para>Installed only while dictation is enabled and the engine can run. The callback runs on the UI thread
/// (the thread that installed it), does only the tracker's table lookups and posts the resulting events to the
/// dispatcher — it never waits for dictation work. Our own synthetic input (tagged <see cref="Native.MukkerInputTag"/>)
/// is ignored, which is also what stops the Start-menu guard from feeding itself.</para>
/// </summary>
internal sealed class DictationKeyHook : IDisposable
{
    private const int VkEscape = 0x1B;

    private readonly Func<DictationSettings> _settings;
    private readonly Func<bool> _suspended;
    private readonly Func<bool> _isRecording;
    private readonly Action<IReadOnlyList<TriggerEvent>> _onEvents;
    private readonly Action _onEscape;
    private readonly Native.LowLevelKeyboardProc _proc; // kept in a field so the GC never collects the delegate under the hook
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private DictationTriggerTracker _tracker;
    private IntPtr _hook;

    public DictationKeyHook(Func<DictationSettings> settings, Func<bool> suspended, Func<bool> isRecording,
        Action<IReadOnlyList<TriggerEvent>> onEvents, Action onEscape)
    {
        _settings = settings;
        _suspended = suspended;
        _isRecording = isRecording;
        _onEvents = onEvents;
        _onEscape = onEscape;
        _proc = HookProc;
        _tracker = new DictationTriggerTracker(DictationTriggerConfig.FromSettings(settings()));
    }

    public bool IsInstalled => _hook != IntPtr.Zero;

    /// <summary>Installs or removes the hook to match the settings, and reconfigures the tracker.</summary>
    public void Sync()
    {
        var want = _settings().Enabled && Engine.TranscriptionEngine.IsSupported;
        if (want && _hook == IntPtr.Zero)
        {
            _tracker = new DictationTriggerTracker(DictationTriggerConfig.FromSettings(_settings()));
            _hook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, _proc, Native.GetModuleHandle(null), 0);
            if (_hook == IntPtr.Zero) AppHost.Log($"dictation: keyboard hook failed ({Marshal.GetLastWin32Error()})");
        }
        else if (!want && _hook != IntPtr.Zero)
        {
            Native.UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
        else if (want)
        {
            _tracker.Reconfigure(DictationTriggerConfig.FromSettings(_settings()));
        }
    }

    /// <summary>Forgets held keys (e.g. after the shortcut recorder took over the keyboard).</summary>
    public void ResetTracker() => _tracker.Reset();

    private IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && !_suspended())
        {
            try
            {
                var msg = (int)wParam;
                var down = msg is Native.WM_KEYDOWN or Native.WM_SYSKEYDOWN;
                var up = msg is Native.WM_KEYUP or Native.WM_SYSKEYUP;
                if (down || up)
                {
                    var k = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
                    var ours = (k.flags & Native.LLKHF_INJECTED) != 0 && k.dwExtraInfo == Native.MukkerInputTag;
                    if (!ours)
                    {
                        var vk = (int)k.vkCode;
                        var result = _tracker.Process(vk, down, _clock.Elapsed.TotalSeconds);

                        if (result.Events.Count > 0)
                        {
                            var events = result.Events;
                            Application.Current.Dispatcher.BeginInvoke(DispatcherPriority.Send, () => _onEvents(events));
                        }
                        if (down && vk == VkEscape && _isRecording())
                            Application.Current.Dispatcher.BeginInvoke(DispatcherPriority.Send, _onEscape); // Esc still reaches the app
                        if (result.NeedsStartMenuGuard)
                        {
                            // A lone Win key-up opens the Start menu; a key event in between turns it into a shortcut.
                            // VK 0xFF is unassigned. SendInput from here is delivered asynchronously and tagged, so
                            // this hook ignores it when it comes back through.
                            Native.SendKeys(Native.Key(0xFF, false), Native.Key(0xFF, true));
                        }
                        if (result.Swallow) return (IntPtr)1;
                    }
                }
            }
            catch (Exception e) { AppHost.Log($"dictation hook: {e.Message}"); }
        }
        return Native.CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero) Native.UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
    }
}
