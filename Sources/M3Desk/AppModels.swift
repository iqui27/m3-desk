import Foundation
import M3DeskCore

enum AppSection: String, CaseIterable, Identifiable {
    case workspace = "Workspace", memory = "Busca & memória", handoff = "Handoff", runs = "Execuções"
    var id: String { rawValue }
    var icon: String {
        switch self { case .workspace: "rectangle.3.group"; case .memory: "magnifyingglass"; case .handoff: "arrow.up.right"; case .runs: "clock.arrow.circlepath" }
    }
}
typealias Project = WorkspaceProject
