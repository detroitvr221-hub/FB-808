//  Components.swift — shared building blocks: type helpers, panel cards,
//  coach notes, and the transport bar used across all production modes.

import SwiftUI

/// Concatenate styled inline text segments into ONE `Text` — the non-deprecated replacement for the
/// `Text + Text` operator (removed in iOS 26). Each segment keeps its own color and optional font; a
/// segment that omits them inherits the call site's `.font(_:)` / `.foregroundStyle(_:)`.
func styledText(_ segments: [(String, Color?, Font?)]) -> Text {
    var s = AttributedString()
    for (str, color, font) in segments {
        var run = AttributedString(str)
        if let color { run.foregroundColor = color }
        if let font { run.font = font }
        s += run
    }
    return Text(s)
}

/// Record-quantize options — only values recordHit can actually honor on the 16-slot grid
/// (a "1/32" chip used to be offered but silently fell back to 1/16). Shared by the Sequence
/// tools row and the TransportBar chip next to ●.
let FD_RECORD_QUANTS = ["1/8", "1/16"]

// MARK: - Zero-distance drag rule

/// Shared rule for the app's `DragGesture(minimumDistance: 0)` controls (velocity bars, the mixer pan
/// knob and fader). Such a gesture delivers its first frame on plain touch-down with zero translation;
/// writing it through a checkpointing setter marked the project dirty, pushed a restore point and wiped
/// the redo stack although nothing changed (#MIX-UNDO). A frame applies only once the finger has really
/// moved; after that every frame applies, because a later frame can legitimately net back to the start.
enum FDDrag {
    // `nonisolated`: `moved` is called from gesture callbacks that are not main-actor isolated,
    // and reading a main-actor constant from there is an error in the Swift 6 language mode.
    nonisolated static let slop: CGFloat = 4
    nonisolated static func moved(_ t: CGSize) -> Bool {
        abs(t.width) > slop || abs(t.height) > slop
    }
    nonisolated static func shouldApply(moved: Bool, dragOpen: Bool) -> Bool {
        moved || dragOpen
    }
}

/// Per-drag bookkeeping for a zero-distance control (fader cap, pan knob, KnobView, velocity bar). Lives in
/// `@State` on the owning view. It MUST be cleared from an `onChange` of a `@GestureState` "touching" flag,
/// not only from `.onEnded`: SwiftUI does not run `.onEnded` for a CANCELLED gesture (a scroll view taking
/// the touch, a second finger, a system gesture), and a stale `start`/`open` made the next touch-down write
/// the previous drag's start value back into the control — the fader "snapped" before the finger moved
/// (#FADER-STALE, FADER_AUDIT_2026-09-16).
struct FDDragTrack {
    var start: Double? = nil
    var moved = false
    var open = false
    mutating func reset() { self = FDDragTrack() }
}

// MARK: - Type helpers

struct Eyebrow: View {
    @EnvironmentObject var settings: AppSettings
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(FDFont.mono(11, .bold))
            .tracking(2)
            .foregroundStyle(settings.accent)
            .lineLimit(1)   // a squeezed header used to wrap this into a 3-line block
    }
}

/// The shared mode header: a 26pt display title + accent eyebrow, an optional inkFaint hint, and an
/// optional trailing slot for mode-specific controls (so Tracks/Teacher keep their header buttons while
/// the title/eyebrow styling stays identical across modes).
struct ModeHead<Trailing: View>: View {
    @EnvironmentObject var settings: AppSettings
    let title: String
    let eyebrow: String
    var hint: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        // On a narrow window the hint is the first thing to go — before it starts stealing width from
        // the mode's own controls and wrapping their labels mid-word ("Rang/e", "Expo/rt").
        // NB: only the TITLE BLOCK goes through ViewThatFits. `trailing` is rendered once, outside it:
        // a mode's header buttons carry .popover, and a popover attached inside a ViewThatFits branch
        // never presents (the Tracks "Range" popover silently did nothing).
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                titleBlock(showHint: hint != nil, showEyebrow: true)
                titleBlock(showHint: false, showEyebrow: true)
                titleBlock(showHint: false, showEyebrow: false)   // last resort: just the title
            }
            Spacer(minLength: 8)
            trailing
        }
    }

    private func titleBlock(showHint: Bool, showEyebrow: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(FDFont.display(26, .bold)).foregroundStyle(settings.ink).lineLimit(1)
            if showEyebrow { Eyebrow(text: eyebrow) }
            if showHint, let hint {
                Text(hint).font(FDFont.ui(12.5)).foregroundStyle(settings.inkFaint)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
extension ModeHead where Trailing == EmptyView {
    init(title: String, eyebrow: String, hint: String? = nil) {
        self.init(title: title, eyebrow: eyebrow, hint: hint, trailing: { EmptyView() })
    }
}

/// Shared "tab pill" for the section/mode switchers in Theory, Learn and Teacher (previously three
/// near-identical hand-rolled copies that drifted in size and a11y). Bakes in the consistent selected
/// chrome AND the `.isSelected` accessibility trait so every tab row is screen-reader-correct. Font/
/// height/padding default to the common size and can be overridden to match a specific row exactly.
struct SegTab: View {
    @EnvironmentObject var settings: AppSettings
    let label: String
    let selected: Bool
    var icon: String? = nil          // optional leading SF Symbol — icon+text tab rows route through here too
    var badge: Int = 0
    var font: Font = FDFont.ui(14, .semibold)
    var iconSize: CGFloat = 14
    var height: CGFloat = 38
    var hPad: CGFloat = 18
    var radius: CGFloat = 10
    var fill: Bool = false           // true → equal-width segments (maxWidth: .infinity); false → hug content
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    Image(systemName: icon).font(.system(size: iconSize))
                        .foregroundStyle(selected ? settings.accent : settings.inkDim)
                }
                Text(label).font(font)
                if badge > 0 {
                    Text("\(badge)").font(FDFont.mono(10, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(settings.theme.miss))
                }
            }
            .foregroundStyle(selected ? settings.ink : settings.inkDim)
            .padding(.horizontal, fill ? 8 : hPad).frame(maxWidth: fill ? .infinity : nil).frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius).fill(selected ? settings.accent.opacity(0.18) : settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(selected ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge > 0 ? "\(label), \(badge) pending" : label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Adaptive stage / side-panel split

/// The production modes are a big "stage" (pads, waveform, grid) next to a fixed-width control panel.
/// That reads well on a wide landscape window, but on a portrait or Split-View window the fixed panel
/// eats a third of the screen and squeezes the stage — so below a usable stage width the panel moves
/// UNDER the stage, which keeps its fixed height while only the panel scrolls. The stage closure is told
/// which layout it got so it can take the extra room (e.g. a bigger pad grid).
struct StageSplit<Stage: View, Side: View>: View {
    var sideWidth: CGFloat = 268
    var spacing: CGFloat = 22
    var minStage: CGFloat = 520          // stage narrower than this ⇒ stack instead
    @ViewBuilder var stage: (_ stacked: Bool) -> Stage
    /// The side panel is also told whether it got the stacked layout, so it can spread its cards across
    /// the full width instead of scrolling a single narrow column under the stage (MAIN_SCREEN_AUDIT #4).
    @ViewBuilder var side: (_ stacked: Bool) -> Side

    init(sideWidth: CGFloat = 268, spacing: CGFloat = 22, minStage: CGFloat = 520,
         @ViewBuilder stage: @escaping (_ stacked: Bool) -> Stage,
         @ViewBuilder side: @escaping (_ stacked: Bool) -> Side) {
        self.sideWidth = sideWidth; self.spacing = spacing; self.minStage = minStage
        self.stage = stage; self.side = side
    }
    /// Panels that don't care about the layout keep the old zero-argument closure.
    init(sideWidth: CGFloat = 268, spacing: CGFloat = 22, minStage: CGFloat = 520,
         @ViewBuilder stage: @escaping (_ stacked: Bool) -> Stage,
         @ViewBuilder side: @escaping () -> Side) {
        self.init(sideWidth: sideWidth, spacing: spacing, minStage: minStage, stage: stage, side: { _ in side() })
    }

    /// Whether the stage stacks above a scrolling side panel for a given geometry.
    ///
    /// Pure and `nonisolated` so the portrait/landscape decision can be unit-tested: the layout branch
    /// itself is only reachable by rendering, and the simulator does not rotate reliably inside a UI
    /// test, so the decision is pinned here and the UI test pins the structural consequence (that no
    /// ScrollView ever owns the pad surface). See finding 37 / #PAD-SCROLL.
    nonisolated static func isStacked(width: CGFloat, height: CGFloat,
                                      sideWidth: CGFloat = 268, spacing: CGFloat = 22,
                                      minStage: CGFloat = 520) -> Bool {
        (width - sideWidth - spacing) < max(minStage, height * 0.75)
    }

    var body: some View {
        GeometryReader { g in
            // Stack when the panel would leave the stage narrow *relative to the height it has* — that's
            // exactly the portrait case where a width-bound stage (the square pad grid) leaves hundreds
            // of points of dead space below it. A landscape window keeps the side-by-side layout.
            if Self.isStacked(width: g.size.width, height: g.size.height,
                              sideWidth: sideWidth, spacing: spacing, minStage: minStage) {
                // The performance stage must stay OUT of the page ScrollView: a drag over the pads is the
                // documented slide-roll / sustained-pad gesture, and an enclosing scroll pan claims the
                // vertical drag and cancels the in-flight pad touches (MultiTouchGrid.release then fires
                // onUp for every held pad, aborting the roll). Only the control panel below scrolls (#PAD-SCROLL).
                VStack(spacing: spacing) {
                    stage(true)
                        .frame(height: max(340, min(g.size.width, g.size.height * 0.70)))
                    ScrollView {
                        side(true)
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                HStack(alignment: .top, spacing: spacing) {
                    stage(false)
                    ScrollView { side(false) }
                        .scrollIndicators(.hidden)
                        .frame(width: sideWidth)
                }
            }
        }
    }
}

// MARK: - Panel card

/// The app's standard card chrome — a filled rounded rect with the hairline border — as one modifier
/// instead of the `.background(RoundedRectangle…fill).overlay(RoundedRectangle…stroke)` pair repeated
/// across every panel. `radius` and `fill` vary per site; the stroke is always the theme hairline.
struct FDCard: ViewModifier {
    @EnvironmentObject var settings: AppSettings
    let radius: CGFloat
    let fill: Color
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(settings.line, lineWidth: 1))
    }
}
extension View {
    func fdCard(_ radius: CGFloat, fill: Color) -> some View { modifier(FDCard(radius: radius, fill: fill)) }
}

struct PanelCard<Content: View>: View {
    @EnvironmentObject var settings: AppSettings
    var title: String? = nil
    var trailing: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let title {
                HStack {
                    Text(title.uppercased()).font(FDFont.mono(10, .bold)).tracking(1.4)
                        .foregroundStyle(settings.inkFaint)
                    Spacer()
                    if let trailing {
                        Text(trailing).font(FDFont.mono(10, .bold)).foregroundStyle(settings.inkFaint)
                    }
                }
            }
            content
        }
        .padding(14)
        .fdCard(16, fill: settings.panel)
    }
}

struct CoachNote: View {
    @EnvironmentObject var settings: AppSettings
    let text: AttributedString
    init(_ markdownish: String) {
        self.text = (try? AttributedString(markdown: markdownish)) ?? AttributedString(markdownish)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("i").font(FDFont.display(13, .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(settings.accent))
            Text(text).font(FDFont.ui(12)).foregroundStyle(settings.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11).padding(.horizontal, 13)
        .background(RoundedRectangle(cornerRadius: 12).fill(settings.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.accent.opacity(0.30), lineWidth: 1))
    }
}

// MARK: - Transport bar

struct TransportBar: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var transport: Transport
    @EnvironmentObject var settings: AppSettings
    @State private var taps: [Date] = []

    private let countIns = [0, 1, 2, 4]

    private var pos: (bar: Int, beat: Int, tick: Int) {
        if project.step < 0 { return (1, 1, 1) }
        return (project.bar + 1, project.step / 4 + 1, project.step % 4 + 1)   // real bar (was bar % 4 → looped at 4 in a 16-bar song)
    }

    var body: some View {
        let th = settings.theme
        // The bar carries more controls than a narrow window (portrait iPad, Split View, iPhone) can
        // hold. Without this the labels wrapped mid-word ("TA/P", "Q 1/1/6"); now the row drops its
        // lowest-value readouts instead. On a wide/landscape window the first (full) variant always
        // fits, so the layout there is unchanged.
        ViewThatFits(in: .horizontal) {
            bar(th, level: .full)
            bar(th, level: .medium)
            bar(th, level: .tight)
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(RoundedRectangle(cornerRadius: 16).fill(th.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(project.recording ? th.miss.opacity(0.55) : th.line, lineWidth: 1))
        .animation(.easeInOut(duration: 0.2), value: project.recording)
    }

    /// How much of the bar survives at the current width. `.full` is the original layout.
    private enum Density { case full, medium, tight }

    @ViewBuilder private func bar(_ th: Theme, level: Density) -> some View {
        HStack(spacing: level == .full ? 14 : 10) {
            // rec + play
            HStack(spacing: 8) {
                Button { transport.record() } label: {
                    Circle().fill(project.recording ? th.miss : settings.inkDim)
                        .frame(width: 12, height: 12)
                        .frame(width: 40, height: 40)
                        .background(recBg)
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                        .overlay(alignment: .bottom) {
                            // show WHICH source the record button captures: mic audio vs pad hits
                            Text(project.audioArmedTrack != nil ? "MIC" : "PAD")
                                .font(FDFont.mono(7, .bold)).tracking(0.5)
                                .foregroundStyle(project.audioArmedTrack != nil ? th.miss : settings.inkFaint)
                                .padding(.bottom, 3)
                        }
                }.buttonStyle(.plain)
                .accessibilityLabel(Text(project.recording ? "Stop recording" : "Record"))
                .accessibilityValue(Text(project.audioArmedTrack != nil ? "Records mic audio" : "Records pad hits"))

                Button { transport.toggle() } label: {
                    Group {
                        if project.playing {
                            RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 13, height: 13)
                        } else {
                            Triangle().fill(.white).frame(width: 14, height: 16)
                        }
                    }
                    .frame(width: 52, height: 40)
                    .background(settings.accent.ctaGradient())
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(.plain)
                .accessibilityLabel(Text(project.playing ? "Stop" : "Play"))
            }
            if level == .full { sep }
            // bpm
            HStack(spacing: 4) {
                stepBtn("–") { project.setBpm(project.bpm - 1) }
                    .accessibilityLabel(Text("Decrease tempo"))
                VStack(spacing: 0) {
                    Text("\(project.bpm)").font(FDFont.mono(22, .bold)).foregroundStyle(th.ink).frame(minWidth: 48)
                    Text("BPM").font(FDFont.mono(9, .bold)).tracking(1).foregroundStyle(th.inkFaint)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Tempo"))
                .accessibilityValue(Text("\(project.bpm) BPM"))
                stepBtn("+") { project.setBpm(project.bpm + 1) }
                    .accessibilityLabel(Text("Increase tempo"))
                if level == .full {
                    tpButton(label: "TAP") { tapTempo() }.padding(.leading, 4)
                        .accessibilityLabel(Text("Tap tempo"))
                }
            }
            if level == .full { sep }
            // metro + count-in + swing
            HStack(spacing: 8) {
                tpButton(icon: "metronome", on: project.metronome) { project.setMetronome(!project.metronome) }
                    .accessibilityLabel(Text("Metronome"))
                    .accessibilityValue(Text(project.metronome ? "On" : "Off"))
                if level != .tight {
                    tpButton(label: project.countIn != 0 ? "\(project.countIn) BAR" : "CNT OFF") { cycleCount() }
                        .accessibilityLabel(Text("Count-in"))
                        .accessibilityValue(Text(project.countIn == 0 ? "Off" : "\(project.countIn) bars"))
                    tpButton(label: "Q \(project.quantize)") {
                        project.checkpoint("quant", coalesce: false)
                        project.quantize = FD_RECORD_QUANTS.next(after: project.quantize)
                    }                    .accessibilityLabel(Text("Record quantize"))
                    .accessibilityValue(Text(project.quantize))
                }
                if level == .full {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(Int(project.swing * 100))%").font(FDFont.mono(14, .bold)).foregroundStyle(th.ink)
                        Text("SWING").font(FDFont.mono(9, .bold)).tracking(1).foregroundStyle(th.inkFaint)
                    }.padding(.leading, 4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Swing"))
                    .accessibilityValue(Text("\(Int(project.swing * 100)) percent"))
                }
            }
            if level == .full { sep }
            // position
            styledText([(String(format: "%02d", pos.bar), settings.accent, nil),
                        (":\(pos.beat):\(pos.tick)", th.ink, nil)])
                .font(FDFont.mono(18, .bold))
                .frame(minWidth: 76, alignment: .leading)

            // while recording, the flex area shows a live waveform of the audio being captured
            if project.recording {
                HStack(spacing: 8) {
                    Circle().fill(th.miss).frame(width: 8, height: 8)
                        .shadow(color: th.miss, radius: 4)
                    RecordingWaveform(color: th.miss).frame(maxWidth: .infinity)
                }
                // minWidth: the waveform's ideal width is ~0, so once it replaced the project-name text the
                // `.full` variant "fit" a portrait window and ViewThatFits picked it — then the fixed chips
                // were crushed into each other ("CNT OFFQ 1/16", "SWI/NG"). Claim a real width so the
                // narrower variants are chosen honestly (MAIN_SCREEN_AUDIT_2026-09-16 #3).
                .frame(minWidth: 140, maxWidth: .infinity).frame(height: 30).padding(.leading, 8)
                .transition(.opacity)
            } else {
                Spacer(minLength: 6)
                if level == .full {
                    Text(project.name).font(FDFont.display(14, .semibold)).foregroundStyle(th.inkDim).lineLimit(1)
                        .transition(.opacity)
                }
            }
            urButton(system: "arrow.uturn.backward", enabled: project.canUndo) { project.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityLabel(Text("Undo"))
            urButton(system: "arrow.uturn.forward", enabled: project.canRedo) { project.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .accessibilityLabel(Text("Redo"))
        }
    }

    private var recBg: some View {
        RoundedRectangle(cornerRadius: 11)
            .fill(project.recording ? settings.theme.miss.opacity(0.18) : settings.panel2)
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(project.recording ? settings.theme.miss : settings.line, lineWidth: 1))
    }

    private var sep: some View { Rectangle().fill(settings.line).frame(width: 1, height: 30) }

    private func stepBtn(_ s: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(FDFont.mono(17, .bold)).foregroundStyle(settings.inkDim)
                .frame(width: 28, height: 28)
                .fdCard(8, fill: settings.panel2)
        }.buttonStyle(.plain)
    }

    private func tpButton(label: String? = nil, icon: String? = nil, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).font(.system(size: 15)) }
                // fixedSize: a squeezed HStack used to wrap these mid-word ("TA/P", "Q 1/1/6") on a
                // narrow window — the bar now drops controls instead (see ViewThatFits above).
                if let label {
                    Text(label).font(FDFont.mono(11, .bold)).tracking(0.5)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(settings.ink)
            .frame(height: 40).padding(.horizontal, 12).frame(minWidth: 40)
            .background(RoundedRectangle(cornerRadius: 11).fill(on ? settings.accent.opacity(0.2) : settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(on ? settings.accent.opacity(0.45) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func urButton(system: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? settings.inkDim : settings.inkFaint.opacity(0.4))
                .frame(width: 34, height: 34)
                .fdCard(9, fill: settings.panel2)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func cycleCount() { project.setCountIn(countIns.next(after: project.countIn)) }
    private func tapTempo() {
        let now = Date()
        taps = taps.filter { now.timeIntervalSince($0) < 2 }
        taps.append(now)
        // need at least 3 taps before committing a tempo; only average gaps that fall in the
        // musical range (~40–220 BPM) so a single stray fast/slow tap can't snap to a clamp.
        guard taps.count >= 3 else { return }
        var gaps: [Double] = []
        for i in 1..<taps.count {
            let g = taps[i].timeIntervalSince(taps[i - 1])
            if g >= 0.27 && g <= 1.5 { gaps.append(g) }   // 0.27s ≈ 222 BPM, 1.5s = 40 BPM
        }
        guard !gaps.isEmpty else { return }
        let avg = gaps.reduce(0, +) / Double(gaps.count)
        if avg > 0 { project.setBpm(60.0 / avg) }
    }
}

// MARK: - Recording waveform

/// A live, scrolling waveform of the audio output — shown while the transport
/// is recording so you can see the music being captured. Polls at ~30 Hz (slower under
/// Reduce Motion) instead of every frame, and skips the redraw when the snapshot hasn't
/// changed, so it can't crowd Transport's main-thread scheduler on slow devices.
struct RecordingWaveform: View {
    @EnvironmentObject var engine: AudioEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color: Color
    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 0.25 : 1.0 / 30.0)) { _ in
            RecordingWaveformCanvas(peaks: engine.recordingWaveform(), color: color)
                .equatable()
        }
    }
}

private struct RecordingWaveformCanvas: View, Equatable {
    let peaks: [Float]
    let color: Color
    static func == (a: Self, b: Self) -> Bool { a.peaks == b.peaks && a.color == b.color }
    var body: some View {
        Canvas { ctx, size in
            let n = peaks.count
            guard n > 1, size.width > 1 else { return }
            let mid = size.height / 2
            let cw = size.width / CGFloat(n)
            for i in 0..<n {
                let p = CGFloat(min(1, Double(peaks[i]) * 1.5))
                let h = max(1.5, p * size.height)
                let x = CGFloat(i) * cw
                let rect = CGRect(x: x, y: mid - h / 2, width: max(0.7, cw - 0.6), height: h)
                ctx.fill(Path(rect), with: .color(color.opacity(0.3 + Double(p) * 0.7)))
            }
        }
    }
}

// MARK: - Shapes

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Shared mute/solo flag button used by the Mixer's channel + track strips (28pt, full-width). The "S"
/// solo state uses the bright fill + dark `soloInk`; both states carry a non-color glyph + a11y traits.
struct MuteSoloButton: View {
    @EnvironmentObject var settings: AppSettings
    let flag: String          // "M" or "S"
    let on: Bool
    let color: Color
    let a11yName: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(flag).font(FDFont.mono(11, .bold))
                .foregroundStyle(on ? (flag == "S" ? FDPalette.soloInk : .white) : settings.inkFaint)
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? color : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? .clear : settings.line, lineWidth: 1))
                // non-color cue so the active state reads without relying on the fill color
                .overlay(alignment: .topTrailing) {
                    if on {
                        Image(systemName: flag == "M" ? "speaker.slash.fill" : "checkmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(flag == "S" ? FDPalette.soloInk : .white)
                            .padding(2)
                            .accessibilityHidden(true)
                    }
                }
        }.buttonStyle(.plain)
        .accessibilityLabel(Text("\(a11yName) \(flag == "M" ? "mute" : "solo")"))
        .accessibilityValue(Text(on ? "On" : "Off"))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
