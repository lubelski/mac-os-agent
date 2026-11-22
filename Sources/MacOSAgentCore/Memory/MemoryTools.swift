import Foundation

extension ToolSource {
    public static let memory = ToolSource(id: "memory", title: "Memory")
}

/// Lists every saved memory with its id and the day it was saved, including any the block at
/// the end of the instructions leaves out.
public struct ReadMemoriesTool: AgentTool {
    public static let name = "read_memories"

    public let library: MemoryLibrary

    public init(library: MemoryLibrary) {
        self.library = library
    }

    public var source: ToolSource { .memory }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: "List every saved memory with its id and the day it was saved, including any left out of the instructions.",
            parameters: Schema.object([:]))
    }

    public func summary(arguments: JSONValue) -> String { "Read the memories" }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        let memories = library.memories()
        guard !memories.isEmpty else { return "There are no memories yet. They are kept in \(library.fileURL.plainPath)." }
        var lines = ["\(memories.count == 1 ? "1 memory" : "\(memories.count) memories") in \(library.fileURL.plainPath), as id, day saved, text:"]
        lines += memories.map { memory in
            memory.saved.map { "- [\(memory.id)] \($0): \(memory.text)" } ?? "- [\(memory.id)] \(memory.text)"
        }
        return lines.joined(separator: "\n")
    }
}

/// Adds, changes, or removes one memory. None of it asks for a go-ahead: a memory is one line
/// the person asked for or can see in the reply, Settings lists them all, and the tool call
/// that removed one keeps its text in the thread.
public struct ChangeMemoryTool: AgentTool {
    public static let name = "change_memory"
    public static let operations = ["add", "change", "remove"]

    public let library: MemoryLibrary

    public init(library: MemoryLibrary) {
        self.library = library
    }

    public var source: ToolSource { .memory }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Add a memory, change one's text, or remove one. A memory is one sentence that makes \
                sense on its own, known in every later episode. A changed memory gets a new id.
                """,
            parameters: Schema.object([
                "operation": ["type": "string", "enum": .array(Self.operations.map { .string($0) })],
                "memory_id": Schema.nullableString("The memory to change or remove. Null to add."),
                "text": Schema.nullableString("For add and change, the memory's whole text. Null to remove."),
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        let id = arguments["memory_id"]?.trimmedString.flatMap { $0.isEmpty ? nil : $0 }
        switch arguments["operation"]?.stringValue {
        case "remove": return id.map { "Forget the memory \($0)" } ?? "Forget a memory"
        case "change": return id.map { "Change the memory \($0)" } ?? "Change a memory"
        default:
            guard let text = arguments["text"]?.trimmedString, !text.isEmpty else { return "Remember something" }
            return "Remember: \(AgentInstructions.singleLine(text))"
        }
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let operation = arguments["operation"]?.stringValue, Self.operations.contains(operation) else {
            return "Error: operation must be one of \(Self.operations.joined(separator: ", "))."
        }
        let id = arguments["memory_id"]?.trimmedString.flatMap { $0.isEmpty ? nil : $0 }
        let text = arguments["text"]?.stringValue
        do {
            switch operation {
            case "add":
                guard let text else { return "Error: add needs the memory's text." }
                let memory = try library.add(text)
                return "Saved memory \(memory.id): \(memory.text)"
            case "change":
                guard let id, let memory = library.find(id) else { return "Error: there is no memory \(id ?? "with no id"). Call \(ReadMemoriesTool.name) for the list." }
                guard let text else { return "Error: change needs the memory's new text." }
                let (old, new) = try library.change(id: memory.id, to: text)
                return "Changed memory \(old.id), which said: \(old.text)\nIt is now \(new.id): \(new.text)"
            default:
                guard let id, let memory = library.find(id) else { return "Error: there is no memory \(id ?? "with no id"). Call \(ReadMemoriesTool.name) for the list." }
                let removed = try library.remove(id: memory.id)
                return "Removed memory \(removed.id), which said: \(removed.text)"
            }
        } catch {
            return "Error: \(String(describing: error))"
        }
    }
}
