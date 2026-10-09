import Foundation

public enum Engine: String, CaseIterable, Sendable {
    case claude, codex, openai

    public var name: String {
        switch self { case .claude: return "Claude"; case .codex: return "Codex"; case .openai: return "OpenAI" }
    }
    /// Model IDs verified on this machine: `claude -p --model haiku` reports claude-haiku-5-5;
    /// `codex debug models` lists gpt-6-luna ("Fast and affordable model for easier tasks").
    public var model: String {
        switch self { case .claude: return "claude-haiku-5-5"; case .codex: return "gpt-6-luna"; case .openai: return "gpt-4o-mini" }
    }

    public struct Invocation {
        public var executable: URL
        public var arguments: [String]
        public var environment: [String: String]
        public var workDir: URL
    }

    public enum Event: Equatable {
        case delta(String)
        case final(String)
        case failure(String)
    }

    static let searchDirs = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        .map { NSString(string: $0).expandingTildeInPath }

    /// GUI apps get a bare PATH, so look in the usual install locations first.
    public func executable(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> URL? {
        let dirs = Self.searchDirs + (path ?? "").split(separator: ":").map(String.init)
        return dirs.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(rawValue) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Empty directory used as cwd (and as HOME for codex) so no project files, AGENTS.md or skills load.
    public static var workDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrayTranslate/run")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Non-interactive run with minimal context: no tools, MCP, plugins, hooks, skills or session files.
    /// The text to translate goes to stdin, never to argv.
    public func invocation(direction: Direction, executable: URL, workDir: URL = Engine.workDir,
                           environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Invocation {
        var env = environment
        env["PATH"] = (Self.searchDirs + [env["PATH"] ?? ""]).joined(separator: ":")
        switch self {
        case .openai:
            throw Translator.Failure(description: "OpenAI работает через API, без CLI")
        case .claude:
            let args = [
                "-p", "--model", model,
                "--setting-sources", "", "--strict-mcp-config", "--tools", "",
                "--disable-slash-commands", "--no-session-persistence",
                "--exclude-dynamic-system-prompt-sections",
                "--system-prompt", direction.instructions,
                "--output-format", "stream-json", "--include-partial-messages", "--verbose",
            ]
            return Invocation(executable: executable, arguments: args, environment: env, workDir: workDir)
        case .codex:
            // codex reads ~/.agents/skills via HOME, so HOME points at the empty dir;
            // CODEX_HOME stays the real one for auth, but its config.toml is ignored.
            env["CODEX_HOME"] = env["CODEX_HOME"] ?? NSString(string: "~/.codex").expandingTildeInPath
            env["HOME"] = workDir.path
            let instructions = workDir.appendingPathComponent("codex-\(direction == .ruToEn ? "ru-en" : "en-ru").md")
            try direction.instructions.write(to: instructions, atomically: true, encoding: .utf8)
            let config = [
                "model=\"\(model)\"", "model_reasoning_effort=\"low\"",
                "model_instructions_file=\"\(instructions.path)\"",
                "project_doc_max_bytes=0", "web_search=\"disabled\"",
                "include_permissions_instructions=false", "include_environment_context=false",
                "include_apps_instructions=false", "include_collaboration_mode_instructions=false",
                "skills.include_instructions=false", "skills.bundled.enabled=false",
            ] + ["multi_agent", "memories", "plugins", "apps", "hooks", "shell_tool", "unified_exec",
                 "goals", "computer_use", "browser_use", "image_generation", "tool_suggest"]
                .map { "features.\($0)=false" }
            let args = ["exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                        "-s", "read-only", "--json"] + config.flatMap { ["-c", $0] } + ["-"]
            return Invocation(executable: executable, arguments: args, environment: env, workDir: workDir)
        }
    }

    /// Parses one JSONL line of CLI output.
    public func parse(line: String) -> Event? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch (self, type) {
        case (.claude, "stream_event"):
            let event = obj["event"] as? [String: Any]
            let delta = event?["delta"] as? [String: Any]
            guard event?["type"] as? String == "content_block_delta", delta?["type"] as? String == "text_delta",
                  let text = delta?["text"] as? String else { return nil }
            return .delta(text)
        case (.claude, "assistant"):
            // Full reply; arrives before claude's post-turn summary and the final "result" line.
            let message = obj["message"] as? [String: Any]
            let blocks = message?["content"] as? [[String: Any]] ?? []
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            if obj["error"] != nil { return .failure(text.isEmpty ? "\(obj["error"]!)" : text) }
            return text.isEmpty ? nil : .final(text)
        case (.claude, "result"):
            let result = obj["result"] as? String ?? ""
            return obj["is_error"] as? Bool == true ? .failure(result) : .final(result)
        case (.codex, "item.completed"):
            guard let item = obj["item"] as? [String: Any], item["type"] as? String == "agent_message",
                  let text = item["text"] as? String else { return nil }
            return .final(text)
        case (.codex, "turn.failed"):
            let error = obj["error"] as? [String: Any]
            return .failure(error?["message"] as? String ?? "turn failed")
        case (.codex, "error"):
            return .failure(obj["message"] as? String ?? "error")
        default:
            return nil
        }
    }
}
