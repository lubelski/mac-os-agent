import MacOSAgentCore
import Observation
import SwiftUI

/// The agent's tools, read-only, grouped by source in registry order.
///
/// Tools from MCP servers will arrive as more groups from `ToolRegistry.groups`, one per
/// server, after the built-in group. Settings for one tool, such as turning it off, would go
/// in `ToolDetailView` with a store of their own, as skills have `skill-settings.json`.
@MainActor
@Observable
final class ToolsSettingsModel {
    let groups: [ToolGroup]
    var selection: ToolSummary.ID?

    init(registry: ToolRegistry) {
        groups = registry.groups
        selection = groups.first?.tools.first?.id
    }

    var selectedTool: ToolSummary? {
        groups.lazy.flatMap(\.tools).first { $0.id == selection }
    }
}

struct ToolsSettingsView: View {
    @Bindable var model: ToolsSettingsModel

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.groups) { group in
                    Section(group.source.title) {
                        ForEach(group.tools) { tool in
                            ToolRow(tool: tool).tag(tool.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(width: 260)
            Divider()
            Group {
                if let tool = model.selectedTool {
                    ToolDetailView(tool: tool)
                } else {
                    ContentUnavailableView("No Tool Selected", systemImage: "wrench.and.screwdriver")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ToolRow: View {
    let tool: ToolSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(.body.monospaced())
                Text(tool.shortDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if tool.goAhead != .never {
                Image(systemName: "hand.raised")
                    .foregroundStyle(.secondary)
                    .help("Can ask for a go-ahead")
                    .accessibilityLabel("Can ask for a go-ahead")
            }
        }
        .padding(.vertical, 2)
    }
}

struct ToolDetailView: View {
    let tool: ToolSummary
    @State private var showingSchema = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.name).font(.title2.monospaced())
                    Text(tool.source.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Asks for a go-ahead").font(.headline)
                    Text("\(tool.goAhead.label). \(tool.goAhead.explanation)")
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Description sent to the model").font(.headline)
                    Text(tool.description)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary, in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Parameters").font(.headline)
                    if tool.parameters.isEmpty {
                        Text("None.").foregroundStyle(.secondary)
                    } else {
                        ForEach(tool.parameters) { parameter in
                            ParameterRow(parameter: parameter)
                            if parameter.id != tool.parameters.last?.id { Divider() }
                        }
                    }
                }

                DisclosureGroup("JSON Schema as sent", isExpanded: $showingSchema) {
                    Text(tool.schemaText)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ParameterRow: View {
    let parameter: ToolParameter

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(parameter.name).font(.body.monospaced())
                Text(parameter.type).foregroundStyle(.secondary)
                Spacer()
                Text(parameter.isRequired ? "Required" : "Optional")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !parameter.description.isEmpty {
                Text(parameter.description)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !parameter.allowedValues.isEmpty {
                Text("One of: \(parameter.allowedValues.joined(separator: ", "))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
