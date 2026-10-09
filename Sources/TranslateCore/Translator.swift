import Foundation

/// Runs one translation through a local CLI or OpenAI API and reports progress.
/// `onUpdate` gets the accumulated text; exactly one of `onDone`/`onError` fires unless cancelled.
/// Callbacks run on a private serial queue.
public final class Translator: @unchecked Sendable {
    public struct Failure: Error, CustomStringConvertible { public let description: String }

    private let process = Process()
    private let queue = DispatchQueue(label: "TrayTranslate.translator")
    private let engine: Engine
    private var apiTask: URLSessionDataTask?
    private var buffer = Data()
    private var text = ""
    private var final: String?
    private var failure: String?
    private var stderr = Data()
    private var cancelled = false
    private var finished = false

    public var onUpdate: (String) -> Void = { _ in }
    public var onDone: (String) -> Void = { _ in }
    public var onError: (String) -> Void = { _ in }

    public init(engine: Engine) { self.engine = engine }

    public func start(text input: String, direction: Direction) throws {
        if engine == .openai {
            guard let key = try OpenAI.apiKey() ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
                throw Failure(description: "Укажите ключ в меню «API-ключ OpenAI…»")
            }
            let request = try OpenAI.request(text: input, direction: direction, apiKey: key)
            apiTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                self.queue.async {
                    do {
                        if let error { throw error }
                        guard let data, let response = response as? HTTPURLResponse else {
                            throw Failure(description: "OpenAI: ответ не получен")
                        }
                        self.final = try OpenAI.translation(data: data, status: response.statusCode)
                    } catch { self.failure = String(describing: error) }
                    self.finish(status: self.failure == nil ? 0 : 1)
                }
            }
            apiTask?.resume()
            return
        }
        guard let exe = engine.executable() else {
            throw Failure(description: "\(engine.rawValue) CLI не найден в ~/.local/bin, /opt/homebrew/bin, /usr/local/bin или PATH")
        }
        let inv = try engine.invocation(direction: direction, executable: exe)
        process.executableURL = inv.executable
        process.arguments = inv.arguments
        process.environment = inv.environment
        process.currentDirectoryURL = inv.workDir
        let stdin = Pipe(), stdout = Pipe(), errPipe = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = errPipe
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            self?.queue.async { self?.consume(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            self?.queue.async { self?.stderr.append(data) }
        }
        process.terminationHandler = { [weak self] p in
            // Drain whatever is left before reporting.
            stdout.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let rest = stdout.fileHandleForReading.readDataToEndOfFile()
            self?.queue.async { self?.consume(rest); self?.finish(status: p.terminationStatus) }
        }
        try process.run()
        stdin.fileHandleForWriting.write(input.data(using: .utf8)!)
        try? stdin.fileHandleForWriting.close()
    }

    public func cancel() {
        queue.async { self.cancelled = true; self.apiTask?.cancel() }
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            switch engine.parse(line: line) {
            case .delta(let d)?:
                text += d
                if !cancelled { onUpdate(text) }
            case .final(let f)?:
                // The CLI may keep running after the answer (claude does a post-turn summary), so stop here.
                final = f
                finish(status: 0)
                if process.isRunning { process.terminate() }
            case .failure(let f)?: failure = f
            case nil: break
            }
        }
    }

    private func finish(status: Int32) {
        guard !cancelled, !finished else { return }
        finished = true
        let result = (final ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 0, failure == nil, !result.isEmpty {
            onDone(result)
        } else {
            let err = String(decoding: stderr, as: UTF8.self)
                .split(separator: "\n").filter { !$0.contains("failed to load skill") }.suffix(3).joined(separator: "\n")
            onError(failure ?? (err.isEmpty ? "\(engine.rawValue) завершился с кодом \(status)" : err))
        }
    }
}
