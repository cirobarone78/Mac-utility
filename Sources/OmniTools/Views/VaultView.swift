import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UtilityCore

@MainActor
final class VaultModel: ObservableObject {
    @Published var vaults: [VaultInfo] = []
    @Published var message: String?
    @Published var busy = false
    @Published var lastOperationID: String?

    private static let key = "vault.paths"

    var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.key) }
    }

    func reload() {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        Task { vaults = await Self.status(urls) }
    }

    nonisolated static func status(_ urls: [URL]) async -> [VaultInfo] { Vault.status(urls) }

    func remember(_ url: URL) {
        if !paths.contains(url.path) { paths.append(url.path) }
        reload()
    }

    func forget(_ v: VaultInfo) {
        paths.removeAll { $0 == v.url.path }
        reload()
    }

    func create(folder: URL, name: String, sizeGB: Int, password: String) {
        busy = true
        Task {
            let result = await Self.make(folder: folder, name: name, sizeGB: sizeGB, password: password)
            switch result {
            case .success(let url):
                remember(url)
                message = "Cassaforte «\(url.deletingPathExtension().lastPathComponent)» creata. Aprila per metterci i file."
            case .failure(let e):
                message = e.localizedDescription
            }
            busy = false
        }
    }

    nonisolated static func make(folder: URL, name: String, sizeGB: Int, password: String) async -> Result<URL, Error> {
        Result { try Vault.create(in: folder, name: name, sizeGB: sizeGB, password: password) }
    }

    func open(_ v: VaultInfo, password: String) {
        busy = true
        Task {
            let r = await Self.attach(v.url, password: password)
            switch r {
            case .success(let mount):
                message = "Aperta in \(mount). Ricordati di chiuderla quando hai finito."
                NSWorkspace.shared.open(URL(fileURLWithPath: mount))
            case .failure(let e):
                message = e.localizedDescription
            }
            busy = false
            reload()
        }
    }

    nonisolated static func attach(_ url: URL, password: String) async -> Result<String, Error> {
        Result { try Vault.open(url, password: password) }
    }

    func close(_ v: VaultInfo) {
        guard let m = v.mountPoint else { return }
        do {
            try Vault.close(m)
            message = "Cassaforte chiusa: ora il contenuto è illeggibile senza password."
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    func moveIn(_ files: [URL], to v: VaultInfo) {
        guard let m = v.mountPoint else { return }
        let r = Vault.moveIn(files, mountPoint: m)
        lastOperationID = r.operationID
        message = "\(r.moved) file spostati nella cassaforte." + (r.errors.isEmpty ? "" : " Problemi: " + r.errors.prefix(3).joined(separator: "; "))
        reload()
    }

    func restoreLast() {
        guard let id = lastOperationID else { return }
        message = Restore.run(id)
        lastOperationID = nil
    }

    func addExisting() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sparsebundle") ?? .data, .diskImage]
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Aggiungi"
        if panel.runModal() == .OK, let url = panel.url { remember(url) }
    }
}

struct VaultView: View {
    @StateObject private var model = VaultModel()
    @State private var creating = false
    @State private var opening: VaultInfo?
    @State private var pendingMove: (files: [URL], vault: VaultInfo)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .vault,
                         subtitle: "Una cartella cifrata con password per i documenti delicati: referti, documenti d'identità, contratti.")
            HStack {
                Button("Nuova cassaforte…") { creating = true }.buttonStyle(.borderedProminent)
                Button("Aggiungi una cassaforte esistente…") { model.addExisting() }
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.bottom, 8)
            if let m = model.message {
                HStack {
                    Text(m).font(.callout)
                    Spacer()
                    if model.lastOperationID != nil { Button("Ripristina") { model.restoreLast() } }
                }
                .padding(10).background(Brand.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20).padding(.bottom, 8)
            }
            if model.vaults.isEmpty {
                ContentUnavailableView("Nessuna cassaforte", systemImage: Module.vault.icon,
                                       description: Text("È un'immagine disco cifrata AES-256 di macOS: chiusa è illeggibile, aperta funziona come un disco nel Finder. La password non viene salvata da nessuna parte."))
            } else {
                List(model.vaults) { v in vaultRow(v) }
            }
        }
        .onAppear { model.reload() }
        .sheet(isPresented: $creating) {
            CreateVaultSheet { folder, name, size, password in
                model.create(folder: folder, name: name, sizeGB: size, password: password)
            }
        }
        .sheet(item: $opening) { v in
            PasswordSheet(title: "Apri «\(v.name)»") { password in model.open(v, password: password) }
        }
        .confirmationDialog("Spostare \(pendingMove?.files.count ?? 0) file nella cassaforte?",
                            isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }),
                            titleVisibility: .visible) {
            Button("Sposta") {
                if let p = pendingMove { model.moveIn(p.files, to: p.vault) }
                pendingMove = nil
            }
        } message: {
            Text("Gli originali escono dalla cartella dove sono: resta solo la copia cifrata. «Ripristina» li rimette al loro posto finché la cassaforte è aperta.")
        }
    }

    private func vaultRow(_ v: VaultInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: v.isOpen ? "lock.open.fill" : "lock.fill")
                    .font(.title2).foregroundStyle(v.isOpen ? Color.orange : Brand.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.name).font(.headline)
                    Text(Finder.short(v.url) + " · " + Bytes.format(v.bytes) + (v.isOpen ? " · aperta" : " · chiusa"))
                        .font(.caption).foregroundStyle(.secondary)
                    if !v.exists { Text("File non trovato: forse è stato spostato.").font(.caption).foregroundStyle(.orange) }
                }
                Spacer()
                if v.isOpen {
                    Button("Mostra") { if let m = v.mountPoint { NSWorkspace.shared.open(URL(fileURLWithPath: m)) } }
                    Button("Chiudi") { model.close(v) }.buttonStyle(.borderedProminent)
                } else if v.exists {
                    Button("Apri…") { opening = v }.buttonStyle(.borderedProminent)
                }
                Menu {
                    Button("Mostra nel Finder") { Finder.reveal(v.url) }
                    Button("Togli dall'elenco (il file resta)") { model.forget(v) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if v.isOpen {
                Text("Trascina qui i file da mettere al sicuro")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(.secondary))
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        collect(providers) { urls in if !urls.isEmpty { pendingMove = (urls, v) } }
                        return true
                    }
            }
        }
        .padding(.vertical, 4)
    }

    private func collect(_ providers: [NSItemProvider], done: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let box = URLBox()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { box.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(box.urls) }
    }
}

/// Raccoglie gli URL trascinati (arrivano da thread diversi).
final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    func append(_ u: URL) { lock.lock(); list.append(u); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return list }
}

struct PasswordSheet: View {
    let title: String
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }
                Button("Apri") { submit() }.buttonStyle(.borderedProminent).disabled(password.isEmpty)
            }
        }
        .padding(20).frame(width: 360)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        onDone(password)
        password = ""
        dismiss()
    }
}

struct CreateVaultSheet: View {
    let onCreate: (URL, String, Int, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Cassaforte"
    @State private var folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    @State private var size = 10
    @State private var password = ""
    @State private var repeatPassword = ""
    @State private var understood = false

    private var strength: (String, Color) {
        let p = password
        var score = 0
        if p.count >= 10 { score += 1 }
        if p.count >= 14 { score += 1 }
        if p.rangeOfCharacter(from: .decimalDigits) != nil { score += 1 }
        if p.rangeOfCharacter(from: .uppercaseLetters) != nil && p.rangeOfCharacter(from: .lowercaseLetters) != nil { score += 1 }
        if p.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { score += 1 }
        switch score {
        case 0...1: return ("debole", .red)
        case 2...3: return ("discreta", .orange)
        default: return ("forte", Brand.accent)
        }
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 8 && password == repeatPassword && understood
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nuova cassaforte").font(.headline)
            TextField("Nome", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Text("Dove: " + Finder.short(folder)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Cambia…") { if let f = Finder.chooseFolder(start: folder) { folder = f } }
            }
            Picker("Dimensione massima", selection: $size) {
                ForEach([1, 5, 10, 25, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
            }
            Text("Occupa solo lo spazio dei file che ci metti, fino al massimo scelto.").font(.caption).foregroundStyle(.secondary)
            SecureField("Password (almeno 8 caratteri)", text: $password).textFieldStyle(.roundedBorder)
            SecureField("Ripeti la password", text: $repeatPassword).textFieldStyle(.roundedBorder)
            if !password.isEmpty {
                HStack {
                    Text("Robustezza: ") + Text(strength.0).foregroundColor(strength.1).bold()
                    if !repeatPassword.isEmpty && password != repeatPassword {
                        Text("· le password non coincidono").foregroundStyle(.red)
                    }
                }
                .font(.caption)
            }
            Toggle("Ho capito: se perdo la password, i file nella cassaforte sono persi per sempre. OmniTools non la conserva.",
                   isOn: $understood)
                .font(.callout)
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }
                Button("Crea") {
                    onCreate(folder, name, size, password)
                    password = ""
                    repeatPassword = ""
                    dismiss()
                }
                .buttonStyle(.borderedProminent).disabled(!valid)
            }
        }
        .padding(20).frame(width: 440)
    }
}
