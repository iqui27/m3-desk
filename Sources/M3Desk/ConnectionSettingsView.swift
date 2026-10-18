import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConnectionSettingsView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var showingAttachment = false

    private var connectionBusy: Bool {
        store.isConnecting || store.isValidatingPlatformConnection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "network").font(.title).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Conexão com o M3").font(.title2.weight(.semibold))
                    Text("Verifique o acesso deste aplicativo à M3 Platform.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            WorkspacePanel {
                SectionHeader(title: "M3 Platform", detail: "Projetos e permissões informados pelo servidor")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Endereço do backend").font(.subheadline.weight(.medium))
                    TextField("http://127.0.0.1:porta", text: $store.platformEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .disabled(store.isValidatingPlatformConnection)
                        .accessibilityLabel("Endereço do backend M3 Platform")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Token individual").font(.subheadline.weight(.medium))
                    SecureField("Token de acesso da M3 Platform", text: $store.platformCredential)
                        .textFieldStyle(.roundedBorder)
                        .disabled(store.isValidatingPlatformConnection)
                        .accessibilityLabel("Token individual da M3 Platform")
                    Text("A credencial é salva nas Chaves deste Mac. Deixe em branco para reutilizar uma credencial já salva para este endereço. Mesmo no acesso local, é necessário um token individual.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button("Salvar e conectar") { store.configurePlatform() }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.platformEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Importar conexão…") { importConnection() }
                        .accessibilityIdentifier("import-platform-connection")
                }
                .disabled(connectionBusy)
                if store.isValidatingPlatformConnection || !store.platformConnectionValidationMessage.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        if store.isValidatingPlatformConnection { ProgressView().controlSize(.small) }
                        Text(verbatim: store.platformConnectionValidationMessage.isEmpty ? "Validando conexão…" : store.platformConnectionValidationMessage)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("platform-connection-validation")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                SectionHeader(title: "Conexão dos agentes é independente")
                Button("Vincular pasta ao projeto selecionado…") { showingAttachment = true }
                    .disabled(store.attachmentProject == nil || connectionBusy)
                    .accessibilityIdentifier("attach-workspace")
                Text("O estado conectado valida apenas o Desk. Codex, Claude Code e OpenCode usam o MCP global m3_platform: cada workspace precisa estar associado explicitamente ao tenant/projeto e a uma referência privada de credencial no mapa global. Não é necessário criar um MCP por projeto.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !store.storageError.isEmpty {
                InlineNotice(text: store.storageError, icon: "exclamationmark.triangle", warning: true)
            }
            HStack {
                Text(store.connectionState).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                Button("Fechar") {
                    store.cancelPlatformConnectionValidation()
                    store.platformCredential = ""
                    store.showConnectionSettings = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(26)
        .frame(width: 520)
        .sheet(isPresented: $showingAttachment) { WorkspaceAttachmentView(store: store) }
        .onDisappear {
            store.cancelPlatformConnectionValidation()
            store.platformCredential = ""
        }
    }

    private func importConnection() {
        guard !connectionBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Importar conexão"
        panel.message = "Selecione o arquivo JSON de conexão fornecido para este Mac."
        panel.prompt = "Importar"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  !store.isConnecting, !store.isValidatingPlatformConnection else { return }
            store.importPlatformConnection(from: url)
        }
    }
}
