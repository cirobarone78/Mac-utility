import Foundation

/// Una sottocartella proposta e i file che ci andrebbero.
public struct OrganizeGroup: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var name: String
    public var files: [DiskItem]
    public let reason: String

    public init(name: String, files: [DiskItem], reason: String) {
        self.name = name
        self.files = files
        self.reason = reason
    }
}

/// Un file che sembra inutile, con il motivo.
public struct RemovalSuggestion: Identifiable, Hashable, Sendable {
    public let item: DiskItem
    public let reason: String
    /// .safe = preselezionato; .review = da guardare, mai preselezionato.
    public let risk: CleanupCategory.Risk
    public var id: URL { item.url }
}

public struct OrganizePlan: Sendable {
    public let folder: URL
    public var groups: [OrganizeGroup]
    public var removals: [RemovalSuggestion]
}

/// Riordina i file sfusi di UNA cartella (non entra nelle sottocartelle).
public struct FolderOrganizer: Sendable {
    public enum Strategy: String, CaseIterable, Sendable {
        case topic = "Per argomento"
        case kind = "Per tipo"
        case month = "Per mese"
    }

    public var strategy: Strategy
    /// Quanti file devono condividere una parola perché diventi una cartella.
    public var minTopicSize = 2
    /// Installer più vecchi di così vengono proposti come inutili.
    public var installerAgeDays = 30

    public init(strategy: Strategy = .topic) { self.strategy = strategy }

    // MARK: - Anteprima

    public func plan(folder: URL, policy: SafetyPolicy, now: Date = Date()) -> OrganizePlan {
        let files = looseFiles(in: folder, policy: policy)
        let removals = uselessFiles(files, folder: folder, now: now)
        let removed = Set(removals.map(\.id))
        let rest = files.filter { !removed.contains($0.url) }

        let groups: [OrganizeGroup]
        switch strategy {
        case .topic: groups = topicGroups(rest)
        case .kind: groups = kindGroups(rest)
        case .month: groups = monthGroups(rest)
        }
        return OrganizePlan(folder: folder, groups: groups, removals: removals)
    }

    /// File normali direttamente nella cartella: niente nascosti, collegamenti o cartelle.
    func looseFiles(in folder: URL, policy: SafetyPolicy) -> [DiskItem] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                         .creationDateKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: keys),
                  v.isRegularFile == true, v.isSymbolicLink != true,
                  !policy.isProtected(url) else { return nil }
            return DiskItem(url: url, bytes: Int64(v.fileSize ?? 0), isDirectory: false,
                            modified: v.creationDate ?? v.contentModificationDate)
        }
        .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Raggruppamenti

    func kindGroups(_ files: [DiskItem]) -> [OrganizeGroup] {
        Dictionary(grouping: files) { FileKind.of($0.url) }
            .map { OrganizeGroup(name: $0.key.rawValue, files: $0.value, reason: "stesso tipo di file") }
            .sorted { $0.files.count > $1.files.count }
    }

    func monthGroups(_ files: [DiskItem]) -> [OrganizeGroup] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "yyyy-MM"
        return Dictionary(grouping: files) { $0.modified.map(f.string(from:)) ?? "Senza data" }
            .map { OrganizeGroup(name: $0.key, files: $0.value, reason: "creati nello stesso mese") }
            .sorted { $0.name > $1.name }
    }

    /// Argomento = una parola (di almeno 3 lettere) che compare nel nome di più file.
    /// Si parte dalle parole più frequenti; i file rimasti senza argomento vanno per tipo.
    func topicGroups(_ files: [DiskItem]) -> [OrganizeGroup] {
        let tokens = Dictionary(uniqueKeysWithValues: files.map {
            ($0.url, Set(Self.tokens($0.url.deletingPathExtension().lastPathComponent)))
        })
        var counts: [String: Int] = [:]
        for set in tokens.values { for t in set { counts[t, default: 0] += 1 } }

        // Una parola presente in quasi tutti i file è l'argomento della cartella stessa: non serve.
        let tooCommon = files.count >= 5 ? Int(Double(files.count) * 0.8) : Int.max
        let candidates = counts
            .filter { $0.value >= minTopicSize && $0.value < tooCommon }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.count > $1.key.count }
            .map { $0.key }

        var assigned = Set<URL>()
        var groups: [String: OrganizeGroup] = [:]
        for word in candidates {
            let members = files.filter { !assigned.contains($0.url) && tokens[$0.url]?.contains(word) == true }
            guard members.count >= minTopicSize else { continue }
            let name = Self.folderName(for: word, in: members.map(\.url))
            if var existing = groups[name] {
                existing.files += members
                groups[name] = existing
            } else {
                groups[name] = OrganizeGroup(name: name, files: members, reason: "il nome contiene «\(word)»")
            }
            assigned.formUnion(members.map(\.url))
        }

        let leftovers = files.filter { !assigned.contains($0.url) }
        return groups.values.sorted { $0.files.count > $1.files.count } + kindGroups(leftovers)
    }

    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "from", "per", "con", "del", "della", "dello", "dei", "delle",
        "degli", "dal", "dalla", "alla", "alle", "allo", "agli", "nel", "nella", "sul", "sulla",
        "una", "uno", "che", "non", "ore", "copy", "copia", "copie", "final", "finale", "def",
        "definitivo", "nuovo", "new", "old", "vecchio", "file", "doc", "img", "image", "immagine",
        "dsc", "scan", "rev", "bozza", "draft", "ver", "version", "versione", "untitled",
        "senza", "titolo", "pdf", "jpg", "jpeg", "png", "heic", "mov", "mp4",
    ]

    /// Parole che indicano la stessa cosa e finiscono nella stessa cartella.
    static let synonyms: [String: String] = [
        "schermata": "Screenshot", "screenshot": "Screenshot", "istantanea": "Screenshot",
        "fattura": "Fatture", "fatture": "Fatture", "invoice": "Fatture", "ricevuta": "Ricevute",
        "ricevute": "Ricevute", "receipt": "Ricevute",
    ]

    /// Usa la grafia più frequente nei nomi originali se ha maiuscole interne ("OmniNeo"),
    /// altrimenti la parola con l'iniziale maiuscola ("Preventivo").
    static func folderName(for word: String, in urls: [URL] = []) -> String {
        var spellings: [String: Int] = [:]
        for url in urls {
            for raw in url.deletingPathExtension().lastPathComponent
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            where raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased() == word {
                spellings[raw, default: 0] += 1
            }
        }
        // Solo grafie con maiuscole (non tutto minuscolo/maiuscolo); a parità vince l'ordine alfabetico.
        let styled = spellings.filter { $0.key != $0.key.lowercased() && $0.key != $0.key.uppercased() }
        if let best = styled.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key {
            return best
        }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// "Fattura_Enel-2024marzo OmniNeo" → ["fatture", "enel", "2024marzo", "marzo", "omnineo", "omni", "neo"]
    /// Conta sia la parola intera sia i suoi pezzi (maiuscole interne, cifre), e unisce i sinonimi.
    static func tokens(_ name: String) -> [String] {
        let locale = Locale(identifier: "it_IT")
        func fold(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale).lowercased()
        }
        var result: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            var w = fold(raw)
            if let canonical = synonyms[w] { w = fold(canonical) }
            guard w.count >= 3, !w.allSatisfy(\.isNumber), !stopwords.contains(w),
                  seen.insert(w).inserted else { return }
            result.append(w)
        }

        for word in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
            add(word)
            // Pezzi: "OmniNeo" → "Omni", "Neo"; "budget2026" → "budget", "2026"
            var piece = ""
            var prev: Character?
            for ch in word {
                if let p = prev,
                   (p.isLowercase && ch.isUppercase) || (p.isLetter && ch.isNumber) || (p.isNumber && ch.isLetter) {
                    add(piece)
                    piece = ""
                }
                piece.append(ch)
                prev = ch
            }
            if piece != word { add(piece) }
        }
        return result
    }

    // MARK: - File inutili

    func uselessFiles(_ files: [DiskItem], folder: URL, now: Date) -> [RemovalSuggestion] {
        var out: [RemovalSuggestion] = []
        var flagged = Set<URL>()
        func add(_ item: DiskItem, _ reason: String, _ risk: CleanupCategory.Risk) {
            if flagged.insert(item.url).inserted {
                out.append(RemovalSuggestion(item: item, reason: reason, risk: risk))
            }
        }

        let partial: Set<String> = ["crdownload", "part", "partial", "download", "tmp", "temp"]
        let siblings = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []))

        for f in files {
            let name = f.url.lastPathComponent
            let ext = f.url.pathExtension.lowercased()
            if f.bytes == 0 {
                add(f, "file vuoto (0 byte)", .safe)
            } else if partial.contains(ext) {
                add(f, "download incompleto o file temporaneo", .safe)
            } else if name.hasPrefix("~$") || name.hasPrefix(".~lock") {
                add(f, "file di blocco lasciato da Office", .safe)
            } else if FileKind.of(f.url) == .installers && ext != "apk" && ext != "aab" && ext != "ipa",
                      let d = f.modified, now.timeIntervalSince(d) > Double(installerAgeDays) * 86_400 {
                add(f, "installer scaricato più di \(installerAgeDays) giorni fa", .review)
            } else if FileKind.of(f.url) == .archives,
                      siblings.contains(f.url.deletingPathExtension().lastPathComponent) {
                add(f, "archivio già estratto (c'è la cartella con lo stesso nome)", .review)
            }
        }

        // Copie identiche: si tiene quella con il nome "più originale", le altre sono proposte.
        let candidates = files.filter { $0.bytes > 0 && !flagged.contains($0.url) }
        for sameSize in Dictionary(grouping: candidates, by: \.bytes).values where sameSize.count > 1 {
            for same in Dictionary(grouping: sameSize, by: { DuplicateFinder.hash($0.url, limit: nil) })
            where same.key != nil && same.value.count > 1 {
                let sorted = same.value.sorted { Self.copyScore($0.url) < Self.copyScore($1.url) }
                for dup in sorted.dropFirst() {
                    add(dup, "copia identica di «\(sorted[0].url.lastPathComponent)»", .safe)
                }
            }
        }
        return out.sorted { $0.item.url.lastPathComponent < $1.item.url.lastPathComponent }
    }

    /// Più è basso, più il nome sembra l'originale ("foto.jpg" batte "foto (1).jpg" e "foto copia.jpg").
    static func copyScore(_ url: URL) -> (Int, Int) {
        let n = url.deletingPathExtension().lastPathComponent.lowercased()
        let marks = [" copia", " copy", "copia di", "copy of", "(1)", "(2)", "(3)", " 2", "-1", "_1"]
        return (marks.filter { n.contains($0) }.count, n.count)
    }
}

// MARK: - Applicazione e annullamento

public struct OrganizeResult: Sendable {
    public var moved = 0
    public var createdFolders = 0
    public var trashed = 0
    public var trashedBytes: Int64 = 0
    public var errors: [String] = []
    /// Identificativo dell'operazione in Cronologia.
    public var operationID: String?
}

extension FolderOrganizer {
    /// Tipi di operazione che «Annulla l'ultimo riordino» può annullare.
    public static let undoableKinds: Set<String> = ["Riordino", "Assistente AI"]

    /// Esegue il piano: crea le cartelle, sposta i file, manda nel Cestino gli inutili selezionati.
    /// Spostamenti e Cestino finiscono in un'unica voce di Cronologia, ripristinabile in un colpo.
    /// `remove` è sostituibile nei test (per non toccare il Cestino vero).
    public static func apply(_ plan: OrganizePlan,
                             removals: [DiskItem],
                             policy: SafetyPolicy,
                             kind: String = "Riordino",
                             recordsFolder: URL = OperationLog.folder,
                             remove: (([DiskItem]) -> SafeRemover.Report)? = nil)
        -> OrganizeResult {
        let fm = FileManager.default
        var result = OrganizeResult()
        var moves: [OperationRecord.Move] = []
        var created: [String] = []

        let toTrash = removals.filter { !policy.isProtected($0.url) }
        let report = remove?(toTrash) ?? SafeRemover(policy: policy).moveToTrash(toTrash, log: false)
        result.trashed = report.moved.count
        result.trashedBytes = report.bytes
        result.errors += report.skipped.map { "\($0.url.lastPathComponent): \($0.reason)" }
        moves += report.trashMoves

        for group in plan.groups where !group.files.isEmpty {
            let dir = plan.folder.appendingPathComponent(sanitize(group.name), isDirectory: true)
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: false)
                    created.append(dir.path)
                    result.createdFolders += 1
                } catch {
                    result.errors.append("\(group.name): \(error.localizedDescription)")
                    continue
                }
            } else if !isDir.boolValue {
                result.errors.append("\(group.name): esiste già un file con questo nome")
                continue
            }
            for file in group.files where !policy.isProtected(file.url) {
                let dest = uniqueDestination(for: file.url.lastPathComponent, in: dir)
                do {
                    try fm.moveItem(at: file.url, to: dest)
                    moves.append(.init(from: file.url.path, to: dest.path))
                    result.moved += 1
                } catch {
                    result.errors.append("\(file.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        let summary = "\(plan.folder.lastPathComponent): \(result.moved) file spostati"
            + (result.trashed > 0 ? ", \(result.trashed) nel Cestino" : "")
        let record = OperationRecord(kind: kind, summary: summary, moves: moves,
                                     createdFolders: created, bytes: result.trashedBytes)
        OperationLog.save(record, in: recordsFolder)
        if !moves.isEmpty || !created.isEmpty { result.operationID = record.id }
        Journal.append(lines: moves.map { "SPOSTATO\t\($0.from)\t→ \($0.to)" })
        return result
    }

    /// Annulla l'ultimo riordino (anche i file mandati nel Cestino tornano al loro posto).
    @discardableResult
    public static func undoLast(recordsFolder: URL = OperationLog.folder) -> RestoreResult? {
        guard let record = OperationLog.latest(kinds: undoableKinds, in: recordsFolder) else { return nil }
        return OperationLog.restore(record, in: recordsFolder)
    }

    public static func latestRecordFolder(recordsFolder: URL = OperationLog.folder) -> String? {
        OperationLog.latest(kinds: undoableKinds, in: recordsFolder)?.summary
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let noDot = cleaned.drop { $0 == "." }
        return noDot.isEmpty ? "Senza nome" : String(noDot)
    }

    /// "foto.jpg" → "foto 2.jpg" se esiste già.
    static func uniqueDestination(for name: String, in dir: URL) -> URL {
        var dest = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return dest
    }
}
