#if os(macOS)
import Foundation
import CoreAudio
import CoreMediaIO

/// Stato di fotocamera e microfono in questo momento.
public struct MediaState: Equatable, Sendable {
    public var cameraOn = false
    public var micOn = false
    /// Identificativi (o PID) dei programmi che stanno usando il microfono (macOS 14.2 e successivi).
    public var micClients: [MediaClient] = []
}

public struct MediaClient: Hashable, Sendable {
    public let pid: Int32
    public let bundleID: String?
}

/// Un evento registrato: «Zoom ha acceso la fotocamera alle 10:32».
public struct MediaEvent: Codable, Identifiable, Hashable, Sendable {
    public enum Device: String, Codable, Sendable { case camera = "Fotocamera", microphone = "Microfono" }
    public let date: Date
    public let device: Device
    public let on: Bool
    public let apps: [String]
    public var id: String { "\(date.timeIntervalSince1970)-\(device.rawValue)-\(on)" }

    public init(date: Date = Date(), device: Device, on: Bool, apps: [String]) {
        self.date = date
        self.device = device
        self.on = on
        self.apps = apps
    }
}

public enum MediaDevices {
    public static func state() -> MediaState {
        var s = MediaState()
        s.cameraOn = cameraRunning()
        if #available(macOS 14.2, *) {
            // Elenco preciso dei processi che registrano: evita i falsi allarmi delle cuffie
            // (es. AirPods) che risultano «in uso» anche quando suonano soltanto.
            s.micClients = micProcesses()
            s.micOn = !s.micClients.isEmpty
        } else {
            s.micOn = micRunning()
        }
        return s
    }

    // MARK: Fotocamera (CoreMediaIO)

    static func cameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &devices) == 0 else { return false }
        for device in devices {
            var a = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var running: UInt32 = 0
            let len = UInt32(MemoryLayout<UInt32>.size)
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &a, 0, nil, len, &got, &running) == 0, running != 0 { return true }
        }
        return false
    }

    // MARK: Microfono (CoreAudio)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func micRunning() -> Bool {
        for device in objects(kAudioHardwarePropertyDevices) {
            // Solo i dispositivi con canali di ingresso.
            var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { continue }
            if uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1 { return true }
        }
        return false
    }

    /// Chi sta registrando dal microfono (disponibile da macOS 14.2).
    static func micProcesses() -> [MediaClient] {
        guard #available(macOS 14.2, *) else { return [] }
        var out: [MediaClient] = []
        for process in objects(kAudioHardwarePropertyProcessObjectList) {
            guard uint32(process, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            var pidAddr = address(kAudioProcessPropertyPID)
            var pid: pid_t = 0
            var size = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(process, &pidAddr, 0, nil, &size, &pid)
            var idAddr = address(kAudioProcessPropertyBundleID)
            var ref: Unmanaged<CFString>?
            var refSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundle: String?
            if AudioObjectGetPropertyData(process, &idAddr, 0, nil, &refSize, &ref) == noErr, let ref {
                bundle = ref.takeRetainedValue() as String
            }
            out.append(MediaClient(pid: pid, bundleID: (bundle?.isEmpty ?? true) ? nil : bundle))
        }
        return out
    }
}

/// Registro degli eventi: ~/Library/Application Support/OmniTools/fotocamera-microfono.json
public enum MediaLog {
    static var url: URL {
        SafetyPolicy.defaultFileURL.deletingLastPathComponent().appendingPathComponent("fotocamera-microfono.json")
    }

    public static func load() -> [MediaEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode([MediaEvent].self, from: data)) ?? []
    }

    public static func append(_ e: MediaEvent) {
        var list = load()
        list.insert(e, at: 0)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(Array(list.prefix(500))).write(to: url, options: .atomic)
    }

    public static func clear() { try? FileManager.default.removeItem(at: url) }
}
#endif
