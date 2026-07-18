import SwiftUI
import UniformTypeIdentifiers

/// Global document library: add/manage documents once, then reuse them across chats
/// (each chat opts in via "Globale Bibliothek einbeziehen").
struct LibraryView: View {
    @ObservedObject private var viewModel: LibraryViewModel
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var graphExtractionService = GraphExtractionService.shared
    @State private var isDragTargeted = false
    @State private var showFilePicker = false
    @State private var showURLPrompt = false
    @State private var urlInput = ""
    @State private var pendingCategory = ""

    init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $viewModel.section) {
                Text(localizedAppText("Documents", de: "Dokumente")).tag(LibrarySection.documents)
                Text(localizedAppText("System Prompts", de: "System-Prompts")).tag(LibrarySection.prompts)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            switch viewModel.section {
            case .documents:
                documentsSection
            case .prompts:
                promptsSection
            }
        }
        .padding()
        .onAppear { viewModel.reload() }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: ChatView.importableContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls { viewModel.importDocument(url: url, category: pendingCategory) }
            }
        }
        .sheet(isPresented: $showURLPrompt) {
            URLPromptSheet(urlInput: $urlInput) { url in
                viewModel.importURL(url, category: pendingCategory)
            }
        }
    }

    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            dropArea
            if viewModel.documents.isEmpty {
                ContentUnavailableView {
                    Label(localizedAppText("No documents yet", de: "Noch keine Dokumente"),
                          systemImage: "books.vertical")
                } description: {
                    Text(localizedAppText(
                        "Add documents here to make them available across all chats.",
                        de: "Füge hier Dokumente hinzu, um sie in allen Chats nutzen zu können."
                    ))
                }
                .frame(maxHeight: .infinity)
            } else {
                documentList
            }
        }
    }

    private var promptsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(localizedAppText("System Prompt Presets", de: "System-Prompt-Vorlagen"),
                      systemImage: "text.badge.star")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    viewModel.createPreset()
                } label: {
                    Label(localizedAppText("New", de: "Neu"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            Text(localizedAppText(
                "Save reusable system prompts and pick them in any chat instead of retyping.",
                de: "Speichere wiederverwendbare System-Prompts und wähle sie in jedem Chat aus, statt sie neu zu tippen."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            if viewModel.presets.isEmpty {
                ContentUnavailableView {
                    Label(localizedAppText("No presets yet", de: "Noch keine Vorlagen"),
                          systemImage: "text.badge.star")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.presets, id: \.id) { preset in
                        PresetEditorRow(
                            preset: preset,
                            onSave: { title, content in
                                viewModel.updatePreset(preset, title: title, content: content)
                            },
                            onDelete: { viewModel.deletePreset(preset) }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var header: some View {
        HStack {
            Label(localizedAppText("Knowledge Library", de: "Wissens-Bibliothek"),
                  systemImage: "books.vertical.fill")
                .font(.title2.weight(.semibold))
            if !viewModel.documents.isEmpty {
                Text("\(viewModel.documents.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            categoryPicker

            if viewModel.isImporting {
                ProgressView().controlSize(.small)
            }
            Button {
                urlInput = ""
                showURLPrompt = true
            } label: {
                Label(localizedAppText("URL…", de: "URL …"), systemImage: "globe")
            }
            .disabled(viewModel.isImporting)
            .help(localizedAppText("Load a web page into the library", de: "Webseite in die Bibliothek laden"))

            Button {
                showFilePicker = true
            } label: {
                Label(localizedAppText("Add…", de: "Hinzufügen …"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isImporting)
        }
    }

    private var categoryPicker: some View {
        HStack(spacing: 4) {
            Image(systemName: "tag")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(
                localizedAppText("Category (optional)", de: "Kategorie (optional)"),
                text: $pendingCategory
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 140)
            if !viewModel.knownCategories.isEmpty {
                Menu {
                    ForEach(viewModel.knownCategories, id: \.self) { category in
                        Button(category) { pendingCategory = category }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(localizedAppText("Pick an existing category", de: "Vorhandene Kategorie wählen"))
            }
        }
        .help(localizedAppText(
            "Applied to the next document(s) you add.",
            de: "Wird für die nächsten hinzugefügten Dokumente verwendet."
        ))
    }

    private var dropArea: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            .foregroundStyle(isDragTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
            .frame(height: 60)
            .overlay(
                Text(localizedAppText(
                    "Drop .txt, .md, .pdf or .docx files here",
                    de: ".txt-, .md-, .pdf- oder .docx-Dateien hier ablegen"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            )
            .background(isDragTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
            .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
                handleDrop(providers)
            }
    }

    private var documentList: some View {
        List {
            ForEach(viewModel.documents, id: \.id) { doc in
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.fileName).font(.body)
                        Text("\(doc.chunkCount) " + localizedAppText("chunks", de: "Abschnitte"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    DocumentCategoryEditor(
                        document: doc,
                        knownCategories: viewModel.knownCategories,
                        onSave: { viewModel.updateDocumentCategory(doc, category: $0) }
                    )
                    if pluginManager.graphStoragePlugins.contains(where: { $0.isReady }) {
                        graphExtractButton(for: doc)
                    }
                    Button(role: .destructive) {
                        viewModel.deleteDocument(doc)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func graphExtractButton(for doc: ChatDocument) -> some View {
        let progress = graphExtractionService.activeExtractions[doc.id]
        if let progress, !progress.isFinished {
            ProgressView()
                .controlSize(.small)
                .help(localizedAppText("Extracting knowledge graph…", de: "Wissensgraph wird extrahiert …"))
        } else {
            HStack(spacing: 4) {
                Button {
                    viewModel.extractToGraph(doc)
                } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.borderless)
                .help(progress?.errorMessage ?? localizedAppText(
                    "Extract into knowledge graph",
                    de: "In Wissensgraph extrahieren"
                ))

                if let errorMessage = progress?.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(errorMessage)
                }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var found = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    viewModel.importDocument(url: url, category: pendingCategory)
                }
            }
            found = true
        }
        return found
    }
}

// MARK: - Document Category Editor

private struct DocumentCategoryEditor: View {
    let document: ChatDocument
    let knownCategories: [String]
    let onSave: (String) -> Void

    @State private var text: String = ""

    var body: some View {
        HStack(spacing: 2) {
            TextField(localizedAppText("Category", de: "Kategorie"), text: $text)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 90)
                .onSubmit { onSave(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if !knownCategories.isEmpty {
                Menu {
                    Button(localizedAppText("None", de: "Keine")) {
                        text = ""
                        onSave("")
                    }
                    ForEach(knownCategories, id: \.self) { category in
                        Button(category) {
                            text = category
                            onSave(category)
                        }
                    }
                } label: {
                    Image(systemName: "tag")
                        .font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .onAppear { text = document.category }
    }
}

// MARK: - Preset Editor Row

private struct PresetEditorRow: View {
    let preset: SystemPromptPreset
    let onSave: (String, String) -> Void
    let onDelete: () -> Void

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var isExpanded = false

    private var isDirty: Bool { title != preset.title || content != preset.content }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(localizedAppText("Title", de: "Titel"), text: $title)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button {
                        TextEditorWindowManager.shared.present(
                            autosaveKey: "text-editor.preset.\(preset.id.uuidString)",
                            title: title.isEmpty ? localizedAppText("Untitled", de: "Ohne Titel") : title,
                            text: $content
                        )
                    } label: {
                        Label(localizedAppText("Edit in window", de: "Erweitert bearbeiten"), systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                TextEditor(text: $content)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 140)
                    .padding(6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button(role: .destructive) { onDelete() } label: {
                        Label(localizedAppText("Delete", de: "Löschen"), systemImage: "trash")
                    }
                    Spacer()
                    Button(localizedAppText("Save", de: "Speichern")) {
                        onSave(title.trimmingCharacters(in: .whitespacesAndNewlines), content)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.vertical, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.title.isEmpty ? localizedAppText("Untitled", de: "Ohne Titel") : preset.title)
                    .font(.body)
                if !preset.content.isEmpty {
                    Text(preset.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .onAppear {
            title = preset.title
            content = preset.content
        }
    }
}
