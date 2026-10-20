import Foundation

/// Una cartella sincronizzata con un servizio cloud, così come appare sul Mac.
public struct CloudLocation: Identifiable, Hashable, Sendable {
    public enum Service: String, Sendable { case iCloudDrive, googleDrive, other }
    public let name: String
    public let url: URL
    public let service: Service
    public var id: URL { url }
}

public enum CloudLocations {
    /// iCloud Drive, Google Drive (uno per account) e gli altri servizi in ~/Library/CloudStorage.
    public static func detect(home: String = NSHomeDirectory()) -> [CloudLocation] {
        let fm = FileManager.default
        var out: [CloudLocation] = []

        let iCloud = URL(fileURLWithPath: home + "/Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) {
            out.append(CloudLocation(name: "iCloud Drive", url: iCloud, service: .iCloudDrive))
        }

        let storage = URL(fileURLWithPath: home + "/Library/CloudStorage")
        let providers = (try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])) ?? []
        for p in providers.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = p.lastPathComponent
            if name.hasPrefix("GoogleDrive-") {
                let account = String(name.dropFirst("GoogleDrive-".count))
                let drives = (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])) ?? []
                for d in drives where !d.lastPathComponent.hasPrefix(".") {
                    out.append(CloudLocation(name: "Google Drive (\(account)) – \(d.lastPathComponent)",
                                             url: d, service: .googleDrive))
                }
            } else {
                out.append(CloudLocation(name: name.replacingOccurrences(of: "-", with: " – "),
                                         url: p, service: .other))
            }
        }
        return out
    }
}
