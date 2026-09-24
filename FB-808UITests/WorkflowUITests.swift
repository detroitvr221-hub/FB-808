import XCTest

final class WorkflowUITests: XCTestCase {
    @MainActor
    func testBlankSynthSaveAndNewThenRelaunchBothSongs() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        let suffix = String(UUID().uuidString.prefix(6))
        let first = "Workflow One " + suffix, second = "Workflow Two " + suffix

        func tap(_ element: XCUIElement) {
            XCTAssertTrue(element.waitForExistence(timeout: 15), app.debugDescription)
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
            element.tap()
        }
        func gone(_ element: XCUIElement) {
            let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 10), .completed)
        }
        func openProjects() { tap(app.buttons["Projects"]); XCTAssertTrue(app.textFields["Project name"].waitForExistence(timeout: 10)) }
        func name(_ value: String) {
            let field = app.textFields["Project name"]
            tap(field)
            let count = (field.value as? String)?.count ?? 40
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count + 5) + value)
        }
        func scratch() {
            tap(app.buttons["Start from scratch"])
            gone(app.buttons["Start from scratch"])
            XCTAssertFalse(app.alerts["Replace your current beat?"].exists, "New Beat must not ask twice")
        }

        app.launch()
        if app.buttons["Skip"].waitForExistence(timeout: 6) { tap(app.buttons["Skip"]) }
        if app.buttons["Start from scratch"].waitForExistence(timeout: 3) { scratch() }
        if app.alerts.buttons["Discard"].waitForExistence(timeout: 2) { tap(app.alerts.buttons["Discard"]) }
        openProjects()
        tap(app.buttons["New Beat"])
        if app.alerts.buttons["Discard & start new"].waitForExistence(timeout: 2) { tap(app.alerts.buttons["Discard & start new"]) }
        scratch()

        // Opening Synth is read-only; selecting a preset is an explicit, saved edit.
        tap(app.buttons["Synth"].firstMatch)
        XCTAssertTrue(app.buttons["Next preset"].waitForExistence(timeout: 10))
        openProjects()
        XCTAssertTrue(app.staticTexts["No unsaved changes"].exists)
        tap(app.buttons["Close"]); gone(app.textFields["Project name"])
        tap(app.buttons["Next preset"])
        openProjects(); name(first)
        tap(app.buttons["Save & New"])
        scratch()

        openProjects()
        XCTAssertEqual(app.textFields["Project name"].value as? String, "Untitled Beat")
        XCTAssertTrue(app.buttons["Open " + first].waitForExistence(timeout: 10))
        name(second)
        tap(app.buttons["Save"])
        XCTAssertTrue(app.buttons["Saved"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Open " + second].waitForExistence(timeout: 10))
        tap(app.buttons["Close"]); gone(app.textFields["Project name"])

        app.terminate(); app.launch()
        openProjects()
        XCTAssertEqual(app.textFields["Project name"].value as? String, second)
        tap(app.buttons["Open " + first]); gone(app.textFields["Project name"])
        openProjects()
        XCTAssertEqual(app.textFields["Project name"].value as? String, first)
        XCTAssertTrue(app.buttons["Open " + second].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "First song reopened after Save & New and relaunch"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
