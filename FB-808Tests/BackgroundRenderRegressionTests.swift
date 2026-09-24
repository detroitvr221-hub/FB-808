import Foundation
import Testing
import FD808Engine
@testable import FB_808

actor SuspendedRender {
    private var pending: CheckedContinuation<([Float], [Float]), Never>?
    private var started: CheckedContinuation<Void, Never>?

    func render(_ plan: ExportPlan) async -> ([Float], [Float]) {
        await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume(); started = nil
        }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() {
        let audio = [Float](repeating: 0.1, count: 2400)
        pending?.resume(returning: (audio, audio.map { $0 / 2 })); pending = nil
    }
}

extension CurrentGapsRegressionTests {
    @Test @MainActor func deletedTrackCannotReceivePendingFreeze() async {
        let p = Project(engine: AudioEngine())
        p.lanes = ["kick": [1]]
        let id = p.sendLanesToNewTrack(rows: ["kick"])
        let gate = SuspendedRender()
        let job = Task { await p.freezeTrack(id, render: { await gate.render($0) }) }
        await gate.waitUntilStarted()
        p.removeTrack(id)
        await gate.finish()
        #expect(await job.value == false)
        #expect(p.audioClips.isEmpty)
        #expect(!p.tracks.contains { $0.frozenToAudio })
        #expect(!p.isBouncing)
    }

    @Test @MainActor func changedBeatCannotReceivePendingFreeze() async {
        let p = Project(engine: AudioEngine())
        p.lanes = ["kick": [1]]
        let id = p.sendLanesToNewTrack(rows: ["kick"])
        let gate = SuspendedRender()
        let job = Task { await p.freezeTrack(id, render: { await gate.render($0) }) }
        await gate.waitUntilStarted()
        p.setStepVel("kick", 0, 0.5)
        await gate.finish()
        #expect(await job.value == false)
        #expect(p.audioClips.isEmpty)
        #expect(p.backgroundOperationNotice != nil)
    }

    @Test @MainActor func projectReplacementDiscardsResample() async {
        let p = Project(engine: AudioEngine())
        p.lanes = ["kick": [1]]
        let gate = SuspendedRender()
        let job = Task { await p.resampleToPad("C:kick", render: { await gate.render($0) }) }
        await gate.waitUntilStarted()
        p.restore(Project(engine: AudioEngine()).snapshot())
        await gate.finish()
        #expect(await job.value == false)
        #expect(p.padSampleData.isEmpty)
        #expect(!p.isBouncing)
    }

    @Test @MainActor func changedTempoDiscardsResampleAndOverlappingRendersAreRejected() async {
        let p = Project(engine: AudioEngine())
        p.bpm = 120
        p.lanes = ["kick": [1]]
        let gate = SuspendedRender()
        let job = Task { await p.resampleToPad("C:kick", render: { await gate.render($0) }) }
        await gate.waitUntilStarted()
        #expect(await p.resampleToPad("C:snare") == false)
        #expect(await p.autoMaster() == nil)
        #expect(p.isBouncing)
        p.bpm = 90
        await gate.finish()
        #expect(await job.value == false)
        #expect(p.padSampleData.isEmpty)
    }

    @Test @MainActor func resampleUsesExactCapturedBarLength() async throws {
        let p = Project(engine: AudioEngine())
        p.bank = "C"; p.bpm = 120; p.barSteps = 12
        let gate = SuspendedRender()
        let job = Task { await p.resampleToPad("C:kick", bars: 2, render: { await gate.render($0) }) }
        await gate.waitUntilStarted()
        await gate.finish()
        #expect(await job.value)
        let file = try #require(p.padParams["C:kick"]?.sampleFile)
        defer { deletePadSampleWAV(file: file) }
        #expect(p.padSampleData["C:kick"]?.count == Int(3 * p.engine.sampleRate))
    }

    @Test @MainActor func projectReplacementDiscardsAutoMaster() async {
        let p = Project(engine: AudioEngine())
        let gate = SuspendedRender()
        let job = Task { await p.autoMaster(render: { await gate.render($0) }) }
        await gate.waitUntilStarted()
        p.clearAll()
        let volume = p.mixer["master"]?.vol
        let limiter = p.masterBus.limiterOn
        await gate.finish()
        #expect(await job.value == nil)
        #expect(p.mixer["master"]?.vol == volume)
        #expect(p.masterBus.limiterOn == limiter)
    }

    @Test @MainActor func cancelledFreezeCannotCommit() async {
        let p = Project(engine: AudioEngine())
        p.lanes = ["kick": [1]]
        let id = p.sendLanesToNewTrack(rows: ["kick"])
        let gate = SuspendedRender()
        let job = Task { await p.freezeTrack(id, render: { await gate.render($0) }) }
        await gate.waitUntilStarted()
        job.cancel()
        await gate.finish()
        #expect(await job.value == false)
        #expect(p.audioClips.isEmpty)
    }

    @Test @MainActor func importedClipRejectsDeletedTrackAndNewProject() {
        let p = Project(engine: AudioEngine())
        let id = p.sendLanesToNewTrack(rows: ["kick"])
        let destination = p.operationDestination()
        p.removeTrack(id)
        #expect(!p.commitImportedClip(destination: destination, trackID: id, startBar: 0, data: [0.1], name: "Old take"))
        p.projectID = UUID().uuidString
        #expect(!p.commitImportedClip(destination: destination, trackID: "drums", startBar: 0, data: [0.1], name: "Old take"))
        #expect(p.audioClips.isEmpty)
    }
}
