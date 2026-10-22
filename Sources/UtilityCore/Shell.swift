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
    public static func run(_ path: String, _ args: [String], environment: [String: String] = [:],
                           input: Data? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if !environment.isEmpty {
            p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let stdin = input.map { _ in Pipe() }
        if let stdin { p.standardInput = stdin }
        guard (try? p.run()) != nil else { return Result(output: "", status: -1) }
        if let stdin, let input {
            // Es. una password per hdiutil: passa solo dalla memoria al programma, mai su disco.
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(output: String(decoding: data, as: UTF8.self), status: p.terminationStatus)
    }
}
#endif
