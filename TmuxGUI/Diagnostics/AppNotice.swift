//
//  AppNotice.swift
//  TmuxGUI
//

import Foundation

/// One thing the app wants the user to know, independent of who noticed it.
///
/// This is the general currency, not a diagnostics type: the deaf-channel
/// probe, an unmet expectation and "tmux paused a pane" all speak it, and
/// whatever producer comes next does too. Presentation lives entirely in
/// `NoticeCenter`; a producer states facts and severity and has no opinion
/// about pixels — which is what keeps every notice in the app one consistent
/// shape instead of each feature growing its own alert.
struct AppNotice {
    enum Severity {
        /// Worth knowing, nothing wrong.
        case info
        /// Something the app asked for did not happen.
        case warning
        /// A connection is not usable.
        case error
    }

    let severity: Severity
    /// One line, sentence case, stating what happened — not advice, not blame.
    let title: String
    /// A second line with the specifics: which target, how long, which session.
    let body: String
    /// Session name, when the notice is about one.
    let session: String?

    init(severity: Severity, title: String, body: String, session: String? = nil) {
        self.severity = severity
        self.title = title
        self.body = body
        self.session = session
    }
}
