import SwiftUI
import AppKit
import Foundation
import M3DeskCore

/// Deterministic, offline UI fixtures. This renderer uses isolated store persistence.
@MainActor
enum PreviewRenderer {
    static func png<V: View>(_ view: V, size: CGSize, scheme: ColorScheme) -> Data? {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -size.width - 40, y: -size.height - 40), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isOpaque = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.wantsLayer = true
        window.contentView = host
        window.orderFrontRegardless()
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: Int(size.width) * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { window.close(); return nil }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        host.layer?.render(in: context)
        context.restoreGState()
        guard let image = context.makeImage() else { window.close(); return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        window.close()
        return bitmap.representation(using: .png, properties: [:])
    }

    static func run() {
        let arguments = CommandLine.arguments
        let output: URL
        if let index = arguments.firstIndex(of: "--preview-output"), arguments.indices.contains(index + 1) {
            output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else {
            output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".ui-previews", isDirectory: true)
        }
        do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        catch { print("PREVIEW_FAILED \(error.localizedDescription)"); return }
        let sizes: [(String, CGSize)] = [
            ("wide", CGSize(width: 1300, height: 850)),
            ("compact", CGSize(width: 1000, height: 700))
        ]
        var count = 0
        for (sizeName, size) in sizes {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let store = WorkspaceStore(preview: true)
                if let project = store.projects.first {
                    store.select(project)
                    var fixture = HandoffDraft()
                    fixture.destination = "Codex"
                    fixture.project = project.name
                    fixture.objective = "Revisar a proposta de retomada"
                    fixture.context = "Exemplo visual: o checkpoint local está pronto para revisão. Este conteúdo não foi recuperado do servidor."
                    fixture.delta = "A interface agora distingue rascunho, checkpoint remoto e execução."
                    fixture.sources = "Fixture de interface · v2\nSem consulta ao servidor"
                    fixture.pending = "Validar o contrato de contexto autorizado."
                    fixture.version = "preview-fixture-2"
                    store.handoff = fixture
                }
                for section in AppSection.allCases {
                    store.section = section
                    let sectionName: String
                    switch section {
                    case .workspace: sectionName = "workspace"
                    case .handoff: sectionName = "handoff"
                    case .memory: sectionName = "memory"
                    case .runs: sectionName = "runs"
                    }
                    let name = "m3desk-\(sizeName)-\(sectionName)-\(scheme == .dark ? "dark" : "light").png"
                    let view = PreviewShell(store: store)
                        .environment(\.colorScheme, scheme)
                        .environment(\.controlActiveState, .active)
                        .tint(.orange)
                    guard let data = png(view, size: size, scheme: scheme) else { continue }
                    do { try data.write(to: output.appendingPathComponent(name)); count += 1 }
                    catch { print("PREVIEW_FAILED \(name): \(error.localizedDescription)") }
                }
            }
        }
        print("PREVIEW_RENDERED \(count) fixtures \(output.path)")
    }
}

private struct PreviewShell: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "viewfinder")
                Text("Preview de interface · dados de exemplo · sem consulta ao servidor")
                Spacer()
                Text("M3 Desk").fontWeight(.semibold)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.orange.opacity(0.12))
            Divider()
            HStack(spacing: 0) {
                Sidebar(store: store).frame(width: 225)
                Divider()
                Group {
                    switch store.section {
                    case .workspace: ProjectWorkspace(store: store)
                    case .handoff: HandoffView(store: store)
                    case .memory: MemoryView(store: store)
                    case .runs: RunsView(store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                Inspector(store: store).frame(width: 236)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
