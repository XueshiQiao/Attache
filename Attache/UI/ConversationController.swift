//
//  ConversationController.swift
//  Attache
//

import Foundation

/// Keeps exactly one conversation open: whichever the window on screen is
/// running.
///
/// **The whole job is knowing when to let go.** A pane's conversation is a live
/// value, not a lookup done once — `/clear` starts a new one, `/resume` opens
/// an old one, quitting the agent and starting another in the same pane makes a
/// third, and the person switches windows constantly. Every one of those has to
/// tear the previous source down, because a source left running holds a file
/// watcher and would keep pushing a conversation nobody is looking at.
///
/// Which provider answers is decided per evidence rather than configured, so
/// adding an agent is adding a provider to `providers` and nothing else.
@MainActor
final class ConversationController {
    /// Ordered because the first one that recognises the evidence wins. Today
    /// there is one; the list is what the second one gets added to.
    private let providers: [AgentConversationProvider] = [ClaudeCodeConversationProvider()]

    private var locator: AgentConversationLocator?
    private var source: AgentConversationSource?
    private(set) var conversation: AgentConversation?

    /// Fired when the conversation changed and the view should redraw.
    var onChange: (() -> Void)?

    /// Point at the window on screen, or at nothing.
    ///
    /// Cheap to call on every tmux notification and it is called that often:
    /// the common case compares two `AgentConversationLocator`s and returns.
    /// The expensive part — `locate`, which touches the disk — runs only when
    /// the evidence is not already resolved to the same place.
    func follow(_ evidence: AgentPaneEvidence?) {
        guard let evidence else { return clear() }

        // `locate` may hit the file system, so it does not belong on the main
        // queue in principle. It is here on purpose anyway: it is a `stat` on a
        // path that is almost always in the cache, and the alternative — hop
        // off, hop back — reorders against the next notification and can settle
        // on a stale locator. Revisit if it ever shows up in a trace.
        guard let next = providers.lazy.compactMap({ $0.locate(evidence) }).first else {
            return clear()
        }
        guard next != locator else { return }

        stopSource()
        locator = next
        conversation = nil

        guard let provider = providers.first(where: { $0.agent == next.agent }) else { return }
        let source = provider.makeSource(for: next)
        source.onSnapshot = { [weak self] snapshot in
            guard let self, self.locator == next else { return }
            // Identical snapshots arrive whenever a file changed without the
            // conversation changing — a status line rewrite, a tool result
            // appended. Rebuilding a few hundred views for one of those would
            // throw away the person's scroll position for nothing.
            guard self.conversation != snapshot else { return }
            self.conversation = snapshot
            self.onChange?()
        }
        self.source = source
        source.start()
        onChange?()
    }

    private func clear() {
        guard locator != nil || conversation != nil else { return }
        stopSource()
        locator = nil
        conversation = nil
        onChange?()
    }

    private func stopSource() {
        source?.stop()
        source = nil
    }
}
