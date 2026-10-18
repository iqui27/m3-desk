import SwiftUI
import AppKit
import M3DeskCore

struct WorkspaceAttachmentView: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var target: WorkspaceProject?
    @State private var folder: URL?
    @State private var message = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vincular pasta aos agentes").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Confirme o projeto autorizado que receberá a memória desta pasta. O mesmo MCP global atende todos os projetos.")
                    if let target {
                        LabeledContent("Projeto", value: target.name)
                        LabeledContent("ID do projeto", value: target.id)
                        LabeledContent("Organização", value: target.tenantID)
                    } else {
                        Text("Conecte o Desk e selecione um projeto autorizado antes de vincular uma pasta.")
                    }
                    Button("Escolher pasta…") { chooseFolder() }
                        .disabled(target == nil || saved)
                        .accessibilityIdentifier("choose-workspace-folder")
                    if let folder {
                        Text(folder.path).font(.callout.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("O vínculo salva apenas pasta, projeto e referências privadas. Ele não copia o token das Chaves e não comprova que os agentes conseguem se conectar.")
                        .font(.callout).foregroundStyle(.secondary)
                    DisclosureGroup("Referências de conexão") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Bearer: M3_PLATFORM_DESK_BEARER")
                            Text("Se remoto: M3_PLATFORM_CF_CLIENT_ID e M3_PLATFORM_CF_CLIENT_SECRET")
                            Text("O inicializador global lê a credencial individual das Chaves para a referência reservada, mantendo-a apenas em memória. O vínculo exige configuração privada do inicializador para o mesmo endereço. Nunca informe tokens neste formulário.")
                        }.font(.caption).textSelection(.enabled)
                    }
                    if !message.isEmpty {
                        Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("workspace-attachment-result")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(saved ? "Fechar" : "Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Confirmar vínculo") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(folder == nil || target == nil || target != store.attachmentProject || saved)
                    .accessibilityIdentifier("confirm-workspace-attachment")
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 560, maxWidth: 680, minHeight: 360, idealHeight: 480, maxHeight: 650)
        .onAppear { target = store.attachmentProject }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Escolher pasta do projeto"
        panel.prompt = "Selecionar pasta"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            folder = url.resolvingSymlinksInPath().standardizedFileURL
            message = ""
        }
    }

    private func save() {
        guard let folder, let target else { return }
        do {
            try store.attachWorkspace(folder: folder, project: target)
            saved = true
            message = "Pasta vinculada. Reconecte o MCP no agente e teste uma busca de memória. O acesso dos agentes ainda não foi verificado."
        } catch { message = error.localizedDescription }
    }
}
