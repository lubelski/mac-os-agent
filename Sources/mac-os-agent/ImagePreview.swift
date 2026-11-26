import Foundation
import MacOSAgentCore

/// Stand-in panel states for attached images, with pictures drawn in code. Nothing here reads
/// or writes the clipboard, the real thread, or the data folder: the images are held in memory.
@MainActor
enum ImagePreview {
    static let names = ["images-attached", "image-sent", "images-unsupported", "images-attached-bars", "image-sent-bars"]

    static func session(named name: String) -> AgentSession? {
        guard names.contains(name) else { return nil }
        var thread = PanelPreview.StandInThread(now: Date())
        thread.earlierExchanges()
        let images = InMemoryImageStore()
        let screenshot = StandInImages.prepared(.errorDialog)
        let chart = StandInImages.prepared(.chart)
        let landscape = StandInImages.prepared(.landscape)
        for image in [screenshot, chart, landscape] { images.keep(image) }

        var entries = thread.entries
        if name.hasPrefix("image-sent") {
            let date = Date().addingTimeInterval(-60)
            entries.append(ThreadEntry(date: date, item: .userMessage(
                text: "what does this error mean", images: [screenshot.attachment])))
            entries.append(ThreadEntry(date: date.addingTimeInterval(8), item: .assistantMessage(.init(
                text: "The disk named **Backup** is full, so Time Machine stopped partway. Delete old backups from it, or use a larger disk.",
                provider: "openai", model: "gpt-6-luna"))))
            entries.append(ThreadEntry(date: date.addingTimeInterval(30), item: .userMessage(
                text: "", images: [chart.attachment, landscape.attachment])))
        }
        let session = AgentSession(previewEntries: entries)
        session.previewImages = images
        if name.hasSuffix("-bars") { PanelWithBarsPreview.configure(session) }
        switch name {
        case "images-attached", "images-attached-bars":
            session.attach(prepared: [screenshot, chart])
            session.draft = "why is the second bar so tall"
            // A render has no pointer, so the remove controls are drawn as if it were over them.
            session.previewRevealsControls = true
        case "images-unsupported":
            session.attach(prepared: [screenshot])
            session.draft = "what does this error mean"
            session.previewAttachmentNotice(ImageInput.unsupportedMessage(modelID: Ollama.modelID("text-only-mini:latest")))
        default:
            break
        }
        return session
    }
}
