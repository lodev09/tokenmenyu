import Foundation
import CryptoKit
import SwiftUI

struct LimitInfo: Identifiable {
    let id: String
    let kind: String
    let title: String
    let percent: Double
    let resetsAt: Date?
    let isActive: Bool
}

struct ProfileInfo {
    let name: String?
    let email: String?
    let organization: String?
    let organizationType: String?
    let tierLabel: String?

    var avatarURL: URL? {
        guard let email else { return nil }
        let normalized = email.lowercased().trimmingCharacters(in: .whitespaces)
        let hash = Insecure.MD5.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=120&d=404")
    }
}

struct UsageSnapshot {
    var limits: [LimitInfo] = []
    var extraUsageTitle = "Extra usage"
    var extraUsage: String?
    var extraUsagePercent: Double?
    var fetchedAt: Date?
}

enum UsageProvider: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"

    var id: String { rawValue }
    var symbol: String { "sparkle" }
    var tint: Color? { self == .claude ? .orange : nil }
}

private struct ProviderUsage {
    var snapshot = UsageSnapshot()
    var error: String?
    var isLoading = false
    var tier: String?
    var profile: ProfileInfo?
    var blockedUntil: Date?
}

@MainActor
final class UsageModel: ObservableObject {
    @Published var provider: UsageProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "usageProvider") }
    }
    @Published private var providers: [UsageProvider: ProviderUsage] = [
        .claude: ProviderUsage(),
        .codex: ProviderUsage()
    ]

    var snapshot: UsageSnapshot { providers[provider]!.snapshot }
    var error: String? { providers[provider]!.error }
    var isLoading: Bool { providers[provider]!.isLoading }
    var profile: ProfileInfo? { providers[provider]!.profile }
    var blockedUntil: Date? { providers[provider]!.blockedUntil }
    static let minRefreshInterval: TimeInterval = 90

    @Published var refreshInterval: TimeInterval {
        didSet {
            let clamped = max(Self.minRefreshInterval, refreshInterval)
            if clamped != refreshInterval { refreshInterval = clamped; return }
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            startPolling()
        }
    }

    var tierLabel: String? {
        profile?.tierLabel ?? providers[provider]!.tier?.capitalized
    }

    func headline(for provider: UsageProvider) -> String {
        guard let session = providers[provider]!.snapshot.limits.first(where: { $0.kind == "session" }) else { return "–" }
        return "\(Int(session.percent))%"
    }

    private var pollTask: Task<Void, Never>?

    init() {
        provider = UserDefaults.standard.string(forKey: "usageProvider").flatMap(UsageProvider.init(rawValue:)) ?? .claude
        let saved = UserDefaults.standard.double(forKey: "refreshInterval")
        refreshInterval = max(Self.minRefreshInterval, saved > 0 ? saved : 300)
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load()
                guard let interval = self?.refreshInterval else { break }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func refresh(force: Bool = false) {
        Task { await load(force: force) }
    }

    private func load(force: Bool = false) async {
        async let claude: Void = load(provider: .claude, force: force)
        async let codex: Void = load(provider: .codex, force: force)
        _ = await (claude, codex)
    }

    private func load(provider: UsageProvider, force: Bool) async {
        let state = providers[provider]!
        guard !state.isLoading else { return }
        if let blocked = state.blockedUntil, Date() < blocked { return }
        if !force, let last = state.snapshot.fetchedAt, Date().timeIntervalSince(last) < 30 { return }
        providers[provider]!.isLoading = true
        defer { providers[provider]!.isLoading = false }
        do {
            switch provider {
            case .claude:
                try await loadClaude()
            case .codex:
                let usage = try await Task.detached { try CodexUsage.fetch() }.value
                providers[.codex]!.snapshot = usage.snapshot
                providers[.codex]!.profile = usage.profile
            }
            providers[provider]!.blockedUntil = nil
            providers[provider]!.error = nil
        } catch let rateLimited as RateLimitedError {
            providers[provider]!.blockedUntil = Date().addingTimeInterval(rateLimited.retryAfter)
            providers[provider]!.error = nil
        } catch {
            providers[provider]!.error = error.localizedDescription
        }
    }

    private func loadClaude() async throws {
        var creds = try await Task.detached { try Self.readCredentials() }.value
        guard !creds.isExpired else { throw TokenExpiredError() }
        providers[.claude]!.tier = creds.tier
        if providers[.claude]!.profile == nil {
            providers[.claude]!.profile = try? await Self.fetchProfile(token: creds.token)
        }
        var usage: UsageSnapshot
        do {
            usage = try await Self.fetchUsage(token: creds.token)
        } catch is TokenExpiredError {
            // Claude Code may have refreshed since we read — re-read and retry once
            let fresh = try await Task.detached { try Self.readCredentials() }.value
            guard fresh.token != creds.token, !fresh.isExpired else { throw TokenExpiredError() }
            creds = fresh
            usage = try await Self.fetchUsage(token: creds.token)
        }
        providers[.claude]!.snapshot = usage
    }

    // MARK: - Keychain

    private struct Credentials {
        let token: String
        let expiresAt: Date?
        let tier: String?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 60
        }
    }

    private nonisolated static func readCredentials() throws -> Credentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else {
            throw AppError("Claude Code credentials not found. Sign in via Claude Code first.")
        }
        return Credentials(
            token: token,
            expiresAt: (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
            tier: oauth["subscriptionType"] as? String
        )
    }

    // MARK: - API

    private static func fetchProfile(token: String) async throws -> ProfileInfo {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError("Profile unavailable")
        }
        let api = try JSONDecoder().decode(ProfileResponse.self, from: data)

        func prettify(_ raw: String?) -> String? {
            raw?
                .replacingOccurrences(of: "default_claude_", with: "")
                .replacingOccurrences(of: "claude_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }

        return ProfileInfo(
            name: api.account?.full_name,
            email: api.account?.email,
            organization: api.organization?.name,
            organizationType: prettify(api.organization?.organization_type),
            tierLabel: prettify(api.organization?.rate_limit_tier)
        )
    }

    private static func fetchUsage(token: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError("Invalid response") }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 {
                throw TokenExpiredError()
            }
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 120
                throw RateLimitedError(retryAfter: retryAfter)
            }
            throw AppError("API error (\(http.statusCode))")
        }

        let api = try JSONDecoder().decode(APIResponse.self, from: data)

        var snapshot = UsageSnapshot()
        snapshot.limits = api.limits.enumerated().map { index, limit in
            LimitInfo(
                id: "\(limit.kind)-\(index)",
                kind: limit.kind,
                title: limit.displayTitle,
                percent: limit.percent,
                resetsAt: limit.resets_at.flatMap(parseDate),
                isActive: limit.is_active ?? false
            )
        }
        if let used = api.spend?.used, api.spend?.enabled == true {
            let amount = used.amount_minor / pow(10, Double(used.exponent))
            var text = amount.formatted(.currency(code: used.currency).presentation(.narrow))
            if let limit = api.spend?.limit {
                let cap = limit.amount_minor / pow(10, Double(limit.exponent))
                text += " of \(cap.formatted(.currency(code: limit.currency).presentation(.narrow)))"
            }
            snapshot.extraUsage = text
            snapshot.extraUsagePercent = api.spend?.percent
        }
        snapshot.fetchedAt = Date()
        return snapshot
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

struct RateLimitedError: LocalizedError {
    let retryAfter: TimeInterval
    var errorDescription: String? { "Rate limited" }
}

struct TokenExpiredError: LocalizedError {
    var errorDescription: String? { "Token expired. Open Claude Code to refresh it." }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - API models

private struct ProfileResponse: Decodable {
    struct Account: Decodable {
        let full_name: String?
        let email: String?
    }
    struct Organization: Decodable {
        let name: String?
        let organization_type: String?
        let rate_limit_tier: String?
    }
    let account: Account?
    let organization: Organization?
}

private struct APIResponse: Decodable {
    let limits: [APILimit]
    let spend: APISpend?
}

private struct APILimit: Decodable {
    let kind: String
    let percent: Double
    let resets_at: String?
    let is_active: Bool?
    let scope: Scope?

    struct Scope: Decodable {
        let model: Model?
        struct Model: Decodable { let display_name: String? }
    }

    var displayTitle: String {
        switch kind {
        case "session": return "Current session"
        case "weekly_all": return "Weekly · All models"
        case "weekly_scoped": return "Weekly · \(scope?.model?.display_name ?? "Model")"
        default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

private struct APISpend: Decodable {
    let used: Money?
    let limit: Money?
    let percent: Double?
    let enabled: Bool?
    struct Money: Decodable {
        let amount_minor: Double
        let currency: String
        let exponent: Int
    }
}
