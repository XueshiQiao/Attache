//
//  GitStatus.swift
//  TmuxGUI
//

import Foundation

/// What a window row's second line says about the repository the pane is in.
///
/// The one thing in this app that tmux is not the source of. Everything else
/// the rail draws comes from a control mode notification, because tmux owns it;
/// a working tree belongs to the filesystem and tmux has never heard of it. So
/// this does not go into `TmuxWindow` — that struct is a mirror, and a Git
/// field in it would be the first thing in the file that tmux could not
/// confirm. It travels beside the window instead, in the rail's view model.
///
/// What keys it *is* tmux's: `#{pane_current_path}`, which arrives on a
/// subscription like everything else.
struct GitSummary: Equatable {
    /// The branch, or nil on a detached HEAD.
    var branch: String?
    /// The short object id, kept only for a detached HEAD — that is the one
    /// case where there is no name to draw and a row saying nothing would look
    /// like a failure to read the repo rather than like the state it is in.
    var detachedAt: String?

    /// Whether an upstream exists at all. Distinct from `ahead == 0 &&
    /// behind == 0`: a branch that was never pushed has no answer, and drawing
    /// a `↑0` for it claims one.
    var hasUpstream: Bool
    var ahead: Int
    var behind: Int

    /// Paths with an index change — `git add`ed, in any form.
    var staged: Int
    /// Paths changed in the working tree and not staged.
    var modified: Int
    /// Untracked paths. Counted, but deliberately not drawn beside the others:
    /// a repo with an unignored `node_modules` would read `+4000` forever and
    /// crowd out the numbers that mean something. See `line`.
    var untracked: Int
    /// Paths in a conflicted merge or rebase. Its own field because it is the
    /// one state where the row should say a word rather than a number.
    var conflicted: Int

    /// When the summary was taken, so a tooltip can say how stale `behind` is.
    /// `behind` is measured against the last fetch and nothing else, so the
    /// number alone is not a statement about the remote.
    var readAt: Date
    /// When this repository was last fetched, read from the newest mtime under
    /// `.git` that a fetch touches. Nil when nothing has ever fetched.
    var lastFetch: Date?

    /// Equality over what is *drawn*, which deliberately leaves out `readAt`.
    ///
    /// Synthesised equality was a defect with a visible symptom. `readAt` is a
    /// fresh `Date` on every read, so two identical reads of an unchanged
    /// repository compared as different, the service reported a change, and the
    /// rail rebuilt — tearing down and recreating every row, including the one
    /// under the pointer. Hovering flickered and clicks landed on views that no
    /// longer existed.
    ///
    /// Measured 2026-07-28 before the fix: **577 rail rebuilds in 30 seconds**
    /// of an idle app, every one of them from this comparison.
    ///
    /// `lastFetch` stays in: it is not drawn, but the tooltip quotes it, and it
    /// only moves when a fetch actually happened.
    static func == (a: GitSummary, b: GitSummary) -> Bool {
        a.branch == b.branch && a.detachedAt == b.detachedAt
            && a.hasUpstream == b.hasUpstream && a.ahead == b.ahead && a.behind == b.behind
            && a.staged == b.staged && a.modified == b.modified
            && a.untracked == b.untracked && a.conflicted == b.conflicted
            && a.lastFetch == b.lastFetch
    }

    var isClean: Bool {
        staged == 0 && modified == 0 && untracked == 0 && conflicted == 0
    }

    /// The branch as it should be drawn, detached HEAD included.
    var displayRef: String {
        if let branch { return branch }
        if let detachedAt { return "detached at \(detachedAt)" }
        return "—"
    }
}

/// Runs `git` and turns its answer into a `GitSummary`.
///
/// One command per refresh. `--porcelain=v2 --branch` yields the branch, the
/// upstream, the ahead/behind pair and every changed path in a single reply —
/// measured at 15ms on this repository — and the format is documented as
/// stable, unlike the human-readable one.
enum GitStatus {
    /// Where `git` is. Resolved once rather than per call, and by asking the
    /// shell's `PATH` rather than assuming `/usr/bin/git`: a Homebrew or Xcode
    /// git is the one the user's terminal runs, and answering from a different
    /// binary than the pane does is the kind of disagreement this app exists to
    /// avoid.
    static let executable: URL? = {
        for candidate in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
            where FileManager.default.isExecutableFile(atPath: candidate)
        {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }()

    /// The failure modes worth telling apart. Everything else is "no repo".
    enum Failure: Error, Equatable {
        /// The path is not inside a work tree. The overwhelmingly common case
        /// and not an error to report anywhere — a home directory is not a
        /// repository and a row over one should simply say so.
        case notARepository
        /// git could not be found, or could not be run.
        case unavailable
        /// git ran and failed for a reason worth keeping.
        case failed(status: Int32, message: String)
    }

    // MARK: - Parsing

    /// Parse `git status --porcelain=v2 --branch` output.
    ///
    /// Split out from running it so it can be checked against captured fixtures
    /// without a repository — see `Tools/GitStatusCheck`. Every defect this can
    /// have is an off-by-one in a status code, and a status code is exactly the
    /// thing a fixture pins down.
    static func parse(porcelainV2 text: String, readAt: Date, lastFetch: Date?) -> GitSummary {
        var summary = GitSummary(
            branch: nil, detachedAt: nil,
            hasUpstream: false, ahead: 0, behind: 0,
            staged: 0, modified: 0, untracked: 0, conflicted: 0,
            readAt: readAt, lastFetch: lastFetch
        )

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let kind = line.first else { continue }
            switch kind {
            case "#":
                parseHeader(line, into: &summary)

            // An ordinary change and a rename carry their status in the same
            // place; a rename only adds fields *after* it. So both are read the
            // same way and the extra fields are ignored rather than special
            // cased — the row counts paths, and a rename is one path however
            // many names it has had.
            case "1", "2":
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard fields.count >= 2 else { continue }
                let xy = Array(fields[1])
                guard xy.count >= 2 else { continue }
                // `.` is "unmodified in this half". X is the index, Y is the
                // working tree, and a path can be counted in both — staged
                // then edited again is genuinely two facts about it.
                if xy[0] != "." { summary.staged += 1 }
                if xy[1] != "." { summary.modified += 1 }

            case "u":
                summary.conflicted += 1

            case "?":
                summary.untracked += 1

            // `!` is an ignored path, which only appears with
            // --ignored and is never asked for here.
            default:
                continue
            }
        }
        return summary
    }

    private static func parseHeader(_ line: Substring, into summary: inout GitSummary) {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3 else { return }
        switch fields[1] {
        case "branch.head":
            // git writes the literal `(detached)` here rather than omitting the
            // line, so the parenthesised form is the signal and not a branch
            // that happens to be called that: a real branch cannot contain a
            // `(` at the start under `git check-ref-format`.
            let name = String(fields[2])
            summary.branch = name == "(detached)" ? nil : name

        case "branch.oid":
            let oid = String(fields[2])
            summary.detachedAt = oid == "(initial)" ? nil : String(oid.prefix(7))

        case "branch.upstream":
            summary.hasUpstream = true

        case "branch.ab":
            // `+N -M`, always both, always in that order. The signs are part of
            // the format rather than of the numbers.
            guard fields.count >= 4 else { return }
            summary.ahead = Int(fields[2].dropFirst()) ?? 0
            summary.behind = Int(fields[3].dropFirst()) ?? 0

        default:
            return
        }
    }

    // MARK: - Running

    /// Read a repository whose top level is already known.
    ///
    /// Takes the root rather than any path inside it, and that is a performance
    /// decision rather than a tidiness one. Resolving the root costs a second
    /// `git` process, and a spawn dominates this work: measured on this machine
    /// 2026-07-28, `git status` on this repository is ~15ms when the shell
    /// times it, but a read that also ran `rev-parse` came out at **167ms**.
    /// Fifteen windows on a refresh loop at 167ms each is a rail that makes the
    /// app feel slow. The root for a given path never changes, so
    /// `GitStatusService` resolves it once and caches it, and this runs exactly
    /// one process per refresh.
    ///
    /// Blocking, and meant to be: the caller owns the queue. Never call this on
    /// the main thread.
    static func read(root: String) throws -> GitSummary {
        guard let executable else { throw Failure.unavailable }

        let output = try run(
            executable,
            arguments: ["status", "--porcelain=v2", "--branch", "--untracked-files=normal"],
            in: root
        )
        guard output.status == 0 else {
            // 128 with this message is git's answer for "not a repository", and
            // it is by far the most common outcome across a rail full of
            // windows — a home directory, a downloads folder, a pane that never
            // left `/`.
            if output.text.contains("not a git repository") {
                throw Failure.notARepository
            }
            throw Failure.failed(status: output.status, message: output.text)
        }
        return parse(
            porcelainV2: output.text,
            readAt: Date(),
            // A stat, not a process — which is the whole reason the root is
            // passed in rather than looked up.
            lastFetch: lastFetchDate(inRepositoryRoot: root)
        )
    }

    /// Bring the remote-tracking refs up to date, so `# branch.ab`'s `behind`
    /// half means something.
    ///
    /// Only ever called when `AppSettings.gitAutoFetch` is on, and that setting
    /// is off by default for a reason worth restating at the call site: this
    /// opens a network connection on the user's behalf, to a host they did not
    /// name, because a sidebar is on screen.
    ///
    /// `--no-tags` because tags are not what the row is asking about and some
    /// repositories carry thousands. Nothing is written to the working tree and
    /// no branch is moved — a fetch is the read-only half of a pull, and the
    /// distinction is the whole reason this is acceptable to do unattended.
    ///
    /// Throws `Failure.failed` on a repository that wants credentials, which
    /// the caller uses to stop asking. `run` already forces every prompt off,
    /// so this fails fast rather than hanging.
    static func fetch(root: String) throws {
        guard let executable else { throw Failure.unavailable }
        let output = try run(
            executable, arguments: ["fetch", "--quiet", "--no-tags"], in: root
        )
        guard output.status == 0 else {
            throw Failure.failed(status: output.status, message: output.text)
        }
    }

    /// The top level of the work tree containing `path`, which is the key
    /// everything is cached under.
    ///
    /// Asked separately so that four windows in four subdirectories of one
    /// repository share a single entry and a single `git status`, rather than
    /// running four identical commands whose answers cannot differ.
    static func repositoryRoot(containing path: String) -> String? {
        guard let executable else { return nil }
        guard let output = try? run(
            executable, arguments: ["rev-parse", "--show-toplevel"], in: path
        ), output.status == 0 else { return nil }
        let root = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    /// When this repository last heard from its remote.
    ///
    /// From `FETCH_HEAD`'s modification time, which git rewrites on every fetch
    /// including one that brought nothing. This is what lets a tooltip say
    /// "behind is unknown, last fetch 47m ago" instead of letting a `↓0` be
    /// read as "the remote has nothing new" — which it does not mean.
    ///
    /// A `.git` that is a *file* rather than a directory is a worktree or a
    /// submodule, and it names the real git directory instead of holding one.
    /// Following that is one read of a small file, and not following it makes
    /// every worktree report "never fetched" — which for this user is not an
    /// edge case, since the app's own workflow creates worktrees.
    static func lastFetchDate(inRepositoryRoot root: String) -> Date? {
        let manager = FileManager.default
        let dotGit = URL(fileURLWithPath: root).appendingPathComponent(".git")

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }

        var gitDirectory = dotGit
        if !isDirectory.boolValue {
            guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
            else { return nil }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDirectory = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: root).appendingPathComponent(path).standardizedFileURL
        }

        let head = gitDirectory.appendingPathComponent("FETCH_HEAD")
        return (try? manager.attributesOfItem(atPath: head.path))?[.modificationDate] as? Date
    }

    // MARK: - Process

    private struct Output {
        let status: Int32
        let text: String
    }

    /// Options prepended to every invocation, and each one is load-bearing.
    ///
    /// **`-c core.fsmonitor=`** — this is a security control, not a tuning
    /// knob. A repository's own `.git/config` can set `core.fsmonitor` to an
    /// arbitrary command, and git runs it during an ordinary `git status`.
    /// Because this app reads every directory a pane happens to be sitting in,
    /// with no user action at all, that turns "the user `cd`'d into a folder"
    /// into code execution — an extracted archive in Downloads is enough.
    /// `safe.directory` does not help: the user owns the directory they
    /// unpacked, so the ownership check passes.
    ///
    /// Demonstrated on this machine 2026-07-28, both directions: a repository
    /// carrying `fsmonitor = "touch …/PWNED"` ran it on a plain `git status`,
    /// and did not with this override in place.
    ///
    /// **`-c core.hooksPath=/dev/null`** — the same argument for anything that
    /// would run a hook. `status` is not supposed to, and this costs nothing.
    ///
    /// **`--no-optional-locks`** — stops git touching the index to refresh its
    /// stat cache. Measured: watching `.git` while running a plain
    /// `git status` in it produced 14 filesystem events over 5 runs, and 4 with
    /// the locks off. That is this service's own reads waking its own watcher,
    /// which is a feedback loop; `GitStatusService` closes the rest of it.
    private static let hardening = [
        "--no-optional-locks",
        "-c", "core.fsmonitor=",
        "-c", "core.hooksPath=/dev/null",
    ]

    private static func run(
        _ executable: URL, arguments: [String], in directory: String
    ) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = hardening + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        var environment = ProcessInfo.processInfo.environment
        // The environment form of `--no-optional-locks`, set as well as the
        // flag because it reaches any git this one runs as a child.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        // Nothing here may ever block on a human. A repository whose remote
        // wants credentials would otherwise hang this call forever, holding the
        // queue and freezing every other repository's refresh behind it — and
        // the prompt would appear nowhere, because there is no terminal
        // attached to it.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/true"
        environment["SSH_ASKPASS"] = "/usr/bin/true"
        // Locale-independent output. `git status --porcelain` is documented not
        // to translate, but `rev-parse`'s errors are, and the "not a git
        // repository" test below reads one.
        environment["LC_ALL"] = "C"
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Never inherited: a git that decided to read from a terminal would
        // read from whatever this app was launched from.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw Failure.unavailable
        }

        // Both pipes, concurrently, and only then wait.
        //
        // Reading before waiting is necessary — a pipe holds 64KB and
        // `git status` in a large repository exceeds it — but reading them one
        // after the other is not sufficient, and the difference is a hang. The
        // first `readDataToEndOfFile` does not return until git closes stdout,
        // and git cannot get there while it is blocked writing a stderr nobody
        // is draining yet. Both have to be large at once, which needs a big
        // repository *and* something noisy on stderr — per-directory
        // "permission denied" warnings are the ordinary way to get there.
        //
        // Reproduced by an independent review with a harness driving 200KB down
        // each pipe: the serial version hung indefinitely. It would have taken
        // one of four queue slots with it, permanently, with nothing logged.
        let group = DispatchGroup()
        var data = Data()
        var errorData = Data()
        let drain = DispatchQueue(label: "tmuxgui.git.drain", attributes: .concurrent)
        drain.async(group: group) { data = out.fileHandleForReading.readDataToEndOfFile() }
        drain.async(group: group) { errorData = err.fileHandleForReading.readDataToEndOfFile() }
        group.wait()
        process.waitUntilExit()

        let text = process.terminationStatus == 0
            ? String(decoding: data, as: UTF8.self)
            : String(decoding: errorData, as: UTF8.self)
        return Output(status: process.terminationStatus, text: text)
    }
}
