//
//  TranscriptTail.swift
//  Attache
//

import Foundation

/// Tracks how far into a growing file has been read, and decides when what was
/// read no longer applies.
///
/// **Split out of the source so it can be checked without a disk.** Everything
/// hard about following a live transcript is here — the file grows while it is
/// being read, so the last thing in the buffer is usually half a record; it can
/// be truncated; it can be replaced at the same path by something larger. Each
/// of those has a wrong behaviour that is silent, and none of them is
/// reproducible on demand against a real agent.
///
/// Two of the three were shipped wrong in the first build and found by review
/// on 2026-08-01. `Tools/TranscriptTailCheck` is the table; the reading itself
/// is injected, so every case runs with no file system.
struct TranscriptTail {
    /// A file's identity, which is not its path. An atomic replace keeps the
    /// path and changes both of these.
    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    struct Step: Equatable {
        /// Complete lines, newline stripped, in file order.
        var lines: [Data]
        /// Everything read before is about a file that is no longer there. The
        /// caller has to throw away its parsed messages too — and publish the
        /// result even when `lines` is empty, which is the case a truncation
        /// to zero produces.
        var didReset: Bool
    }

    private(set) var offset: UInt64 = 0
    /// A trailing fragment with no newline yet.
    ///
    /// Held as raw `Data`, never decoded, which is what keeps a multi-byte
    /// character split across two reads intact — decoding the fragment on its
    /// own would turn the leading half of a UTF-8 sequence into a replacement
    /// character that no later append can undo.
    private var carry = Data()
    private var identity: FileIdentity?
    /// The last bytes actually consumed, re-checked before advancing. See
    /// `isContinuous`.
    private var fingerprint = Data()
    private static let fingerprintLength = 64

    init() {}

    /// Take the file as it is now and return whatever complete lines are new.
    ///
    /// `read(from:count:)` returns the bytes at that range, or nil if it could
    /// not. Injected so the check tool can drive every case — including ones a
    /// real file system makes hard to stage, like a replacement that is exactly
    /// as long as what was already consumed.
    mutating func advance(
        size: UInt64,
        identity current: FileIdentity?,
        read: (UInt64, Int) -> Data?
    ) -> Step {
        // **No identity, no reading.** Falling back to the size rule looks
        // harmless and is not: consume bytes from a file whose identity is
        // unknown, and the next successful identity becomes the baseline
        // without ever having been compared to anything — so a replacement
        // that happened across that gap is never noticed and the offset stays
        // wrong for the life of the source. Skipping the pass costs one poll
        // interval; guessing costs a conversation spliced from two.
        guard let current else { return Step(lines: [], didReset: false) }

        var didReset = false

        // **Identity first, size second.** Size alone catches only the
        // shrinking cases: a replacement at least as large as what has been
        // consumed passes a size check unchanged, and the read then resumes at
        // an offset that means nothing in the new file — its prefix is skipped,
        // the offset usually lands mid-record so that record is lost too, and
        // everything after is appended to the previous file's messages. What
        // the sidebar shows is then a conversation spliced from two that never
        // happened.
        if let identity, current != identity {
            reset()
            didReset = true
        } else if size < offset {
            // Same file, truncated in place.
            reset()
            didReset = true
        } else if !isContinuous(with: read) {
            // **Identity and size can both be unchanged and the bytes still
            // be different.** Truncate a file to zero and rewrite it past the
            // old offset before the next read: same inode, size no longer
            // below the offset, so neither test above fires and the read
            // resumes in the middle of a file it has never seen. This compares
            // the bytes just before the offset against what was actually
            // consumed there. Found by review 2026-08-01.
            reset()
            didReset = true
        }
        identity = current

        guard size > offset else { return Step(lines: [], didReset: didReset) }

        guard let chunk = read(offset, Int(size - offset)), !chunk.isEmpty else {
            return Step(lines: [], didReset: didReset)
        }
        offset += UInt64(chunk.count)

        var buffer = carry
        buffer.append(chunk)
        carry.removeAll()

        var lines = [Data]()
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            if newline > start { lines.append(Data(buffer[start..<newline])) }
            start = buffer.index(after: newline)
        }
        // No newline yet: a half-written record, or a final line the agent has
        // not terminated. Either way it waits rather than being parsed.
        if start < buffer.endIndex { carry = Data(buffer[start...]) }

        fingerprint = Data(chunk.suffix(Self.fingerprintLength))
        return Step(lines: lines, didReset: didReset)
    }

    /// Are the bytes immediately before the offset still the ones that were
    /// read there?
    ///
    /// The cheapest test that can tell "this file grew" from "this file was
    /// rewritten to the same length". Only the last few bytes are compared:
    /// transcript records are long and unique, so a rewrite matching here and
    /// differing later would have to be a file that genuinely shares that
    /// prefix — in which case resuming is correct anyway.
    private func isContinuous(with read: (UInt64, Int) -> Data?) -> Bool {
        guard offset > 0, !fingerprint.isEmpty else { return true }
        let length = min(UInt64(fingerprint.count), offset)
        guard let actual = read(offset - length, Int(length)) else { return false }
        return actual == fingerprint.suffix(Int(length))
    }

    private mutating func reset() {
        offset = 0
        carry.removeAll()
        fingerprint.removeAll()
    }
}
