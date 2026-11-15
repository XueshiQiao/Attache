//
//  MermaidCommand.swift
//  Attache
//

import CryptoKit
import Foundation

/// `attache-cli mermaid`: what is asked and how the answer is read.
///
/// The drawing is attache-cli's — layout and pixels — so that the phone shows
/// the same picture and so that this app needs nothing but an image view
/// (`cli/src/mermaid.rs`; no web view may draw it, CLAUDE.md).
nonisolated enum MermaidCommand {
    /// What became of one request.
    ///
    /// Three outcomes and not two, and the third is the reason this type
    /// exists. `refused` is attache-cli saying the source cannot be drawn —
    /// true of that source forever, so it is kept and the block stays code.
    /// `unanswered` is everything else: ssh dropped, the command timed out,
    /// an attache-cli from before `mermaid` printed its usage and no line.
    /// None of those says anything about the source, and keeping one as a
    /// refusal would leave a good diagram as code for as long as the app
    /// runs, on the strength of one bad second on the network.
    enum Answer: Equatable {
        /// The PNG, and its size in points.
        case picture(Data, width: Double, height: Double)
        case refused(String)
        case unanswered
    }

    /// Larger than this is refused by attache-cli anyway (64 KB); not asking
    /// keeps a huge block off an ssh command line.
    static let maxSource = 64 * 1024

    /// `--inline`: the PNG comes back in the answer itself, which this app
    /// reads straight off a process. (The phone asks for a path instead and
    /// fetches the file.)
    static func argv(source: String, dark: Bool, scale: Int) -> [String]? {
        let bytes = Data(source.utf8)
        guard !bytes.isEmpty, bytes.count <= maxSource, (1...4).contains(scale) else { return nil }
        return ["mermaid", "--source", bytes.base64EncodedString(), "--scale", String(scale), "--inline"]
            + (dark ? ["--dark"] : [])
    }

    /// `lines` is what `AttacheCliLink.run` hands back: nil when the command
    /// could not be run or timed out, and possibly empty when it ran.
    static func answer(_ lines: [String]?) -> Answer {
        guard let lines else { return .unanswered }
        // The last line that is an answer: a renderer that panicked prints
        // its refusal from the panic hook, after nothing or after noise.
        for line in lines.reversed() {
            guard let object = AttacheCliProtocol.object(line), let drawn = object["mermaid"] as? Bool else { continue }
            guard drawn else { return .refused(object["why"] as? String ?? "") }
            guard let encoded = object["png"] as? String, let png = Data(base64Encoded: encoded), isPNG(png),
                  let width = (object["width"] as? NSNumber)?.doubleValue,
                  let height = (object["height"] as? NSNumber)?.doubleValue,
                  width >= 1, height >= 1, width <= maxSide, height <= maxSide
            else { return .unanswered }
            return .picture(png, width: width, height: height)
        }
        return .unanswered
    }

    static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// Past this a size is not a diagram's, and not one to hand a layout.
    static let maxSide: Double = 20000

    /// What a drawn diagram is kept under, in memory and on disk. Everything
    /// that changes the picture is in it; `generation` is raised by hand when
    /// attache-cli's own defaults change what it draws for the same source.
    static func key(source: String, dark: Bool, scale: Int) -> String {
        let text = "\(generation)\n\(dark ? "dark" : "light")\n\(scale)\n\(source)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let generation = 5
}
