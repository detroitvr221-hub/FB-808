//  FD808 — Finger Drummer 808
//  A native iPad MPC-style finger-drumming + beat-production workstation.
//  Ported from the FD808 HTML/CSS/JS design prototype to SwiftUI.

import SwiftUI

@main
struct FD808App: App {
    @StateObject private var engine: AudioEngine
    @StateObject private var project: Project
    @StateObject private var fx: PadFX
    @StateObject private var transport: Transport
    @StateObject private var link: LinkClock
    @StateObject private var store = ProjectStore()

    init() {
        let eng = AudioEngine()
        let proj = Project(engine: eng)
        let fxObj = PadFX()
        let tp = Transport(project: proj, engine: eng, fx: fxObj)
        let lk = LinkClock(bpm: Double(proj.bpm))
        tp.link = lk
        _engine = StateObject(wrappedValue: eng)
        _project = StateObject(wrappedValue: proj)
        _fx = StateObject(wrappedValue: fxObj)
        _transport = StateObject(wrappedValue: tp)
        _link = StateObject(wrappedValue: lk)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(project)
                .environmentObject(fx)
                .environmentObject(transport)
                .environmentObject(link)
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}
