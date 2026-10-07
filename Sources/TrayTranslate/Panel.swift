import AppKit
import SwiftUI
import TranslateCore

@MainActor
final class PanelModel: ObservableObject {
    enum Phase: Equatable { case working, copied, failed(String) }
    @Published var direction = Direction.enToRu
    @Published var engine = Engine.claude
    @Published var text = ""
    @Published var phase = Phase.working
}

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.direction.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(model.engine.name).font(.caption).foregroundStyle(.tertiary)
            }
            if !model.text.isEmpty {
                ScrollView {
                    Text(model.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
            }
            status
        }
        .padding(12)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .working:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Перевожу…").font(.caption).foregroundStyle(.secondary)
            }
        case .copied:
            Label("Скопировано в буфер обмена", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(4)
        }
    }
}

/// Floating panel near the cursor that does not steal focus from the frontmost app.
final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onCancel: () -> Void = {}

    init(model: PanelModel) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = .preferredContentSize
        contentViewController = host
    }

    override func cancelOperation(_ sender: Any?) { onCancel() }

    /// Top-left corner just below-right of the cursor, kept inside the visible screen area.
    private var anchor = NSPoint.zero

    func show(at mouse: NSPoint) {
        anchor = NSPoint(x: mouse.x + 8, y: mouse.y - 12)
        reposition()
        makeKeyAndOrderFront(nil)
    }

    func reposition() {
        guard let content = contentViewController?.view else { return }
        let size = content.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        var frame = NSRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height)
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
            if frame.minY < visible.minY + 8 { frame.origin.y = anchor.y + 24 }  // flip above the cursor
            frame.origin.y = min(frame.origin.y, visible.maxY - frame.height - 8)
        }
        setFrame(frame, display: true)
    }
}
