import SwiftUI
import M3DeskCore

struct ContentView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        GeometryReader { viewport in
            workspace(viewportHeight: viewport.size.height)
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
        }
        .frame(minWidth: 1000, minHeight: 680)
    }

    private func workspace(viewportHeight: CGFloat) -> some View {
        NavigationSplitView {
            Sidebar(store: store)
                .frame(height: viewportHeight)
                .navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 285)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if !store.verificationNotice.isEmpty {
                        InlineNotice(text: store.verificationNotice, icon: "testtube.2")
                            .padding([.horizontal, .top], 16)
                    }
                    if !store.platformProfileNotice.isEmpty {
                        InlineNotice(text: store.platformProfileNotice, icon: "externaldrive")
                            .padding([.horizontal, .top], 16)
                            .accessibilityIdentifier("platform-profile-origin")
                    }
                    if !store.storageError.isEmpty {
                        InlineNotice(text: store.storageError, icon: "exclamationmark.triangle", warning: true)
                            .padding([.horizontal, .top], 16)
                    }
                    activeContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                Inspector(store: store).frame(width: 236)
            }
            .frame(height: viewportHeight)
        }
        .sheet(isPresented: $store.showConnectionSettings) {
            ConnectionSettingsView(store: store)
        }
        .sheet(isPresented: $store.showRecovery) {
            DraftRecoveryView(store: store)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Image(systemName: "square.stack.3d.up").foregroundStyle(.orange)
                    Text(store.selectedProject?.name ?? "M3 Desk").font(.subheadline.weight(.medium))
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.section = .handoff } label: {
                    Label("Preparar contexto", systemImage: "arrow.up.right")
                }
                .disabled(store.selectedProject == nil)
                .help("Preparar um rascunho local para copiar ou exportar")
            }
        }
    }

    @ViewBuilder private var activeContent: some View {
        switch store.section {
        case .workspace: ProjectWorkspace(store: store)
        case .memory: MemoryView(store: store)
        case .handoff: HandoffView(store: store)
        case .runs: RunsView(store: store)
        }
    }
}

struct Sidebar: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.orange).font(.title3)
                    Text("M3 Desk").font(.headline)
                }
                Picker("Organização", selection: Binding(get: { store.selectedTenantID }, set: store.selectTenant)) {
                    ForEach(store.tenants) { tenant in Text(tenant.name).tag(tenant.id) }
                }
                .labelsHidden()
                .accessibilityLabel("Organização ou espaço pessoal")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .fixedSize(horizontal: false, vertical: true)

            List {
                Section {
                    ForEach(AppSection.allCases) { section in
                        Button { store.section = section } label: {
                            Label {
                                Text(section.rawValue)
                            } icon: {
                                Image(systemName: section.icon)
                                    .foregroundStyle(store.section == section ? Color.orange : Color.secondary)
                            }
                                .font(.subheadline.weight(store.section == section ? .semibold : .regular))
                                .foregroundStyle(store.section == section ? Color.orange : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 7)
                                .padding(.horizontal, 7)
                                .background(store.section == section ? Color.orange.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(store.section == section ? .isSelected : [])
                        .accessibilityRemoveTraits(store.section == section ? [] : .isSelected)
                    }
                }
                Section {
                    TextField("Filtrar projetos", text: $store.projectFilter)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Filtrar lista de projetos")
                    ForEach(store.visibleProjects) { project in
                        Button {
                            store.select(project)
                            store.section = .workspace
                        } label: {
                            HStack(spacing: 9) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(store.selectedProject?.id == project.id ? Color.orange : Color.secondary.opacity(0.4))
                                    .frame(width: 6, height: 20)
                                Text(project.name).lineLimit(2)
                                Spacer(minLength: 0)
                                if store.selectedProject?.id == project.id {
                                    Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 7)
                            .padding(.horizontal, 7)
                            .contentShape(Rectangle())
                            .background(store.selectedProject?.id == project.id ? Color.orange.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(store.selectedProject?.id == project.id ? .isSelected : [])
                        .accessibilityRemoveTraits(store.selectedProject?.id == project.id ? [] : .isSelected)
                    }
                    if store.visibleProjects.isEmpty {
                        Text("Nenhum projeto neste filtro.")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                } header: {
                    HStack { Text("Projetos"); Spacer(); Text("\(store.visibleProjects.count)").monospacedDigit() }
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .layoutPriority(-1)

            VStack(alignment: .leading, spacing: 9) {
                Text(store.registryLabel).font(.caption2).foregroundStyle(.secondary)
                Menu("Configuração local") {
                    Button("Importar registro de projetos…") { store.configureRegistry() }
                    Button("Recuperar rascunhos antigos…") {
                        store.refreshRecoveryCandidates()
                        store.showRecovery = true
                    }
                }
                .font(.caption)
                .menuStyle(.borderlessButton)
                .fixedSize()
                HStack(alignment: .top, spacing: 7) {
                    if store.isConnecting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle().fill(store.connectionReady ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 6, height: 6).padding(.top, 4)
                    }
                    Text(store.connectionState).font(.caption).lineLimit(3).foregroundStyle(.secondary)
                }
                Button(store.connectionReady ? "Verificar conexão" : "Conectar ao M3") { store.checkMCP() }
                    .font(.caption)
                    .disabled(store.isConnecting)
                Button("Conexão…") { store.showConnectionSettings = true }
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.primary.opacity(0.025))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct ProjectWorkspace: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        if let project = store.selectedProject {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Retomar projeto").font(.subheadline).foregroundStyle(.secondary)
                        Text(project.name).font(.title2.weight(.semibold))
                        if !project.detail.isEmpty { Text(project.detail).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    if !store.localNotice.isEmpty { InlineNotice(text: store.localNotice, icon: "internaldrive") }
                    if !store.checkpointError.isEmpty {
                        InlineNotice(text: store.checkpointError, icon: "exclamationmark.triangle", warning: true)
                    }
                    if !store.checkpointSummary.isEmpty {
                        WorkspacePanel {
                            SectionHeader(title: "Checkpoint do servidor", detail: "Recuperado no contexto autorizado")
                            Text(store.checkpointSummary).font(.subheadline).lineLimit(6)
                            DisclosureGroup("Checkpoint completo e fontes") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(store.checkpointSummary).font(.subheadline).textSelection(.enabled)
                                    Divider()
                                    ForEach(Array(store.checkpointSources.enumerated()), id: \.offset) { _, source in
                                        Text(source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                                .padding(.top, 8)
                            }
                            .font(.caption)
                            Button("Usar no rascunho local") { store.adoptCheckpoint() }
                                .disabled(!store.draftWritable)
                        }
                    }
                    WorkspacePanel {
                        SectionHeader(title: "Onde parei", detail: "Checkpoint local do contexto selecionado")
                        EditableBlock(text: $store.handoff.context, placeholder: "Registre o ponto de retomada…", height: 100, save: store.saveDraft)
                        SectionHeader(title: "Próxima ação")
                        TextField("Defina uma ação concreta…", text: $store.handoff.objective)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Próxima ação")
                            .onChange(of: store.handoff.objective) { _, _ in store.saveDraft() }
                    }
                    .disabled(!store.draftWritable)
                    WorkspacePanel {
                        SectionHeader(title: "O que mudou", detail: "Delta registrado por você desde o último checkpoint")
                        EditableBlock(text: $store.handoff.delta, placeholder: "Registre mudanças, resultados ou novas decisões…", save: store.saveDraft)
                        SectionHeader(title: "Bloqueios e pendências")
                        EditableBlock(text: $store.handoff.pending, placeholder: "Anote dependências e decisões ainda abertas…", height: 68, save: store.saveDraft)
                    }
                    .disabled(!store.draftWritable)
                    HStack {
                        Button { store.section = .handoff } label: { Label("Preparar contexto", systemImage: "arrow.up.right") }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                        Text("Rascunho local").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(22)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            EmptyState(title: "Selecione um projeto", message: "Escolha uma organização e um projeto para retomar seu contexto local.", icon: "sidebar.left")
        }
    }
}

struct Inspector: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Contexto selecionado").font(.headline)
                if let project = store.selectedProject {
                    InspectorRow(label: "Organização / espaço", value: store.tenants.first(where: { $0.id == store.selectedTenantID })?.name ?? store.selectedTenantID)
                    InspectorRow(label: "Projeto", value: project.name)
                    DisclosureGroup("Identidade do projeto") {
                        InspectorRow(label: "ID", value: project.id, monospaced: true)
                            .padding(.top, 5)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if !project.subprojects.isEmpty {
                        Picker("Subprojeto", selection: Binding(get: { store.selectedSubproject }, set: store.selectSubproject)) {
                            Text("Projeto inteiro").tag("")
                            ForEach(project.subprojects) { subproject in Text(subproject.name).tag(subproject.id) }
                        }
                        .font(.caption)
                    }
                    Divider()
                    InspectorRow(label: "Versão local", value: store.handoff.version, monospaced: true)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Fontes e versões").font(.subheadline.weight(.medium))
                        EditableBlock(text: $store.handoff.sources, placeholder: "Adicione fonte, versão e data…", height: 114, save: store.saveDraft)
                            .disabled(!store.draftWritable)
                        Text("Referências registradas no rascunho. Verifique a origem antes de usar.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Divider()
                    InspectorRow(label: "Conexão", value: store.connectionState)
                    Text(store.capabilitiesMessage).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("O inspector acompanha o projeto selecionado em todas as telas.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
