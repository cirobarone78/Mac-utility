import SwiftUI
import UtilityCore

@MainActor
final class BreachesModel: ObservableObject {
    @Published var password = ""
    @Published var passwordResult: String?
    @Published var passwordFound = false
    @Published var checkingPassword = false

    @Published var email = UserDefaults.standard.string(forKey: "breaches.email") ?? ""
    @Published var hasKey = Keychain.readKey(Keychain.hibp)?.isEmpty == false
    @Published var breaches: [Breach]?
    @Published var emailError: String?
    @Published var checkingEmail = false

    func checkPassword() {
        let pwd = password
        guard !pwd.isEmpty else { return }
        checkingPassword = true
        Task {
            do {
                let n = try await BreachCheck.passwordCount(pwd)
                passwordFound = n > 0
                passwordResult = n > 0
                    ? "Questa password compare \(n.formatted()) volte nei furti di dati noti. Non usarla più: cambiala ovunque l'hai usata."
                    : "Questa password non compare nei furti di dati noti. Bene, ma usala su un solo sito."
            } catch {
                passwordFound = false
                passwordResult = error.localizedDescription
            }
            password = ""
            checkingPassword = false
        }
    }

    func saveKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        hasKey = Keychain.saveKey(k, account: Keychain.hibp)
    }

    func forgetKey() {
        Keychain.deleteKey(Keychain.hibp)
        hasKey = false
    }

    func checkEmail() {
        let address = email.trimmingCharacters(in: .whitespaces)
        guard address.contains("@") else { emailError = "Scrivi un indirizzo email completo."; return }
        UserDefaults.standard.set(address, forKey: "breaches.email")
        checkingEmail = true
        emailError = nil
        let key = Keychain.readKey(Keychain.hibp) ?? ""
        Task {
            do {
                breaches = try await BreachCheck.breaches(email: address, apiKey: key)
            } catch {
                breaches = nil
                emailError = error.localizedDescription
            }
            checkingEmail = false
        }
    }
}

struct BreachesView: View {
    @StateObject private var model = BreachesModel()
    @State private var keyField = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .breaches,
                         subtitle: "Le tue password o il tuo indirizzo email sono finiti in un furto di dati?")
            List {
                Section("Password (gratis)") {
                    HStack {
                        SecureField("Scrivi una password da controllare", text: $model.password)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.checkPassword() }
                        Button("Controlla") { model.checkPassword() }
                            .disabled(model.password.isEmpty || model.checkingPassword)
                    }
                    if let r = model.passwordResult {
                        Label(r, systemImage: model.passwordFound ? "exclamationmark.triangle.fill" : "checkmark.circle")
                            .foregroundStyle(model.passwordFound ? Color.red : Brand.accent)
                    }
                    Text("La password non lascia il Mac: si inviano solo i primi 5 caratteri della sua impronta, e il confronto si fa qui. Non viene salvata da nessuna parte. Le password salvate nell'app Password di Apple hanno già questo controllo in «Avvisi di sicurezza».")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Indirizzo email") {
                    if model.hasKey {
                        HStack {
                            TextField("nome@esempio.it", text: $model.email).textFieldStyle(.roundedBorder)
                                .onSubmit { model.checkEmail() }
                            Button("Controlla") { model.checkEmail() }.disabled(model.checkingEmail)
                            Menu("Chiave") {
                                Button("Dimentica la chiave", role: .destructive) { model.forgetKey() }
                            }
                            .frame(width: 80)
                        }
                        if model.checkingEmail { ProgressView().controlSize(.small) }
                        if let e = model.emailError { Text(e).foregroundStyle(.orange) }
                        if let list = model.breaches {
                            if list.isEmpty {
                                Label("L'indirizzo non compare nei furti di dati noti.", systemImage: "checkmark.circle")
                                    .foregroundStyle(Brand.accent)
                            } else {
                                Text("Compare in \(list.count) furti di dati. Per ciascuno: cambia la password di quel sito e di ogni sito dove usavi la stessa.")
                                    .font(.callout.bold())
                                ForEach(list) { b in breachRow(b) }
                            }
                        }
                    } else {
                        Text("Il controllo per indirizzo email usa Have I Been Pwned, che chiede una chiave a pagamento (circa 4 dollari al mese, si può disdire quando vuoi). Senza chiave puoi controllare gratis dal sito, una ricerca alla volta.")
                            .font(.callout)
                        HStack {
                            Button("Cerca gratis sul sito") { Finder.open("https://haveibeenpwned.com") }
                            Button("Prendi una chiave") { Finder.open("https://haveibeenpwned.com/API/Key") }
                        }
                        HStack {
                            SecureField("Chiave di Have I Been Pwned", text: $keyField).textFieldStyle(.roundedBorder)
                            Button("Salva") { model.saveKey(keyField); keyField = "" }.disabled(keyField.isEmpty)
                        }
                    }
                }
            }
        }
    }

    private func breachRow(_ b: Breach) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(b.title).font(.body.bold())
                if !b.domain.isEmpty { Text(b.domain).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(b.date).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("Dati rubati: " + b.data.joined(separator: ", ")).font(.caption)
                .foregroundStyle(b.includesPasswords ? Color.red : Color.secondary)
            Text(b.description).font(.caption).foregroundStyle(.secondary).lineLimit(4)
        }
        .padding(.vertical, 2)
    }
}
