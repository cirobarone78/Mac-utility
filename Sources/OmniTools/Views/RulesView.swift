import SwiftUI
import UtilityCore

struct RulesView: View {
    @EnvironmentObject var state: AppState
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .rules, subtitle: "Ciò che l'app non toccherà mai, nemmeno se glielo chiedi.")
            Form {
                Section {
                    ForEach(state.policy.neverTouchPaths, id: \.self) { p in
                        HStack {
                            Text(p)
                            Spacer()
                            Button(role: .destructive) {
                                state.policy.neverTouchPaths.removeAll { $0 == p }
                                state.savePolicy()
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Aggiungi cartella protetta…") {
                        if let url = Finder.chooseFolder() {
                            state.policy.neverTouchPaths.append(Finder.short(url))
                            state.savePolicy()
                        }
                    }
                } header: {
                    Text("Cartelle protette")
                } footer: {
                    Text("Sono sempre protette anche la home, le sue cartelle principali (Documenti, Scrivania…), /Applications e il sistema.")
                }

                Section("Nomi protetti ovunque") {
                    ForEach(state.policy.neverTouchNames, id: \.self) { n in
                        HStack {
                            Text(n).monospaced()
                            Spacer()
                            Button(role: .destructive) {
                                state.policy.neverTouchNames.removeAll { $0 == n }
                                state.savePolicy()
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("es. .git oppure Libri", text: $newName)
                        Button("Aggiungi") {
                            let n = newName.trimmingCharacters(in: .whitespaces)
                            guard !n.isEmpty else { return }
                            state.policy.neverTouchNames.append(n)
                            state.savePolicy()
                            newName = ""
                        }
                    }
                }

                Section("File") {
                    Button("Apri il file delle regole") { Finder.reveal(SafetyPolicy.defaultFileURL) }
                    Button("Apri il registro delle operazioni") { Finder.reveal(Journal.fileURL) }
                }
            }
            .formStyle(.grouped)
        }
    }
}
