import SwiftUI

struct SectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct WorkspacePanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EditableBlock: View {
    @Binding var text: String
    let placeholder: String
    var height: CGFloat = 84
    let save: () -> Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(7)
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 15)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(placeholder)
            .onChange(of: text) { _, _ in _ = save() }
    }
}

struct DraftField: View {
    let label: String
    @Binding var text: String
    let save: () -> Bool
    var multiline = false
    var placeholder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.medium))
            if multiline {
                EditableBlock(text: $text, placeholder: placeholder.isEmpty ? label : placeholder, save: save)
            } else {
                TextField(placeholder.isEmpty ? label : placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(label)
                    .onChange(of: text) { _, _ in _ = save() }
            }
        }
    }
}

struct InspectorRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value.isEmpty ? "Não registrado" : value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct InlineNotice: View {
    let text: String
    var icon = "info.circle"
    var warning = false

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption)
        .foregroundStyle(warning ? Color.orange : Color.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background((warning ? Color.orange : Color.primary).opacity(0.065), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct EmptyState: View {
    let title: String
    let message: String
    var icon = "tray"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}
