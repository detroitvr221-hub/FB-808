//  SpectrumView.swift — master output spectrum analyzer (FL-Mobile parity, Phase 2).
//  Reuses the engine's master capture ring buffer; an Accelerate (vDSP) real FFT →
//  log-spaced magnitude bars. Doubles as a teaching aid next to the LUFS meter.

import SwiftUI
import Combine
import Accelerate

/// Cached real-FFT → log-spaced normalized magnitude bands.
final class SpectrumAnalyzer {
    private let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    let bandCount: Int
    private let edges: [Int]   // bin index per band edge (log-spaced)

    init(n: Int = 1024, bands: Int = 28) {
        self.n = n
        self.bandCount = bands
        log2n = vDSP_Length(log2(Float(n)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let half = n / 2
        var e: [Int] = []
        for b in 0...bands { e.append(max(1, min(half - 1, Int(pow(Double(half), Double(b) / Double(bands)))))) }
        edges = e
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    /// `bandCount` normalized (0..1) log-spaced magnitudes from the most recent `n` samples.
    func analyze(_ input: [Float]) -> [Float] {
        guard input.count >= n else { return [Float](repeating: 0, count: bandCount) }
        let recent = Array(input.suffix(n))
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(recent, 1, window, 1, &windowed, 1, vDSP_Length(n))
        let half = n / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        var bands = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let lo = edges[b], hi = max(lo + 1, edges[b + 1])
            var peak: Float = 0
            for k in lo..<hi { peak = Swift.max(peak, mags[k]) }
            let db = 20 * log10(Swift.max(1e-7, peak / Float(n)))   // ≈ −140..~0 dBFS
            bands[b] = Swift.max(0, Swift.min(1, (db + 75) / 75))    // map −75..0 dB → 0..1
        }
        return bands
    }

    /// The center frequency (Hz) of a band, for tests/labels.
    func bandFreq(_ b: Int, sampleRate: Double = 48000) -> Double {
        let bin = Double(edges[b] + edges[b + 1]) / 2
        return bin * sampleRate / Double(n)
    }
}

struct SpectrumView: View {
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings
    @State private var bands: [Float] = []
    private let analyzer = SpectrumAnalyzer()
    private let timer = Timer.publish(every: 1.0 / 24.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(0..<analyzer.bandCount), id: \.self) { i in
                    let v = i < bands.count ? bands[i] : 0
                    RoundedRectangle(cornerRadius: 1)
                        .fill(LinearGradient(colors: [settings.accent, settings.accent.opacity(0.3)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 4, height: max(1, CGFloat(v) * 64))
                }
            }
            .frame(height: 66, alignment: .bottom)
            .overlay(Rectangle().fill(settings.line).frame(height: 1), alignment: .bottom)
            HStack(spacing: 0) {   // frequency axis (#visual-polish)
                ForEach(["20", "100", "500", "2k", "8k", "20k"], id: \.self) { s in
                    Text(s).font(FDFont.mono(7, .bold)).foregroundStyle(settings.inkFaint).frame(maxWidth: .infinity)
                }
            }
        }
        .onReceive(timer) { _ in
            let next = analyzer.analyze(engine.spectrumSamples(1024))
            if next != bands { bands = next }   // park when silent (no needless redraws)
        }
    }
}
