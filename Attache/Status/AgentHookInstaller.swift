//
//  AgentHookInstaller.swift
//  Attache
//

import Foundation

/// Coordinates hook installation across all supported coding agents
/// (`ClaudeHookProvider`, `AntigravityHookProvider`, `GrokHookProvider`) and
/// stages the standalone `attache-agent-hub` receiver executable to
/// `~/.config/attache/bin/attache-agent-hub`.
///
/// Safety invariants for every shared configuration file we touch:
/// - **Validate every target file before writing any of them**, so a malformed
///   config in one agent aborts the batch cleanly without leaving a half-installed
///   machine behind.
/// - **Back up raw bytes beside the resolved target** (never `copyItem` on a
///   symlink, which copies the link rather than snapshotting the target).
/// - **Preserve symlinks and POSIX permissions** (`~/.claude/settings.json` is
///   commonly a dotfiles symlink; `~/.gemini/config/hooks.json` is `0600`).
/// - **Refuse concurrent modifications** via double-stamped reads (`readAt`).
enum AgentHookInstaller {
    /// Claude Code's settings file — retained as a named property because
    /// `AgentStatusLineInstaller` edits the `statusLine` key in the same file
    /// through the shared I/O primitives below.
    static var settingsURL: URL {
        ClaudeHookProvider().configURL(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Stable host path every installed hook invokes (`~/.config/attache/bin/attache-agent-hub`).
    static var scriptURL: URL {
        AgentHubConstants.installedExecutableURL()
    }

    /// Compiled `attache-agent-hub` Mach-O binary embedded inside
    /// `Attaché.app/Contents/MacOS/attache-agent-hub`.
    static var bundledHubURL: URL? {
        guard let mainExec = Bundle.main.executableURL else { return nil }
        let sibling = mainExec
            .deletingLastPathComponent()
            .appendingPathComponent(AgentHubConstants.executableName)
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    static let scriptVersion = AgentHubConstants.version
    static let script = AgentHubPortableScript.script

    enum Failure: LocalizedError {
        case unreadableSettings(String)
        case unexpectedShape(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadableSettings(let detail):
                detail
            case .unexpectedShape(let detail):
                detail
            case .writeFailed(let detail):
                detail
            }
        }
    }

    struct ProviderStatus: Equatable {
        let kind: ManagedAgentKind
        let configURL: URL
        let isAgentPresent: Bool
        let isInstalled: Bool
        let isUpToDate: Bool
    }

    // MARK: - Inspecting installed state

    private static let statusCacheLock = NSLock()
    nonisolated(unsafe) private static var cachedStatuses: [ProviderStatus]?
    nonisolated(unsafe) private static var cachedStatusesAt: Date = .distantPast
    nonisolated(unsafe) private static var statusRefreshInFlight = false
    private static let statusCacheTTL: TimeInterval = 15

    static func invalidateStatusCache() {
        statusCacheLock.lock()
        cachedStatuses = nil
        cachedStatusesAt = .distantPast
        statusCacheLock.unlock()
    }

    private static func computeProviderStatuses(
        home: URL,
        environment: [String: String]
    ) -> [ProviderStatus] {
        let hubPath = AgentHubConstants.installedExecutablePath(home: home.path)
        return AgentHookCatalog.providers.map { provider in
            let url = provider.configURL(home: home, environment: environment)
            let present = provider.isAgentPresent(home: home, environment: environment)
            let root = (try? loadJSONObject(at: url)) ?? [:]
            let installed = provider.hasAnyInstalledEntry(in: root, hubPath: hubPath)
            let current = provider.isUpToDate(in: root, hubPath: hubPath)
            return ProviderStatus(
                kind: provider.kind,
                configURL: url,
                isAgentPresent: present,
                isInstalled: installed,
                isUpToDate: current
            )
        }
    }

    static func providerStatuses(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ProviderStatus] {
        let defaultHome = FileManager.default.homeDirectoryForCurrentUser
        guard home == defaultHome else {
            return computeProviderStatuses(home: home, environment: environment)
        }
        let now = Date()
        statusCacheLock.lock()
        if let cached = cachedStatuses {
            let expired = now.timeIntervalSince(cachedStatusesAt) >= statusCacheTTL
            let shouldRefresh = expired && !statusRefreshInFlight
            if shouldRefresh { statusRefreshInFlight = true }
            statusCacheLock.unlock()
            if shouldRefresh {
                DispatchQueue.global(qos: .utility).async {
                    let fresh = computeProviderStatuses(home: home, environment: environment)
                    statusCacheLock.lock()
                    cachedStatuses = fresh
                    cachedStatusesAt = Date()
                    statusRefreshInFlight = false
                    statusCacheLock.unlock()
                }
            }
            return cached
        }
        statusCacheLock.unlock()

        let computed = computeProviderStatuses(home: home, environment: environment)
        statusCacheLock.lock()
        cachedStatuses = computed
        cachedStatusesAt = Date()
        statusCacheLock.unlock()
        return computed
    }

    /// Providers that belong on this machine: every agent detected on disk or
    /// `PATH`, plus any agent whose config already carries our entries (with
    /// Claude Code always included as the baseline fallback).
    private static func activeProviders(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [any AgentHookProvider] {
        let hubPath = AgentHubConstants.installedExecutablePath(home: home.path)
        let matched = AgentHookCatalog.providers.filter { provider in
            if provider.isAgentPresent(home: home, environment: environment) { return true }
            let url = provider.configURL(home: home, environment: environment)
            let root = (try? loadJSONObject(at: url)) ?? [:]
            return provider.hasAnyInstalledEntry(in: root, hubPath: hubPath)
        }
        return matched.isEmpty ? [ClaudeHookProvider()] : matched
    }

    static func isInstalled() -> Bool {
        providerStatuses().contains(where: \.isInstalled)
    }

    static func isInstalled(forKind rawKind: String?) -> Bool {
        guard let rawKind else { return isInstalled() }
        let normalized = rawKind == "antigravity" ? "agy" : rawKind
        guard let managed = ManagedAgentKind(rawValue: normalized) else {
            return isInstalled()
        }
        return providerStatuses().first(where: { $0.kind == managed })?.isInstalled ?? false
    }

    static func isUpToDate() -> Bool {
        let statuses = providerStatuses()
        let active = statuses.filter { $0.isAgentPresent || $0.isInstalled }
        let targetList = active.isEmpty ? statuses.filter { $0.kind == .claude } : active
        guard !targetList.isEmpty, targetList.allSatisfy(\.isUpToDate) else {
            return false
        }
        return isStagedHubBinaryCurrent()
    }

    static func statusSummary() -> String {
        let statuses = providerStatuses()
        let active = statuses.filter { $0.isAgentPresent || $0.isInstalled }
        let installedNames = active.filter(\.isInstalled).map(\.kind.displayName)
        let pendingNames = active.filter { !$0.isInstalled }.map(\.kind.displayName)

        if installedNames.isEmpty {
            let detected = active.map(\.kind.displayName)
            if detected.isEmpty {
                return "Agents are detected, but not what they are doing"
            }
            return "\( englishList(detected) ) detected — install hooks to report state"
        }

        if pendingNames.isEmpty && isUpToDate() {
            let verb = installedNames.count == 1 ? "reports its state" : "report their state"
            return "\(englishList(installedNames)) \(verb)"
        }

        if !pendingNames.isEmpty {
            return "\(englishList(installedNames)) installed · \(englishList(pendingNames)) ready to add"
        }

        return "\(englishList(installedNames)) installed · update available"
    }

    nonisolated static func same(_ a: Any?, _ b: Any?) -> Bool {
        AgentJSONStructural.same(a, b)
    }

    /// Exact preview of every file an install or update will touch.
    static func plannedAdditions(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let hubPath = AgentHubConstants.installedExecutablePath(home: home.path)
        var sections = [String]()
        for provider in activeProviders(home: home, environment: environment) {
            let url = provider.configURL(home: home, environment: environment)
            let root = try loadJSONObject(at: url)
            let display = abbreviateHome(url.path, home: home.path)
            let diff = try provider.previewDiff(from: root, hubPath: hubPath, displayPath: display)
            if !diff.isEmpty {
                sections.append(diff)
            }
        }
        if sections.isEmpty, isInstalled(), !isStagedHubBinaryCurrent() {
            let display = abbreviateHome(hubPath, home: home.path)
            sections.append("Update receiver binary at \(display) to version \(scriptVersion).")
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Install, refresh, and uninstall

    /// Stages `attache-agent-hub` and installs/updates hooks for all detected
    /// agents on this machine. Returns the backup files created.
    @discardableResult
    static func install(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [URL] {
        let providers = activeProviders(home: home, environment: environment)
        let hubURL = AgentHubConstants.installedExecutableURL(home: home)
        let hubPath = hubURL.path

        // Phase 1: read + validate every target file before modifying anything
        // on disk.
        struct Prepared {
            let provider: any AgentHookProvider
            let url: URL
            let original: [String: Any]
            let merged: [String: Any]
            let readAt: Date?
        }

        var prepared = [Prepared]()
        for provider in providers {
            let url = provider.configURL(home: home, environment: environment)
            let (root, readAt) = try loadJSONObjectVerifying(at: url)
            do {
                try provider.validateShape(root, path: url.path)
            } catch {
                throw Failure.unexpectedShape(error.localizedDescription)
            }
            let merged = provider.merge(into: root, hubPath: hubPath)
            prepared.append(Prepared(
                provider: provider, url: url, original: root, merged: merged, readAt: readAt
            ))
        }

        // Phase 2: stage the standalone receiver executable before hooks point
        // to it, so no window exists where a firing hook finds a missing file.
        try stageHubExecutable(to: hubURL)

        // Phase 3: back up and write only the files whose contents actually move.
        var backups = [URL]()
        for item in prepared where !same(item.original, item.merged) {
            if let backup = try backUpFile(at: item.url) {
                backups.append(backup)
            }
            try writeJSONObject(
                item.merged,
                to: item.url,
                readAt: item.readAt,
                removeWhenEmpty: false
            )
            TmuxLog.destructive("installed \(item.provider.kind.rawValue) hooks into \(item.url.path)")
        }
        invalidateStatusCache()
        return backups
    }

    /// Removes Attaché's hook entries from every provider config that carries
    /// them. Returns the backup files created.
    @discardableResult
    static func uninstall(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [URL] {
        let hubPath = AgentHubConstants.installedExecutablePath(home: home.path)

        struct Prepared {
            let provider: any AgentHookProvider
            let url: URL
            let cleaned: [String: Any]
            let readAt: Date?
        }

        var prepared = [Prepared]()
        for provider in AgentHookCatalog.providers {
            let url = provider.configURL(home: home, environment: environment)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let (root, readAt) = try loadJSONObjectVerifying(at: url)
            guard provider.hasAnyInstalledEntry(in: root, hubPath: hubPath) else { continue }
            do {
                try provider.validateShape(root, path: url.path)
            } catch {
                throw Failure.unexpectedShape(error.localizedDescription)
            }
            let cleaned = provider.unmerge(from: root, hubPath: hubPath)
            prepared.append(Prepared(
                provider: provider, url: url, cleaned: cleaned, readAt: readAt
            ))
        }

        var backups = [URL]()
        for item in prepared {
            if let backup = try backUpFile(at: item.url) {
                backups.append(backup)
            }
            try writeJSONObject(
                item.cleaned,
                to: item.url,
                readAt: item.readAt,
                removeWhenEmpty: item.provider.removeFileWhenEmpty
            )
            TmuxLog.destructive("removed \(item.provider.kind.rawValue) hooks from \(item.url.path)")
        }
        invalidateStatusCache()
        return backups
    }

    /// Keeps `~/.config/attache/bin/attache-agent-hub` aligned with the
    /// currently running `Attaché.app` bundle whenever hooks are already
    /// installed. Touches only Attaché's own binary directory, never any
    /// agent's settings file.
    static func refreshInstalledHubBinaryIfNeeded() {
        guard isInstalled(), !isStagedHubBinaryCurrent() else { return }
        try? stageHubExecutable(to: scriptURL)
    }

    private static func isStagedHubBinaryCurrent() -> Bool {
        let destination = scriptURL
        guard FileManager.default.isExecutableFile(atPath: destination.path) else { return false }
        if let bundled = bundledHubURL,
           let bundledBytes = try? Data(contentsOf: bundled),
           let installedBytes = try? Data(contentsOf: destination)
        {
            return bundledBytes == installedBytes
        }
        return true
    }

    private static func stageHubExecutable(to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let tmp = directory.appendingPathComponent(".\(AgentHubConstants.executableName).tmp-\(getpid())")
            if let bundled = bundledHubURL {
                let bytes = try Data(contentsOf: bundled)
                try bytes.write(to: tmp, options: [.atomic])
            } else {
                try Data(AgentHubPortableScript.script.utf8).write(to: tmp, options: [.atomic])
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tmp.path
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: destination)
            }
        } catch {
            throw Failure.writeFailed(
                "the receiver binary at \(destination.path) could not be written — \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Pure Claude transforms (shared with HookInstallCheck & RemoteAgentSetup)

    static var events: [(event: String, matcher: String?, eventArg: String)] {
        ClaudeHookProvider.specs.map { ($0.event, $0.matcher, $0.eventArg) }
    }

    static func merge(
        intoSettings settings: [String: Any], scriptPath: String? = nil
    ) -> [String: Any] {
        ClaudeHookProvider().merge(into: settings, hubPath: scriptPath ?? scriptURL.path)
    }

    static func unmerge(
        fromSettings settings: [String: Any], scriptPath: String? = nil
    ) -> [String: Any] {
        ClaudeHookProvider().unmerge(from: settings, hubPath: scriptPath ?? scriptURL.path)
    }

    static func validateShape(_ settings: [String: Any]) throws {
        do {
            try ClaudeHookProvider().validateShape(settings, path: settingsURL.path)
        } catch let err as AgentHookConfigFailure {
            throw Failure.unexpectedShape(err.localizedDescription)
        }
    }

    // MARK: - Generic symlink-safe, CAS-guarded JSON file primitives

    static func loadJSONObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw Failure.unreadableSettings(
                "Could not read \(url.path) — \(error.localizedDescription). Nothing was changed."
            )
        }
        guard !data.isEmpty else { return [:] }
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: data) } catch {
            throw Failure.unreadableSettings(
                "Could not read \(url.path) — it is not valid JSON (\(error.localizedDescription)). Nothing was changed."
            )
        }
        guard let object = parsed as? [String: Any] else {
            throw Failure.unexpectedShape(
                "\(url.path) is not shaped the way Attaché expects — the top level is not an object. Nothing was changed."
            )
        }
        return object
    }

    static func resolvedURL(for url: URL) -> URL {
        url.resolvingSymlinksInPath()
    }

    static func modificationDate(of url: URL) -> Date? {
        let resolved = resolvedURL(for: url)
        return (try? FileManager.default.attributesOfItem(atPath: resolved.path))?[
            .modificationDate
        ] as? Date
    }

    static func loadJSONObjectVerifying(at url: URL) throws -> ([String: Any], Date?) {
        for _ in 0 ..< 3 {
            let before = modificationDate(of: url)
            let object = try loadJSONObject(at: url)
            let after = modificationDate(of: url)
            if before == after { return (object, after) }
        }
        throw Failure.writeFailed(
            "\(url.path) kept changing while it was being read — nothing was written."
                + " Close whatever is editing it and try again."
        )
    }

    static func backUpFile(at url: URL) throws -> URL? {
        let source = resolvedURL(for: url)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")

        let directory = source.deletingLastPathComponent()
        let baseName = source.lastPathComponent
        var backup = directory.appendingPathComponent("\(baseName).tmuxgui-backup-\(stamp)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: backup.path), suffix < 100 {
            backup = directory.appendingPathComponent(
                "\(baseName).tmuxgui-backup-\(stamp)-\(suffix)"
            )
            suffix += 1
        }

        do {
            let existingMode = (try? FileManager.default.attributesOfItem(atPath: source.path))?[
                .posixPermissions
            ] as? NSNumber
            let contents = try Data(contentsOf: source)
            try contents.write(to: backup, options: [.atomic])
            if let existingMode {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: existingMode], ofItemAtPath: backup.path
                )
            }
            return backup
        } catch {
            throw Failure.writeFailed(
                "the backup for \(source.path) could not be made — \(error.localizedDescription)"
            )
        }
    }

    static func writeJSONObject(
        _ object: [String: Any],
        to url: URL,
        readAt: Date?,
        removeWhenEmpty: Bool
    ) throws {
        let now = modificationDate(of: url)
        if now != readAt {
            throw Failure.writeFailed(
                "\(url.path) changed while this was being prepared — nothing was written."
                    + " Close whatever edited it and try again."
            )
        }

        let target = resolvedURL(for: url)
        if removeWhenEmpty && object.isEmpty {
            if FileManager.default.fileExists(atPath: target.path) {
                do {
                    try FileManager.default.removeItem(at: target)
                } catch {
                    throw Failure.writeFailed(error.localizedDescription)
                }
            }
            return
        }

        let existingMode = (try? FileManager.default.attributesOfItem(atPath: target.path))?[
            .posixPermissions
        ] as? NSNumber

        let data: Data
        do {
            var encoded = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            encoded.append(0x0A)
            data = encoded
        } catch {
            throw Failure.writeFailed(
                "the merged settings for \(url.path) could not be encoded — \(error.localizedDescription)"
            )
        }

        do {
            let directory = target.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try data.write(to: target, options: [.atomic])
            if let existingMode {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: existingMode], ofItemAtPath: target.path
                )
            }
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Claude settings aliases used by `AgentStatusLineInstaller`

    static func loadSettings() throws -> [String: Any] {
        try loadJSONObject(at: settingsURL)
    }

    static func resolvedSettingsURL() -> URL {
        resolvedURL(for: settingsURL)
    }

    static func backUpSettings() throws -> URL {
        if let backup = try backUpFile(at: settingsURL) {
            return backup
        }
        let source = resolvedSettingsURL()
        return source.deletingLastPathComponent()
            .appendingPathComponent("settings.json.tmuxgui-backup-new")
    }

    static func settingsModified() -> Date? {
        modificationDate(of: settingsURL)
    }

    static func loadSettingsVerifying() throws -> ([String: Any], Date?) {
        try loadJSONObjectVerifying(at: settingsURL)
    }

    static func writeSettings(_ settings: [String: Any], readAt: Date?) throws {
        try writeJSONObject(settings, to: settingsURL, readAt: readAt, removeWhenEmpty: false)
    }

    // MARK: - Formatting helpers

    private static func abbreviateHome(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private static func englishList(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }
}
