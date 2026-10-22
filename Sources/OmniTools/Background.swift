import SwiftUI
import AppKit
import UserNotifications
import CoreLocation
import ServiceManagement
import UtilityCore

// MARK: - Notifiche

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String, id: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

// MARK: - Fotocamera e microfono

/// Controlla ogni 2 secondi se fotocamera o microfono si accendono, avvisa e tiene il registro.
@MainActor
final class MediaMonitor: ObservableObject {
    static let shared = MediaMonitor()
    @Published private(set) var state = MediaState()
    @Published private(set) var cameraApps: [String] = []
    @Published private(set) var micApps: [String] = []
    private var loop: Task<Void, Never>?

    static var notifyEnabled: Bool {
        UserDefaults.standard.object(forKey: "media.notify") as? Bool ?? true
    }

    func start() {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                let s = await Self.read()
                update(s)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    nonisolated static func read() async -> MediaState { MediaDevices.state() }

    private func update(_ s: MediaState) {
        let old = state
        guard s != old else { return }
        state = s
        var names: [String] = []
        for c in s.micClients {
            let n = Self.name(for: c)
            if !names.contains(n) { names.append(n) }
        }
        micApps = names
        if s.cameraOn != old.cameraOn {
            cameraApps = s.cameraOn ? Self.cameraCandidates() : []
            event(.camera, on: s.cameraOn, apps: cameraApps)
        }
        if s.micOn != old.micOn || (s.micOn && Set(s.micClients) != Set(old.micClients) && !micApps.isEmpty) {
            event(.microphone, on: s.micOn, apps: micApps)
        }
    }

    private func event(_ device: MediaEvent.Device, on: Bool, apps: [String]) {
        MediaLog.append(MediaEvent(device: device, on: on, apps: apps))
        guard on, Self.notifyEnabled else { return }
        let who = apps.isEmpty ? "" : (device == .camera && apps.count > 1 ? "Probabilmente: " : "Da: ") + apps.joined(separator: ", ")
        Notifier.post("\(device.rawValue) accesa", who.isEmpty ? "Un'app sta usando la \(device.rawValue.lowercased())." : who,
                      id: "media-\(device.rawValue)")
    }

    /// Nome dell'app che usa il microfono (anche quando è un suo processo di aiuto).
    static func name(for c: MediaClient) -> String {
        if let app = NSRunningApplication(processIdentifier: c.pid), let n = app.localizedName {
            // Processi di aiuto ("Google Chrome Helper"): si risale all'app principale.
            if let bid = app.bundleIdentifier, let main = mainApp(for: bid) { return main }
            return n
        }
        if let bid = c.bundleID, let main = mainApp(for: bid) { return main }
        return c.bundleID ?? "PID \(c.pid)"
    }

    static func mainApp(for bundleID: String) -> String? {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        // L'app con l'identificativo più lungo che sia un prefisso (com.google.Chrome per com.google.Chrome.helper).
        if let app = running.filter({ guard let b = $0.bundleIdentifier else { return false }
            return bundleID == b || bundleID.hasPrefix(b + ".") }).max(by: { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }) {
            return app.localizedName
        }
        if bundleID.hasPrefix("com.apple.WebKit") { return "Safari o un'app con pagine web" }
        return nil
    }

    /// macOS non dice quale app usa la fotocamera: si indicano le app aperte che hanno il permesso.
    static func cameraCandidates() -> [String] {
        let allowed = Set(PrivacyPermissions.list().grants
            .filter { $0.service == "kTCCServiceCamera" && $0.allowed && !$0.clientIsPath }.map(\.client))
        let names = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard let b = app.bundleIdentifier, allowed.contains(b) else { return nil }
            return app.localizedName
        }
        if !names.isEmpty { return names }
        // Senza Accesso completo al disco il registro dei permessi non è leggibile: app note.
        let known = ["us.zoom.xos", "com.apple.FaceTime", "com.microsoft.teams2", "com.microsoft.teams",
                     "com.google.Chrome", "com.apple.Safari", "com.hnc.Discord", "com.skype.skype",
                     "net.whatsapp.WhatsApp", "com.apple.PhotoBooth", "com.obsproject.obs-studio"]
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let b = app.bundleIdentifier, known.contains(b) else { return nil }
            return app.localizedName
        }
    }
}

// MARK: - Manutenzione automatica

struct MaintenanceReport: Codable {
    var date = Date()
    var cleanableBytes: Int64 = 0
    var updates: [String] = []
    var backupDays: Int?
    var backupConfigured = true
    var diskFree: Int64?
    var batteryCapacity: Double?
    var suggestChargeLimit: Bool? = nil
    var lines: [String] = []
}

@MainActor
final class Maintenance: ObservableObject {
    static let shared = Maintenance()

    enum Frequency: Int, CaseIterable, Identifiable {
        case daily = 1, weekly = 7, monthly = 30
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .daily: "Ogni giorno"
            case .weekly: "Ogni settimana"
            case .monthly: "Ogni mese"
            }
        }
    }

    @AppStorage("maintenance.enabled") var enabled = true
    @AppStorage("maintenance.frequency") var frequencyDays = 7
    @AppStorage("maintenance.updates") var checkUpdates = true
    @Published private(set) var running = false
    @Published private(set) var last: MaintenanceReport?
    private var timer: Task<Void, Never>?

    static var reportURL: URL {
        SafetyPolicy.defaultFileURL.deletingLastPathComponent().appendingPathComponent("manutenzione.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.reportURL) {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            last = try? d.decode(MaintenanceReport.self, from: data)
        }
    }

    /// Ogni ora controlla se è il momento: così funziona anche se il Mac era spento o in stop.
    func start() {
        guard timer == nil else { return }
        timer = Task {
            try? await Task.sleep(for: .seconds(120))   // lascia avviare il Mac in pace
            while !Task.isCancelled {
                // Un campione all'ora delle abitudini di carica (serve al consiglio sul limite).
                let battery = await Self.readBattery()
                ChargeHabits.record(battery)
                if enabled, isDue { await run(notify: true) }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    nonisolated static func readBattery() async -> BatteryHealth { Battery.read() }

    var isDue: Bool {
        guard let date = last?.date else { return true }
        return Date().timeIntervalSince(date) >= Double(frequencyDays) * 86_400 - 600
    }

    var nextRun: Date? {
        guard enabled else { return nil }
        return (last?.date ?? Date()).addingTimeInterval(Double(frequencyDays) * 86_400)
    }

    func run(notify: Bool) async {
        guard !running else { return }
        running = true
        let policy = AppState.shared.policy
        let report = await Self.collect(policy: policy, updates: checkUpdates)
        last = report
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: Self.reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? e.encode(report).write(to: Self.reportURL, options: .atomic)
        running = false
        if notify && !report.lines.isEmpty {
            Notifier.post("OmniTools – controllo periodico", report.lines.prefix(4).joined(separator: " · "), id: "maintenance")
        }
    }

    /// Solo controlli: non cancella e non installa nulla.
    nonisolated static func collect(policy: SafetyPolicy, updates: Bool) async -> MaintenanceReport {
        var r = MaintenanceReport()
        let safe = CleanupCatalog.standard.filter { $0.risk == .safe }
        r.cleanableBytes = CleanupCatalog.scan(safe, policy: policy).filter { $0.risk == .safe }
            .reduce(0) { $0 + $1.item.bytes }
        if r.cleanableBytes > 1_000_000_000 { r.lines.append("\(Bytes.format(r.cleanableBytes)) da liberare") }

        if updates {
            let apps = AppUninstaller.installedApps(withSizes: false)
            r.updates = await UpdateChecker.check(apps: apps).updates.map(\.name)
            if !r.updates.isEmpty { r.lines.append("\(r.updates.count) app da aggiornare") }
        }

        let backup = BackupCheck.run()
        r.backupConfigured = !backup.destinations.isEmpty
        if let last = backup.lastBackup { r.backupDays = Int(Date().timeIntervalSince(last) / 86_400) }
        if !r.backupConfigured { r.lines.append("Time Machine non configurato") }
        else if let d = r.backupDays, d > 7 { r.lines.append("backup fermo da \(d) giorni") }

        if let free = SystemMonitor.disk()?.free {
            r.diskFree = free
            if free < 20_000_000_000 { r.lines.append("solo \(Bytes.format(free)) liberi sul disco") }
        }
        let battery = Battery.read()
        r.batteryCapacity = battery.maxCapacity
        if let c = battery.maxCapacity, c < 0.8 { r.lines.append("batteria al \(Int(c * 100))%") }
        let suggest = ChargeHabits.summary().suggestsLimit && battery.chargeLimit == nil && !battery.holdingCharge
        r.suggestChargeLimit = suggest
        if suggest { r.lines.append("il Mac sta quasi sempre al 100% in carica: imposta il limite all'80%") }
        return r
    }

    // Apertura automatica all'accesso (serve perché la manutenzione giri senza aprire l'app a mano).
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {}
            objectWillChange.send()
        }
    }
}

// MARK: - Localizzazione (per leggere il nome della rete Wi-Fi)

@MainActor
final class LocationPermission: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationPermission()
    private let manager = CLLocationManager()
    @Published var status: CLAuthorizationStatus

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// 3 = sempre, 4 = mentre l'app è in uso.
    var granted: Bool { status.rawValue >= 3 }

    func request() {
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            Finder.open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in self.status = s }
    }
}
