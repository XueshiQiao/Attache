//
//  GhosttyTerminfo.swift
//  Attache
//

import Foundation

/// The terminal description this app's surfaces run on, and where it comes
/// from.
///
/// libghostty is compiled into this app, but the terminfo entry describing
/// what it can do is not — that ships with **Ghostty.app**, an unrelated
/// application, and libghostty locates it through the `GHOSTTY_RESOURCES_DIR`
/// environment variable. This app never set that variable. It only ever
/// *inherited* it, from whatever shell happened to launch the app, which made
/// a working pane depend on someone else's application staying installed at
/// the same path.
///
/// It is not a dependency worth having and this file removes it: the
/// description is vendored (`Resources/xterm-ghostty.terminfo`, compiled into
/// `Resources/terminfo` and copied into the bundle), and `adoptOwnResources`
/// points the variable at the app's own copy before the first surface exists.
/// After that no branch reads Ghostty.app — including the broken-bundle
/// branch, which *unsets* the inherited value rather than falling back to it.
///
/// The measurements the mechanism rests on, all taken 2026-08-09 against the
/// shipped binary with an isolated config (`ATTACHE_CONFIG`) and an isolated
/// tmux server (`-L`):
///
///     GHOSTTY_RESOURCES_DIR      child TERM       child TERMINFO       attach
///     unset                      xterm-256color   unset                works
///     present but empty          xterm-256color   unset                works
///     set, no terminfo sibling   xterm-ghostty    <dir>/../terminfo    FAILS
///     set, terminfo sibling      xterm-ghostty    <dir>/../terminfo    works
///
/// Four things in that table are not guessable from the code and each cost a
/// launch to find out:
///
/// - `TERMINFO` is **written** from the variable, not passed on. A dead
///   resources directory plus a perfectly good inherited `TERMINFO` still
///   failed, so the good value is overwritten with the bad one.
/// - The resources directory itself is **never looked at**. `TERMINFO` is
///   `<dir>/../terminfo` by string arithmetic alone: pointing the variable at
///   a directory that does not exist, whose sibling `terminfo` does, produced
///   a working `xterm-ghostty` pane. That is why the directory this app names
///   holds only a README.
/// - libghostty does **not** check that the entry is there before choosing the
///   name, so a missing database and a present one take the same branch.
/// - A variable that is present but empty takes the same branch as an absent
///   one. Measured rather than assumed, because a library is free to tell
///   those two apart and this one does not.
///
/// The failure that follows from row three is worth stating plainly, because
/// it is what makes this worth a file: `tmux attach` answers `missing or
/// unsuitable terminal: xterm-ghostty` and exits, the rail keeps working from
/// its own control connection, and the app reads as perfectly alive with a
/// blank content half.
///
/// `decide` stays as the guard behind all of it. It cannot fire once the app
/// owns the variable — which is the point of a guard.
///
/// No AppKit, no environment and no file system of its own, so
/// `Tools/TerminfoCheck` can drive every case without a disk.
enum GhosttyTerminfo {
    /// What libghostty calls the child when it believes it has a database.
    static let ghosttyTerm = "xterm-ghostty"

    /// Resolvable on any macOS install from ncurses' own database.
    static let fallbackTerm = "xterm-256color"

    /// The environment variable libghostty reads its resources — and therefore
    /// its terminfo and its `TERM` — out of.
    static let resourcesVariable = "GHOSTTY_RESOURCES_DIR"

    /// The variable ncurses itself reads, which a Ghostty-launched process
    /// also inherits and which libghostty only overwrites for the children it
    /// spawns. Every *other* child of this app — the control-mode `tmux -C`,
    /// ssh, the git tool's program — gets it by plain inheritance, so leaving
    /// it alone left processes this app started pointing into Ghostty.app.
    /// Measured on the running app 2026-08-09: its control client had
    /// `TERMINFO=/Applications/Ghostty.app/Contents/Resources/terminfo`.
    /// `TERMINFO_DIRS` is deliberately not in this list — nothing in the
    /// environment Ghostty exports sets it.
    static let terminfoVariable = "TERMINFO"

    /// What to do about `term` for a surface about to be built.
    struct Decision: Equatable {
        /// The value to pin as `term` in the generated config, or nil to leave
        /// libghostty's own choice alone.
        let term: String?

        /// The terminfo directory that was looked in and came up empty, when
        /// there was one. Left nil when nothing is wrong — a launch with no
        /// resources directory at all is ordinary and says nothing worth
        /// telling anyone.
        let missingFrom: String?

        /// The variable that would not take the value it was given, read back
        /// after the write. `setenv` can fail, and a failure there is the one
        /// that matters: it leaves the *inherited* value in place, which is
        /// the value that names another application.
        let unownedVariable: String?

        init(term: String?, missingFrom: String?, unownedVariable: String? = nil) {
            self.term = term
            self.missingFrom = missingFrom
            self.unownedVariable = unownedVariable
        }

        static let leaveAlone = Decision(term: nil, missingFrom: nil)
    }

    // MARK: - Owning the variable

    /// Where the app's own copy of the database sits inside its bundle,
    /// relative to `Contents/Resources`.
    static let ownTerminfoSubdirectory = "terminfo"

    /// The directory named as `GHOSTTY_RESOURCES_DIR` so that the app's own
    /// `terminfo` is the sibling libghostty resolves. It holds a README and
    /// nothing else — see the note above about the directory never being read.
    static let ownResourcesSubdirectory = "ghostty"

    /// Take **both** terminfo variables over from whatever launched the app,
    /// and say whether it worked.
    ///
    /// Every outcome ends with no inherited value left standing, which is the
    /// requirement — this app has nothing to do with Ghostty.app and no branch
    /// may quietly restore a path into it:
    ///
    /// - **The bundled entry is there.** Both variables name this bundle.
    ///   Panes get the full `xterm-ghostty` from a file this repository owns,
    ///   whether or not Ghostty is installed anywhere.
    /// - **It is not** — a broken or half-copied bundle. *Remove* both rather
    ///   than leaving the inherited ones, so libghostty takes its own
    ///   `xterm-256color` branch and every other child of this app resolves
    ///   from the system database. Falling back to Ghostty.app here would
    ///   restore exactly the dependency this exists to remove, and would do it
    ///   only on the machines where something was already wrong.
    ///
    /// Then it **reads the variables back**. `setenv` can fail, and its
    /// failure mode is precisely the one that matters: the write does nothing
    /// and the inherited value — the one naming another application — survives
    /// as though it had been replaced. A decision built from what was
    /// *intended* would report success there. `unownedVariable` reports what
    /// the environment actually says, and a caller that finds it set must pin
    /// `term` rather than trust anything the environment points at.
    ///
    /// - Parameter bundleResourcePath: `Bundle.main.resourcePath`, injected.
    @discardableResult
    static func adoptOwnResources(
        bundleResourcePath: String?,
        entryExists: (String) -> Bool,
        readVariable: (String) -> String?,
        setVariable: (String, String?) -> Void
    ) -> Decision {
        let own = bundleResourcePath
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { ($0 as NSString).appendingPathComponent(ownResourcesSubdirectory) }

        let decision = own.map { decide(resourcesDirectory: $0, entryExists: entryExists) }
            ?? Decision(term: fallbackTerm, missingFrom: nil)

        let resources = decision.term == nil ? own : nil
        let terminfo = resources.map { terminfoDirectory(resourcesDirectory: $0) }

        func giveUp(_ name: String) -> Decision {
            Decision(term: fallbackTerm, missingFrom: decision.missingFrom, unownedVariable: name)
        }

        // Empty first, then fill, and never overwrite in place.
        //
        // Writing straight over the inherited values means one failed write
        // leaves a *pair that disagrees* — this bundle on one name and another
        // application's on the other — and each name read on its own then says
        // everything is fine. Clearing both first makes the worst outcome
        // "neither is set", which is a state every consumer already handles:
        // libghostty falls back on its own, and ncurses resolves from the
        // system database. A half-owned environment has no such floor, and it
        // is inherited by every child this app spawns.
        for name in [terminfoVariable, resourcesVariable] { setVariable(name, nil) }
        for name in [terminfoVariable, resourcesVariable] where readVariable(name) != nil {
            return giveUp(name)
        }

        // The bundle had nothing to point at. Cleared is the whole job.
        guard let resources, let terminfo else { return decision }

        for (name, value) in [(terminfoVariable, terminfo), (resourcesVariable, resources)] {
            setVariable(name, value)
            guard readVariable(name) == value else {
                // Back to empty rather than half-filled, for the same reason.
                for name in [terminfoVariable, resourcesVariable] { setVariable(name, nil) }
                return giveUp(name)
            }
        }
        return decision
    }

    /// The same, against the real bundle and the real environment, remembering
    /// the answer for the surfaces built later.
    @discardableResult
    static func adoptOwnResourcesAtLaunch(
        bundle: Bundle = .main,
        entryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Decision {
        let decision = adoptOwnResources(
            bundleResourcePath: bundle.resourcePath,
            entryExists: entryExists,
            readVariable: { name in
                getenv(name).map { String(cString: $0) }
            },
            setVariable: { name, value in
                if let value {
                    setenv(name, value, 1)
                } else {
                    unsetenv(name)
                }
            }
        )
        launchDecision = decision
        return decision
    }

    /// What the takeover concluded, for surfaces built afterwards.
    ///
    /// Remembered rather than re-derived, and that is not an optimisation. A
    /// takeover that *failed* leaves the environment still naming another
    /// application — so a surface that only re-read the environment would find
    /// that entry, conclude everything was fine, and use it. Which is the one
    /// outcome this whole file exists to prevent.
    ///
    /// Written once, before the first surface, and only read afterwards.
    nonisolated(unsafe) private(set) static var launchDecision = Decision.leaveAlone

    // MARK: - The guard

    /// Decide from a resources directory and a way to ask whether a file is
    /// there.
    ///
    /// Three branches, each with its own reason to exist:
    ///
    /// - **No resources directory, or one that is exactly empty.** Leave it
    ///   alone; libghostty falls back to `xterm-256color` by itself in both
    ///   cases (measured separately — see the note above).
    /// - **An entry is there.** Leave it alone; `xterm-ghostty` is the better
    ///   terminal and it will resolve.
    /// - **Any other value, with no entry under it.** Pin the fallback. Note
    ///   that "any other" includes a value of nothing but spaces: that is a
    ///   real path as far as a library reading the variable is concerned, it
    ///   was *not* measured to take the fallback branch, and treating it as
    ///   absent on the strength of it looking absent to a human is the guess
    ///   this whole file exists to avoid making.
    static func decide(
        resourcesDirectory: String?,
        entryExists: (String) -> Bool
    ) -> Decision {
        guard let directory = resourcesDirectory, !directory.isEmpty
        else { return .leaveAlone }

        let paths = candidateEntryPaths(resourcesDirectory: directory)
        if paths.contains(where: entryExists) { return .leaveAlone }
        return Decision(
            term: fallbackTerm,
            missingFrom: terminfoDirectory(resourcesDirectory: directory)
        )
    }

    /// What a surface being built now should pin as `term`, or nil to leave
    /// libghostty's choice alone.
    ///
    /// Two questions, and the surface is only safe if both say so. The launch
    /// answer covers a takeover that did not take — where the environment is
    /// still someone else's and must not be believed. The live answer covers a
    /// database that has gone away since launch, and is asked per surface
    /// rather than cached because it is a handful of `access` calls and the
    /// next pane should get the current truth.
    static func termForSurface(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        entryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        if let pinned = launchDecision.term { return pinned }
        return decideForThisMachine(environment: environment, entryExists: entryExists).term
    }

    /// The same decision against the machine this is running on.
    static func decideForThisMachine(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        entryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Decision {
        decide(resourcesDirectory: environment[resourcesVariable], entryExists: entryExists)
    }

    /// Where libghostty will tell the child to look: `<resources>/../terminfo`,
    /// by string arithmetic and without consulting the disk. Measured, not
    /// assumed — see the note above.
    static func terminfoDirectory(resourcesDirectory: String) -> String {
        let trimmed = trimmingTrailingSlashes(resourcesDirectory)
        let parent = (trimmed as NSString).deletingLastPathComponent
        // A resources directory of "/" or one bare component leaves no parent
        // to speak of; joining onto an empty string would produce a relative
        // path, which is never what libghostty resolves.
        guard !parent.isEmpty else { return "/terminfo" }
        return (parent as NSString).appendingPathComponent("terminfo")
    }

    /// Every file that would satisfy the lookup.
    ///
    /// One directory — the one libghostty was measured to export — and both
    /// spellings of the first character in it, because ncurses reads either:
    /// the compiled database has `78/` (hex for `x`) and a `tic` run can also
    /// write `x/`.
    ///
    /// A second directory was tried here and taken out again, and the reason
    /// is the whole point of the file. Also accepting `<resources>/terminfo`
    /// was meant to tolerate a database that moves one day. But an entry found
    /// somewhere libghostty does not export cannot establish that libghostty
    /// will look there — so a stale or half-finished copy in that spot would
    /// certify the real directory as present while the child is pointed at the
    /// missing one, which is exactly the blank pane this exists to prevent.
    /// Being wrong towards `xterm-256color` costs a few capabilities; being
    /// wrong the other way costs the pane. If the layout ever does move,
    /// measure where `TERMINFO` points and change this list to match.
    static func candidateEntryPaths(
        resourcesDirectory: String,
        term: String = ghosttyTerm
    ) -> [String] {
        guard let first = term.unicodeScalars.first, first.isASCII else { return [] }
        let directory = terminfoDirectory(resourcesDirectory: resourcesDirectory)
        let buckets = [String(Character(first)), String(format: "%02x", first.value)]
        return buckets.map { bucket in
            ((directory as NSString).appendingPathComponent(bucket) as NSString)
                .appendingPathComponent(term)
        }
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }
}
