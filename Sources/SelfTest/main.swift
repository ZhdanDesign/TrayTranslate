// Plain test runner: swift-testing/XCTest macros aren't available with Command Line Tools only.
import Foundation
import TranslateCore

var failures = 0
func check(_ ok: Bool, _ line: Int) {
    if !ok { failures += 1; print("FAIL line \(line)") }
}

// Direction
check(Direction.detect("Hello, world") == .enToRu, #line)
check(Direction.detect("Привет, мир") == .ruToEn, #line)
check(Direction.detect("Ошибка в функции parse()") == .ruToEn, #line)
check(Direction.detect("Call parse() — функция") == .enToRu, #line)
check(Direction.detect("12345 !!!") == .enToRu, #line)

// DoubleTap
var tap = DoubleTap(interval: 0.5)
check(!tap.press(at: 10.0), #line)
check(tap.press(at: 10.4), #line)
check(!tap.press(at: 10.6), #line)   // third press starts a new pair
check(!tap.press(at: 11.2), #line)   // too slow
check(tap.press(at: 11.5), #line)

// Parsing
let claude = Engine.claude
check(claude.parse(line: #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"При"}}}"#) == .delta("При"), #line)
check(claude.parse(line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Привет"}]}}"#) == .final("Привет"), #line)
check(claude.parse(line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Not logged in"}]},"error":"authentication_failed"}"#) == .failure("Not logged in"), #line)
check(claude.parse(line: #"{"type":"result","subtype":"success","is_error":false,"result":"Привет"}"#) == .final("Привет"), #line)
check(claude.parse(line: #"{"type":"result","is_error":true,"result":"Not logged in"}"#) == .failure("Not logged in"), #line)
check(claude.parse(line: #"{"type":"system","subtype":"init"}"#) == nil, #line)
let codex = Engine.codex
check(codex.parse(line: #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Привет"}}"#) == .final("Привет"), #line)
check(codex.parse(line: #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"warn"}}"#) == nil, #line)
check(codex.parse(line: #"{"type":"turn.failed","error":{"message":"quota"}}"#) == .failure("quota"), #line)
check(codex.parse(line: "not json") == nil, #line)

// Invocation: text never in argv, codex isolated from user config
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tt-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let exe = URL(fileURLWithPath: "/bin/echo")
let ci = try codex.invocation(direction: .enToRu, executable: exe, workDir: tmp, environment: ["HOME": "/Users/x"])
check(ci.environment["HOME"] == tmp.path, #line)
check(ci.environment["CODEX_HOME"] == NSString(string: "~/.codex").expandingTildeInPath, #line)
check(ci.arguments.contains("--ignore-user-config") && ci.arguments.last == "-", #line)
check(ci.arguments.contains("model=\"gpt-6-luna\""), #line)
let cl = try claude.invocation(direction: .ruToEn, executable: exe, workDir: tmp, environment: [:])
check(cl.arguments.contains("claude-haiku-5-5") && cl.arguments.contains("--strict-mcp-config"), #line)
check(cl.arguments.contains(Direction.ruToEn.instructions), #line)

// OpenAI: request contents and response/error handling, without a real key or network.
check(Engine.allCases.contains(.openai) && Engine.openai.model == "gpt-4o-mini", #line)
let request = try OpenAI.request(text: "Hello\n\"world\"", direction: .enToRu, apiKey: "test-key")
check(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions", #line)
check(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", #line)
let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
check(body["model"] as? String == "gpt-4o-mini" && body["store"] as? Bool == false, #line)
let messages = body["messages"] as! [[String: String]]
check(messages == [["role": "system", "content": Direction.enToRu.instructions],
                   ["role": "user", "content": "Hello\n\"world\""]], #line)
check(try OpenAI.translation(data: Data(#"{"choices":[{"message":{"content":"Привет"},"finish_reason":"stop"}]}"#.utf8), status: 200) == "Привет", #line)
for (json, status, expected) in [
    (#"{"error":{"message":"Invalid API key"}}"#, 401, "HTTP 401: Invalid API key"),
    (#"{"error":{"message":"Quota exceeded"}}"#, 429, "HTTP 429: Quota exceeded"),
    ("not json", 502, "HTTP 502"),
    ("not json", 200, "некорректный ответ"),
    (#"{"choices":[{"message":{"content":" "}}]}"#, 200, "пустой"),
    (#"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#, 200, "обрезан"),
] {
    do { _ = try OpenAI.translation(data: Data(json.utf8), status: status); check(false, #line) }
    catch { check(String(describing: error).contains(expected), #line) }
}
do { try OpenAI.saveAPIKey("   "); check(false, #line) }
catch { check(String(describing: error).contains("Введите API-ключ"), #line) }

print(failures == 0 ? "SelfTest: all passed" : "SelfTest: \(failures) failed")
exit(failures == 0 ? 0 : 1)
