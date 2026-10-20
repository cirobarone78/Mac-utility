import SwiftUI
import UtilityCore

/// Tutto ciò che OmniTools ha fatto, con un tasto per tornare indietro.
struct HistoryView: View {
    @State private var records: [OperationRecord] = []
    @State private var confirming: OperationRecord?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .history,
                         subtitle: "Ogni pulizia e ogni riordino si possono annullare finché non svuoti il Cestino.")
            if let message {
                Text(message).font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
            if records.isEmpty {
                ContentUnavailableView("Nessuna operazione", systemImage: Module.history.icon,
                                       description: Text("Qui compariranno pulizie, eliminazioni di duplicati e riordini, ognuno con il tasto «Ripristina»."))
            } else {
                List(records) { r in
                    HistoryRow(record: r) { confirming = r }
                }
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog("Ripristinare questa operazione?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { r in
            Button("Ripristina") {
                message = "\(r.kind): " + OperationLog.restore(r).message
                reload()
            }
        } message: { r in
            Text("\(r.summary). Ogni file torna dov'era: anche quelli nel Cestino, se non l'hai svuotato. Le cartelle create e rimaste vuote vengono tolte.")
        }
    }

    private func reload() { records = OperationLog.list() }
}

private struct HistoryRow: View {
    let record: OperationRecord
    let onRestore: () -> Void
    @State private var expanded = false

    private var icon: String {
        switch record.kind {
        case "Pulizia disco", "Pulizia rapida": Module.cleanup.icon
        case "Duplicati": Module.duplicates.icon
        case "Riordino": Module.organize.icon
        case "Assistente AI": Module.assistant.icon
        case "Analisi spazio": Module.space.icon
        default: "trash"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(Brand.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(record.kind).font(.headline)
                        if record.restored { Badge(text: "ripristinata", color: .secondary) }
                    }
                    Text(record.summary).font(.callout).foregroundStyle(.secondary)
                    Text(record.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button(expanded ? "Nascondi" : "Dettagli") { expanded.toggle() }.buttonStyle(.link)
                Button("Ripristina…", action: onRestore)
                    .disabled(record.restored)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(record.moves.prefix(200), id: \.self) { m in
                        HStack(spacing: 6) {
                            Text((m.from as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            Text(m.toTrash ? "Cestino" : Finder.short(URL(fileURLWithPath: (m.to as NSString).deletingLastPathComponent)))
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.caption)
                    }
                    if record.moves.count > 200 {
                        Text("…e altri \(record.moves.count - 200)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 34)
            }
        }
        .padding(.vertical, 4)
    }
}
