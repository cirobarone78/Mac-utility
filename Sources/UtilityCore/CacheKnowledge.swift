import Foundation

/// Spiegazione in italiano di una voce proposta dalla pulizia.
public struct CacheInfo: Sendable, Hashable {
    /// Nome comprensibile, es. "Google Chrome – cache di navigazione".
    public let title: String
    /// Che cos'è.
    public let what: String
    /// Cosa succede se la elimini.
    public let effect: String
    /// Rischio specifico della voce (prevale su quello della categoria).
    public let risk: CleanupCategory.Risk
    /// App che la usano: se sono aperte conviene chiuderle prima.
    public let bundleIDs: [String]
    /// Voce da non proporre mai (es. dati di sincronizzazione di iCloud).
    public let neverPropose: Bool

    init(_ title: String, what: String, effect: String, risk: CleanupCategory.Risk = .safe,
         apps: [String] = [], neverPropose: Bool = false) {
        self.title = title
        self.what = what
        self.effect = effect
        self.risk = risk
        self.bundleIDs = apps
        self.neverPropose = neverPropose
    }
}

/// Conoscenze sulle cartelle che si trovano di solito tra cache, log e residui di sviluppo.
public enum CacheKnowledge {
    static let regenerates = "L'app la ricrea da sola quando serve. Non perdi dati."

    /// Voci note in ~/Library/Caches (nome esatto della cartella, minuscolo).
    static let known: [String: CacheInfo] = [
        // Browser
        "google": CacheInfo("Google Chrome – cache di navigazione",
            what: "Copie temporanee di pagine, immagini e script dei siti visitati con Chrome (e di altri programmi Google, come l'aggiornamento automatico).",
            effect: "Segnalibri, password, cronologia e accessi ai siti NON stanno qui e restano intatti. Per qualche giorno i siti si aprono un po' più lentamente. Chiudi Chrome prima di pulire.",
            apps: ["com.google.Chrome"]),
        "com.google.chrome": CacheInfo("Google Chrome – cache",
            what: "Cache di navigazione di Chrome.", effect: "Come sopra: niente segnalibri o password, solo pagine salvate temporaneamente.",
            apps: ["com.google.Chrome"]),
        "com.apple.safari": CacheInfo("Safari – cache di navigazione",
            what: "Copie temporanee delle pagine visitate con Safari.",
            effect: "Segnalibri, password e cronologia restano. Chiudi Safari prima di pulire.",
            apps: ["com.apple.Safari"]),
        "firefox": CacheInfo("Firefox – cache di navigazione", what: "Copie temporanee delle pagine visitate con Firefox.",
            effect: "Profilo, segnalibri e password restano.", apps: ["org.mozilla.firefox"]),
        "mozilla": CacheInfo("Firefox – cache di navigazione", what: "Copie temporanee delle pagine visitate con Firefox.",
            effect: "Profilo, segnalibri e password restano.", apps: ["org.mozilla.firefox"]),
        "microsoft edge": CacheInfo("Microsoft Edge – cache di navigazione", what: "Pagine visitate con Edge.",
            effect: "Preferiti e password restano.", apps: ["com.microsoft.edgemac"]),
        "bravesoftware": CacheInfo("Brave – cache di navigazione", what: "Pagine visitate con Brave.",
            effect: "Preferiti e password restano.", apps: ["com.brave.Browser"]),

        // Sviluppo
        "org.swift.swiftpm": CacheInfo("Swift Package Manager – pacchetti scaricati",
            what: "Copie dei pacchetti Swift usati dai progetti (anche da OmniTools).",
            effect: "Alla prossima compilazione vengono riscaricati: serve la connessione e qualche minuto in più."),
        "homebrew": CacheInfo("Homebrew – installer già scaricati",
            what: "Archivi dei programmi installati con brew, tenuti per reinstallazioni veloci.",
            effect: "Nessun effetto sui programmi installati. Equivale a «brew cleanup»."),
        "pip": CacheInfo("Python (pip) – pacchetti scaricati",
            what: "Pacchetti Python già scaricati.", effect: "Si riscaricano alla prossima installazione."),
        "com.apple.python": CacheInfo("Python di Apple – file compilati",
            what: "Versioni precompilate (.pyc) degli script Python.", effect: regenerates),
        "cocoapods": CacheInfo("CocoaPods – librerie iOS scaricate",
            what: "Librerie scaricate per i progetti iOS (per esempio l'app OmniNeo con Capacitor).",
            effect: "Si riscaricano al prossimo «pod install»."),
        "node-gyp": CacheInfo("Node.js – intestazioni per moduli nativi",
            what: "File di Node usati per compilare moduli nativi.", effect: "Si riscaricano quando servono."),
        "yarn": CacheInfo("Yarn – pacchetti scaricati", what: "Pacchetti JavaScript scaricati da Yarn.",
            effect: "Si riscaricano alla prossima installazione."),
        "pnpm": CacheInfo("pnpm – pacchetti scaricati", what: "Pacchetti JavaScript scaricati da pnpm.",
            effect: "Si riscaricano alla prossima installazione."),
        "go-build": CacheInfo("Go – compilazioni", what: "Risultati intermedi del compilatore Go.", effect: regenerates),
        "ms-playwright": CacheInfo("Playwright – browser per i test automatici",
            what: "I browser (Chromium, Firefox, WebKit) installati da Playwright. Non è una vera cache.",
            effect: "Se usi Playwright dovrai reinstallarli con «npx playwright install». Se non lo usi più, puoi eliminarli.",
            risk: .review),
        "codex": CacheInfo("Codex – cache", what: "File temporanei dello strumento Codex.",
            effect: "Si ricreano al prossimo uso."),
        "jetbrains": CacheInfo("JetBrains – indici dei progetti",
            what: "Indici costruiti da IntelliJ, PyCharm, Android Studio…",
            effect: "Alla prossima apertura l'IDE re-indicizza i progetti, anche per diversi minuti.", risk: .review),
        "com.apple.dt.xcode": CacheInfo("Xcode – cache", what: "File temporanei di Xcode.",
            effect: regenerates + " Chiudi Xcode prima di pulire.", apps: ["com.apple.dt.Xcode"]),

        // App comuni
        "com.anthropic.claudefordesktop.shipit": CacheInfo("App Claude – aggiornamenti già installati",
            what: "Pacchetti di aggiornamento dell'app Claude scaricati in passato.",
            effect: "Nessun effetto: l'aggiornamento è già installato."),
        "com.microsoft.vscode.shipit": CacheInfo("VS Code – aggiornamenti già installati",
            what: "Pacchetti di aggiornamento già installati.", effect: "Nessun effetto."),
        "com.spotify.client": CacheInfo("Spotify – brani in cache",
            what: "Brani ascoltati di recente e, talvolta, quelli scaricati per l'ascolto offline.",
            effect: "I brani scaricati per l'offline potrebbero dover essere riscaricati.", risk: .review,
            apps: ["com.spotify.client"]),
        "com.tinyspeck.slackmacgap": CacheInfo("Slack – cache", what: "Immagini e file visti in Slack.",
            effect: regenerates, apps: ["com.tinyspeck.slackmacgap"]),
        "us.zoom.xos": CacheInfo("Zoom – cache", what: "File temporanei di Zoom.", effect: regenerates, apps: ["us.zoom.xos"]),
        "adobe": CacheInfo("Adobe – cache multimediale",
            what: "Anteprime e cache multimediali di Photoshop, Premiere, Lightroom…",
            effect: "Si ricreano, ma l'app può essere lenta per un po'.", risk: .review),

        // macOS
        "geoservices": CacheInfo("Mappe di Apple – riquadri della mappa",
            what: "Pezzi di mappa già scaricati da Mappe e dalle app che mostrano mappe.", effect: "Si riscaricano quando apri una mappa."),
        "com.apple.e5rt.e5bundlecache": CacheInfo("Apple Intelligence – modelli preparati",
            what: "Versioni ottimizzate dei modelli di Apple Intelligence per questo Mac.",
            effect: "macOS le ricrea in background: per un po' qualche funzione può essere più lenta."),
        "com.apple.parsecd": CacheInfo("Spotlight e Siri – suggerimenti",
            what: "Suggerimenti scaricati per Spotlight, Safari e Siri.", effect: regenerates),
        "com.apple.helpd": CacheInfo("Aiuto di macOS", what: "Pagine di aiuto già scaricate.", effect: regenerates),
        "com.apple.tipsd": CacheInfo("App Suggerimenti", what: "Contenuti dell'app Suggerimenti.", effect: regenerates),
        "com.apple.tv": CacheInfo("App TV – copertine e anteprime", what: "Copertine e dati del catalogo.",
            effect: "I film scaricati per l'offline NON stanno qui.", apps: ["com.apple.TV"]),
        "com.apple.games": CacheInfo("App Giochi", what: "Copertine e dati di Apple Games.", effect: regenerates),
        "com.apple.visualintelligencecore": CacheInfo("Intelligenza visiva di Apple",
            what: "Dati per riconoscere oggetti e testo nelle immagini.", effect: regenerates),
        "com.apple.nsurlsessiond": CacheInfo("Download in corso di sistema",
            what: "Download in background di macOS e delle app (anche quelli non ancora finiti).",
            effect: "Un download in corso ripartirebbe da capo.", risk: .review),

        // Da non toccare mai: sincronizzazione di iCloud e simili.
        "com.apple.bird": CacheInfo("iCloud Drive", what: "Stato della sincronizzazione di iCloud Drive.",
            effect: "Non va toccato.", neverPropose: true),
        "cloudkit": CacheInfo("iCloud (CloudKit)", what: "Dati di sincronizzazione delle app con iCloud.",
            effect: "Non va toccato.", neverPropose: true),
        "com.apple.cloudkit": CacheInfo("iCloud (CloudKit)", what: "Dati di sincronizzazione delle app con iCloud.",
            effect: "Non va toccato.", neverPropose: true),
        "familycircle": CacheInfo("In famiglia", what: "Dati di Condivisione in famiglia.", effect: "Non va toccato.", neverPropose: true),
    ]

    /// Spiega una voce trovata dalla pulizia.
    public static func info(for item: DiskItem, category: CleanupCategory,
                            appName: (String) -> String? = { _ in nil }) -> CacheInfo {
        let name = item.url.lastPathComponent
        let key = name.lowercased()

        switch category.id {
        case "user-caches":
            if let k = known[key] { return k }
            if key.hasPrefix("com.apple.") {
                let service = String(name.dropFirst("com.apple.".count))
                return CacheInfo("macOS – cache di «\(service)»",
                                 what: "Cache di un servizio di sistema di Apple.", effect: "macOS la ricrea da solo.")
            }
            if key.contains("."), let app = appName(name) {
                return CacheInfo("\(app) – cache", what: "File temporanei dell'app \(app).",
                                 effect: regenerates + " Meglio chiudere \(app) prima di pulire.", apps: [name])
            }
            return CacheInfo(name, what: "Cache di un'app o di un programma (cartella «\(name)»).", effect: regenerates)

        case "user-logs":
            return CacheInfo("Log – \(name)", what: "Registri di funzionamento e rapporti di arresto anomalo.",
                             effect: "Servono solo per diagnosticare problemi passati. Nessun effetto sulle app.")

        case "xcode-derived":
            let project = name.split(separator: "-").dropLast().joined(separator: "-")
            return CacheInfo("Progetto «\(project.isEmpty ? name : project)» – compilazioni di Xcode",
                             what: "Risultati intermedi della compilazione e indici del progetto.",
                             effect: "La prossima build del progetto sarà più lunga. Chiudi Xcode prima di pulire.",
                             apps: ["com.apple.dt.Xcode"])

        case "xcode-devicesupport":
            return CacheInfo("Supporto per «\(name)»",
                             what: "Simboli di debug copiati da un iPhone o iPad collegato in passato con questa versione di iOS.",
                             effect: "Se ricolleghi un dispositivo con questa versione, Xcode li ricopia (qualche minuto).",
                             risk: .review)

        case "xcode-archives":
            return CacheInfo("Archivi Xcode del \(name)",
                             what: "Build pubblicate o pronte per gli store, con i simboli per leggere i rapporti di arresto.",
                             effect: "Senza archivio non puoi più decifrare i crash di quella versione pubblicata. Tieni almeno le ultime.",
                             risk: .review)

        case "simulator-caches":
            return CacheInfo("Simulatori iOS – \(name)", what: "Cache dei simulatori.", effect: regenerates)

        case "gradle":
            return CacheInfo("Gradle (Android) – \(name)",
                             what: "Librerie e risultati di build per i progetti Android (es. l'app OmniNeo per Play).",
                             effect: "La prossima build Android le riscarica: serve la connessione e più tempo.")

        case "npm":
            return CacheInfo("npm – \(name)", what: "Pacchetti JavaScript già scaricati.",
                             effect: "Si riscaricano alla prossima installazione.")

        case "old-downloads":
            return CacheInfo(name, what: "Elemento della cartella Download non aperto né modificato da oltre 90 giorni.",
                             effect: "Controllalo: potrebbe essere un documento che ti serve.", risk: .review)

        default:
            return CacheInfo(name, what: category.detail, effect: regenerates, risk: category.risk)
        }
    }
}
