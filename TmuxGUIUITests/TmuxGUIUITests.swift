import XCTest

/// Placeholder. What this replaced was libghostty's own sample test — terminal
/// selection, the copy menu, CJK input — none of which this app wires up the
/// same way, and it had never been run.
///
/// Real coverage here needs a tmux server in a known state: the test would have
/// to create a throwaway session, drive the app against it, and tear it down.
/// Until that exists this target only proves the app launches and reaches live
/// tmux state. See TODO.md item 2 — the target should either grow real coverage
/// or be dropped when the project moves to XcodeGen.
final class TmuxGUIUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testLaunchesAndShowsSessionRail() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window appeared")

        // The app refuses to start without a tmux server, so reaching a window
        // at all means it connected. The rail header is the first thing drawn
        // from live tmux state rather than from the nib-less setup code.
        let rail = app.staticTexts["SESSIONS"].firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 10), "session rail never appeared")
    }
}
