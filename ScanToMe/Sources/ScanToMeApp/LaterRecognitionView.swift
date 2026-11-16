import AppKit
import ScanCore
import SwiftUI

/// „Später erkennen“: ohne Inhaltserkennung abgelegte Scans nachträglich von Claude benennen lassen.
/// Je Datei: erkennen, Vorschlag prüfen und ändern, dann umbenennen. Der Dateiinhalt bleibt unverändert.
struct LaterRecognitionView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var scan: ScanModel
    @Environment(\.dismiss) private var dismiss

    @State private var selected: FiledScan?
    @State private var proposal: DocumentProposal?
    @State private var isWorking = false
    @State private var message: String?
    @State private var renamed: [String] = []
    @State private var trashed: [String] = []
    @State private var confirmTrash: FiledScan?
    /// Womit erkannt wird; vorbelegt mit der gewählten Art (bei „Aus“ lokal, wenn möglich).
    @State private var engine: RecognitionMode = .local

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "text.viewfinder").font(.title).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("Später erkennen", "Recognise later")).font(.title2.bold())
                    Text(loc("Diese Scans wurden ohne Inhaltserkennung abgelegt. Sie lassen sich jetzt benennen; "
                             + "die Datei wird dabei nur umbenannt.",
                             "These scans were saved without content recognition. They can be named now; "
                             + "the file is only renamed."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Text(loc("Erkennen mit:", "Recognise with:"))
                Picker(loc("Erkennen mit", "Recognise with"), selection: $engine) {
                    Text(RecognitionMode.local.label).tag(RecognitionMode.local)
                    Text(RecognitionMode.claude.label).tag(RecognitionMode.claude)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(isWorking)
                Label(engine == .local ? loc("bleibt auf diesem Mac, Erkennung ungenauer", "stays on this Mac, less accurate")
                                       : loc("wird an Anthropic gesendet", "is sent to Anthropic"),
                      systemImage: engine == .local ? "lock" : "icloud.and.arrow.up")
                    .font(.callout).foregroundStyle(.secondary)
                if !scan.isAvailable(engine) {
                    Text(engine == .local ? scan.localStatus.explanation
                                          : loc("Dafür fehlt der API-Schlüssel.", "This needs the API key."))
                        .font(.callout)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                fileList.frame(width: 300)
                detail.frame(maxWidth: .infinity, alignment: .topLeading)
            }

            if !renamed.isEmpty {
                Label(loc("Umbenannt: ", "Renamed: ") + renamed.joined(separator: ", "), systemImage: "checkmark.circle")
                    .font(.callout)
                    .lineLimit(3)
            }
            if !trashed.isEmpty {
                Label(loc("In den Papierkorb gelegt: ", "Moved to Trash: ") + trashed.joined(separator: ", "), systemImage: "trash")
                    .font(.callout)
                    .lineLimit(3)
            }
            HStack {
                Spacer()
                Button(loc("Schließen", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 860, height: 560)
        .onAppear {
            scan.refreshLaterScans()
            scan.refreshLocalStatus()
            engine = scan.explicitMode ?? (scan.localAvailable ? .local : .claude)
        }
        .confirmationDialog(loc("Diese Datei in den Papierkorb legen?", "Move this file to the Trash?"),
                            isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } }),
                            presenting: confirmTrash) { item in
            Button(loc("In den Papierkorb", "Move to Trash"), role: .destructive) { trash(item) }
            Button(loc("Abbrechen", "Cancel"), role: .cancel) {}
        } message: { item in
            Text(loc("„\(item.name)“ wird in den Papierkorb gelegt. Von dort lässt sie sich zurücklegen.",
                     "“\(item.name)” will be moved to the Trash. You can put it back from there."))
        }
    }

    private var fileList: some View {
        List(scan.laterScans, selection: Binding(get: { selected?.url }, set: { url in
            guard !isWorking else { return }
            selected = scan.laterScans.first { $0.url == url }
            proposal = nil
            message = nil
        })) { item in
            Label(item.name, systemImage: "doc.richtext")
                .font(.body.monospaced())
                .tag(item.url)
        }
        .overlay {
            if scan.laterScans.isEmpty {
                Text(loc("Keine Scans ohne Erkennung im Ablageordner.", "No scans without recognition in the storage folder."))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = selected {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    FileNameText(name: item.name)
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(item.url)
                    } label: {
                        Label(loc("Ansehen", "View"), systemImage: "eye")
                    }
                    .help(loc("Öffnet die Datei in Vorschau", "Opens the file in Preview"))
                    Button(role: .destructive) {
                        confirmTrash = item
                    } label: {
                        Label(loc("Löschen …", "Delete …"), systemImage: "trash")
                    }
                    .disabled(isWorking)
                    .help(loc("Legt die Datei in den Papierkorb", "Moves the file to the Trash"))
                }
                if let proposal {
                    editor(item: item, proposal: proposal)
                } else {
                    HStack(spacing: 10) {
                        Button {
                            recognize(item)
                        } label: {
                            Label(loc("Inhalt erkennen", "Recognise content"), systemImage: "text.viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking || !scan.isAvailable(engine))
                        if isWorking { ProgressView().controlSize(.small) }
                    }
                }
                if let message {
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            .card()
        } else {
            Text(loc("Wählen Sie links eine Datei.", "Choose a file on the left."))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
    }

    private func editor(item: FiledScan, proposal: DocumentProposal) -> some View {
        let binding = Binding(get: { self.proposal ?? proposal }, set: { self.proposal = $0 })
        return VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(loc("Typ", "Type")).foregroundStyle(.secondary)
                    Picker(loc("Typ", "Type"), selection: binding.typeCode) {
                        ForEach(scan.typeCatalog) { type in
                            Text("\(DocumentTypes.displayCode(type.code)) – \(type.isBuiltIn ? DocumentTypes.displayTitle(type) : type.hint)")
                                .tag(type.code)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text(loc("Von", "From")).foregroundStyle(.secondary)
                    TextField(loc("Absender", "Sender"), text: binding.sender)
                }
                GridRow {
                    Text(loc("Name", "Name")).foregroundStyle(.secondary)
                    TextField(loc("Kurzbezeichnung", "Short description"), text: binding.title)
                }
                GridRow {
                    Text(loc("Datum", "Date")).foregroundStyle(.secondary)
                    DatePicker(loc("Datum", "Date"), selection: Binding(
                        get: { binding.wrappedValue.documentDate ?? item.date },
                        set: { binding.wrappedValue.documentDate = $0; binding.wrappedValue.dateKind = "manuell" }),
                               displayedComponents: .date)
                        .labelsHidden()
                }
            }
            Divider()
            LabeledContent(loc("Neuer Name", "New name")) {
                FileNameText(name: LaterRecognition.proposedName(item, proposal: binding.wrappedValue, scheme: model.fileNameScheme))
            }
            HStack {
                Button(loc("Verwerfen", "Discard")) { self.proposal = nil }
                Spacer()
                Button(loc("Umbenennen", "Rename")) { rename(item) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func recognize(_ item: FiledScan) {
        if engine == .local {
            isWorking = true
            message = loc("Inhalt wird auf diesem Mac erkannt …", "Recognising content on this Mac …")
            let types = DocumentTypes.recognitionOrder(custom: model.customTypes)
            Task {
                defer { isWorking = false }
                do {
                    proposal = try await LaterRecognition.analyzeLocally(item, types: types)
                    message = nil
                } catch {
                    message = loc("Inhalt nicht erkannt", "Content not recognised") + ": "
                        + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
            return
        }
        guard let key = KeychainStore.anthropicAPIKey.read() else {
            message = loc("Es ist kein API-Schlüssel gespeichert.", "No API key is stored.")
            return
        }
        isWorking = true
        message = loc("Inhalt wird erkannt …", "Recognising content …")
        let types = DocumentTypes.recognitionOrder(custom: model.customTypes)
        Task {
            defer { isWorking = false }
            do {
                proposal = try await LaterRecognition.analyze(item, client: ClaudeClient(apiKey: key, ledger: .shared), types: types)
                message = nil
            } catch {
                message = loc("Inhalt nicht erkannt", "Content not recognised") + ": "
                    + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func trash(_ item: FiledScan) {
        do {
            try LaterRecognition.moveToTrash(item)
            trashed.append(item.name)
            proposal = nil
            selected = nil
            message = nil
            scan.refreshLaterScans()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func rename(_ item: FiledScan) {
        guard let proposal else { return }
        do {
            let url = try LaterRecognition.rename(item, proposal: proposal, scheme: model.fileNameScheme)
            renamed.append(url.lastPathComponent)
            self.proposal = nil
            selected = nil
            message = nil
            scan.refreshLaterScans()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
