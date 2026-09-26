import Foundation

public enum HealthSeverity: String, Codable {
    case info
    case healthy
    case warning
    case critical
    case unknown
}

public struct HealthCheckResult: Codable, Identifiable {
    public let identifier: String
    public let category: String
    public let title: String
    public let details: String
    public let severity: HealthSeverity
    public let remediationAvailable: Bool

    public var id: String { identifier }

    public init(identifier: String, category: String, title: String, details: String,
                severity: HealthSeverity, remediationAvailable: Bool = false) {
        self.identifier = identifier
        self.category = category
        self.title = title
        self.details = details
        self.severity = severity
        self.remediationAvailable = remediationAvailable
    }
}

public struct DoctorReport: Codable {
    public let machine: MachineSummary
    public let generated: Date
    public let results: [HealthCheckResult]

    public init(machine: MachineSummary, generated: Date = Date(), results: [HealthCheckResult]) {
        self.machine = machine
        self.generated = generated
        self.results = results
    }
}

/// A single, read-only health check. Every check in this phase only reads
/// system state — none of them change anything, and none of them claim
/// something is insecure without a clear factual basis: when a check can't
/// get a clean answer, it reports `.unknown` rather than guessing.
public protocol HealthCheck: Sendable {
    var identifier: String { get }
    func run() async -> HealthCheckResult
}

/// Runs a command with a timeout and returns its trimmed stdout, or nil on
/// any failure/timeout/non-zero exit — the shared plumbing every shell-backed
/// check below uses so none of them has to reinvent "what if this hangs".
enum HealthCheckShell {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 8) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
