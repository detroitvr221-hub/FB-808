// Content resolution uses the requested playback mode, including offline operations.
// An export must never consult a different mode selected by the transport UI.
nonisolated enum PlaybackContext: Sendable {
    case pattern
    case song
}

extension Project {
    var playbackContext: PlaybackContext { songMode ? .song : .pattern }
}
