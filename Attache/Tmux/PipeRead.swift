//
//  PipeRead.swift
//  Attache
//

import Foundation

extension FileHandle {
    /// Read this handle on a background queue until the writer closes it, then
    /// stop for good.
    ///
    /// Every pipe this app reads goes through here rather than through
    /// `readabilityHandler` directly, because the raw API has one failure mode
    /// that is silent, permanent, and enormous.
    ///
    /// A dispatch read source on a pipe is *permanently readable* once the
    /// write end closes: `read` returns zero bytes immediately, and keeps doing
    /// so. So a handler written the obvious way —
    ///
    ///     handle.readabilityHandler = { handle in
    ///         let data = handle.availableData
    ///         guard !data.isEmpty else { return }   // reads as "nothing to do"
    ///         …
    ///     }
    ///
    /// does not go quiet when the child exits. It is re-entered as fast as the
    /// queue can run it, one saturated core per pipe, until the app is quit.
    /// Measured 2026-08-23 against `/bin/echo`: **1,552,268 calls in the two
    /// seconds after the child exited**, all of them empty. The same day the
    /// live app — up fourteen days, so eight ssh helper channels and one
    /// control client had died and been replaced in the ordinary way, two
    /// pipes each — was sitting at **1313% CPU** with 83% of the whole machine
    /// in the kernel, on nothing but this.
    ///
    /// The repair is one line, and it is exactly the line that is easy not to
    /// write: clearing the handler is what cancels the source. Doing it here
    /// means a new call site cannot leave it out. `Tools/PipeReadCheck` is the
    /// cross-check, and it fails on the unfixed shape as well as passing on
    /// this one.
    ///
    /// `onData` is never called with empty data — empty is EOF and is consumed
    /// here — so a caller has no "no bytes" case left to write.
    func readUntilEOF(_ onData: @escaping (Data) -> Void) {
        readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // Cancels the source, and releases everything the handler
                // captured with it — at both current call sites that includes
                // the `Process`, and so the pipe's file descriptors.
                handle.readabilityHandler = nil
                return
            }
            onData(data)
        }
    }
}
