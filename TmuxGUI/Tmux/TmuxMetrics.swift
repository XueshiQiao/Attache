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

        /// Bytes over the last few whole seconds, and the span they cover.
        ///
        /// Kept separate from the cumulative counters because the two answer
        /// different questions. The probe controls its own measurement window
        /// and wants the total across it; a footer that redraws once a second
        /// is read as "what is happening now", and a lifetime average says
        /// nothing about now — a session that streamed hard for a minute at
        /// launch and has been quiet since still reads as busy forever.
        var recentWatchedBytes = 0
        var recentOtherBytes = 0
        var recentSpan: TimeInterval = 0

        // Lifetime rates — `watchedBytesPerSecond`, `totalBytesPerSecond` —
        // went with the report that was their only caller. The counters they
        // divided are still here because the probe reads them, but an average
        // over the whole connection answers no question anyone asks: the footer
        // wants the last two seconds and the probe wants its own window.

        var recentWatchedBytesPerSecond: Double {
            recentSpan > 0 ? Double(recentWatchedBytes) / recentSpan : 0
        }

        var recentTotalBytesPerSecond: Double {
            recentSpan > 0 ? Double(recentWatchedBytes + recentOtherBytes) / recentSpan : 0
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

    /// One bucket per whole second of recent history. Buckets rather than a
    /// list of arrival times because this is the hot path — every `%output`
    /// chunk lands here, measured at 19 MB/s — and an array of timestamps
    /// would grow far faster than anything reads it. At most `recentSeconds`
    /// plus the second in progress are ever held.
    private var buckets = [(second: Int, watched: Int, other: Int)]()

    /// Two seconds, and the length is the whole design.
    ///
    /// This is a trailing average, so it under-reports a burst that has been
    /// running for less time than the window — measured with a 5 second
    /// window, three seconds of steady 100 KB/s read as 78 KB/s, which is
    /// arithmetically right and not what a footer redrawing every second is
    /// taken to mean. Two seconds is long enough that a chunky stream does not
    /// make the number jump between redraws and short enough that it is about
    /// now.
    ///
    /// The same arithmetic makes the first two seconds after attaching, or
    /// after the probe resets the counters, read low — there are not two whole
    /// seconds of history to divide by yet. Left as it is: it corrects itself
    /// within two redraws, and reading low is the failure that does not invent
    /// throughput that was not there.
    private let recentSeconds = 2

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

        // Matched by value rather than by taking the last bucket. The clock
        // here is the wall clock, and a backward step — an NTP correction, or
        // someone setting the date — would otherwise open a second bucket for
        // a second already in the array and have the readout count both.
        let second = Self.wholeSecond(now)
        if let index = buckets.firstIndex(where: { $0.second == second }) {
            if watched { buckets[index].watched += byteCount } else { buckets[index].other += byteCount }
        } else {
            buckets.append((second, watched ? byteCount : 0, watched ? 0 : byteCount))
            while buckets.count > recentSeconds + 1 { buckets.removeFirst() }
        }
    }

    private static func wholeSecond(_ date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate)
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
        buckets.removeAll(keepingCapacity: true)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        var result = Snapshot()
        result.watchedBytes = watchedBytes
        result.otherBytes = otherBytes
        result.watchedChunks = watchedChunks
        result.otherChunks = otherChunks
        result.elapsed = now.timeIntervalSince(start)

        // Whole seconds only, and never the one in progress: a partial second
        // in the numerator against a full second in the denominator would show
        // a steady stream as fluctuating by up to the poll interval. Buckets
        // are filtered by their own timestamp rather than by position, because
        // a pane that has been silent for an hour still has its last bucket
        // sitting there and it must not count as recent.
        let wholeSecondsSinceStart = Int(result.elapsed)
        let span = max(1, min(recentSeconds, wholeSecondsSinceStart))
        let currentSecond = Self.wholeSecond(now)
        for bucket in buckets where bucket.second >= currentSecond - span && bucket.second < currentSecond {
            result.recentWatchedBytes += bucket.watched
            result.recentOtherBytes += bucket.other
        }
        result.recentSpan = TimeInterval(span)

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
    /// One-line summary for the sidebar footer, describing the last few
    /// seconds rather than everything since the connection attached.
    ///
    /// It used to carry a `stall p99` figure and that number could not be
    /// made to mean anything. A gap between two chunks is only a stall if the
    /// pane had something to send during it, and nothing on this side of the
    /// pipe can tell "the pipe was busy" from "the program had nothing to
    /// print" — so a pane left alone for a minute reported a p99 stall of a
    /// minute. Gating it on recent activity does not fix that either: a pane
    /// that printed a moment ago and then genuinely went quiet still
    /// contributes its silence as latency.
    ///
    /// The gap statistics are still measured and still mean something in the
    /// one place that constructs a source emitting at a known constant rate —
    /// the A/B throughput probe, where the watched pane is a heartbeat
    /// printing every 50ms and any gap beyond that really is the pipe. Here,
    /// saying nothing beats saying something wrong.
    var titleSummary: String {
        guard recentWatchedBytes > 0 || recentOtherBytes > 0 else { return "idle" }
        let watched = Self.formatRate(recentWatchedBytesPerSecond)
        let total = Self.formatRate(recentTotalBytesPerSecond)
        return "pane \(watched) · session \(total)"
    }

    // A multi-line `report` used to live here and was deleted rather than
    // fixed. Nothing called it — the sidebar footer takes `titleSummary` and
    // the probe formats its own comparison — and what it printed was the
    // problem: the arrival gap statistics laid out as a general-purpose
    // readout, which is the reading `titleSummary` above exists to refuse. A
    // gap only means latency when something was waiting to be sent, and the
    // one place that is true by construction is the A/B probe's heartbeat. It
    // already renders them, in `TmuxSessionConnection.compare(baseline:loaded:)`,
    // next to the baseline that gives them a scale.

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
