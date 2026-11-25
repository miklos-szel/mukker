using System.Text.Json;
using Mukker.Core.Dictation;
using Mukker.Core.Settings;

namespace Mukker.Core.Tests;

public class DictationPressMachineTests
{
    [Fact]
    public void PushToTalkRecordsWhileHeld()
    {
        var m = new DictationPressMachine(DictationActivation.PushToTalk);
        Assert.Equal(DictationCommand.Start, m.Press(0));
        Assert.Null(m.Press(0.1));
        Assert.Equal(DictationCommand.Stop, m.Release(0.05));
        Assert.Equal(DictationPressMachine.Phase.Idle, m.State);
    }

    [Fact]
    public void ToggleStartsAndStopsOnPresses()
    {
        var m = new DictationPressMachine(DictationActivation.Toggle);
        Assert.Equal(DictationCommand.Start, m.Press(0));
        Assert.Null(m.Release(2));
        Assert.Equal(DictationPressMachine.Phase.Latched, m.State);
        Assert.Equal(DictationCommand.Stop, m.Press(5));
        Assert.Null(m.Release(5.1));
        Assert.Equal(DictationPressMachine.Phase.Idle, m.State);
    }

    [Fact]
    public void HoldOrToggleHoldIsPushToTalk()
    {
        var m = new DictationPressMachine(DictationActivation.HoldOrToggle, 0.3);
        Assert.Equal(DictationCommand.Start, m.Press(10));
        Assert.Equal(DictationCommand.Stop, m.Release(10.3));
    }

    [Fact]
    public void HoldOrToggleTapLatches()
    {
        var m = new DictationPressMachine(DictationActivation.HoldOrToggle, 0.3);
        Assert.Equal(DictationCommand.Start, m.Press(10));
        Assert.Null(m.Release(10.29));
        Assert.Equal(DictationPressMachine.Phase.Latched, m.State);
        Assert.Equal(DictationCommand.Stop, m.Press(14));
        Assert.Null(m.Release(14.1));
        Assert.Equal(DictationCommand.Start, m.Press(20));
    }

    [Fact]
    public void AnotherKeyCancelsAHeldPress()
    {
        var m = new DictationPressMachine(DictationActivation.HoldOrToggle);
        Assert.Equal(DictationCommand.Start, m.Press(0));
        Assert.Equal(DictationCommand.Cancel, m.Interrupt());
        Assert.Null(m.Interrupt());
        Assert.Null(m.Release(1));
        Assert.Equal(DictationPressMachine.Phase.Idle, m.State);
    }

    [Fact]
    public void TypingWhileLatchedDoesNotCancel()
    {
        var m = new DictationPressMachine(DictationActivation.Toggle);
        m.Press(0); m.Release(0.1);
        Assert.Null(m.Interrupt());
        Assert.Equal(DictationPressMachine.Phase.Latched, m.State);
    }

    [Fact]
    public void RecordingEndedElsewhere()
    {
        var held = new DictationPressMachine(DictationActivation.PushToTalk);
        held.Press(0);
        held.RecordingEnded();
        Assert.Null(held.Release(1));
        Assert.Equal(DictationPressMachine.Phase.Idle, held.State);

        var latched = new DictationPressMachine(DictationActivation.Toggle);
        latched.Press(0); latched.Release(0.1);
        latched.RecordingEnded();
        Assert.Equal(DictationCommand.Start, latched.Press(3));
    }

    [Fact]
    public void MenuStartedRecordingStopsOnNextPress()
    {
        var m = new DictationPressMachine(DictationActivation.PushToTalk);
        m.RecordingStartedElsewhere();
        Assert.Equal(DictationCommand.Stop, m.Press(0));
    }
}

public class DictationCatalogTests
{
    private static DictationModel Parakeet => DictationCatalog.Model("parakeet-ultra");
    private static DictationModel Whisper => DictationCatalog.Model("whisper-large-v3-turbo");
    private static readonly DictationLanguage En = DictationLanguage.English, De = DictationLanguage.German, Hu = DictationLanguage.Hungarian;

    [Fact]
    public void ParakeetAlwaysDecidesItself()
    {
        Assert.Equal(new DictationLanguagePlan.ModelDecides(), DictationLanguagePlan.Plan(Parakeet, De, [En]));
        Assert.Equal(new DictationLanguagePlan.ModelDecides(), DictationLanguagePlan.Plan(Parakeet, De, [En], forced: Hu));
    }

    [Fact]
    public void FixedLanguageWins() =>
        Assert.Equal(new DictationLanguagePlan.Fixed(Hu), DictationLanguagePlan.Plan(Whisper, Hu, [En]));

    [Fact]
    public void ForcedBeatsSelectedAndAutomatic()
    {
        Assert.Equal(new DictationLanguagePlan.Fixed(De), DictationLanguagePlan.Plan(Whisper, Hu, [En], forced: De));
        Assert.Equal(new DictationLanguagePlan.Fixed(En), DictationLanguagePlan.Plan(Whisper, null, [De, Hu], forced: En));
    }

    [Fact]
    public void AutomaticDetectsAmongPreferred() =>
        Assert.Equal(new DictationLanguagePlan.Detect([En, Hu]), DictationLanguagePlan.Plan(Whisper, null, [Hu, En]));

    [Fact]
    public void AutomaticWithOnePreferredIsFixed() =>
        Assert.Equal(new DictationLanguagePlan.Fixed(De), DictationLanguagePlan.Plan(Whisper, null, [De]));

    [Fact]
    public void AutomaticWithNothingPreferredUsesAllThree() =>
        Assert.Equal(new DictationLanguagePlan.Detect([En, De, Hu]), DictationLanguagePlan.Plan(Whisper, null, []));

    [Fact]
    public void LanguageCodesAndLabels()
    {
        Assert.Equal(["en", "de", "hu"], Enum.GetValues<DictationLanguage>().Select(l => l.Code()));
        Assert.Equal("Hungarian", Hu.Label());
    }

    [Fact]
    public void DefaultModelIsWhisperTurbo()
    {
        Assert.Equal("whisper-large-v3-turbo", DictationCatalog.DefaultModelId);
        Assert.Equal("whisper-large-v3-turbo", DictationCatalog.Model("no-such-model").Id);
        Assert.Contains(DictationCatalog.Models, m => m.Id == "parakeet-ultra");
    }

    [Fact]
    public void CatalogEntriesArePinned()
    {
        var ids = DictationCatalog.Models.Select(m => m.Id).ToList();
        Assert.Equal(ids.Count, ids.Distinct().Count());
        foreach (var f in DictationCatalog.Models.Select(m => m.File).Append(DictationCatalog.LanguageDetector))
        {
            Assert.Equal(40, f.Revision.Length);
            Assert.Equal(64, f.Sha256.Length);
            Assert.True(f.ByteSize > 0);
            Assert.Equal($"https://huggingface.co/{f.Repo}/resolve/{f.Revision}/{f.FileName}", f.DownloadUrl);
        }
        Assert.Equal(886_381_728, Whisper.File.ByteSize);
        Assert.Equal("a1539be1b849ea7463b88343e5277b373d0c4ea9", Parakeet.File.Revision);
        Assert.Equal("063e6cb0af3d53085fc7d68356dfde5ecee2ffa7bc79855f7e4ff930081bfe3a", DictationCatalog.LanguageDetector.Sha256);
    }

    [Fact]
    public void OnlyHintableModelsNeedTheDetector()
    {
        Assert.Equal([Whisper.File, DictationCatalog.LanguageDetector], DictationCatalog.Files(Whisper));
        Assert.Equal([Parakeet.File], DictationCatalog.Files(Parakeet));
    }
}

public class DictationTextTests
{
    [Fact]
    public void Sha256OfFile()
    {
        var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        File.WriteAllText(path, "abc");
        try
        {
            Assert.Equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", DictationText.Sha256OfFile(path));
            Assert.Null(DictationText.Sha256OfFile(path + ".missing"));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void FinalText()
    {
        Assert.Equal("Hello there.", DictationText.FinalText("  Hello there.\n", false));
        Assert.Equal("Hello ", DictationText.FinalText("Hello", true));
        Assert.Equal("", DictationText.FinalText(" \n ", true));
    }

    [Fact]
    public void LevelMapping()
    {
        Assert.Equal(0, DictationText.RmsLevel([]));
        Assert.Equal(0, DictationText.RmsLevel([0, 0, 0]));
        Assert.Equal(1, DictationText.RmsLevel([1, -1, 1, -1]), 3);
    }

    [Fact]
    public void Constants()
    {
        Assert.Equal(0.3, DictationText.MinimumDuration);
        Assert.Equal(16000, DictationText.SampleRate);
        Assert.Equal(300, DictationText.MaxDuration);
    }
}

public class DictationStorePlanTests
{
    private static DictationModel Whisper => DictationCatalog.Model("whisper-large-v3-turbo");
    private static DictationModel Small => DictationCatalog.Model("whisper-small");
    private static DictationModel Parakeet => DictationCatalog.Model("parakeet-ultra");
    private static Func<DictationModelFile, bool> Has(params DictationModelFile[] files) => f => files.Contains(f);

    [Fact]
    public void MissingAndRemaining()
    {
        var none = Has();
        Assert.Equal(2, DictationStorePlan.MissingFiles(Whisper, none).Count);
        Assert.Equal(886_381_728L + 26_693_632L, DictationStorePlan.RemainingBytes(Whisper, none));
        var detectorOnly = Has(DictationCatalog.LanguageDetector);
        Assert.Equal(886_381_728L, DictationStorePlan.RemainingBytes(Whisper, detectorOnly));
        Assert.Equal(740_363_168L, DictationStorePlan.RemainingBytes(Parakeet, detectorOnly));
    }

    [Fact]
    public void IsInstalledNeedsEveryFile()
    {
        Assert.False(DictationStorePlan.IsInstalled(Whisper, Has(Whisper.File)));
        Assert.True(DictationStorePlan.IsInstalled(Whisper, Has(Whisper.File, DictationCatalog.LanguageDetector)));
        Assert.True(DictationStorePlan.IsInstalled(Parakeet, Has(Parakeet.File)));
    }

    [Fact]
    public void DeleteKeepsSharedDetectorWhileAnotherModelNeedsIt()
    {
        var present = Has(Whisper.File, Small.File, DictationCatalog.LanguageDetector);
        Assert.Equal([Whisper.File], DictationStorePlan.FilesToDelete(Whisper, present));
        var alone = Has(Whisper.File, DictationCatalog.LanguageDetector);
        Assert.Equal([Whisper.File, DictationCatalog.LanguageDetector], DictationStorePlan.FilesToDelete(Whisper, alone));
        Assert.Equal([Parakeet.File], DictationStorePlan.FilesToDelete(Parakeet, Has(Parakeet.File, DictationCatalog.LanguageDetector)));
    }
}

public class DictationSettingsTests
{
    private static readonly DictationLanguage En = DictationLanguage.English, De = DictationLanguage.German, Hu = DictationLanguage.Hungarian;

    [Fact]
    public void Defaults()
    {
        var s = new AppSettings().Dictation;
        Assert.True(s.Enabled);
        Assert.Equal(DictationTrigger.CtrlWin, s.Trigger);
        Assert.Equal(new KeyCombo(KeyModifiers.Alt, 0x20), s.Combo);
        Assert.Equal(DictationActivation.HoldOrToggle, s.Activation);
        Assert.Equal("whisper-large-v3-turbo", s.ModelId);
        Assert.Null(s.Language);
        Assert.Equal("", s.MicrophoneId);
        Assert.True(s.SoundsEnabled);
        Assert.Equal(0.6, s.SoundVolume);
        Assert.True(s.OverlayEnabled);
        Assert.False(s.AppendTrailingSpace);
        Assert.Equal(DictationUnloadDelay.FiveMinutes, s.UnloadDelay);
        Assert.Null(s.EnglishCombo); Assert.Null(s.GermanCombo); Assert.Null(s.HungarianCombo);
        Assert.Contains(En, s.PreferredLanguages);
    }

    [Fact]
    public void JsonRoundTrip()
    {
        var a = new AppSettings();
        a.Dictation.Trigger = DictationTrigger.Combo;
        a.Dictation.Activation = DictationActivation.Toggle;
        a.Dictation.Language = De;
        a.Dictation.PreferredLanguages = [De, Hu];
        a.Dictation.ModelId = "parakeet-ultra";
        a.Dictation.UnloadDelay = DictationUnloadDelay.Never;
        a.Dictation.GermanCombo = new KeyCombo(KeyModifiers.Control | KeyModifiers.Win, 0x47);
        var json = JsonSerializer.Serialize(a, SettingsStore.JsonOptions);
        Assert.Contains("\"Combo\"", json);
        var b = JsonSerializer.Deserialize<AppSettings>(json, SettingsStore.JsonOptions)!.Dictation;
        Assert.Equal(DictationTrigger.Combo, b.Trigger);
        Assert.Equal(DictationActivation.Toggle, b.Activation);
        Assert.Equal(De, b.Language);
        Assert.Equal([De, Hu], b.PreferredLanguages);
        Assert.Equal("parakeet-ultra", b.ModelId);
        Assert.Equal(DictationUnloadDelay.Never, b.UnloadDelay);
        Assert.Equal(a.Dictation.GermanCombo, b.GermanCombo);
        Assert.Null(b.EnglishCombo);

        a.Dictation.Language = null;
        var c = JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(a, SettingsStore.JsonOptions), SettingsStore.JsonOptions)!.Dictation;
        Assert.Null(c.Language);
    }

    [Fact]
    public void UnknownStoredModelFallsBackToDefault()
    {
        var s = new DictationSettings { ModelId = "retired-model" };
        Assert.Equal(DictationCatalog.DefaultModelId, s.Model.Id);
    }

    [Fact]
    public void VolumeIsClamped()
    {
        var s = new DictationSettings { SoundVolume = 3 };
        Assert.Equal(1, s.SoundVolume);
        s.SoundVolume = -1;
        Assert.Equal(0, s.SoundVolume);
    }

    [Fact]
    public void DefaultPreferredLanguagesFollowSystem()
    {
        Assert.Equal([En, Hu], DictationSettings.DefaultPreferredLanguages(["hu-HU", "en-US"]));
        Assert.Equal([En], DictationSettings.DefaultPreferredLanguages(["fr-FR"]));
        Assert.Equal([En, De, Hu], DictationSettings.DefaultPreferredLanguages(["hu", "de"]));
        Assert.Equal([En], DictationSettings.DefaultPreferredLanguages([""]));
    }

    [Fact]
    public void LanguageCombosActiveNeedsEnabledHintableModel()
    {
        var s = new DictationSettings();
        Assert.True(s.LanguageCombosActive);
        s.ModelId = "parakeet-ultra";
        Assert.False(s.LanguageCombosActive);
        s.ModelId = "whisper-small"; s.Enabled = false;
        Assert.False(s.LanguageCombosActive);
    }

    [Fact]
    public void LabelsMatchTheMac()
    {
        Assert.Equal("Hold to talk, or tap to start/stop", DictationActivation.HoldOrToggle.Label());
        Assert.Equal("Hold to talk", DictationActivation.PushToTalk.Label());
        Assert.Equal("After 5 minutes", DictationUnloadDelay.FiveMinutes.Label());
        Assert.Equal("Never", DictationUnloadDelay.Never.Label());
    }

    [Fact]
    public void ConfigFromSettingsDropsLanguageCombosForParakeet()
    {
        var s = new DictationSettings { EnglishCombo = new(KeyModifiers.Control, 0x45) };
        Assert.NotNull(DictationTriggerConfig.FromSettings(s).English);
        s.ModelId = "parakeet-ultra";
        Assert.Null(DictationTriggerConfig.FromSettings(s).English);
    }
}

public class DictationTriggerTrackerTests
{
    private const int LCtrl = 0xA2, RCtrl = 0xA3, LWin = 0x5B, RWin = 0x5C, LShift = 0xA0, LAlt = 0xA4, Space = 0x20, E = 0x45, A = 0x41, B = 0x42, G = 0x47;
    private double _t;

    private static DictationTriggerTracker Chord() => new(new DictationTriggerConfig(DictationTrigger.CtrlWin, null));
    private static DictationTriggerTracker Combo(KeyCombo? lang = null) =>
        new(new DictationTriggerConfig(DictationTrigger.Combo, new(KeyModifiers.Alt, Space), lang));

    private TriggerResult Down(DictationTriggerTracker t, int vk) => t.Process(vk, true, _t += 0.01);
    private TriggerResult Up(DictationTriggerTracker t, int vk) => t.Process(vk, false, _t += 0.01);

    private static void Is(TriggerResult r, params (TriggerEventKind, DictationLanguage?)[] expected) =>
        Assert.Equal(expected, r.Events.Select(e => (e.Kind, e.Trigger.Language)).ToArray());

    private static readonly DictationLanguage? Base = null;

    [Fact]
    public void ChordPressesWhenBothDownInEitherOrder()
    {
        var t = Chord();
        Is(Down(t, LCtrl));
        var r = Down(t, LWin);
        Is(r, (TriggerEventKind.Press, Base));
        Assert.False(r.Swallow);

        var t2 = Chord();
        Is(Down(t2, RWin));
        Is(Down(t2, RCtrl), (TriggerEventKind.Press, Base));
    }

    [Fact]
    public void GenericControlCodeCounts()
    {
        var t = Chord();
        Down(t, 0x11);
        Is(Down(t, LWin), (TriggerEventKind.Press, Base));
    }

    [Fact]
    public void ChordReleasesOnceAndAutoRepeatIsIgnored()
    {
        var t = Chord();
        Down(t, LCtrl); Down(t, LWin);
        Is(Down(t, LCtrl));
        Is(Down(t, LWin));
        var r = Up(t, LWin);
        Is(r, (TriggerEventKind.Release, Base));
        Assert.True(r.NeedsStartMenuGuard);
        var r2 = Up(t, LCtrl);
        Is(r2);
        Assert.False(r2.NeedsStartMenuGuard);
    }

    [Fact]
    public void ChordReleasedViaCtrlHasNoGuardUntilWinUp()
    {
        var t = Chord();
        Down(t, LCtrl); Down(t, LWin);
        var r = Up(t, LCtrl);
        Is(r, (TriggerEventKind.Release, Base));
        Assert.False(r.NeedsStartMenuGuard);
        Assert.True(Up(t, LWin).NeedsStartMenuGuard);
    }

    [Fact]
    public void ChordDoesNotPressWithAnotherKeyHeld()
    {
        var t = Chord();
        Down(t, A);
        Down(t, LCtrl);
        Is(Down(t, LWin));
        Up(t, LWin);
        Down(t, LShift);
        Is(Down(t, LWin));
    }

    [Fact]
    public void ShiftHeldBlocksChordPress()
    {
        var t = Chord();
        Down(t, LShift); Down(t, LCtrl);
        Is(Down(t, LWin));
    }

    [Fact]
    public void ChordInterruptedOnceThenReleasedOnceAndStaysConsumed()
    {
        var t = Chord();
        Down(t, LCtrl); Down(t, LWin);
        var r = Down(t, A);
        Is(r, (TriggerEventKind.Interrupt, Base));
        Assert.False(r.Swallow);
        Is(Down(t, B));
        Is(Up(t, A));
        Is(Up(t, B));
        Is(Up(t, LCtrl), (TriggerEventKind.Release, Base));
        // Ctrl pressed again while Win still down: consumed, no new press.
        Is(Down(t, LCtrl));
        Is(Up(t, LCtrl));
        Is(Up(t, LWin));
        // Both released: fresh press possible.
        Down(t, LCtrl);
        Is(Down(t, LWin), (TriggerEventKind.Press, Base));
    }

    [Fact]
    public void ChordInterruptedByModifier()
    {
        var t = Chord();
        Down(t, LCtrl); Down(t, LWin);
        Is(Down(t, LShift), (TriggerEventKind.Interrupt, Base));
    }

    [Fact]
    public void SecondCtrlOrWinKeyDoesNotInterrupt()
    {
        var t = Chord();
        Down(t, LCtrl); Down(t, LWin);
        Is(Down(t, RCtrl));
        Is(Up(t, LCtrl));
        Is(Up(t, RCtrl), (TriggerEventKind.Release, Base));
    }

    [Fact]
    public void ChordIgnoredWhenBaseIsACombo()
    {
        var t = Combo();
        Down(t, LCtrl);
        Is(Down(t, LWin));
    }

    [Fact]
    public void ComboPressSwallowsDownRepeatAndUp()
    {
        var t = Combo();
        Is(Down(t, LAlt));
        var d = Down(t, Space);
        Is(d, (TriggerEventKind.Press, Base));
        Assert.True(d.Swallow);
        var rep = Down(t, Space);
        Is(rep);
        Assert.True(rep.Swallow);
        var u = Up(t, Space);
        Is(u, (TriggerEventKind.Release, Base));
        Assert.True(u.Swallow);
        // The Alt release afterwards is not a second release.
        Is(Up(t, LAlt));
    }

    [Fact]
    public void ComboReleasesWhenModifierGoesUpFirstAndSwallowsLateKeyUp()
    {
        var t = Combo();
        Down(t, LAlt); Down(t, Space);
        var r = Up(t, LAlt);
        Is(r, (TriggerEventKind.Release, Base));
        Assert.False(r.Swallow);
        var u = Up(t, Space);
        Is(u);
        Assert.True(u.Swallow);
    }

    [Fact]
    public void ComboNeedsExactModifiers()
    {
        var t = Combo();
        Down(t, LAlt); Down(t, LShift);
        var r = Down(t, Space);
        Is(r);
        Assert.False(r.Swallow);
        Assert.False(Up(t, Space).Swallow);

        var t2 = Combo();
        var bare = Down(t2, Space);
        Is(bare);
        Assert.False(bare.Swallow);
    }

    [Fact]
    public void ComboInterruptedByAnotherKey()
    {
        var t = Combo();
        Down(t, LAlt); Down(t, Space);
        var r = Down(t, A);
        Is(r, (TriggerEventKind.Interrupt, Base));
        Assert.False(r.Swallow);
        Is(Down(t, B));
        Is(Up(t, Space), (TriggerEventKind.Release, Base));
    }

    [Fact]
    public void ComboPressRejectedWhenAnotherKeyHeld()
    {
        var t = Combo();
        Down(t, A); Down(t, LAlt);
        Is(Down(t, Space));
    }

    [Fact]
    public void LanguageComboPressesWithItsOwnId()
    {
        var t = Combo(new KeyCombo(KeyModifiers.Control | KeyModifiers.Shift, E));
        Down(t, LCtrl); Down(t, LShift);
        var r = Down(t, E);
        Is(r, (TriggerEventKind.Press, DictationLanguage.English));
        Assert.True(r.Swallow);
        Is(Up(t, E), (TriggerEventKind.Release, DictationLanguage.English));
    }

    [Fact]
    public void LanguageComboOnTopOfPressedChordCancelsThenPresses()
    {
        var t = new DictationTriggerTracker(new DictationTriggerConfig(
            DictationTrigger.CtrlWin, null, English: new(KeyModifiers.Control | KeyModifiers.Win, E)));
        Is(Down(t, LCtrl));
        Is(Down(t, LWin), (TriggerEventKind.Press, Base));
        var r = Down(t, E);
        Is(r, (TriggerEventKind.Interrupt, Base), (TriggerEventKind.Press, DictationLanguage.English));
        Assert.True(r.Swallow);
        Assert.True(Down(t, E).Swallow);
        // Release of the language trigger, none for the chord.
        var u = Up(t, E);
        Is(u, (TriggerEventKind.Release, DictationLanguage.English));
        Assert.True(u.Swallow);
        // Later releasing Ctrl/Win emits nothing more (chord was handed over).
        Is(Up(t, LCtrl));
        var w = Up(t, LWin);
        Is(w);
        Assert.True(w.NeedsStartMenuGuard);
    }

    [Fact]
    public void LanguageComboReleasedByModifierWhileChordHandedOver()
    {
        var t = new DictationTriggerTracker(new DictationTriggerConfig(
            DictationTrigger.CtrlWin, null, English: new(KeyModifiers.Control | KeyModifiers.Win, E)));
        Down(t, LCtrl); Down(t, LWin); Down(t, E);
        Is(Up(t, LWin), (TriggerEventKind.Release, DictationLanguage.English));
        Is(Up(t, E));
        Is(Up(t, LCtrl));
    }

    [Fact]
    public void NonMatchingKeyOnChordIsOnlyAnInterrupt()
    {
        var t = new DictationTriggerTracker(new DictationTriggerConfig(
            DictationTrigger.CtrlWin, null, English: new(KeyModifiers.Control | KeyModifiers.Win, E)));
        Down(t, LCtrl); Down(t, LWin);
        var r = Down(t, G);
        Is(r, (TriggerEventKind.Interrupt, Base));
        Assert.False(r.Swallow);
    }

    [Fact]
    public void ThreeLanguageCombosAreDistinct()
    {
        var t = new DictationTriggerTracker(new DictationTriggerConfig(
            DictationTrigger.CtrlWin, null,
            new(KeyModifiers.Control | KeyModifiers.Shift, E),
            new(KeyModifiers.Control | KeyModifiers.Shift, G),
            new(KeyModifiers.Control | KeyModifiers.Shift, 0x48)));
        Down(t, LCtrl); Down(t, LShift);
        Is(Down(t, G), (TriggerEventKind.Press, DictationLanguage.German));
        Is(Up(t, G), (TriggerEventKind.Release, DictationLanguage.German));
        Is(Down(t, 0x48), (TriggerEventKind.Press, DictationLanguage.Hungarian));
    }

    [Fact]
    public void ReconfigureAndResetForgetState()
    {
        var t = Chord();
        Down(t, LCtrl); Down(t, LWin);
        t.Reset();
        Is(Up(t, LWin));
        Down(t, LWin);
        Is(Down(t, LCtrl), (TriggerEventKind.Press, Base));
        t.Reconfigure(new DictationTriggerConfig(DictationTrigger.Combo, new(KeyModifiers.Alt, Space)));
        Down(t, LAlt);
        Is(Down(t, Space), (TriggerEventKind.Press, Base));
    }

    [Fact]
    public void EventsCarryTime()
    {
        var t = Chord();
        t.Process(LCtrl, true, 5);
        var r = t.Process(LWin, true, 5.5);
        Assert.Equal(5.5, r.Events[0].Time);
    }
}
