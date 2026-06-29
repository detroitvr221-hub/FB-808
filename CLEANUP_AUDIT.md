# FD-808 Code-Cleanup Audit

Cleanup-only audit (dead code, duplication, simplification, compiler warnings) — no behavior changes,
no bug-hunting (that's covered by the deep audit + AUDIT memory). Produced by a 4-agent fan-out + a clean
compiler-warnings build. The **engine package (`FD808Engine`) came back completely clean** — every finding
is app-side. Work landed on branch `code-cleanup` (off `cleanup-dead-code-dedup`).

Status legend: ✅ applied · ⏳ deferred (needs on-device visual verification) · ⏸️ intentionally kept

---

## §1 Dead code — ✅ applied (commit 0c7fe64)

Two vestigial half-wired features + scattered unused symbols, all grep-verified across app + engine:

- ✅ AudioSessionManager: removed the input-picker cluster (`availableInputs`, `setPreferredInput`,
  `InputOption`, `inputKind`, `applyPreferredInput`, `preferredInputUID`) — superseded by
  `AudioInputPicker`'s system picker.
- ✅ LinkClock: removed `toggle()`/`setActive()` (no enable path was wired) + `import AVFoundation`.
- ✅ `Project.saveSynth()`, `AudioEngine.channelPeaks()`, `SynthModeView.stepperBtn` (dead twin of the
  used one in SequenceModeView), `SoundFont.SFInstrument.region(for:)`, `Glossary.infoTip` modifier.
- ✅ `Theme.FDRadius` unused cases (`xs`/`lg`/`panel`/`cta`); `import AVFoundation` in TeacherModeView.
- ⏸️ `FourStemSeparator.describe()` — KEPT: documented dev diagnostic ("run once after adding a model").
- Reverted two agent false-positives: `import Combine` in LearnModeView (needed by `PracticeModel`'s
  `@Published`) and `import os` in Export (needed by `fdLog.error`'s `privacy:` interpolation).

Medium-confidence set-but-never-read fields NOT removed (low value vs. churn across constructors):
`Kit.Lesson.locked` (+10 literals), `SoundFont.SFRegion.tuneCents/loopStart/loopEnd`, `Theme.name`,
`MIDIManager.onCC` (invoked but never assigned → CC branch is inert).

## §2 Swift 6 concurrency warnings — ✅ applied (commit 0c7fe64)

Root cause: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes top-level decls implicitly `@MainActor`,
but they're used from nonisolated `Task.detached` file I/O (several were "error in the Swift 6 language
mode"). Fixed by marking `nonisolated`: `fdLog`, `AudioDefaults`, `ProjectSnapshot`,
`ProjectStore.ProjectHeader`, `ExportFormat`, `FourStemSeparator` + `StemModelContract`. Also
`AudioSessionManager`: `allowBluetooth` → `allowBluetoothHFP` (deprecation; deployment target is iOS 26.2).
Result: clean build, **0 warnings**.

## §3 Duplication → shared helpers

### Logic/data dedup — ✅ applied (commit 41d23b6)
- ✅ `Music.scaleLadder(root:scaleID:octaves:/count:)` — replaces the 2-octave diatonic-ladder loop
  duplicated 4× (Project.generateMelody/synthPadMidis, SynthModeView.scaleKeys/SynthRoll.ladder).
- ✅ `Music.theoryChordVoice` + `Music.functionColor(_:)` — the identical "Theory" chord patch and T/S/D
  color switch across CircleOfFifths + ChordSuggest (TheoryMode's distinct "Ear" voice left as-is).
- ✅ `Array.next(after:)` — the "firstIndex ?? 0; [(i+1)%count]" cycle idiom in 7 places (SequenceModeView
  swing/humanize/groove/quantize/sig + cycleAuto, Components.cycleCount).

### View-layer consolidation — ⏳ deferred (mechanical but visual; verify on device before applying)
- `Theme.accentGradient(_:)` — the CTA accent vertical gradient repeated ~23× with drifting darkness
  (15× `.darker(0.22)`, 6× `0.24`, 1× `0.28`). One helper fixes the duplication AND the visual drift.
- `MuteSoloButton` view + `FDPalette.soloInk` token — 4 byte-identical mute/solo builders
  (`MixerModeView.msButton`/`msBtn`, `SequenceModeView.rowFlag`, `TrackModeView.laneFlag`) and the
  `#08240f` solo-ink hex hard-coded 7×.
- `MeterBar` + `FaderTrack` views — duplicated meter/fader chrome between MixStrip and TrackStrip.
- `.selectableChip(on:radius:)` modifier + `.selectedTrait(_:)` a11y helper — the selected-chip fill/stroke
  pair (~24×) and the `[.isButton,.isSelected]` cluster (~28×) that `SegTab` doesn't cover.
- `FilledButton`/CTA button (CircleOfFifths.actionButton ≡ ChordSuggest.actionBtn) and a generic
  `PillButton`/`ToggleChip` to absorb ~35 one-off per-file chip/toggle builders (largest line count).
- Minor: shared `fmtPct`/`fmtHz`/`fmtMs` formatters; `AudioDefaults.gainToDb(_:)` (20·log10 reimplemented
  in MixerModeView/Project/SpectrumView); `presentedBinding(_:)` for `Binding(get:{x != nil}…)` (4×);
  a `clamped(to:)` extension (~15 `max(lo,min(hi,x))` sites).

## §4 Complexity / decomposition — ⏳ deferred (readability + type-checker safety)

Larger structural refactors, lower mechanical-confidence — left as follow-ups:
- `LearnModeView.cell` → a `CellGrade` enum computed once (worst-nested body; type-checker risk).
- `SampleModeView.waveBox` → split `sampleWaveContent`/`emptyWaveContent`.
- `SynthModeView.detailPanel`, `Transport.scheduleStep` (~180 lines / 6 passes),
  `Components.TransportBar.body` → decompose into named sub-views/passes.
- `MixerModeView` meter decay/bump loops → `compactMapValues`/`.max()`.
- `Export.buildExportPlan`/`buildSoloTrackPlan` shared groove-timing + prob-seed helpers (must stay in
  sync with Transport).
- Engine DSP hot paths (`SynthCore.render`, `renderOffline`, per-sample `*.next()`/`*.process()`) are
  **out of scope** — any arithmetic/allocation change risks timing/output.

---

Net so far: §1+§2+§3-logic removed ~200+ lines of dead/duplicated code and cleared all compiler warnings,
behavior-preserving, each batch build-verified. §3-view and §4 are queued for when the app can be run in
the simulator to confirm no visual/layout regression.
