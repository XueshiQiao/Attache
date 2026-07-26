import XCTest

/// A launch smoke test, and only that.
///
/// What it covers: the app starts, gets a window on screen, and draws the
/// session rail from live tmux state. Since the app refuses to start without a
/// tmux server, reaching the rail at all means the control-mode connection came
/// up. That is enough to catch the failures that are invisible at build time —
/// a missing entitlement, a framework that will not load, a crash in
/// `applicationDidFinishLaunching`.
///
/// What it does not cover: anything below the rail. No window tabs, no pane
/// geometry, no input, no resize. Real coverage needs a tmux server in a known
/// state — the test would have to create a throwaway session on its own `-L`
/// socket, drive the app against it, and tear it down.
///
/// **Running this is not free.** `XCUIApplication().launch()` takes the focus of
/// whoever is at the machine, and the app attaches to whatever tmux server is
/// live — on a development machine that is the owner's real one, with real
/// long-running work in it. Run it deliberately, once, when nobody is mid-task.
/// Never in a loop and never unattended.
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
