import XCTest

final class FB_808UITests: XCTestCase {
    @MainActor
    func testProjectLibraryOnMini() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 10) { skip.tap() }
        let scratch = app.buttons["Start from scratch"]
        if scratch.waitForExistence(timeout: 3) { scratch.tap() }
        let projects = app.buttons["Projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 15))
        XCTAssertTrue(projects.isHittable)
        projects.tap()
        let name = app.textFields["Project name"]
        let nameVisible = name.waitForExistence(timeout: 5)
        if !nameVisible { print("Project library accessibility hierarchy: \(app.debugDescription)") }
        XCTAssertTrue(nameVisible)
        let search = app.textFields["Search saved beats"]
        XCTAssertTrue(search.isHittable)
        search.tap()
        search.typeText("No matching beat " + UUID().uuidString)
        XCTAssertTrue(app.staticTexts["No beats match your search. Try another name."].exists || app.staticTexts["No saved projects yet. Name your beat and tap Save."].exists)
        let clear = app.buttons["Clear search"]
        XCTAssertTrue(clear.isHittable)
        clear.tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Project library on iPad mini"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    // MARK: - Shared launch preamble

    /// Launch, clear the first-run flow (and any crash-recovery alert left by an earlier test), and land
    /// on the mode rail. The rail's "Pads" entry is the anchor every test below waits for.
    @MainActor
    private func launchToRail(_ app: XCUIApplication, orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        app.launch()
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 10) { skip.tap() }
        let scratch = app.buttons["Start from scratch"]
        if scratch.waitForExistence(timeout: 3) { scratch.tap() }
        let discard = app.buttons["Discard"]
        if discard.waitForExistence(timeout: 2) { discard.tap() }
        XCTAssertTrue(app.buttons["Pads"].waitForExistence(timeout: 15),
                      "App never reached the mode rail. Hierarchy:\n\(app.debugDescription)")
    }

    // MARK: - Finding 37 proof: the pad stage is outside every page ScrollView

    /// Finding 37: `StageSplit` must never put the performance stage inside the page ScrollView, in
    /// either branch. If it does, the scroll pan claims a vertical drag over the pads — which is the
    /// documented slide-roll / sustained-pad gesture — cancelling the in-flight pad touches.
    ///
    /// The branch DECISION is pinned by the pure `StageSplit.isStacked` unit tests. This test pins the
    /// structural consequence, which must hold whatever branch was taken.
    @MainActor
    func testPadSurfaceIsNeverInsideAPageScrollView() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchToRail(app, orientation: .portrait)

        let kick = app.buttons["KICK"]
        XCTAssertTrue(kick.waitForExistence(timeout: 10),
                      "Pad grid did not render. Hierarchy:\n\(app.debugDescription)")
        XCTAssertTrue(kick.isHittable)

        // NOTE ON LAYOUT COVERAGE. The simulator does not rotate reliably from inside a UI test, so we
        // deliberately do NOT assert which branch was taken — an earlier version asserted the window
        // was portrait and failed whenever the device stayed landscape. The portrait/landscape
        // DECISION is pinned by the pure `StageSplit.isStacked` unit tests; this test pins the
        // structural consequence that matters, and that holds in BOTH branches: the pad surface is
        // never a descendant of a page ScrollView.

        // Guard against a vacuous pass. The layout always contains a ScrollView (it holds the side
        // panel), so if none exists at all the query below would trivially be 0 and prove nothing.
        XCTAssertGreaterThan(app.scrollViews.count, 0,
                             "No ScrollView at all — the pin below would be vacuous. "
                             + "Hierarchy:\n\(app.debugDescription)")

        // THE PIN. Assert the property directly instead of inferring it from whether a swipe happens
        // to move the pad: no ScrollView may have the pad surface as a descendant. A swipe-based
        // assertion was observed to pass against the reverted (broken) layout, because the enclosing
        // pan does not always claim the drag — that made it a false-pass risk. This query is
        // deterministic: it fails whenever the stage is put back inside a page scroll view, whatever
        // the gesture does (#PAD-SCROLL).
        XCTAssertEqual(app.scrollViews.containing(.button, identifier: "KICK").count, 0,
                       "The pad surface is a descendant of a ScrollView, so the page pan can claim "
                       + "vertical pad drags. Hierarchy:\n\(app.debugDescription)")

        let before = kick.frame
        XCTAssertGreaterThan(before.width, 40, "Pad frame looks collapsed: \(before)")

        // A real vertical performance drag started on a pad.
        kick.swipeUp()

        let after = kick.frame
        XCTAssertEqual(after.midY, before.midY, accuracy: 2.0,
                       "A vertical drag on a pad scrolled the page: pad moved from \(before) to \(after). "
                       + "The pad stage must not live inside a ScrollView (#PAD-SCROLL).")
        XCTAssertEqual(after.midX, before.midX, accuracy: 2.0)
        XCTAssertTrue(kick.isHittable, "Pad was left covered/off-screen after the drag")

        // And the drag must not have opened the pad editor either (a swipe is far shorter than the hold).
        XCTAssertFalse(app.buttons["Close pad editor"].exists,
                       "A swipe on a pad opened the pad editor")
    }

    // MARK: - Finding 39 proof: the pad-editor swatches reach the accessibility tree

    /// Finding 39's naming/selection helpers are unit-tested, but deleting the actual
    /// `.accessibilityLabel` / `.accessibilityValue` / `.isSelected` / 44 pt-frame wiring left the unit test
    /// green. This queries the real accessibility tree: the 13 swatches must carry distinct names, a
    /// selected trait that follows the selection, and a ≥44×44 pt hit target.
    @MainActor
    func testPadInspectorSwatchesReachTheAccessibilityTree() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchToRail(app, orientation: .landscapeLeft)

        let kick = app.buttons["KICK"]
        XCTAssertTrue(kick.waitForExistence(timeout: 10))
        kick.press(forDuration: 1.0)   // the pad-editor long-press (0.6 s) with margin

        let names = ["Coral", "Orange", "Amber", "Yellow", "Green", "Teal", "Sky",
                     "Blue", "Indigo", "Violet", "Purple", "Magenta", "Pink"]
        let coral = app.buttons["Pad colour Coral"]
        XCTAssertTrue(coral.waitForExistence(timeout: 6),
                      "Pad-editor swatches have no accessible names. Hierarchy:\n\(app.debugDescription)")

        for name in names {
            let swatch = app.buttons["Pad colour \(name)"]
            XCTAssertTrue(swatch.exists, "Missing accessible swatch 'Pad colour \(name)'")
            XCTAssertGreaterThanOrEqual(swatch.frame.width, 44, "'\(name)' hit target narrower than 44 pt")
            XCTAssertGreaterThanOrEqual(swatch.frame.height, 44, "'\(name)' hit target shorter than 44 pt")
        }

        // The selected trait must actually track the selection, not be hard-coded.
        //
        // Poll for the state rather than reading isSelected immediately after tap(): the accessibility
        // snapshot is not updated synchronously with the tap, so an immediate read made this flaky
        // (observed failing on the final assertion after the same tap had already passed earlier).
        // It still fails if the trait never becomes selected, so it remains a real assertion.
        let blue = app.buttons["Pad colour Blue"]
        blue.tap()
        XCTAssertTrue(waitForSelected(blue, timeout: 5),
                      "'Pad colour Blue' was tapped but is not exposed as selected")
        XCTAssertFalse(coral.isSelected, "Selecting Blue left Coral marked selected")

        coral.tap()
        XCTAssertTrue(waitForSelected(coral, timeout: 5),
                      "'Pad colour Coral' was tapped but is not exposed as selected")
        XCTAssertFalse(blue.isSelected, "Selecting Coral left Blue marked selected")
    }

    /// Poll `isSelected` until it becomes true or the timeout expires. Used because XCUIElement state
    /// is read from a snapshot that is not guaranteed to reflect a tap immediately.
    @MainActor
    private func waitForSelected(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isSelected { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return element.isSelected
    }

    // MARK: - Finding 66: icon-only buttons need an accessible name

    /// The kit browser's close, and the synth preset bar's prev/next/save-patch, were bare `Image`s, so
    /// VoiceOver announced the raw symbol name and the one-tap "save this patch" star was unidentifiable.
    @MainActor
    func testIconOnlyButtonsExposeAccessibleNames() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchToRail(app, orientation: .landscapeLeft)

        app.buttons["Synth"].firstMatch.tap()

        let prev = app.buttons["Previous preset"]
        XCTAssertTrue(prev.waitForExistence(timeout: 10),
                      "Synth preset bar exposes no 'Previous preset'. Hierarchy:\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Next preset"].exists)
        XCTAssertTrue(app.buttons["Save patch to library"].exists)
        XCTAssertTrue(prev.isHittable)
        XCTAssertTrue(app.buttons["Next preset"].isHittable)
        XCTAssertTrue(app.buttons["Save patch to library"].isHittable)

        app.buttons["Pads"].firstMatch.tap()
        let kits = app.buttons["Browse & Download Kits"]
        XCTAssertTrue(kits.waitForExistence(timeout: 10))
        kits.tap()
        XCTAssertTrue(app.buttons["Close kit browser"].waitForExistence(timeout: 10),
                      "Kit browser close button has no accessible name. Hierarchy:\n\(app.debugDescription)")
    }

    // MARK: - Finding 68: the sequence Mute/Solo flags need a full-width hit target

    /// The per-row M/S flags were `22 pt` wide — half the HIG minimum — 5 pt from the row-select button
    /// and the paint-drag surface, for a control the app tells users to hit live during playback. This
    /// measures the rendered accessibility frame, which is what a finger actually has to hit.
    @MainActor
    func testSequenceRowFlagsHaveFullWidthHitTargets() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchToRail(app, orientation: .landscapeLeft)

        app.buttons["Sequence"].firstMatch.tap()
        let mute = app.buttons["Mute"].firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 10),
                      "Sequence rows expose no 'Mute' flag. Hierarchy:\n\(app.debugDescription)")
        XCTAssertGreaterThanOrEqual(mute.frame.width, 44,
                                    "Sequence Mute hit target is only \(mute.frame.width) pt wide (need ≥44)")
        let solo = app.buttons["Solo"].firstMatch
        XCTAssertTrue(solo.exists)
        XCTAssertGreaterThanOrEqual(solo.frame.width, 44,
                                    "Sequence Solo hit target is only \(solo.frame.width) pt wide (need ≥44)")
    }
}
