//
//  PosixChecksum.swift
//  Attache
//

import Foundation

/// The POSIX `cksum` algorithm — CRC-32/CKSUM plus the length, exactly as
/// `/usr/bin/cksum` prints it on every Unix.
///
/// It exists for one job: the remote settings write is a compare-and-swap on
/// *content*. The bytes are read over the helper channel, this token is
/// computed from those exact bytes locally, and the write exec recomputes
/// `cksum < target` on the host and refuses on mismatch — so there is no
/// second read whose timing could pair old content with a new stamp, and no
/// mtime resolution to hide a same-second edit in. POSIX specifies the
/// algorithm, which is what makes the two sides comparable at all;
/// `Tools/HelperCheck` compares this implementation against the system
/// binary on random data.
nonisolated enum PosixChecksum {
    private static let table: [UInt32] = {
        (0 ..< 256).map { index -> UInt32 in
            var crc = UInt32(index) << 24
            for _ in 0 ..< 8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
            return crc
        }
    }()

    /// The two fields `cksum` prints: CRC then byte count, space-separated —
    /// the exact token the write exec compares against.
    static func token(for data: Data) -> String {
        var crc: UInt32 = 0
        for byte in data {
            crc = (crc << 8) ^ table[Int((crc >> 24) ^ UInt32(byte)) & 0xFF]
        }
        var length = UInt64(data.count)
        while length != 0 {
            crc = (crc << 8) ^ table[Int((crc >> 24) ^ UInt32(length & 0xFF)) & 0xFF]
            length >>= 8
        }
        return "\(~crc) \(data.count)"
    }
}
