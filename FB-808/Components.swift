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

// MARK: - Type helpers

struct Eyebrow: View {
    @EnvironmentObject var settings: AppSettings
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(FDFont.mono(11, .bold))
            .tracking(2)
            .foregroundStyle(settings.accent)
    }
}

struct ModeHead: View {
    @EnvironmentObject var settings: AppSettings
    let title: String
    let eyebrow: String
    var hint: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(FDFont.display(26, .bold)).foregroundStyle(settings.ink)
            Eyebrow(text: eyebrow)
            Spacer(minLength: 8)
            if let hint {
                Text(hint).font(FDFont.ui(12.5)).foregroundStyle(settings.inkFaint)
                    .lineLimit(1)
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
        HStack(spacing: 14) {
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
                    .background(LinearGradient(colors: [settings.accent, settings.accent.darker(0.24)], startPoint: .top, endPoint: .bottom))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(.plain)
                .accessibilityLabel(Text(project.playing ? "Stop" : "Play"))
            }
            sep
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
                tpButton(label: "TAP") { tapTempo() }.padding(.leading, 4)
                    .accessibilityLabel(Text("Tap tempo"))
            }
            sep
            // metro + count-in + swing
            HStack(spacing: 8) {
                tpButton(icon: "metronome", on: project.metronome) { project.metronome.toggle() }
                    .accessibilityLabel(Text("Metronome"))
                    .accessibilityValue(Text(project.metronome ? "On" : "Off"))
                tpButton(label: project.countIn != 0 ? "\(project.countIn) BAR" : "CNT OFF") { cycleCount() }
                    .accessibilityLabel(Text("Count-in"))
                    .accessibilityValue(Text(project.countIn == 0 ? "Off" : "\(project.countIn) bars"))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Int(project.swing * 100))%").font(FDFont.mono(14, .bold)).foregroundStyle(th.ink)
                    Text("SWING").font(FDFont.mono(9, .bold)).tracking(1).foregroundStyle(th.inkFaint)
                }.padding(.leading, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Swing"))
                .accessibilityValue(Text("\(Int(project.swing * 100)) percent"))
            }
            sep
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
                .frame(maxWidth: .infinity).frame(height: 30).padding(.leading, 8)
                .transition(.opacity)
            } else {
                Spacer(minLength: 6)
                Text(project.name).font(FDFont.display(14, .semibold)).foregroundStyle(th.inkDim).lineLimit(1)
                    .transition(.opacity)
            }
            urButton(system: "arrow.uturn.backward", enabled: project.canUndo) { project.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityLabel(Text("Undo"))
            urButton(system: "arrow.uturn.forward", enabled: project.canRedo) { project.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .accessibilityLabel(Text("Redo"))
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(RoundedRectangle(cornerRadius: 16).fill(th.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(project.recording ? th.miss.opacity(0.55) : th.line, lineWidth: 1))
        .animation(.easeInOut(duration: 0.2), value: project.recording)
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
                if let label { Text(label).font(FDFont.mono(11, .bold)).tracking(0.5) }
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

    private func cycleCount() {
        let i = countIns.firstIndex(of: project.countIn) ?? 0
        project.countIn = countIns[(i + 1) % countIns.count]
    }
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
/// is recording so you can see the music being captured.
struct RecordingWaveform: View {
    @EnvironmentObject var engine: AudioEngine
    var color: Color
    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { ctx, size in
                let peaks = engine.recordingWaveform()
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
