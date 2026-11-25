// P/Invoke surface of transcribe.cpp (https://github.com/handy-computer/transcribe.cpp), the engine Dictation uses.
//
// Header version: v0.4.2 (include/transcribe.h + include/transcribe/langid.h at that tag; header hash
// f99ad4169374b8f3 per the native archive's contract.json). Struct layouts below were checked field-by-field
// against those headers (x86_64 Windows, natural alignment: enums are 4-byte ints, `bool` is 1 byte, pointers
// 8) and are verified again at load time against transcribe_abi_struct_size(), so a library/header drift
// disables Dictation with a clear reason instead of corrupting memory. Every params struct is filled by its
// transcribe_*_init() first (it stamps struct_size and the defaults); only the fields we need are changed.
//
// The native library is a GGML_BACKEND_DL build: the compute backends (ggml-cpu-*.dll, ggml-vulkan.dll) are
// separate DLLs that transcribe_init_backends() loads from a directory we pass explicitly — the directory the
// transcribe.dll we actually loaded lives in (in a single-file publish that is the self-extraction directory).
using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

namespace Mukker.App.Dictation.Engine;

internal sealed class TranscribeException : Exception
{
    public int Status { get; }
    public TranscribeException(int status, string context)
        : base($"{context}: {TranscribeNative.StatusString(status)} (status {status})") => Status = status;
}

internal static unsafe class TranscribeNative
{
    public const string ExpectedVersion = "0.4.2";
    private const string Lib = "transcribe";

    public const int Ok = 0;
    public const int ErrBackend = 8;
    public const int BackendAuto = 0;
    public const int BackendCpu = 1;

    // ---- struct layouts (see header comment) ---------------------------------------------------------

    [StructLayout(LayoutKind.Sequential)]
    public struct ModelLoadParams   // transcribe_model_load_params
    {
        public ulong StructSize;
        public int Backend;         // transcribe_backend_request
        public IntPtr Device;       // transcribe_device_t, NULL = pick by backend
        public byte NoMmap;         // bool
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SessionParams     // transcribe_session_params
    {
        public ulong StructSize;
        public int NThreads;
        public int KvType;          // transcribe_kv_type
        public int NCtx;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RunParams         // transcribe_run_params
    {
        public ulong StructSize;
        public int Task;
        public int Timestamps;
        public int Pnc;
        public int Itn;
        public int Diarize;
        public IntPtr Language;         // const char *
        public IntPtr TargetLanguage;   // const char *
        public byte KeepSpecialTags;    // bool
        public IntPtr Family;           // const transcribe_ext *
        public int SpecKDrafts;
        public IntPtr Vocabulary;       // const char * const *
        public int NVocabulary;
        public IntPtr Prompt;
        public IntPtr Prefix;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LangIdSessionParams   // transcribe_langid_session_params
    {
        public ulong StructSize;
        public int NThreads;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LangIdParams          // transcribe_langid_params
    {
        public ulong StructSize;
        public IntPtr Allowed;          // const char * const *
        public int NAllowed;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LangIdResult          // transcribe_langid_result
    {
        public ulong StructSize;
        public int NCandidates;
        public float AllowedMass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LangIdCandidate       // transcribe_langid_candidate
    {
        public ulong StructSize;
        public int Index;
        public IntPtr Code;             // const char *
        public IntPtr Name;
        public float P;
        public float Logit;
    }

    // transcribe_abi_struct ids used for the load-time layout check.
    private const int AbiModelLoadParams = 0, AbiSessionParams = 1, AbiRunParams = 2,
        AbiLangIdSessionParams = 20, AbiLangIdParams = 21, AbiLangIdResult = 22, AbiLangIdCandidate = 23;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void LogCallback(int level, IntPtr msg, IntPtr userdata);

    // ---- imports ---------------------------------------------------------------------------------------

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr transcribe_version();
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr transcribe_status_string(int status);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern nuint transcribe_abi_struct_size(int which);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void transcribe_log_set(LogCallback? cb, IntPtr userdata);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int transcribe_init_backends(byte* artifactDir);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void transcribe_model_load_params_init(ModelLoadParams* p);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int transcribe_model_load_file(byte* path, ModelLoadParams* p, IntPtr* outModel);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void transcribe_model_free(IntPtr model);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr transcribe_model_backend(IntPtr model);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void transcribe_session_params_init(SessionParams* p);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int transcribe_session_init(IntPtr model, SessionParams* p, IntPtr* outSession);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void transcribe_session_free(IntPtr session);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void transcribe_run_params_init(RunParams* p);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int transcribe_run(IntPtr session, float* pcm, int nSamples, RunParams* p);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr transcribe_full_text(IntPtr session);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr transcribe_detected_language(IntPtr session);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void transcribe_langid_session_params_init(LangIdSessionParams* p);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int transcribe_langid_session_init(IntPtr model, LangIdSessionParams* p, IntPtr* outSession);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void transcribe_langid_session_free(IntPtr session);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void transcribe_langid_params_init(LangIdParams* p);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int transcribe_langid_run(IntPtr session, float* pcm, int nSamples, LangIdParams* p);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void transcribe_langid_result_init(LangIdResult* p);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int transcribe_langid_get_result(IntPtr session, LangIdResult* p);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void transcribe_langid_candidate_init(LangIdCandidate* p);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int transcribe_langid_get_candidate(IntPtr session, int i, LangIdCandidate* p);

    [DllImport("kernel32", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint GetModuleFileNameW(IntPtr module, char* buffer, uint size);

    // ---- loading ---------------------------------------------------------------------------------------

    private static readonly object LoadLock = new();
    private static bool _loadAttempted;
    private static bool _supported;
    private static string? _reason;
    private static IntPtr _handle;
    private static LogCallback? _logCallback;   // kept alive: the native side holds the function pointer

    /// <summary>True when the x64 process loaded a matching transcribe.dll and its backends.</summary>
    public static bool IsSupported { get { EnsureLoaded(); return _supported; } }

    /// <summary>A user-facing sentence when <see cref="IsSupported"/> is false.</summary>
    public static string? UnsupportedReason { get { EnsureLoaded(); return _reason; } }

    /// <summary>The directory the native library was loaded from (where its backend modules live).</summary>
    public static string? NativeDirectory { get; private set; }

    private static void EnsureLoaded()
    {
        lock (LoadLock)
        {
            if (_loadAttempted) return;
            _loadAttempted = true;
            try { Load(); }
            catch (Exception ex)
            {
                _supported = false;
                _reason ??= "Dictation's speech engine could not be started.";
                AppHost.Log($"dictation: native load failed: {ex.GetType().Name}: {ex.Message}");
            }
        }
    }

    private static void Load()
    {
        if (RuntimeInformation.ProcessArchitecture != Architecture.X64)
        {
            _reason = "Dictation needs the x64 build of Mukker.";
            return;
        }

        NativeLibrary.SetDllImportResolver(typeof(TranscribeNative).Assembly, Resolve);
        if (!TryLoadHandle(out _handle))
        {
            _reason = "Dictation's speech engine (transcribe.dll) is missing from this build.";
            AppHost.Log("dictation: transcribe.dll not found");
            return;
        }
        NativeDirectory = ModuleDirectory(_handle);

        string version = Marshal.PtrToStringUTF8(transcribe_version()) ?? "?";
        if (version != ExpectedVersion)
        {
            _reason = $"Dictation's speech engine is version {version}, but this build needs {ExpectedVersion}.";
            AppHost.Log($"dictation: transcribe.dll version {version}, expected {ExpectedVersion}");
            return;
        }

        // Layout check: every struct we hand over must be exactly the size the library stamps into it.
        (int id, int managed, string name)[] sizes =
        [
            (AbiModelLoadParams, sizeof(ModelLoadParams), nameof(ModelLoadParams)),
            (AbiSessionParams, sizeof(SessionParams), nameof(SessionParams)),
            (AbiRunParams, sizeof(RunParams), nameof(RunParams)),
            (AbiLangIdSessionParams, sizeof(LangIdSessionParams), nameof(LangIdSessionParams)),
            (AbiLangIdParams, sizeof(LangIdParams), nameof(LangIdParams)),
            (AbiLangIdResult, sizeof(LangIdResult), nameof(LangIdResult)),
            (AbiLangIdCandidate, sizeof(LangIdCandidate), nameof(LangIdCandidate)),
        ];
        foreach (var (id, managed, name) in sizes)
        {
            nuint native = transcribe_abi_struct_size(id);   // 0 = unknown id, cannot verify
            if (native != 0 && (int)native != managed)
            {
                _reason = "Dictation's speech engine does not match this build of Mukker.";
                AppHost.Log($"dictation: ABI mismatch for {name}: native {native}, managed {managed}");
                return;
            }
        }

        // Only warnings and errors are worth keeping; the library's own messages never carry audio or text.
        _logCallback = OnNativeLog;
        transcribe_log_set(_logCallback, IntPtr.Zero);

        int status;
        fixed (byte* dir = Utf8Z(NativeDirectory!)) status = transcribe_init_backends(dir);
        if (status != Ok)
        {
            _reason = "Dictation could not start any compute backend.";
            AppHost.Log($"dictation: init_backends: {StatusString(status)} (dir {NativeDirectory})");
            return;
        }
        AppHost.Log($"dictation: transcribe.cpp {version} ready, backends from {NativeDirectory}");
        _supported = true;
    }

    private static bool TryLoadHandle(out IntPtr handle)
    {
        handle = IntPtr.Zero;
        try
        {
            string beside = Path.Combine(AppContext.BaseDirectory, "transcribe.dll");
            if (File.Exists(beside) && NativeLibrary.TryLoad(beside, out handle)) return true;
        }
        catch (Exception ex) { AppHost.Log($"dictation: loading beside the exe failed: {ex.Message}"); }
        try
        {
            // Default probing: includes the single-file self-extraction directory.
            if (NativeLibrary.TryLoad(Lib, typeof(TranscribeNative).Assembly, null, out handle)) return true;
        }
        catch (Exception ex) { AppHost.Log($"dictation: probing for transcribe.dll failed: {ex.Message}"); }
        return false;
    }

    private static IntPtr Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath) =>
        libraryName == Lib && _handle != IntPtr.Zero ? _handle : IntPtr.Zero;

    private static string ModuleDirectory(IntPtr module)
    {
        char* buf = stackalloc char[1024];
        uint n = GetModuleFileNameW(module, buf, 1024);
        string path = n > 0 && n < 1024 ? new string(buf, 0, (int)n) : "";
        string? dir = Path.GetDirectoryName(path);
        return string.IsNullOrEmpty(dir) ? AppContext.BaseDirectory : dir;
    }

    private static void OnNativeLog(int level, IntPtr msg, IntPtr userdata)
    {
        if (level != 2 && level != 3) return;   // WARN, ERROR
        try
        {
            string text = (Marshal.PtrToStringUTF8(msg) ?? "").TrimEnd();
            AppHost.Log($"dictation: transcribe.cpp {(level == 3 ? "error" : "warn")}: {text}");
        }
        catch { /* must not throw into native code */ }
    }

    // ---- helpers ---------------------------------------------------------------------------------------

    public static string StatusString(int status)
    {
        try { return Marshal.PtrToStringUTF8(transcribe_status_string(status)) ?? "unknown"; }
        catch { return "unknown"; }
    }

    internal static byte[] Utf8Z(string s)
    {
        int n = Encoding.UTF8.GetByteCount(s);
        var b = new byte[n + 1];
        Encoding.UTF8.GetBytes(s, 0, s.Length, b, 0);
        return b;
    }

    private static void Check(int status, string context)
    {
        if (status != Ok) throw new TranscribeException(status, context);
    }

    // ---- model / session -------------------------------------------------------------------------------

    /// <summary>Loads a GGUF model; returns the handle and the backend it landed on ("cpu", "vulkan", ...).</summary>
    public static IntPtr LoadModel(string path, int backendRequest, out string backend)
    {
        ModelLoadParams p = default;
        transcribe_model_load_params_init(&p);
        p.Backend = backendRequest;
        IntPtr model = IntPtr.Zero;
        int status;
        fixed (byte* path8 = Utf8Z(path)) status = transcribe_model_load_file(path8, &p, &model);
        Check(status, "loading model");
        if (model == IntPtr.Zero) throw new TranscribeException(1, "loading model (null handle)");
        backend = Marshal.PtrToStringUTF8(transcribe_model_backend(model)) ?? "?";
        return model;
    }

    public static void FreeModel(IntPtr model) { if (model != IntPtr.Zero) transcribe_model_free(model); }

    public static IntPtr CreateSession(IntPtr model)
    {
        SessionParams p = default;
        transcribe_session_params_init(&p);
        IntPtr session = IntPtr.Zero;
        Check(transcribe_session_init(model, &p, &session), "creating session");
        return session;
    }

    public static void FreeSession(IntPtr session) { if (session != IntPtr.Zero) transcribe_session_free(session); }

    /// <summary>Runs one transcription; <paramref name="language"/> is the hint (null = the model decides).</summary>
    public static (string Text, string? Language) Run(IntPtr session, float[] samples, string? language)
    {
        if (samples.Length == 0) return ("", null);
        IntPtr lang = language is null ? IntPtr.Zero : Marshal.StringToCoTaskMemUTF8(language);
        try
        {
            RunParams p = default;
            transcribe_run_params_init(&p);
            p.Language = lang;
            int status;
            fixed (float* pcm = samples) status = transcribe_run(session, pcm, samples.Length, &p);
            Check(status, "transcribing");
        }
        finally { if (lang != IntPtr.Zero) Marshal.FreeCoTaskMem(lang); }

        string text = Marshal.PtrToStringUTF8(transcribe_full_text(session)) ?? "";
        string detected = Marshal.PtrToStringUTF8(transcribe_detected_language(session)) ?? "";
        return (text, detected.Length == 0 ? null : detected);
    }

    // ---- language id -----------------------------------------------------------------------------------

    public static IntPtr CreateLangIdSession(IntPtr model)
    {
        LangIdSessionParams p = default;
        transcribe_langid_session_params_init(&p);
        IntPtr session = IntPtr.Zero;
        Check(transcribe_langid_session_init(model, &p, &session), "creating language-id session");
        return session;
    }

    public static void FreeLangIdSession(IntPtr session) { if (session != IntPtr.Zero) transcribe_langid_session_free(session); }

    /// <summary>The top candidate's code among <paramref name="allowed"/> (null/empty = every label), or null.</summary>
    public static string? DetectLanguage(IntPtr session, float[] samples, string[]? allowed)
    {
        if (samples.Length == 0) return null;
        int n = allowed?.Length ?? 0;
        var owned = new IntPtr[n];
        IntPtr table = IntPtr.Zero;
        try
        {
            for (int i = 0; i < n; i++) owned[i] = Marshal.StringToCoTaskMemUTF8(allowed![i]);
            if (n > 0)
            {
                table = Marshal.AllocHGlobal(n * IntPtr.Size);
                for (int i = 0; i < n; i++) ((IntPtr*)table)[i] = owned[i];
            }
            LangIdParams p = default;
            transcribe_langid_params_init(&p);
            if (n > 0) { p.Allowed = table; p.NAllowed = n; }   // NULL + 0 would mean "every label"
            int status;
            fixed (float* pcm = samples) status = transcribe_langid_run(session, pcm, samples.Length, &p);
            Check(status, "detecting language");

            LangIdResult res = default;
            transcribe_langid_result_init(&res);
            Check(transcribe_langid_get_result(session, &res), "reading language-id result");
            if (res.NCandidates <= 0) return null;
            LangIdCandidate c = default;
            transcribe_langid_candidate_init(&c);
            Check(transcribe_langid_get_candidate(session, 0, &c), "reading language-id candidate");
            return c.Code == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(c.Code);
        }
        finally
        {
            if (table != IntPtr.Zero) Marshal.FreeHGlobal(table);
            foreach (var s in owned) if (s != IntPtr.Zero) Marshal.FreeCoTaskMem(s);
        }
    }
}
