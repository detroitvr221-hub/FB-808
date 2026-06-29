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

### View-layer consolidation
- ✅ `Color.ctaGradient()` — replaced the CTA accent gradient at 21 top→bottom sites and normalized the
  drifted darkness (0.22/0.24 → 0.22). The one diagonal gradient (RootView header) left as-is.
- ✅ `MuteSoloButton` view + `FDPalette.soloInk` token — consolidated the 2 byte-identical Mixer builders
  (`msButton`/`msBtn`) and the `#08240f` hex (7×). `rowFlag`/`laneFlag` are genuinely different sizes/glyphs
  (19×19 vs 18×18+hit-area, glyph present/absent) — ⏸️ left distinct on purpose.
- ✅ `Comparable.clamped(to:)` helper added (apply at call sites incrementally).
- ⏳ `MeterBar` + `FaderTrack` views — duplicated meter/fader chrome between MixStrip and TrackStrip.
- ⏳ `.selectableChip`/`.selectedTrait` (~24/28×) and a generic `PillButton`/`ToggleChip` over ~35 per-file
  chip builders. NOTE: these builders genuinely differ in size/radius/glyph — force-merging all 35 would
  trade duplication for a pile of parameters and risk visual regressions, so this needs case-by-case
  judgment, not a blanket sweep.
- ⏳ Minor: shared `fmtPct`/`fmtHz`/`fmtMs`; `presentedBinding(_:)` (4×). `AudioDefaults.gainToDb` was
  NOT done — the three call sites use different floors, so it isn't a clean behavior-preserving merge.

## §4 Complexity / decomposition

- ✅ `LearnModeView.cell` → a `CellGrade` enum computed once + shared toggle closure (was the worst-nested
  body / type-checker risk). Behavior-identical.
- ⏳ `SampleModeView.waveBox` split; `SynthModeView.detailPanel`, `Transport.scheduleStep`,
  `Components.TransportBar.body` decomposition — pure readability on already-working complex views; left
  to avoid churn/regression surface without a concrete need.
- ⏸️ `Export.buildExportPlan`/`buildSoloTrackPlan` groove-timing + prob-seed dedup — deliberately NOT done:
  the two prob-seed copies are already identical and correct, and this is the audio-output hot path that
  can't be output-verified here, so a marginal dedup isn't worth the risk.
- ⏸️ Engine DSP hot paths — out of scope (any arithmetic/allocation change risks timing/output).

## Verification

Booted iPad Pro 13" simulator, installed, launched. The app renders correctly with all changes (CTA
gradient, pad grid, kit list intact). **Found + fixed a pre-existing first-run crash**: the onboarding
`TourOverlay` used `.fdCard`, whose `@EnvironmentObject settings` isn't inherited by the overlay → SIGTRAP
on fresh launch. Inlined the card chrome using the explicitly-passed `settings` (commit 5e3abbf). Re-ran
on a fresh install: the tour now shows correctly.

---

Net: dead code + Swift 6 + logic/token/view dedup + CellGrade removed ~200+ lines and cleared all compiler
warnings; one real first-run crash fixed; each batch build-verified and the app smoke-tested in the
simulator. Remaining ⏳ items are larger stylistic refactors with regression surface; remaining ⏸️ items
are deliberate (force-merging distinct controls or touching the audio hot path would lower quality).
