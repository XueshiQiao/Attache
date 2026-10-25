import Aptabase

/// Only launches are tracked. Do not add feature, preference, or content events.
@MainActor
enum Analytics {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        // Check before initialization so an opted-out launch never starts the SDK.
        guard AppSettings.analyticsEnabled else { return }

        Aptabase.shared.initialize(appKey: "A-US-9829785092")
        Aptabase.shared.trackEvent("app_launched")
    }
}
