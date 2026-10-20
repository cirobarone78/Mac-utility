import SwiftUI
import UtilityCore

struct StartupView: View {
    @State private var items: [StartupItem] = []
    @State private var selection = Set<StartupItem.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .startup, subtitle: "Programmi che partono da soli. Per ora solo consultazione.")
            Table(items, selection: $selection) {
                TableColumn("Nome") { Text($0.label).lineLimit(1) }
                TableColumn("Programma") { Text($0.program ?? "–").lineLimit(1).truncationMode(.middle) }
                TableColumn("Tipo") { Text($0.scope.rawValue) }.width(140)
                TableColumn("Stato") { i in
                    Text(i.disabled ? "Disattivato" : i.runAtLoad ? "All'avvio" : "Su richiesta")
                        .foregroundStyle(i.disabled ? .secondary : .primary)
                }
                .width(100)
            }
            .contextMenu(forSelectionType: StartupItem.ID.self) { ids in
                if let id = ids.first { Button("Mostra nel Finder") { Finder.reveal(id) } }
            }
            Text("Gli elementi di accesso delle app si gestiscono anche da Impostazioni di Sistema › Generali › Elementi login.")
                .font(.callout).foregroundStyle(.secondary).padding(16)
        }
        .onAppear { items = StartupItems.list() }
    }
}
