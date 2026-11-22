import Foundation

extension ToolSource {
    public static let memory = ToolSource(id: "memory", title: "Memory")
}

/// Reads memory as it is now: core and the index of topic files, or one file.
public struct ReadMemoryTool: AgentTool {
    public static let name = "read_memory"

    public let library: MemoryLibrary

    public init(library: MemoryLibrary) {
        self.library = library
    }

    public var source: ToolSource { .memory }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: "Read your memory as it is now: core and the list of topic files, or one file.",
            parameters: Schema.object([
                "file": Schema.nullableString("\"core\" or a topic file's name for that file. Null for core and the full list of topic files."),
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        guard let file = arguments["file"]?.trimmedString, !file.isEmpty else { return "Read memory" }
        return "Read memory: \(file)"
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        library.reconcile()
        if let name = arguments["file"]?.trimmedString, !name.isEmpty {
            guard let file = library.file(named: name), file.kind != .archived else {
                return "Error: " + MemoryLibrary.missing(name).description
            }
            if file.kind == .core {
                return file.text.isEmpty ? "core.md is empty." : "core.md, \(file.characters.formatted()) characters:\n\(file.text)"
            }
            var lines = ["\(file.id).md, \(file.characters.formatted()) characters."]
            if let problem = file.problem {
                lines.append("Its front matter cannot be read: \(problem) The whole file:")
                lines.append(file.text)
            } else {
                lines.append("Description: \(file.description ?? "")")
                lines.append(file.body.isEmpty ? "Its body is empty." : file.body)
            }
            return lines.joined(separator: "\n")
        }
        // Everything, with no cap, so what the block leaves out can be read here.
        let core = library.core()
        let topics = library.topics()
        var lines = ["Memory as it is now. core.md, \(core.characters.formatted()) characters:"]
        lines.append(core.text.isEmpty ? "(empty)" : core.text.trimmingCharacters(in: .newlines))
        lines.append("")
        if topics.isEmpty {
            lines.append("There are no topic files.")
        } else {
            lines.append("Topic files, as name (changed, characters): description:")
            for file in topics {
                let changed = file.modified.map { MemoryBlock.day($0, calendar: .current) } ?? "unknown"
                let description = file.problem.map { "(Its front matter cannot be read: \($0))" } ?? file.description ?? ""
                lines.append("- \(file.id) (\(changed), \(file.characters.formatted())): \(description)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Changes memory with one local edit: a new topic file, a replaced, removed, or added piece of
/// text, a description, a name, or an archive. None asks for a go-ahead: every change is in the
/// journal and can be restored from Settings, and a deleted file goes to the archive.
public struct ChangeMemoryTool: AgentTool {
    public static let name = "change_memory"
    public static let operations = ["create", "replace", "remove", "append", "set_description", "rename", "delete"]

    public let library: MemoryLibrary

    public init(library: MemoryLibrary) {
        self.library = library
    }

    public var source: ToolSource { .memory }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Change your memory with one edit. create: a new topic file (file, description, text). \
                replace: exact old_text in a file becomes text. remove: delete exact old_text. append: add \
                text at the end. set_description, rename (new_name), and delete, which archives a topic file.
                """,
            parameters: Schema.object([
                "operation": ["type": "string", "enum": .array(Self.operations.map { .string($0) })],
                "file": Schema.string("\"core\" or a topic file's name: lowercase letters, digits, and hyphens."),
                "old_text": Schema.nullableString("For replace and remove, the exact text now in the file, matching once. Null otherwise."),
                "text": Schema.nullableString("For create, the body. For replace, the new text. For append, the text to add. Null otherwise."),
                "description": Schema.nullableString("For create and set_description, one line saying when to read the file. Null otherwise."),
                "new_name": Schema.nullableString("For rename, the new name. Null otherwise."),
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        let file = arguments["file"]?.trimmedString.flatMap { $0.isEmpty ? nil : $0 } ?? "memory"
        switch arguments["operation"]?.stringValue {
        case "create": return "Remember in a new file: \(file)"
        case "append": return "Remember in \(file)"
        case "replace": return "Update \(file)"
        case "remove": return "Forget something in \(file)"
        case "set_description": return "Describe \(file)"
        case "rename": return "Rename \(file) to \(arguments["new_name"]?.trimmedString ?? "")"
        case "delete": return "Forget \(file)"
        default: return "Change memory"
        }
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let operation = arguments["operation"]?.stringValue, Self.operations.contains(operation) else {
            return "Error: operation must be one of \(Self.operations.joined(separator: ", "))."
        }
        guard let file = arguments["file"]?.trimmedString, !file.isEmpty else { return "Error: \(operation) needs a file." }
        let oldText = arguments["old_text"]?.stringValue
        let text = arguments["text"]?.stringValue
        let description = arguments["description"]?.stringValue
        let newName = arguments["new_name"]?.stringValue
        let change: MemoryLibrary.Change
        switch operation {
        case "create":
            guard let description else { return "Error: create needs a description that says when to read the file." }
            change = .create(name: file, description: description, body: text ?? "")
        case "replace":
            guard let oldText, let text else { return "Error: replace needs old_text and text." }
            change = .replace(file: file, old: oldText, new: text)
        case "remove":
            guard let oldText else { return "Error: remove needs old_text, the exact text to remove." }
            change = .remove(file: file, text: oldText)
        case "append":
            guard let text else { return "Error: append needs text." }
            change = .append(file: file, text: text)
        case "set_description":
            guard let description else { return "Error: set_description needs a description." }
            change = .setDescription(file: file, description: description)
        case "rename":
            guard let newName else { return "Error: rename needs new_name." }
            change = .rename(file: file, newName: newName)
        default:
            change = .delete(file: file)
        }
        do {
            let result = try library.apply(change, cause: .episode(context.episodeID))
            return result.summary + " It is in the memory block from the next episode.\n" + library.sizeNote()
        } catch {
            return "Error: \(String(describing: error))"
        }
    }
}
