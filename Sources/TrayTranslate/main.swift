import AppKit
import Foundation
import TranslateCore

// Headless mode for scripts and verification (text on stdin):
//   TrayTranslate --translate [--engine claude|codex] [--runs N]
// Prints the translation and timings: first visible text and total.
let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--translate") {
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    let engines = value("--engine").flatMap(Engine.init(rawValue:)).map { [$0] } ?? Engine.allCases
    let runs = value("--runs").flatMap(Int.init) ?? 1
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let direction = Direction.detect(input)
    var failed = false
    for engine in engines {
        for run in 1...runs {
            let start = Date()
            var first: TimeInterval?
            let done = DispatchSemaphore(value: 0)
            let t = Translator(engine: engine)
            t.onUpdate = { _ in if first == nil { first = Date().timeIntervalSince(start) } }
            t.onDone = { text in
                let total = Date().timeIntervalSince(start)
                print(String(format: "%@ %@ run %d: first %.2fs, total %.2fs | %@", engine.name, direction.label, run,
                             first ?? total, total, text.replacingOccurrences(of: "\n", with: " ⏎ ")))
                done.signal()
            }
            t.onError = { err in print("\(engine.name) run \(run): ERROR \(err)"); failed = true; done.signal() }
            do { try t.start(text: input, direction: direction) } catch { print("\(engine.name): \(error)"); failed = true; continue }
            done.wait()
        }
    }
    exit(failed ? 1 : 0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
