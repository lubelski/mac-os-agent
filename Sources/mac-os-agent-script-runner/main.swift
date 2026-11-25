import Foundation
import JavaScriptCore

// Runs one script from mac-os-agent in JavaScriptCore. The app starts this helper for each
// `run_script` call and kills it when the script ends, times out, or is stopped.
//
// The script's only way out is the functions installed below. JavaScriptCore gives a context
// nothing else: no file system, network, timers, or processes. The helper is also signed with
// the App Sandbox and no other entitlement, so even a bug here cannot reach the owner's files.
//
// It talks to the app with one JSON object per line. `ScriptRunnerProtocol` in
// `MacOSAgentCore` is the app's side, and the messages are described there.

let output = FileHandle.standardOutput
let outputLock = NSLock()

func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
    outputLock.lock()
    output.write(data + Data([0x0A]))
    outputLock.unlock()
}

/// The most text the script can produce. Past it the script fails, so a runaway loop of
/// `text()` cannot fill the app's memory. The app cuts what the model reads much shorter.
let maximumOutputCharacters = 4_000_000

/// Everything runs on the main thread, one message at a time, so the context is never touched
/// from two threads.
@MainActor
final class ScriptRun {
    let context: JSContext
    var pending: [Int: (resolve: JSValue, reject: JSValue)] = [:]
    var nextCallID = 1
    var finished = false
    var outputCharacters = 0
    /// Calls made while handling the current message. They are sent when it has been handled,
    /// and dropped if the script finished meanwhile, since a call the script did not wait for
    /// must not run after it ends.
    var outbox: [[String: Any]] = []

    init(tools: [[String: Any]]) {
        context = JSContext()!
        context.name = "mac-os-agent script"
        context.exceptionHandler = { [unowned self] _, exception in
            // Only for exceptions thrown outside the script's promise, such as a syntax error.
            self.finish(ok: false, error: Self.describe(exception))
        }
        install(tools: tools)
    }

    private func install(tools: [[String: Any]]) {
        let call: @convention(block) (String, String) -> JSValue = { [unowned self] name, arguments in
            let id = self.nextCallID
            self.nextCallID += 1
            let promise = JSValue(newPromiseIn: self.context) { resolve, reject in
                if let resolve, let reject { self.pending[id] = (resolve, reject) }
            }!
            self.outbox.append(["type": "call", "id": id, "tool": name, "arguments": arguments])
            return promise
        }
        let write: @convention(block) (String, Bool) -> Bool = { [unowned self] text, console in
            self.outputCharacters += text.count
            if self.outputCharacters > maximumOutputCharacters { return false }
            send(["type": "output", "text": text, "console": console])
            return true
        }
        let done: @convention(block) (Bool, JSValue, JSValue) -> Void = { [unowned self] ok, value, error in
            if ok {
                self.finish(ok: true, value: value.isUndefined ? nil : value.toString())
            } else {
                self.finish(ok: false, error: Self.describe(error))
            }
        }
        context.setObject(call, forKeyedSubscript: "__call" as NSString)
        context.setObject(write, forKeyedSubscript: "__write" as NSString)
        context.setObject(done, forKeyedSubscript: "__done" as NSString)
        context.setObject(tools, forKeyedSubscript: "__tools" as NSString)
        context.evaluateScript(Self.prelude, withSourceURL: URL(string: "prelude.js"))
    }

    /// Builds the script's globals on the three functions above, then removes them, so the
    /// script sees only `tools`, `ALL_TOOLS`, `describeTool`, `text`, and `console`.
    static let prelude = #"""
    (() => {
      const call = __call, write = __write, done = __done, list = __tools;
      delete globalThis.__call; delete globalThis.__write; delete globalThis.__done; delete globalThis.__tools;
      const format = (value) => typeof value === "string" ? value : (() => {
        try { const json = JSON.stringify(value); return json === undefined ? String(value) : json; }
        catch { return String(value); }
      })();
      const emit = (text, isConsole) => {
        if (!write(text, isConsole)) throw new RangeError("The script's output passed 4,000,000 characters.");
      };
      const tools = {};
      for (const tool of list) {
        const run = async (args) => {
          const json = JSON.stringify(args === undefined ? {} : args);
          if (json === undefined || json[0] !== "{") throw new TypeError(tool.name + " takes one object of arguments.");
          return await call(tool.name, json);
        };
        tools[tool.name] = run;
        if (tool.jsName !== tool.name) tools[tool.jsName] = run;
      }
      globalThis.tools = Object.freeze(tools);
      globalThis.ALL_TOOLS = Object.freeze(list.map((tool) => Object.freeze({ name: tool.jsName, description: tool.description })));
      globalThis.describeTool = (name) => {
        const tool = list.find((tool) => tool.name === name || tool.jsName === name);
        return tool === undefined ? undefined : { name: tool.jsName, description: tool.description, parameters: JSON.parse(tool.parameters) };
      };
      globalThis.text = (value) => { emit(format(value), false); };
      const log = (...values) => { emit(values.map(format).join(" "), true); };
      globalThis.console = Object.freeze({ log, info: log, warn: log, error: log, debug: log });
      globalThis.__finish = (promise) => promise.then(
        (value) => done(true, value === undefined ? undefined : format(value), undefined),
        (error) => done(false, undefined, error));
    })();
    """#

    func start(code: String) {
        // The script is the body of an async function. Its first line shares a line with the
        // wrapper, so an error's line number is the line in the script.
        let finish = context.objectForKeyedSubscript("__finish")!
        context.evaluateScript("delete globalThis.__finish;")
        let promise = context.evaluateScript("(async () => {" + code + "\n})()", withSourceURL: URL(string: "script.js"))
        // A syntax error leaves no promise, and the exception handler has already finished the run.
        guard !finished, let promise, promise.isObject else { return }
        finish.call(withArguments: [promise])
        checkStuck()
    }

    func deliver(id: Int, ok: Bool, value: String) {
        guard let call = pending.removeValue(forKey: id) else { return }
        if ok {
            call.resolve.call(withArguments: [value])
        } else {
            let error = context.objectForKeyedSubscript("Error").construct(withArguments: [value])!
            call.reject.call(withArguments: [error])
        }
        checkStuck()
    }

    /// A script that waits on a promise nothing can settle would wait forever, since it has no
    /// timers. With no call outstanding and the script not finished, that is what it does.
    private func checkStuck() {
        if !finished && outbox.isEmpty && pending.isEmpty {
            finish(ok: false, error: [
                "message": "The script waited on something that can never finish. Every call to a tool must be awaited, and there are no timers.",
            ])
        }
    }

    /// Sends the calls the last message led to, unless the script has finished.
    func flush() {
        if !finished { outbox.forEach(send) }
        outbox = []
    }

    func finish(ok: Bool, value: String? = nil, error: [String: Any]? = nil) {
        guard !finished else { return }
        finished = true
        var message: [String: Any] = ["type": "done", "ok": ok]
        if let value { message["value"] = value }
        if let error { message["error"] = error }
        send(message)
    }

    /// The message, the line in the script, and the name of a thrown error.
    static func describe(_ error: JSValue?) -> [String: Any] {
        guard let error, !error.isUndefined, !error.isNull else { return ["message": "The script failed."] }
        var result: [String: Any] = [:]
        if error.isObject, error.hasProperty("message") {
            let name = error.forProperty("name")?.toString() ?? "Error"
            result["message"] = "\(name): \(error.forProperty("message")?.toString() ?? "")"
            if let stack = error.forProperty("stack"), !stack.isUndefined { result["stack"] = stack.toString() }
            if let line = error.forProperty("line"), line.isNumber, (error.forProperty("sourceURL")?.toString() ?? "script.js").hasSuffix("script.js") {
                result["line"] = line.toInt32()
            } else if let line = scriptLine(in: result["stack"] as? String) {
                result["line"] = line
            }
        } else {
            result["message"] = "Uncaught \(error.toString() ?? "value")"
        }
        return result
    }

    /// The first line number given for `script.js` in a stack, such as `script.js:4:12`.
    static func scriptLine(in stack: String?) -> Int? {
        guard let stack, let range = stack.range(of: #"script\.js:(\d+)"#, options: .regularExpression) else { return nil }
        return Int(stack[range].split(separator: ":")[1])
    }
}

var run: ScriptRun?

@MainActor
func handle(_ line: Data) {
    guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
          let type = message["type"] as? String
    else { return }
    switch type {
    case "start":
        let tools = message["tools"] as? [[String: Any]] ?? []
        let code = message["code"] as? String ?? ""
        let script = ScriptRun(tools: tools)
        run = script
        script.start(code: code)
        script.flush()
    case "result":
        guard let id = message["id"] as? Int else { return }
        run?.deliver(id: id, ok: message["ok"] as? Bool ?? false, value: message["value"] as? String ?? "")
        run?.flush()
    default:
        break
    }
}

// Read stdin and handle each line in turn. The app closing the pipe ends the helper.
var buffer = Data()
let input = FileHandle.standardInput
while true {
    let chunk = input.availableData
    if chunk.isEmpty { break }
    buffer.append(chunk)
    while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<newline]
        buffer.removeSubrange(buffer.startIndex...newline)
        handle(Data(line))
    }
}
exit(0)
