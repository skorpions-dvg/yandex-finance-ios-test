import Foundation

/// The only thing the app hands to the Home Screen widget: three ready sums and when they were taken. No operations,
/// accounts, payees or keys leave the app; the widget never reads the vault and computes nothing itself.
struct WidgetSummary: Codable, Equatable {
    var schemaVersion = 1
    var currency = "RUB"
    /// nil means unknown, never zero.
    var reserveEndOfMonthKopecks: Int64?
    var spentTodayKopecks: Int64?
    var spentMonthKopecks: Int64?
    var updatedAt: Date
    /// The day and month the sums belong to, so «сегодня» does not silently become yesterday after midnight.
    var dayKey: String
    var monthKey: String
    var timeZoneIdentifier: String
    /// The widget test marks which button wrote the file («A», «B»); a real summary leaves it nil.
    var label: String?
}

enum WidgetShared {
    /// The group the app and the widget declare. SideStore registers it with the Team ID appended
    /// («….YandexFinancePrototype.<TEAM>»), so the real name is read from the signed profile at run time.
    static let baseGroup = "group.com.example.YandexFinancePrototype"
    static let fileName = "widget-summary-v1.json"
    static let widgetKind = "HorizonSummary"

    enum ReadResult: Equatable {
        case summary(WidgetSummary)
        /// The group works, the app has not written a summary yet (or cleared it).
        case empty
        /// No shared group is available: the build or the signing lost it.
        case noGroup
        /// The file exists but cannot be read now (locked phone, complete protection) or is damaged.
        case unreadable
    }

    /// The groups to try, best first: the base name with one of the profile's Team IDs, then the base name itself,
    /// then any other allowed «base.…» name. Unrelated groups are never chosen. Without a profile only the base name is left.
    static func groupCandidates(base: String, allowed: [String]?, teamIDs: [String]) -> [String] {
        guard let allowed else { return [base] }
        var result: [String] = []
        for team in teamIDs where allowed.contains(base + "." + team) { result.append(base + "." + team) }
        if allowed.contains(base) { result.append(base) }
        let others = allowed.filter { $0.hasPrefix(base + ".") && !result.contains($0) }.sorted { ($0.count, $0) < ($1.count, $1) }
        result.append(contentsOf: others)
        return result
    }

    /// The app groups and Team IDs of a provisioning profile: a signed (CMS) wrapper around a plain XML property list.
    static func profileGroups(_ data: Data) -> (groups: [String], teamIDs: [String])? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil),
              let root = plist as? [String: Any] else { return nil }
        let entitlements = root["Entitlements"] as? [String: Any]
        let groups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
        let teams = root["TeamIdentifier"] as? [String] ?? []
        return (groups, teams)
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
        String(dayKey(date, calendar: calendar).prefix(7))
    }

    /// Fictional sums for the widget test; nothing of the user's history.
    static func sample(_ label: String, now: Date = Date()) -> WidgetSummary {
        let sums: (Int64, Int64, Int64) = label == "A" ? (123_456, 12_345, 456_789) : (987_600, 5_000, 2_100_050)
        return WidgetSummary(reserveEndOfMonthKopecks: sums.0, spentTodayKopecks: sums.1, spentMonthKopecks: sums.2,
                             updatedAt: now, dayKey: dayKey(now), monthKey: monthKey(now),
                             timeZoneIdentifier: TimeZone.current.identifier, label: label)
    }

#if os(iOS)
    /// The shared group this signed copy can really open, with its container.
    static func resolvedGroup() -> (name: String, container: URL)? {
        var allowed: [String]?
        var teams: [String] = []
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url), let profile = profileGroups(data) {
            allowed = profile.groups
            teams = profile.teamIDs
        }
        for name in groupCandidates(base: baseGroup, allowed: allowed, teamIDs: teams) {
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: name) {
                return (name, container)
            }
        }
        return nil
    }

    private static func fileURL(in container: URL) -> URL {
        container.appendingPathComponent("Widget", isDirectory: true).appendingPathComponent(fileName)
    }

    /// Writes the summary atomically with complete protection, or removes it for nil.
    static func write(_ summary: WidgetSummary?) throws {
        guard let group = resolvedGroup() else { throw CocoaError(.fileNoSuchFile) }
        let url = fileURL(in: group.container)
        guard let summary else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        try? folder.setResourceValues(excluded)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(summary).write(to: url, options: [.atomic, .completeFileProtection])
        var file = url
        try? file.setResourceValues(excluded)
    }

    static func read() -> ReadResult {
        guard let group = resolvedGroup() else { return .noGroup }
        let url = fileURL(in: group.container)
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let summary = try? decoder.decode(WidgetSummary.self, from: data) else { return .unreadable }
        return .summary(summary)
    }
#endif
}
