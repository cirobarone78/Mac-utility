import Foundation

/// Trova le risorse (icone) sia avviando da Xcode o `swift run` sia dentro OmniTools.app.
/// Non usa `Bundle.module`, che fa chiudere l'app se il pacchetto risorse non è dove se lo aspetta.
enum Resources {
    static let bundle: Bundle = {
        let name = "OmniTools_OmniTools.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),      // dentro OmniTools.app
            Bundle.main.bundleURL.appendingPathComponent(name),         // swift run / Xcode
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
        ]
        for case let url? in candidates {
            if let b = Bundle(url: url) { return b }
        }
        return .main
    }()
}
