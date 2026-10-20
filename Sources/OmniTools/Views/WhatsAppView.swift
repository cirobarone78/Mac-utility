import SwiftUI
import AppKit
import QuickLookThumbnailing
import UtilityCore

@MainActor
final class WhatsAppModel: ObservableObject {
    enum Age: Int, CaseIterable, Identifiable {
        case any = 0, m3 = 3, m6 = 6, y1 = 12, y2 = 24
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .any: "qualsiasi data"
            case .m3: "più vecchi di 3 mesi"
            case .m6: "più vecchi di 6 mesi"
            case .y1: "più vecchi di 1 anno"
            case .y2: "più vecchi di 2 anni"
            }
        }
    }

    @Published var root = WhatsAppScanner.dataFolder()
    @Published var scanning = false
    @Published var status = ""
    @Published var result: WhatsAppScanResult?
    @Published var selected: Set<URL> = []
    @Published var message: String?
    @Published var lastOperationID: String?
    @Published var running = false

    // Filtri
    @Published var kind: WhatsAppMedia.Kind?
    @Published var chat: String?
    @Published var age: Age = .any
    @Published var minMB: Double = 0
    @Published var onlyDuplicates = false

    private var task: Task<Void, Never>?

    func refreshRunning() {
        running = NSRunningApplication.runningApplications(withBundleIdentifier: WhatsAppScanner.bundleID).isEmpty == false
    }

    func quitWhatsApp() {
        NSRunningApplication.runningApplications(withBundleIdentifier: WhatsAppScanner.bundleID).forEach { $0.terminate() }
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); refreshRunning() }
    }

    func analyze(policy: SafetyPolicy) {
        guard let root else { return }
        task?.cancel()
        scanning = true
        message = nil
        selected = []
        refreshRunning()
        let box = WeakRef(self)
        task = Task {
            let r = await Self.run(root, policy: policy) { n in
                Task { @MainActor in box.value?.status = "\(n) file letti…" }
            }
            if Task.isCancelled { return }
            result = r
            scanning = false
            status = ""
            if r.mediaFolderUnreadable || (r.media.isEmpty && r.deniedFolders > 0) {
                message = "macOS non permette a OmniTools di leggere i dati di WhatsApp. Apri Impostazioni di Sistema › Privacy e sicurezza › Accesso completo al disco, attiva OmniTools (o aggiungilo con +), poi chiudi e riapri OmniTools."
            } else if r.media.isEmpty {
                message = "Nessun media trovato in \(Finder.short(root)). Se in WhatsApp hai foto e video, mandami il risultato di: du -sh ~/Library/Group\\ Containers/*whatsapp*/*"
            } else if r.deniedFolders > 0 {
                message = "Attenzione: \(r.deniedFolders) cartelle non leggibili per mancanza di permessi; il totale potrebbe essere incompleto."
            }
        }
    }

    nonisolated static func run(_ root: URL, policy: SafetyPolicy,
                                progress: @escaping @Sendable (Int) -> Void) async -> WhatsAppScanResult {
        WhatsAppScanner.scan(root: root, policy: policy, progress: progress, isCancelled: { Task.isCancelled })
    }

    var filtered: [WhatsAppMedia] {
        guard let result else { return [] }
        let cutoff = age == .any ? nil : Calendar.current.date(byAdding: .month, value: -age.rawValue, to: Date())
        let minBytes = Int64(minMB * 1_000_000)
        return result.media.filter { m in
            (kind == nil || m.kind == kind)
                && (chat == nil || m.chatID == chat)
                && (cutoff == nil || (m.date ?? .distantFuture) < cutoff!)
                && m.bytes >= minBytes
                && (!onlyDuplicates || result.duplicates.contains(m.url))
        }
        .sorted { $0.bytes > $1.bytes }
    }

    struct Total: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
        let count: Int
    }

    var byKind: [Total] {
        guard let result else { return [] }
        return Dictionary(grouping: result.media, by: \.kind)
            .map { Total(id: $0.key.rawValue, name: $0.key.rawValue, bytes: $0.value.reduce(0) { $0 + $1.bytes }, count: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
    }

    var byChat: [Total] {
        guard let result else { return [] }
        return Dictionary(grouping: result.media, by: \.chatID)
            .map { Total(id: $0.key, name: $0.value.first?.chatName ?? $0.key,
                         bytes: $0.value.reduce(0) { $0 + $1.bytes }, count: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
    }

    var duplicateBytes: Int64 {
        guard let result else { return 0 }
        return result.media.filter { result.duplicates.contains($0.url) }.reduce(0) { $0 + $1.bytes }
    }

    var selectedBytes: Int64 { (result?.media ?? []).filter { selected.contains($0.url) }.reduce(0) { $0 + $1.bytes } }

    func trash(policy: SafetyPolicy) {
        guard let result else { return }
        let items = result.media.filter { selected.contains($0.url) }
            .map { DiskItem(url: $0.url, bytes: $0.bytes, isDirectory: false) }
        let r = SafeRemover(policy: policy).moveToTrash(items, kind: "WhatsApp")
        lastOperationID = r.operationID
        message = "\(r.moved.count) file di WhatsApp nel Cestino (\(Bytes.format(r.bytes)))."
            + (r.skipped.isEmpty ? "" : " Saltati \(r.skipped.count). Motivo: \(r.skipped[0].reason)")
        let moved = Set(r.moved)
        self.result?.media.removeAll { moved.contains($0.url) }
        self.result?.duplicates.subtract(moved)
        selected.subtract(moved)
    }

    func restoreLast() {
        guard let id = lastOperationID else { return }
        message = (Restore.run(id) ?? "Già ripristinato.") + " Riapri WhatsApp per vedere di nuovo gli allegati."
        lastOperationID = nil
        result = nil
    }
}

struct WhatsAppView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = WhatsAppModel()
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .whatsapp,
                         subtitle: "Quanto occupano foto, video, vocali e documenti delle chat. Tutto finisce nel Cestino, con «Ripristina».")
            if let m = model.message, model.result?.media.isEmpty ?? false {
                Label(m, systemImage: "lock.shield").font(.callout).foregroundStyle(.orange)
                    .padding(.horizontal, 20).padding(.bottom, 8)
                HStack {
                    Button("Apri le impostazioni della privacy") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    Button("Mostra la cartella di WhatsApp") { if let r = model.root { Finder.reveal(r) } }
                }
                .padding(.horizontal, 20).padding(.bottom, 8)
            }
            if model.root == nil {
                ContentUnavailableView("WhatsApp per Mac non trovata", systemImage: Module.whatsapp.icon,
                                       description: Text("Installa l'app WhatsApp dal Mac App Store e accedi al tuo account."))
            } else {
                header
                Divider()
                content
            }
        }
        .onAppear { model.refreshRunning() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshRunning()
        }
        .confirmationDialog("Spostare nel Cestino \(model.selected.count) file di WhatsApp?", isPresented: $confirming) {
            Button("Sposta nel Cestino (\(Bytes.format(model.selectedBytes)))", role: .destructive) {
                model.trash(policy: state.policy)
            }
        } message: {
            Text("I messaggi restano nelle chat, ma questi allegati risulteranno «non disponibili» su questo Mac (sul telefono non cambia nulla). Puoi rimetterli a posto da Cronologia › Ripristina finché non svuoti il Cestino.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.running {
                HStack {
                    Label("WhatsApp è aperta: chiudila prima di eliminare qualcosa.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Chiudi WhatsApp") { model.quitWhatsApp() }
                }
                .font(.callout)
            }
            HStack {
                if let r = model.result {
                    Text("\(r.media.count) file · \(Bytes.format(r.totalBytes)) · copie identiche: \(Bytes.format(model.duplicateBytes))")
                        .font(.callout)
                } else {
                    Text("I media restano sul telefono: qui si libera solo lo spazio del Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.scanning {
                    Button("Interrompi") { model.result = nil; model.scanning = false }
                } else {
                    Button(model.result == nil ? "Analizza" : "Analizza di nuovo") { model.analyze(policy: state.policy) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let m = model.message {
                HStack {
                    Text(m).font(.caption).foregroundStyle(.secondary)
                    if model.lastOperationID != nil { Button("Ripristina") { model.restoreLast() }.controlSize(.small) }
                }
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.scanning {
            ProgressView(model.status.isEmpty ? "Leggo i media di WhatsApp…" : model.status)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = model.result, !result.media.isEmpty {
            HSplitView {
                summary.frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                fileList.frame(minWidth: 420)
            }
        } else {
            ContentUnavailableView {
                Label("Premi «Analizza»", systemImage: Module.whatsapp.icon)
            } description: {
                Text("Vedrai quanto spazio occupano foto, video, vocali e documenti, chat per chat, e potrai scegliere cosa togliere dal Mac.")
            } actions: {
                if model.lastOperationID != nil { Button("Ripristina") { model.restoreLast() } }
            }
        }
    }

    // MARK: - Riepilogo (clic = filtro)

    private var summary: some View {
        List {
            Section("Per tipo") {
                totalRow("Tutti i tipi", bytes: model.result?.totalBytes ?? 0, active: model.kind == nil) { model.kind = nil }
                ForEach(model.byKind) { t in
                    totalRow("\(t.name) (\(t.count))", bytes: t.bytes, active: model.kind?.rawValue == t.id) {
                        model.kind = WhatsAppMedia.Kind(rawValue: t.id)
                    }
                }
            }
            Section("Per chat") {
                totalRow("Tutte le chat", bytes: model.result?.totalBytes ?? 0, active: model.chat == nil) { model.chat = nil }
                ForEach(model.byChat.prefix(60)) { t in
                    totalRow(t.name, bytes: t.bytes, active: model.chat == t.id) { model.chat = t.id }
                }
            }
        }
    }

    private func totalRow(_ title: String, bytes: Int64, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).lineLimit(1).fontWeight(active ? .semibold : .regular)
                Spacer()
                Text(Bytes.format(bytes)).monospacedDigit().foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Brand.accent : .primary)
    }

    // MARK: - Elenco filtrato

    private var fileList: some View {
        let files = model.filtered
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $model.age) {
                    ForEach(WhatsAppModel.Age.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 190)
                HStack(spacing: 4) {
                    Text("almeno")
                    Slider(value: $model.minMB, in: 0...100, step: 5).frame(width: 90)
                    Text("\(Int(model.minMB)) MB").monospacedDigit().frame(width: 50, alignment: .leading)
                }
                Toggle("solo copie identiche", isOn: $model.onlyDuplicates)
            }
            .font(.callout)
            .padding(10)

            List(files.prefix(1500)) { m in
                WhatsAppRow(media: m, isDuplicate: model.result?.duplicates.contains(m.url) == true,
                            selected: Binding(get: { model.selected.contains(m.url) },
                                              set: { on in if on { model.selected.insert(m.url) } else { model.selected.remove(m.url) } }))
            }

            HStack {
                Text("\(files.count) file · \(Bytes.format(files.reduce(0) { $0 + $1.bytes }))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Seleziona tutti questi") { model.selected.formUnion(files.map(\.url)) }
                Button("Deseleziona") { model.selected = [] }
                Spacer()
                Text("Selezionati: \(Bytes.format(model.selectedBytes))").monospacedDigit()
                Button("Sposta nel Cestino…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selected.isEmpty || model.running)
                    .help(model.running ? "Chiudi prima WhatsApp" : "")
            }
            .padding(12)
        }
    }
}

private struct WhatsAppRow: View {
    let media: WhatsAppMedia
    let isDuplicate: Bool
    @Binding var selected: Bool
    @State private var thumb: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $selected).labelsHidden()
            Group {
                if let thumb {
                    Image(nsImage: thumb).resizable().scaledToFill()
                } else {
                    Image(systemName: icon).foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(media.chatName).lineLimit(1)
                    if isDuplicate { Badge(text: "copia", color: Brand.accent) }
                }
                Text([media.kind.rawValue, media.date?.formatted(date: .abbreviated, time: .omitted)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Bytes.format(media.bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Apri") { NSWorkspace.shared.open(media.url) }
            Button("Mostra nel Finder") { Finder.reveal(media.url) }
        }
        .task(id: media.url) {
            guard media.kind == .photo || media.kind == .video || media.kind == .sticker else { return }
            let request = QLThumbnailGenerator.Request(fileAt: media.url, size: CGSize(width: 88, height: 88),
                                                       scale: 2, representationTypes: .thumbnail)
            thumb = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }

    private var icon: String {
        switch media.kind {
        case .photo: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .document: "doc.text"
        case .sticker: "face.smiling"
        case .other: "doc"
        }
    }
}
