//
//  DesktopCallServer.swift
//  Attache
//

import Darwin
import Foundation

/// Lets a client that reached this Mac over SSH ask the desktop app to do
/// something only a process in the desktop login can do.
///
/// The phone reads everything through `attache-cli`, which it starts over
/// SSH, and a process that came in over SSH cannot read the login keychain:
/// measured 2026-11-08, from the phone's channel `claude auth status --json`
/// said `loggedIn: false` and `security show-keychain-info` failed with
/// "User interaction is not allowed" (XueshiQiao/Attache#39). This app runs
/// in the desktop login, where both work — also with the screen locked,
/// measured the same day. So attache-cli asks here, over a Unix socket in
/// the owner's home folder, which both sides reach whatever login they came
/// from.
///
/// The owner's rule (2026-11-08): the phone's core — SSH, tmux, agents,
/// conversations — never depends on this app. Only what needs the desktop
/// login does, and a client that finds nobody listening says so instead.
///
/// One request per connection, both directions one line of JSON:
///
/// ```text
/// → {"call":"usage.refresh","max_age":240}
/// ← {"ok":true,"providers":{"claude":"ok via claude.cli",…}}
/// ```
///
/// The answer to `usage.refresh` is only an acknowledgement. The numbers
/// themselves land in AIUsageKit's shared cache, which attache-cli already
/// watches and passes on.
///
/// `nonisolated`: the project makes every type main-actor by default, and
/// nothing here runs on the main thread — accept, serve and reply are on
/// their own threads, start and stop on `setupQueue`.
nonisolated final class DesktopCallServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ request: [String: Any]) async -> [String: Any]

    /// `~/.local/state/attache/desktop.sock`, beside what attache-cli keeps.
    /// Fixed rather than `$XDG_STATE_HOME`: a variable set in the owner's
    /// shell is not set for this app, and the two sides must agree.
    static let socketURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/attache", isDirectory: true)
        .appendingPathComponent("desktop.sock")

    /// `~/Library/Logs/Attache/desktop-calls.log`: every call, who made it,
    /// what came back and how long it took.
    static let logURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Attache", isDirectory: true)
        .appendingPathComponent("desktop-calls.log")

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var listener: Int32 = -1
    /// The socket file this instance bound, so `stop` removes only its own
    /// and never one a second copy of the app put there since.
    private var boundInode: ino_t = 0
    /// Where `start` and `stop` run, one after the other: off the main
    /// thread (no file or socket work there, 459bf8a), and in order, so a
    /// start still under way cannot come after the stop.
    private let setupQueue = DispatchQueue(label: "DesktopCallServer.setup")

    func register(_ call: String, _ handler: @escaping Handler) {
        lock.lock()
        handlers[call] = handler
        lock.unlock()
    }

    func start() {
        setupQueue.async { [self] in startNow() }
    }

    private func startNow() {
        lock.lock()
        let running = listener >= 0
        lock.unlock()
        guard !running else { return }
        let path = Self.socketURL.path
        try? FileManager.default.createDirectory(
            at: Self.socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Another copy of the app already answering keeps the socket: taking
        // it over would leave that one deaf with no sign of why.
        if Self.someoneListens(at: path) {
            Self.log("not started: another process already listens on \(path)")
            return
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Self.log("not started: socket() failed, errno \(errno)")
            return
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var addr = Self.address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            Self.log("not started: bind(\(path)) failed, errno \(errno)")
            close(fd)
            return
        }
        // Owner only. The calls are harmless, but nobody else has any
        // business starting the owner's CLIs.
        chmod(path, 0o600)
        var info = stat()
        let inode = stat(path, &info) == 0 ? info.st_ino : 0
        guard listen(fd, 8) == 0 else {
            Self.log("not started: listen failed, errno \(errno)")
            close(fd)
            return
        }
        lock.lock()
        listener = fd
        boundInode = inode
        lock.unlock()
        Self.log("listening on \(path)")
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "DesktopCallServer"
        thread.start()
    }

    /// Called as the app quits, and waited for: one close and one unlink,
    /// so the file is gone before the process is and attache-cli finds
    /// nobody rather than a socket nobody answers.
    func stop() {
        setupQueue.sync { [self] in stopNow() }
    }

    private func stopNow() {
        lock.lock()
        let fd = listener
        let inode = boundInode
        listener = -1
        lock.unlock()
        guard fd >= 0 else { return }
        // Closing the listener ends the blocked accept.
        shutdown(fd, SHUT_RDWR)
        close(fd)
        let path = Self.socketURL.path
        var info = stat()
        if stat(path, &info) == 0, info.st_ino == inode {
            unlink(path)
        }
        Self.log("stopped")
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 {
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(conn, F_SETFD, FD_CLOEXEC)
            // A client gone before the answer must cost a failed write, not
            // the app: SIGPIPE's default is to end the process, and nothing
            // guarantees the app ignores it by the time a call arrives.
            var on: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.serve(conn)
            }
        }
    }

    private func serve(_ conn: Int32) {
        let peer = Self.peerPID(conn)
        // Each read and write waits at most this long, and the whole request
        // has `requestLimit` (in `readLine`): a client that says nothing, or
        // a byte at a time, or never reads its answer, must not hold a thread.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var sendTimeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        let line: Data
        switch Self.readLine(conn) {
        case .closed:
            // Connected and gone without a word: another copy of the app
            // checking whether this one listens. Nothing to answer.
            close(conn)
            return
        case let .failed(why):
            Self.log("peer \(peer): no request (\(why))")
            Self.reply(conn, ["ok": false, "error": "no request: \(why)"])
            return
        case let .line(data):
            line = data
        }
        guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let call = request["call"] as? String
        else {
            Self.log("peer \(peer): unreadable request")
            Self.reply(conn, ["ok": false, "error": "unreadable request"])
            return
        }
        lock.lock()
        let handler = handlers[call]
        lock.unlock()
        guard let handler else {
            Self.log("peer \(peer): \(call): no such call")
            Self.reply(conn, ["ok": false, "error": "no such call: \(call)"])
            return
        }
        let started = Date()
        Self.log("peer \(peer): \(call) \(Self.compact(request))")
        Task.detached {
            let answer = await handler(request)
            let took = String(format: "%.1fs", Date().timeIntervalSince(started))
            Self.log("peer \(peer): \(call) answered in \(took): \(Self.compact(answer))")
            Self.reply(conn, answer)
        }
    }

    // MARK: - Plumbing

    private static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(capacity - 1))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    private static func someoneListens(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = address(path)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return r == 0
    }

    private static func peerPID(_ fd: Int32) -> String {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 else { return "?" }
        return String(pid)
    }

    private enum Request {
        case line(Data)
        /// EOF before a single byte.
        case closed
        case failed(String)
    }

    /// How long a whole request may take to arrive.
    private static let requestLimit: TimeInterval = 10

    /// Up to the first newline, at most 64 KB, within `requestLimit`.
    private static func readLine(_ fd: Int32) -> Request {
        var data = Data()
        var byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(requestLimit)
        while data.count < 64 * 1024 {
            if Date() > deadline { return .failed("too slow") }
            let n = read(fd, &byte, 1)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return .failed("read errno \(errno)")
            }
            if n == 0 { return data.isEmpty ? .closed : .failed("ended mid-line") }
            if byte == UInt8(ascii: "\n") { return .line(data) }
            data.append(byte)
        }
        return .failed("longer than 64 KB")
    }

    private static func reply(_ fd: Int32, _ answer: [String: Any]) {
        var data = (try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                // Gone, or not reading within the send timeout: give up.
                if n <= 0 { break }
                offset += n
            }
        }
        close(fd)
    }

    private static func compact(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "?" }
        return String(decoding: data, as: UTF8.self)
    }

    private static let logQueue = DispatchQueue(label: "DesktopCallServer.log")

    private static let stamp = ISO8601DateFormatter()

    static func log(_ message: String) {
        let at = Date()
        logQueue.async {
            let line = "\(stamp.string(from: at)) [\(getpid())] \(message)\n"
            let url = logURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
