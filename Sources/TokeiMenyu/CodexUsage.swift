import Foundation
import Darwin

struct CodexUsage {
    let snapshot: UsageSnapshot
    let profile: ProfileInfo

    static func fetch() throws -> CodexUsage {
        let server = try CodexServer()
        defer { server.close() }

        _ = try server.request("initialize", id: 0, params: [
            "clientInfo": ["name": "tokeimenyu", "version": "1.0"]
        ])
        try server.send(["method": "initialized"])
        let accountData = try server.request("account/read", id: 1, params: ["refreshToken": false])
        let account = try JSONDecoder().decode(AccountResponse.self, from: accountData).account
        guard let account else {
            throw AppError("Sign in to Codex with ChatGPT first. Run codex login in Terminal.")
        }
        guard account.type == "chatgpt" else {
            throw AppError("Codex usage limits require a ChatGPT sign-in. API key usage is not supported.")
        }

        let data = try server.request("account/rateLimits/read", id: 2)
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: data)
        return CodexUsage(
            snapshot: response.snapshot,
            profile: ProfileInfo(
                name: nil,
                email: account.email,
                organization: nil,
                organizationType: nil,
                tierLabel: account.planType?.capitalized
            )
        )
    }
}

private final class CodexServer {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private let deadline = Date().addingTimeInterval(30)

    init() throws {
        var environment = ProcessInfo.processInfo.environment
        let paths = (environment["PATH"] ?? "").components(separatedBy: ":") + [
            "/opt/homebrew/bin", "/usr/local/bin",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        ]
        guard let executable = paths.map({ URL(fileURLWithPath: $0).appendingPathComponent("codex") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw AppError("Codex CLI not found. Install Codex CLI and run codex login in Terminal.")
        }
        environment["PATH"] = paths.joined(separator: ":")
        process.environment = environment
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
    }

    func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func request(_ method: String, id: Int, params: [String: Any] = [:]) throws -> Data {
        try send(["method": method, "id": id, "params": params])
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw AppError("Invalid response from Codex.")
                }
                guard message["id"] as? Int == id else { continue }
                if let error = message["error"] as? [String: Any] {
                    throw AppError(error["message"] as? String ?? "Codex request failed.")
                }
                guard let result = message["result"] else { throw AppError("Missing Codex response.") }
                return try JSONSerialization.data(withJSONObject: result)
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AppError("Codex usage request timed out.") }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(remaining * 1000))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw AppError("Codex usage request timed out.") }
            let count = Darwin.read(descriptor.fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard count > 0 else {
                throw AppError("Codex app-server stopped. Check that Codex CLI is up to date and signed in.")
            }
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }
}

private struct AccountResponse: Decodable {
    let account: Account?

    struct Account: Decodable {
        let type: String
        let email: String?
        let planType: String?
    }
}

private struct RateLimitsResponse: Decodable {
    let rateLimits: RateLimitBucket
    let rateLimitsByLimitId: [String: RateLimitBucket]?

    var snapshot: UsageSnapshot {
        let buckets = rateLimitsByLimitId.flatMap { $0.isEmpty ? nil : $0 }
            ?? [rateLimits.limitId ?? "codex": rateLimits]
        let main = buckets["codex"] ?? rateLimits
        var snapshot = UsageSnapshot()
        for key in buckets.keys.sorted(by: { ($0 == "codex" ? "" : $0) < ($1 == "codex" ? "" : $1) }) {
            let bucket = buckets[key]!
            for (kind, window) in [("session", bucket.primary), ("weekly_all", bucket.secondary)] {
                guard let window else { continue }
                let title = window.title ?? (kind == "session" ? "Current session" : "Secondary limit")
                snapshot.limits.append(LimitInfo(
                    id: "\(key)-\(kind)",
                    kind: key == "codex" || buckets.count == 1 ? kind : "\(key)-\(kind)",
                    title: key == "codex" ? title : "\(bucket.limitName ?? key) · \(title)",
                    percent: window.usedPercent,
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) },
                    isActive: true
                ))
            }
        }
        if let credits = main.credits {
            snapshot.extraUsageTitle = "Credits remaining"
            snapshot.extraUsage = credits.unlimited ? "Unlimited" : credits.balance
        }
        snapshot.fetchedAt = Date()
        return snapshot
    }
}

private struct RateLimitBucket: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: Window?
    let secondary: Window?
    let credits: Credits?

    struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: Double?

        var title: String? {
            guard let minutes = windowDurationMins else { return nil }
            if minutes == 10080 { return "Weekly · All models" }
            if minutes % 1440 == 0 { return "\(minutes / 1440)-day limit" }
            if minutes % 60 == 0 { return "\(minutes / 60)-hour limit" }
            return "\(minutes)-minute limit"
        }
    }

    struct Credits: Decodable {
        let unlimited: Bool
        let balance: String?
    }
}
