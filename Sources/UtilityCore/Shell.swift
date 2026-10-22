#if os(macOS)
import Foundation

/// Esegue un programma di sistema e ne restituisce l'output (stdout + stderr).
public enum Shell {
    public struct Result: Sendable {
        public let output: String
        public let status: Int32
        public var ok: Bool { status == 0 }
    }

    @discardableResult
    public static func run(_ path: String, _ args: [String], environment: [String: String] = [:]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if !environment.isEmpty {
            p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return Result(output: "", status: -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(output: String(decoding: data, as: UTF8.self), status: p.terminationStatus)
    }
}
#endif
