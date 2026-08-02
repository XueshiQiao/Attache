//
//  main.swift
//  TranscriptTailCheck
//
//  Cross-check for `TranscriptTail`, in the same spirit as
//  `Tools/LinkTargetCheck` — the reading is injected, so every case runs with
//  no file system and the answers do not depend on the machine.
//
//      swiftc -O -o /tmp/tailcheck \
//          Attache/Conversation/TranscriptTail.swift \
//          Tools/TranscriptTailCheck/main.swift
//      /tmp/tailcheck
//
//  This is the state machine between "the file changed" and "here are the new
//  records", and every way it fails is silent. It reads a file that is being
//  written, so the tail is routinely half a record; the file can be truncated;
//  it can be replaced at the same path by a *larger* file. Two of those three
//  were wrong in the first build and neither showed any symptom short of a
//  conversation that looked subtly wrong.
//

import Foundation

// MARK: - A file that can be rewritten under the reader

/// Stands in for the disk. Holds bytes and an identity, and hands out ranges
/// the way a real read would — including the case where the range asked for
/// runs past the end.
final class FakeFile {
    private(set) var bytes: Data
    private(set) var identity: TranscriptTail.FileIdentity

    init(_ text: String, inode: UInt64 = 1) {
        bytes = Data(text.utf8)
        identity = TranscriptTail.FileIdentity(device: 1, inode: inode)
    }

    var size: UInt64 { UInt64(bytes.count) }

    func append(_ text: String) { bytes.append(Data(text.utf8)) }
    func appendRaw(_ data: Data) { bytes.append(data) }

    /// Truncate in place — same file, fewer bytes.
    func truncate(to count: Int) { bytes = bytes.prefix(count) }

    /// Replace at the same path: new identity, arbitrary contents.
    func replace(with text: String, inode: UInt64) {
        bytes = Data(text.utf8)
        identity = TranscriptTail.FileIdentity(device: 1, inode: inode)
    }

    func read(from offset: UInt64, count: Int) -> Data? {
        guard offset <= size else { return nil }
        let start = Int(offset)
        let end = min(bytes.count, start + count)
        guard start < end else { return nil }
        return bytes.subdata(in: start..<end)
    }
}

func step(_ tail: inout TranscriptTail, _ file: FakeFile) -> TranscriptTail.Step {
    tail.advance(size: file.size, identity: file.identity, read: file.read)
}

func text(_ lines: [Data]) -> [String] {
    lines.map { String(decoding: $0, as: UTF8.self) }
}

var failures = 0
func check(_ what: String, _ actual: some Equatable, _ expected: some Equatable) {
    guard "\(actual)" != "\(expected)" else { return }
    failures += 1
    print("FAIL  \(what)")
    print("      expected \(expected)")
    print("      actual   \(actual)")
}

// MARK: - Ordinary growth

do {
    let file = FakeFile("a\nb\n")
    var tail = TranscriptTail()
    check("first read yields both lines", text(step(&tail, file).lines), ["a", "b"])
    check("nothing new yields nothing", text(step(&tail, file).lines), [String]())

    file.append("c\n")
    check("an append yields only the new line", text(step(&tail, file).lines), ["c"])
}

// MARK: - Half-written records
//
// The normal case, not an edge case: the agent is writing while this reads.

do {
    let file = FakeFile("full\npar")
    var tail = TranscriptTail()
    check("a fragment is withheld", text(step(&tail, file).lines), ["full"])

    file.append("tial\n")
    check("and completed on the next pass", text(step(&tail, file).lines), ["partial"])
}

do {
    // A multi-byte character split across two reads. Decoding the fragment on
    // its own would replace the leading half with U+FFFD permanently.
    let full = Data("研究\n".utf8)
    let file = FakeFile("")
    file.appendRaw(full.prefix(4))          // 研 + first byte of 究
    var tail = TranscriptTail()
    check("a split code point yields no line yet", text(step(&tail, file).lines), [String]())

    file.appendRaw(full.dropFirst(4))
    check("and survives the join intact", text(step(&tail, file).lines), ["研究"])
}

do {
    let file = FakeFile("a\n\n\nb\n")
    var tail = TranscriptTail()
    check("blank lines are not records", text(step(&tail, file).lines), ["a", "b"])
}

// MARK: - Truncation
//
// Same file, fewer bytes.

do {
    let file = FakeFile("one\ntwo\nthree\n")
    var tail = TranscriptTail()
    _ = step(&tail, file)

    file.truncate(to: 0)
    let after = step(&tail, file)
    check("TRUNCATED TO EMPTY reports a reset", after.didReset, true)
    check("TRUNCATED TO EMPTY yields no lines", text(after.lines), [String]())

    file.append("fresh\n")
    check("and then reads the new file from its start", text(step(&tail, file).lines), ["fresh"])
}

do {
    let file = FakeFile("one\ntwo\nthree\n")
    var tail = TranscriptTail()
    _ = step(&tail, file)

    file.truncate(to: 4)                    // just "one\n"
    let after = step(&tail, file)
    check("a partial truncation resets", after.didReset, true)
    check("and re-reads what is left", text(after.lines), ["one"])
}

// MARK: - Replacement at the same path
//
// The finding that made this file exist. A size check alone passes every one
// of these unchanged.

do {
    let file = FakeFile("aaa\nbbb\n", inode: 1)     // 8 bytes
    var tail = TranscriptTail()
    _ = step(&tail, file)

    file.replace(with: "xxx\nyyy\n", inode: 2)      // 8 bytes — exactly the same size
    let after = step(&tail, file)
    check("REPLACED, SAME SIZE reports a reset", after.didReset, true)
    check("REPLACED, SAME SIZE reads the new file whole", text(after.lines), ["xxx", "yyy"])
}

do {
    let file = FakeFile("aaa\nbbb\n", inode: 1)     // 8 bytes
    var tail = TranscriptTail()
    _ = step(&tail, file)

    file.replace(with: "xxx\nyyy\nzzz\n", inode: 2) // 12 bytes — larger
    let after = step(&tail, file)
    check("REPLACED, LARGER reports a reset", after.didReset, true)
    check("REPLACED, LARGER loses nothing off the front", text(after.lines), ["xxx", "yyy", "zzz"])
}

do {
    let file = FakeFile("aaa\nbbb\nccc\n", inode: 1)
    var tail = TranscriptTail()
    _ = step(&tail, file)

    file.replace(with: "x\n", inode: 2)             // smaller
    let after = step(&tail, file)
    check("REPLACED, SMALLER resets too", after.didReset, true)
    check("REPLACED, SMALLER reads the new file", text(after.lines), ["x"])
}

do {
    // A replacement whose length happens to leave the old offset mid-record.
    // Without an identity check the read starts there and the record is lost.
    let file = FakeFile("aaaa\n", inode: 1)         // 5 bytes consumed
    var tail = TranscriptTail()
    _ = step(&tail, file)

    file.replace(with: "first-record-here\nsecond\n", inode: 2)
    let after = step(&tail, file)
    check(
        "REPLACED, offset would land mid-record — nothing is spliced",
        text(after.lines), ["first-record-here", "second"]
    )
}

// MARK: - Same file, rewritten in place
//
// Identity unchanged, size unchanged or larger, and the bytes different
// anyway. Neither the identity test nor the size test sees it.
// Found by review 2026-08-01.

do {
    let file = FakeFile("aaaa\nbbbb\n", inode: 1)   // 10 bytes consumed
    var tail = TranscriptTail()
    _ = step(&tail, file)

    // Truncate to nothing and rewrite past the old offset, same inode, before
    // the next read. A size check sees 14 > 10 and reads from byte 10.
    file.truncate(to: 0)
    file.append("wwww\nxxxx\nyyyy\n")               // 15 bytes
    let after = step(&tail, file)
    check("REWRITTEN IN PLACE reports a reset", after.didReset, true)
    check("REWRITTEN IN PLACE reads it whole", text(after.lines), ["wwww", "xxxx", "yyyy"])
}

do {
    // The same shape, but the rewrite happens to be exactly as long as what
    // was consumed — nothing about size or identity differs at all.
    let file = FakeFile("aaaa\nbbbb\n", inode: 1)
    var tail = TranscriptTail()
    _ = step(&tail, file)

    file.truncate(to: 0)
    file.append("wwww\nxxxx\n")                     // same 10 bytes
    let after = step(&tail, file)
    check("REWRITTEN TO THE SAME LENGTH still resets", after.didReset, true)
    check("and yields the new content", text(after.lines), ["wwww", "xxxx"])
}

do {
    // The continuity check must not fire on ordinary growth, or every append
    // would re-read the whole file.
    let file = FakeFile("aaaa\nbbbb\n", inode: 1)
    var tail = TranscriptTail()
    _ = step(&tail, file)
    file.append("cccc\n")
    let after = step(&tail, file)
    check("ordinary growth does not report a reset", after.didReset, false)
    check("and yields only what is new", text(after.lines), ["cccc"])
}

do {
    // Growth larger than the fingerprint window, repeatedly — the fingerprint
    // has to follow the offset, not stay at the first read.
    let file = FakeFile("", inode: 1)
    var tail = TranscriptTail()
    for round in 0..<6 {
        file.append(String(repeating: "z", count: 200) + "-\(round)\n")
        let after = step(&tail, file)
        check("round \(round) is not a reset", after.didReset, false)
        check("round \(round) yields one line", after.lines.count, 1)
    }
}

// MARK: - Identity unavailable
//
// `fstat` failed. Consuming bytes anyway means the next successful identity
// becomes the baseline without ever being compared, so a replacement across
// that gap is never noticed. Found by review 2026-08-01.

do {
    let file = FakeFile("a\nb\n")
    var tail = TranscriptTail()
    let first = tail.advance(size: file.size, identity: nil, read: file.read)
    check("NO IDENTITY yields nothing rather than guessing", text(first.lines), [String]())
    check("NO IDENTITY is not reported as a reset", first.didReset, false)

    // The next pass, with an identity, reads the file from its start — nothing
    // was consumed while it was unknown.
    let second = step(&tail, file)
    check("and the retry reads it whole", text(second.lines), ["a", "b"])
}

do {
    // The dangerous sequence: read A with no identity, A is replaced by a
    // larger B, then identity works again.
    let file = FakeFile("aaa\nbbb\n", inode: 1)
    var tail = TranscriptTail()
    _ = tail.advance(size: file.size, identity: nil, read: file.read)

    file.replace(with: "xxx\nyyy\nzzz\n", inode: 2)
    let after = step(&tail, file)
    check("a replacement across an unknown-identity gap loses nothing",
          text(after.lines), ["xxx", "yyy", "zzz"])
}

do {
    // The first read has no previous identity to compare against, so it must
    // not report a reset — the caller would publish an empty snapshot over a
    // conversation it had just been handed.
    let file = FakeFile("a\n")
    var tail = TranscriptTail()
    check("the first read is not a reset", step(&tail, file).didReset, false)
}

// MARK: - Result

if failures == 0 {
    print("TranscriptTailCheck: all cases pass")
} else {
    print("TranscriptTailCheck: \(failures) failed")
    exit(1)
}
