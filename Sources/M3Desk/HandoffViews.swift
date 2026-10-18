import SwiftUI
import M3DeskCore

struct HandoffView: View {
    @ObservedObject var store: WorkspaceStore
    private let destinations = ["Claude · chat", "Claude Code", "ChatGPT", "Codex", "Devin", "OpenCode"]

    var body: some View {
        if store.selectedProject != nil {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Preparar contexto").font(.title2.weight(.semibold))
                    Text("Monte um handoff com o checkpoint, as mudanças e a próxima ação.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Picker("Conteúdo", selection: $store.showHandoffPreview) {
                            Text("Editar").tag(false)
                            Text("Prévia").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 175)
                        Spacer()
                        Menu {
                            ForEach(destinations, id: \.self) { destination in
                                Button(destination) { store.handoff.destination = destination; store.saveDraft() }
                            }
                        } label: {
                            Label(store.handoff.destination, systemImage: "person.2")
                        }
                        .disabled(!store.draftWritable)
                        .help("Identificação do destino no documento; não envia mensagens")
                    }
                }
                .padding(22)
                Divider()
                ScrollView {
                    if store.showHandoffPreview {
                        Text(store.handoff.preview)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(22)
                    } else {
                        VStack(alignment: .leading, spacing: 17) {
                            InspectorRow(label: "Projeto", value: store.selectedProject?.name ?? "")
                            DraftField(label: "Objetivo / próxima ação", text: $store.handoff.objective, save: store.saveDraft, placeholder: "Qual ação deve acontecer a seguir?")
                            DraftField(label: "Onde parei", text: $store.handoff.context, save: store.saveDraft, multiline: true, placeholder: "Checkpoint e contexto necessário…")
                            DraftField(label: "O que mudou", text: $store.handoff.delta, save: store.saveDraft, multiline: true, placeholder: "Resultados e decisões desde o último checkpoint…")
                            DraftField(label: "Fontes e versões", text: $store.handoff.sources, save: store.saveDraft, multiline: true, placeholder: "Origem, versão e data das referências…")
                            DraftField(label: "Bloqueios e pendências", text: $store.handoff.pending, save: store.saveDraft, multiline: true, placeholder: "Dependências, restrições e decisões em aberto…")
                        }
                        .disabled(!store.draftWritable)
                        .padding(22)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 9) {
                        Button { store.copyHandoff() } label: { Label("Copiar", systemImage: "doc.on.doc") }
                            .buttonStyle(.borderedProminent)
                        Button { store.exportHandoff() } label: { Label("Exportar…", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button { store.section = .runs } label: { Label("Execuções", systemImage: "play.circle") }
                            .buttonStyle(.borderless)
                    }
                    .disabled(!store.draftWritable)
                    Text(store.handoffFeedback.isEmpty ? "Rascunho local · copiar e exportar não inicia uma execução." : store.handoffFeedback)
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("handoff-feedback")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            EmptyState(title: "Escolha o contexto primeiro", message: "Selecione um projeto para preparar um handoff com identidade e rascunho próprios.", icon: "arrow.up.right")
        }
    }
}

struct MemoryView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Busca & memória").font(.title2.weight(.semibold))
                Text(store.selectedProject.map { "Contexto: \($0.name)" } ?? "Selecione um projeto para consultar seu contexto.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 9) {
                TextField("Buscar neste projeto…", text: $store.memoryQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if store.supportsScopedSearch && !store.isSearching { store.searchMemory() } }
                    .accessibilityLabel("Busca na memória do projeto")
                Button { store.searchMemory() } label: {
                    if store.isSearching { ProgressView().controlSize(.small) } else { Text("Buscar") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.supportsScopedSearch || store.selectedProject == nil || store.memoryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSearching)
            }
            if !store.supportsScopedSearch {
                InlineNotice(text: store.capabilitiesMessage.isEmpty ? "Busca por projeto indisponível. O servidor precisa validar a organização, o projeto e suas permissões antes da consulta." : store.capabilitiesMessage, icon: "lock", warning: true)
            }
            Text(store.memorySearchState).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("memory-search-state")
            if store.memoryResults.isEmpty {
                EmptyState(title: store.isSearching ? "Consultando o contexto…" : store.supportsScopedSearch ? "Busque neste projeto" : "Conecte para buscar", message: store.supportsScopedSearch ? "Digite uma palavra ou uma decisão que deseja recuperar e clique em Buscar." : "Abra Conexão para conectar à M3 Platform. Seus rascunhos locais continuam disponíveis.", icon: "magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(store.memoryResults.enumerated()), id: \.offset) { _, result in
                            Text(result)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .padding(22)
    }
}

struct RunsView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Execuções").font(.title2.weight(.semibold))
                    Text("Acompanhe os registros e os eventos confirmados pelo servidor.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                WorkspacePanel {
                    SectionHeader(title: "Objetivo a enviar")
                    InspectorRow(label: "Projeto", value: store.selectedProject?.name ?? "Nenhum selecionado")
                    Text(verbatim: store.handoff.objective.isEmpty ? "Defina a próxima ação no handoff." : store.handoff.objective)
                        .font(.subheadline).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("run-objective-preview")
                    Text("Somente este objetivo e o executor selecionado serão enviados. O restante do handoff continua local.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { store.section = .handoff } label: { Label("Revisar handoff", systemImage: "doc.text") }
                        .disabled(store.selectedProject == nil)
                    Divider()
                    providerPicker
                }
                if !store.executionProviders.contains(where: \.isSupported) {
                    InlineNotice(text: "Nenhum executor compatível foi anunciado. Verifique a conexão para consultar a disponibilidade.", icon: "clock", warning: true)
                } else if !store.canRegisterRun {
                    InlineNotice(text: "Conecte a um projeto com permissão para registrar execuções. Seu handoff local continua disponível.", icon: "lock", warning: true)
                }
                if !store.pendingRunNotice.isEmpty {
                    InlineNotice(text: store.pendingRunNotice, icon: "arrow.clockwise", warning: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { createButton; refreshButton; Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 10) { createButton; refreshButton }
                }
                Text(store.runStatus)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("run-status")
                Divider()
                if store.runs.isEmpty {
                    EmptyState(title: "Nenhuma execução carregada", message: "Após conectar, atualize a lista para recuperar as execuções deste projeto.", icon: "clock.arrow.circlepath")
                        .frame(minHeight: 170)
                } else {
                    SectionHeader(title: "Neste projeto", detail: "Selecione uma execução para acompanhar seus eventos")
                    LazyVStack(spacing: 9) {
                        ForEach(store.runs) { run in
                            RunRow(run: run, selected: store.selectedRunID == run.id) { store.selectRun(run) }
                        }
                    }
                    if let run = store.runs.first(where: { $0.id == store.selectedRunID }) {
                        runDetail(run)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var selectedProvider: DeskExecutionProvider? {
        store.executionProviders.first { $0.id == store.selectedProviderID && $0.isSupported }
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("Executor", selection: Binding(
                get: { selectedProvider?.id ?? "" },
                set: { store.selectProvider($0) }
            )) {
                Text("Escolha um executor…").tag("")
                ForEach(store.executionProviders.filter(\.isSupported)) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }
            .disabled(store.isRunning || !store.draftWritable || store.executionProviders.isEmpty)
            .accessibilityIdentifier("execution-provider")
            if let provider = selectedProvider {
                Text(provider.kindLabel).font(.subheadline.weight(.medium))
                if let model = provider.model, !model.isEmpty {
                    Text(verbatim: model).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if provider.kind == "text-model" {
                    Text("Modelo experimental para respostas curtas em texto. Sem ferramentas ou histórico entre pedidos.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if provider.kind == "docker-tool" {
                    Text("Executa uma ferramenta predefinida no servidor. Não usa modelo de IA.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Escolha explicitamente como executar este objetivo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var createButton: some View {
        Button { store.executeHandoff() } label: {
            Label(selectedProvider?.kind == "text-model" ? "Iniciar modelo local" : selectedProvider?.kind == "docker-tool" ? "Executar ferramenta" : "Iniciar execução", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!store.canRegisterRun || selectedProvider == nil || store.isRunning || !store.draftWritable || store.handoff.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("create-run")
    }

    private var refreshButton: some View {
        Button { store.refreshRuns() } label: { Label("Atualizar lista", systemImage: "arrow.clockwise") }
            .disabled(!store.canRefreshRuns || store.isRunning)
            .accessibilityIdentifier("refresh-runs")
    }

    private func runDetail(_ run: DeskRun) -> some View {
        WorkspacePanel {
            HStack(alignment: .top) {
                SectionHeader(title: "Eventos da execução", detail: "O histórico acompanha este projeto e esta identidade.")
                Spacer(minLength: 8)
                if store.isLoadingEvents { ProgressView().controlSize(.small) }
            }
            InspectorRow(label: "ID da execução", value: run.id, monospaced: true)
            InspectorRow(label: "Executor", value: run.providerLabel)
            if let failure = run.failureCode, !failure.isEmpty {
                InspectorRow(label: "Falha informada pelo servidor", value: failure, monospaced: true)
                if failure == "effect_requires_reconciliation" {
                    InlineNotice(text: "O servidor exige reconciliar o efeito da tentativa anterior antes de retomar. O rascunho permanece salvo.", icon: "exclamationmark.circle", warning: true)
                }
            }
            if let model = run.resultModel, !model.isEmpty {
                InspectorRow(label: "Modelo informado pelo resultado", value: model, monospaced: true)
            }
            if let result = run.resultText, !result.isEmpty {
                Divider()
                Text("Resultado textual").font(.subheadline.weight(.semibold))
                Text(verbatim: result)
                    .font(.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("run-result-text")
                Divider()
            }
            if let checkpoint = run.checkpointText, !checkpoint.isEmpty {
                DisclosureGroup("Checkpoint da execução") {
                    Text(verbatim: checkpoint)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .font(.caption)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { eventButtons(run); Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 10) { eventButtons(run) }
            }
            Text(store.eventsStatus).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("run-events-status")
            if store.runEvents.isEmpty {
                Text("Nenhum evento carregado para esta execução.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(store.runEvents, id: \.id) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(Color.orange.opacity(0.65)).frame(width: 6, height: 6).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(eventTitle(event.type)).font(.subheadline.weight(.medium))
                                Text(eventDate(event.createdAt)).font(.caption2).foregroundStyle(.secondary)
                                if let payload = eventPayload(event.payload), payload != "{}", payload != "null" {
                                    DisclosureGroup("Detalhes do evento") {
                                        Text(payload).font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                            .padding(.top, 4)
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func eventPayload(_ payload: PlatformJSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func eventDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let precise = formatter.date(from: value)
        formatter.formatOptions = [.withInternetDateTime]
        return (precise ?? formatter.date(from: value))?.formatted(date: .abbreviated, time: .shortened) ?? value
    }

    private func eventTitle(_ type: String) -> String {
        switch type {
        case "run.created", "created": "Execução registrada"
        case "run.queued", "queued": "Adicionada à fila"
        case "run.started", "started", "running": "Trabalho iniciado"
        case "run.resumed", "resumed": "Retomada solicitada"
        case "run.cancelled", "cancelled": "Execução cancelada"
        case "run.succeeded", "succeeded": "Execução concluída"
        case "run.failed", "failed": "Execução falhou"
        default: type
        }
    }

    @ViewBuilder private func eventButtons(_ run: DeskRun) -> some View {
        Button { store.refreshRunEvents() } label: { Label("Atualizar eventos", systemImage: "arrow.clockwise") }
            .disabled(!store.canRefreshRunEvents || store.isLoadingEvents || store.isRunning)
        if store.canResume(run) {
            Button { store.resumeRun(run) } label: { Label("Retomar", systemImage: "play.circle") }
                .disabled(store.isRunning)
        }
        if store.canCancel(run) {
            Button(role: .destructive) { store.cancelRun(run) } label: { Label("Cancelar", systemImage: "stop.circle") }
                .disabled(store.isRunning)
                .help("Cancela esta execução e os filhos no servidor")
        }
    }
}

private struct RunRow: View {
    let run: DeskRun
    let selected: Bool
    let select: () -> Void

    private var state: (title: String, icon: String, color: Color) {
        switch run.status {
        case "queued": ("Na fila", "clock", .secondary)
        case "running": ("Em andamento", "arrow.triangle.2.circlepath", .orange)
        case "succeeded": ("Concluída", "checkmark.circle", .green)
        case "failed": ("Falhou", "exclamationmark.circle", .red)
        case "cancelled": ("Cancelada", "stop.circle", .secondary)
        default: (run.status, "questionmark.circle", .secondary)
        }
    }

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: state.icon).foregroundStyle(state.color).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(run.summary.isEmpty ? "Execução sem descrição" : run.summary)
                        .font(.subheadline.weight(.medium)).lineLimit(3)
                    Text(state.title).font(.caption).foregroundStyle(state.color)
                    Text(run.providerLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.orange.opacity(0.08) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.orange.opacity(0.4) : Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityRemoveTraits(selected ? [] : .isSelected)
        .accessibilityLabel("\(run.summary), \(state.title), \(run.providerLabel)")
    }
}

struct DraftRecoveryView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Recuperar rascunhos antigos", detail: "Escolha um rascunho para copiar para o contexto selecionado.")
            InspectorRow(label: "Destino", value: [store.tenants.first(where: { $0.id == store.selectedTenantID })?.name, store.selectedProject?.name, store.selectedSubprojectName.isEmpty ? nil : store.selectedSubprojectName].compactMap { $0 }.joined(separator: " / "))
            InlineNotice(text: "O original é preservado. A recuperação só pode ocupar um contexto local que ainda não tenha um rascunho salvo.", icon: "doc.on.doc")
            if !store.canRecoverLegacyDraft {
                InlineNotice(text: "Este contexto já tem um rascunho salvo ou está indisponível. Selecione um destino vazio; novos projetos podem ser adicionados pela configuração local.", icon: "lock", warning: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.recoveryCandidates) { candidate in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(candidate.projectName ?? "Rascunho sem nome legível").font(.subheadline.weight(.medium))
                                Text(status(candidate.status)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Recuperar") { store.recoverLegacy(candidate) }
                                .disabled(candidate.status == .malformed || !store.canRecoverLegacyDraft)
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if store.recoveryCandidates.isEmpty {
                        EmptyState(title: "Nenhum rascunho antigo encontrado", message: "Os rascunhos novos são preservados por organização, projeto e identidade.", icon: "doc")
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 320)
            if !store.storageError.isEmpty { InlineNotice(text: store.storageError, warning: true) }
            HStack {
                Button("Atualizar") { store.refreshRecoveryCandidates() }
                Spacer()
                Button("Fechar") { store.showRecovery = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private func status(_ status: LegacyDraftCandidate.Status) -> String {
        switch status {
        case .recoverable: "Disponível para recuperação"
        case .alreadyAssigned: "Já atribuído anteriormente · uma cópia adicional preserva o original"
        case .keyMismatch: "Nome e chave antiga divergem · requer seleção explícita"
        case .malformed: "Conteúdo ilegível · original preservado"
        }
    }
}
