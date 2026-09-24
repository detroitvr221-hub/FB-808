import Foundation

/// A render may finish after the user has edited or replaced its source document.
struct ProjectRenderDestination {
    let projectID: String
    let contentRevision: UInt64
    let renderRevision: UInt64
    let bpm: Int
    let barSteps: Int
    let songMode: Bool

    @MainActor init(_ project: Project) {
        projectID = project.projectID
        contentRevision = project.contentRevision
        renderRevision = project.renderRevision
        bpm = project.bpm
        barSteps = project.barSteps
        songMode = project.songMode
    }

    @MainActor func matches(_ project: Project) -> Bool {
        projectID == project.projectID && contentRevision == project.contentRevision
            && renderRevision == project.renderRevision && bpm == project.bpm
            && barSteps == project.barSteps && songMode == project.songMode
    }
}

typealias ProjectOfflineRenderer = @Sendable (ExportPlan) async -> ([Float], [Float])

extension Project {
    @discardableResult
    func commitSamplerImport(destination: ProjectOperationDestination, data: [Float], name: String) -> Bool {
        guard !Task.isCancelled, destination.matches(self), !data.isEmpty else {
            backgroundOperationNotice = "The destination changed while importing. Import the audio again in the current beat."
            return false
        }
        mutateSample("import") {
            let r = engine.importBuffer(data)
            sample = SampleState(name: name.isEmpty ? "Imported" : name, kind: "import",
                                 dur: r.dur, wave: r.wave, transients: r.transients)
            sliceBank = nil
        }
        return true
    }

    @discardableResult
    func commitPadImport(destination: ProjectOperationDestination, padID: String, data: [Float], name: String) -> Bool {
        guard !Task.isCancelled, destination.matches(self) else {
            backgroundOperationNotice = "The pad destination changed while importing. Select the pad and import again."
            return false
        }
        return setPadSample(padID, data: data, name: name, bank: destination.bank)
    }

    nonisolated static func renderOfflinePlan(_ plan: ExportPlan) async -> ([Float], [Float]) {
        await Task.detached(priority: .userInitiated) { renderOffline(plan) }.value
    }

    func acceptRender(_ destination: ProjectRenderDestination) -> Bool {
        guard !Task.isCancelled, destination.matches(self) else {
            backgroundOperationNotice = "The beat changed while rendering. Try again with the current beat."
            return false
        }
        return true
    }

    /// An import captures the project and track before decoding, then resolves the track again.
    @discardableResult
    func commitImportedClip(destination: ProjectOperationDestination, trackID: String,
                            startBar: Int, data: [Float], dataR: [Float]? = nil, name: String) -> Bool {
        guard !Task.isCancelled, destination.matches(self), tracks.contains(where: { $0.id == trackID }) else {
            backgroundOperationNotice = "The destination changed while importing. Choose a track and import the audio again."
            return false
        }
        return addAudioClip(track: trackID, startBar: startBar, data: data, dataR: dataR, name: name)
    }
}
