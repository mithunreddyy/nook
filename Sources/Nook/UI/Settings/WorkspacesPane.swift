import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Saved arrangements of windows to load again: per project, per task.
struct WorkspacesPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var engine = Engine.shared
    @State private var name = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Name", text: $name, prompt: Text("Writing, Coding…"))
                        .labelsHidden()
                        .onSubmit(save)
                    Button("Save Current Windows", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !engine.canTile)
                }
            } header: {
                Text("Save a workspace")
            } footer: {
                Text("Keeps each screen's layout, window count and where every window sits. Saving under a name that exists replaces it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if prefs.workspaces.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(prefs.workspaces) { ws in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ws.name)
                                Text(summary(ws)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Load") { engine.run(.loadWorkspace(ws.name), from: .mouse) }
                                .disabled(!engine.canTile)
                            Menu {
                                Button("Replace with Current Windows") { engine.saveWorkspace(ws.name) }
                                Button("Export…") { export(ws) }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    prefs.workspaces.removeAll { $0.name == ws.name }
                                    prefs.customShortcuts[Command.loadWorkspace(ws.name).name] = nil
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityLabel("More for \(ws.name)")
                        }
                        LabeledContent("Shortcut") {
                            ShortcutField(command: .loadWorkspace(ws.name), defaults: [])
                        }
                        .font(.callout)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Saved")
            } footer: {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack { Spacer(); Button("Import…") { importFile() } }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Loading") {
                Text("Open windows move to their saved places. Apps that aren't open start, and their windows find their places as they appear.")
                    .foregroundStyle(.secondary)
                Text("nook workspace save Coding\nnook workspace load Coding")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private func summary(_ ws: Workspace) -> String {
        let w = ws.windowCount == 1 ? "1 window" : "\(ws.windowCount) windows"
        let s = ws.screens.count == 1 ? "1 screen" : "\(ws.screens.count) screens"
        return "\(w) · \(s) · \(ws.saved.formatted(date: .abbreviated, time: .shortened))"
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        engine.run(.saveWorkspace(n), from: .mouse)
        name = ""
    }

    private func export(_ ws: Workspace) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(ws.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try engine.exportWorkspace(ws.name, to: url)
            message = "Exported “\(ws.name)”."
        } catch {
            message = "Couldn't export: \(error.localizedDescription)"
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let ws = try engine.importWorkspace(from: url)
            message = "Imported “\(ws.name)”."
        } catch {
            message = "That file isn't a Nook workspace."
        }
    }
}
