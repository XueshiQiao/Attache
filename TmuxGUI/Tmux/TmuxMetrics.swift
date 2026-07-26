//
//  TmuxMetrics.swift
//  TmuxGUI
//

import Foundation

/// Throughput and stall measurements for the control mode stream.
///
/// This exists to answer the one question that can kill the whole approach:
/// control mode multiplexes **every** pane in the session down a single pipe,
/// so a pane running an AI agent at full tilt could starve the pane you are
/// actually looking at. Counting bytes is not enough to see that — what
/// matters is the gap between consecutive chunks for the *watched* pane while
/// some other pane floods.
final class TmuxMetrics {
    struct Snapshot {
        var watchedBytes = 0
        var otherBytes = 0
        var watchedChunks = 0
        var otherChunks = 0
        var elapsed: TimeInterval = 0
        /// Longest silence between two chunks of the watched pane.
        var worstGap: TimeInterval = 0
        /// 99th percentile gap — worst case is often a one-off; this is the
        /// number that reflects how the terminal actually feels.
        var p99Gap: TimeInterval = 0
        var medianGap: TimeInterval = 0

        var watchedBytesPerSecond: Double {
            elapsed > 0 ? Double(watchedBytes) / elapsed : 0
        }

        var totalBytesPerSecond: Double {
            elapsed > 0 ? Double(watchedBytes + otherBytes) / elapsed : 0
        }
    }

    private let lock = NSLock()
    private var start = Date()
    private var watchedBytes = 0
    private var otherBytes = 0
    private var watchedChunks = 0
    private var otherChunks = 0
    private var lastWatchedArrival: Date?
    private var gaps = [TimeInterval]()

    /// Cap the gap history so a long-running session cannot grow unbounded.
    /// 200k samples is far more than any measurement run needs and still costs
    /// only a couple of megabytes.
    private let maximumGapSamples = 200_000

    func record(pane: String, watched: Bool, byteCount: Int) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }

        if watched {
            watchedBytes += byteCount
            watchedChunks += 1
            if let last = lastWatchedArrival, gaps.count < maximumGapSamples {
                gaps.append(now.timeIntervalSince(last))
            }
            lastWatchedArrival = now
        } else {
            otherBytes += byteCount
            otherChunks += 1
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        start = Date()
        watchedBytes = 0
        otherBytes = 0
        watchedChunks = 0
        otherChunks = 0
        lastWatchedArrival = nil
        gaps.removeAll(keepingCapacity: true)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        var result = Snapshot()
        result.watchedBytes = watchedBytes
        result.otherBytes = otherBytes
        result.watchedChunks = watchedChunks
        result.otherChunks = otherChunks
        result.elapsed = Date().timeIntervalSince(start)

        guard !gaps.isEmpty else { return result }
        let sorted = gaps.sorted()
        result.worstGap = sorted[sorted.count - 1]
        result.medianGap = sorted[sorted.count / 2]
        // Index clamped so a tiny sample set does not run off the end.
        let p99Index = min(sorted.count - 1, Int(Double(sorted.count) * 0.99))
        result.p99Gap = sorted[p99Index]
        return result
    }
}

extension TmuxMetrics.Snapshot {
    /// One-line summary for the window title.
    var titleSummary: String {
        let watched = Self.formatRate(watchedBytesPerSecond)
        let total = Self.formatRate(totalBytesPerSecond)
        let p99 = String(format: "%.0fms", p99Gap * 1000)
        return "本窗格 \(watched) · 全会话 \(total) · 卡顿 p99 \(p99)"
    }

    /// Multi-line report for the log.
    var report: String {
        """
        ── 控制模式吞吐测量 ──────────────────────
        采样时长        \(String(format: "%.1f", elapsed)) 秒
        本窗格          \(watchedBytes) 字节 / \(watchedChunks) 块  = \(Self.formatRate(watchedBytesPerSecond))
        同会话其它窗格  \(otherBytes) 字节 / \(otherChunks) 块
        全会话合计      \(Self.formatRate(totalBytesPerSecond))
        本窗格到达间隔  中位 \(String(format: "%.1f", medianGap * 1000))ms \
        · p99 \(String(format: "%.1f", p99Gap * 1000))ms \
        · 最差 \(String(format: "%.1f", worstGap * 1000))ms
        ──────────────────────────────────────────
        """
    }

    private static func formatRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
        if bytesPerSecond >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1024)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}
