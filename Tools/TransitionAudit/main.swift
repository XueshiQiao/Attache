//
//  main.swift
//  TransitionAudit
//
//  Reads what the app actually did — `~/Library/Logs/Attache/agent-state/` —
//  and checks it against the state machine it is supposed to implement.
//
//  Every other check tool in this project takes fixtures and asks whether the
//  code handles them. This one is the other way round: the code has been running
//  against a real machine for hours, and this asks whether what it did makes
//  sense. Neither question substitutes for the other. A fixture cannot contain
//  the transition nobody thought of, and this cannot run before there is data.
//
//  It reports findings, not pass/fail, and exits 0 unless something is
//  *structurally* wrong — a transition the machine has no edge for. Everything
//  else is a count and an example, because "12 flaps in 3 hours" is a judgement
//  about a threshold and the person reading it makes that judgement.
//
//  swiftc -O -o /tmp/transitionaudit Tools/TransitionAudit/main.swift \
//      && /tmp/transitionaudit
//

import Foundation

// MARK: - Reading

struct Transition {
    let at: Date
    let window: String
    let windowName: String
    let pane: String
    let from: String?
    let to: String
    let source: String
    let reason: String
    let heldFor: Double?
}

let directory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Attache/agent-state")

let parser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func loadTransitions() -> [Transition] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return [] }
    var out = [Transition]()
    for name in names where name.hasSuffix(".jsonl") && name != "clicks.jsonl" {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        else { continue }
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let at = (o["at"] as? String).flatMap(parser.date(from:)),
                  let to = o["to"] as? String else { continue }
            out.append(Transition(
                at: at,
                window: o["window"] as? String ?? "?",
                windowName: o["windowName"] as? String ?? "?",
                pane: o["pane"] as? String ?? "?",
                from: o["from"] as? String,
                to: to,
                source: o["source"] as? String ?? "?",
                reason: o["reason"] as? String ?? "-",
                heldFor: o["heldFor"] as? Double
            ))
        }
    }
    return out.sorted { $0.at < $1.at }
}

// MARK: - The machine as intended

/// Every edge the design allows. Anything else is a finding, not a nuance.
///
/// `none` is "no agent in this pane" and is both the entry and the exit: an
/// agent appears, and a pane drops back to a shell or closes.
let allowed: Set<String> = [
    // entering
    "none→none", "none→working", "none→needs-input", "none→done",
    // the ordinary cycle
    "working→needs-input", "working→done", "needs-input→working", "needs-input→done",
    "done→working", "done→needs-input",
    // leaving
    "working→none", "needs-input→none", "done→none",
]

/// Which reasons may produce which state. A reason that produces the wrong
/// state is a mapping bug, and the log is the only place it shows.
func reasonAgrees(_ reason: String, with state: String) -> Bool? {
    let r = reason.lowercased()
    // Hook events.
    if r.hasPrefix("stop") { return state == "done" }
    if r.hasPrefix("sessionend") { return state == "none" }
    if r.hasPrefix("pretooluse") || r.hasPrefix("posttooluse")
        || r.hasPrefix("userpromptsubmit") || r.hasPrefix("sessionstart")
    { return state == "working" }
    if r.hasPrefix("notification:idle_prompt") { return state == "done" }
    if r.hasPrefix("notification:") || r.hasPrefix("permissionrequest") {
        return state == "needs-input"
    }
    // Screen rules.
    if r.contains("rule 300") { return state == "needs-input" }
    if r.contains("rule 100") || r.contains("repainted") { return state == "working" }
    if r.contains("no rule matched") { return state == "done" }
    if r.contains("not captured") || r.contains("no screen rules") { return state == "none" }
    if r.contains("pane closed") { return state == "none" }
    return nil // nothing to say about it
}

// MARK: - Findings

var structural = 0

func heading(_ text: String) { print("\n\(text)") }

func report(_ label: String, _ hits: [String], structuralProblem: Bool = false) {
    guard !hits.isEmpty else { print("  ok    \(label)"); return }
    if structuralProblem { structural += hits.count }
    print("  \(structuralProblem ? "FAIL" : "note")  \(label) — \(hits.count)")
    for hit in hits.prefix(4) { print("          \(hit)") }
    if hits.count > 4 { print("          … and \(hits.count - 4) more") }
}

let transitions = loadTransitions()
guard !transitions.isEmpty else {
    print("No transitions recorded yet at \(directory.path).")
    print("Run the app for a while with an agent in a pane, then try again.")
    exit(0)
}

let span = transitions.last!.at.timeIntervalSince(transitions.first!.at)
print("\(transitions.count) transitions over \(Int(span / 60)) minutes, "
    + "\(Set(transitions.map(\.window)).count) windows, "
    + "sources: \(Set(transitions.map(\.source)).sorted().joined(separator: ", "))")

heading("— edges the machine does not have —")
report("every transition is one the design allows",
       transitions.compactMap { t -> String? in
           guard let from = t.from else { return nil }
           let edge = "\(from)→\(t.to)"
           guard !allowed.contains(edge) else { return nil }
           return "\(t.windowName) \(t.pane): \(edge) — \(t.reason)"
       },
       structuralProblem: true)

report("every reason produces the state it should",
       transitions.compactMap { t -> String? in
           guard reasonAgrees(t.reason, with: t.to) == false else { return nil }
           return "\(t.windowName) \(t.pane): reason \"\(t.reason)\" produced \(t.to)"
       },
       structuralProblem: true)

heading("— things that are legal but suspicious —")

// The screen strategy has no memory, so a spinner missed for one tick reads as
// finished. Two seconds later it is working again. Nothing is broken; the log is
// showing what the strategy costs, and the count is how much it costs today.
report("done → working within 5s (a spinner missed for one tick)",
       transitions.compactMap { t -> String? in
           guard t.from == "done", t.to == "working",
                 let held = t.heldFor, held < 5 else { return nil }
           return "\(t.windowName) \(t.pane): held done for \(String(format: "%.1f", held))s [\(t.source)]"
       })

// The one that would actually hide something from the user.
report("needs-input lost without the user acting",
       transitions.compactMap { t -> String? in
           guard t.from == "needs-input", t.to == "done",
                 t.reason.contains("no rule matched") || t.reason.contains("static")
           else { return nil }
           return "\(t.windowName) \(t.pane): blocked → done because nothing matched"
       })

report("a state held under a second",
       transitions.compactMap { t -> String? in
           guard let held = t.heldFor, held < 1, t.from != nil else { return nil }
           return "\(t.windowName) \(t.pane): \(t.from!)→\(t.to) after \(String(format: "%.2f", held))s"
       })

report("an agent that never reported (hook installed but silent)",
       Dictionary(grouping: transitions.filter { $0.to == "none" && $0.source == "hook" },
                  by: \.pane)
           .filter { $0.value.count >= 2 }
           .map { "\($0.value[0].windowName) \($0.key): stayed unreported \($0.value.count) times" })

// MARK: - Result

print("")
if structural == 0 {
    print("Nothing structurally wrong. Anything above marked `note` is a cost, not a defect —")
    print("read the counts and decide whether they are acceptable.")
} else {
    print("\(structural) structural finding(s): the machine did something the design has no")
    print("edge for, or a reason produced the wrong state. These are defects.")
    exit(1)
}
