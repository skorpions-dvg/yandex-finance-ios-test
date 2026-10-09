import Foundation

// Checks of the widget's shared group choice and profile reading (fictional profiles only).
@main
struct WidgetSummaryTests {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        if !condition {
            failures += 1
            print("FAIL " + name)
        }
    }

    static func profile(_ groups: [String], teams: [String]) -> Data {
        let list = groups.map { "<string>\($0)</string>" }.joined()
        let teamList = teams.map { "<string>\($0)</string>" }.joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Entitlements</key><dict><key>com.apple.security.application-groups</key><array>\(list)</array></dict>
        <key>TeamIdentifier</key><array>\(teamList)</array>
        </dict></plist>
        """
        // The signed wrapper around the plist: arbitrary bytes before and after it.
        return Data([0x30, 0x82, 0x3c, 0x00, 0xff]) + Data(xml.utf8) + Data([0x00, 0xa0, 0x82, 0x3c])
    }

    static func main() {
        let base = WidgetShared.baseGroup
        let team = "ABCDE12345"

        // SideStore's renamed group comes first, an unrelated group is never picked.
        let parsed = WidgetShared.profileGroups(profile(["group.other.app", base + "." + team], teams: [team]))
        check(parsed?.groups == ["group.other.app", base + "." + team], "profile groups are read")
        check(parsed?.teamIDs == [team], "profile team is read")
        check(WidgetShared.groupCandidates(base: base, allowed: parsed?.groups, teamIDs: parsed?.teamIDs ?? []) == [base + "." + team],
              "renamed group chosen, unrelated skipped")

        // The base name without a suffix, and both: the team name first.
        check(WidgetShared.groupCandidates(base: base, allowed: [base], teamIDs: [team]) == [base], "base group")
        check(WidgetShared.groupCandidates(base: base, allowed: [base, base + "." + team], teamIDs: [team]) == [base + "." + team, base],
              "team group before base")
        // A look-alike name («…PrototypeX») is not a group of ours.
        check(WidgetShared.groupCandidates(base: base, allowed: [base + "X"], teamIDs: [team]).isEmpty, "look-alike rejected")
        // Another team's suffix is kept only as a last resort.
        check(WidgetShared.groupCandidates(base: base, allowed: [base + ".ZZZ", base + "." + team], teamIDs: [team]) == [base + "." + team, base + ".ZZZ"],
              "own team first")
        // No profile (development build): only the base name.
        check(WidgetShared.groupCandidates(base: base, allowed: nil, teamIDs: []) == [base], "no profile")
        // A profile without groups gives nothing to try.
        let empty = WidgetShared.profileGroups(profile([], teams: [team]))
        check(empty != nil && WidgetShared.groupCandidates(base: base, allowed: empty?.groups, teamIDs: [team]).isEmpty, "profile without groups")
        check(WidgetShared.profileGroups(Data("not a profile".utf8)) == nil, "garbage is not a profile")

        // Day and month keys.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_760_000_000)  // 2025-10-09 08:53 UTC
        check(WidgetShared.dayKey(date, calendar: calendar) == "2025-10-09", "day key")
        check(WidgetShared.monthKey(date, calendar: calendar) == "2025-10", "month key")

        // The two test summaries differ in every sum and round-trip through JSON.
        let a = WidgetShared.sample("A", now: date), b = WidgetShared.sample("B", now: date)
        check(a.reserveEndOfMonthKopecks != b.reserveEndOfMonthKopecks && a.spentTodayKopecks != b.spentTodayKopecks
              && a.spentMonthKopecks != b.spentMonthKopecks, "samples differ")
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        let back = (try? encoder.encode(a)).flatMap { try? decoder.decode(WidgetSummary.self, from: $0) }
        check(back == a, "summary JSON round trip")
        // An unknown sum stays unknown, not zero.
        var unknown = a
        unknown.spentTodayKopecks = nil
        let json = (try? encoder.encode(unknown)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(!json.contains("\"spentTodayKopecks\":0"), "unknown is not zero")

        // The real summary: the sums as given; switched off — no sum at all, only the mark.
        let shown = WidgetShared.summary(reserve: -1_297_800, spentToday: 0, spentMonth: 4_500_000, now: date, showSums: true)
        check(shown.reserveEndOfMonthKopecks == -1_297_800 && shown.spentTodayKopecks == 0 && shown.spentMonthKopecks == 4_500_000
              && shown.sumsHidden == nil && shown.label == nil, "summary keeps the sums")
        let hidden = WidgetShared.summary(reserve: -1_297_800, spentToday: 0, spentMonth: 4_500_000, now: date, showSums: false)
        check(hidden.reserveEndOfMonthKopecks == nil && hidden.spentTodayKopecks == nil && hidden.spentMonthKopecks == nil
              && hidden.sumsHidden == true, "hidden summary has no sums")
        let hiddenJSON = (try? encoder.encode(hidden)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(!hiddenJSON.contains("1297800") && !hiddenJSON.contains("4500000"), "hidden sums never reach the file")
        // Same numbers later the same day: no rewrite; another number or another day: rewrite.
        let later = WidgetShared.summary(reserve: -1_297_800, spentToday: 0, spentMonth: 4_500_000, now: date.addingTimeInterval(600), showSums: true)
        check(shown.sameContent(as: later), "same content ignores the time")
        let changed = WidgetShared.summary(reserve: -1_297_800, spentToday: 100, spentMonth: 4_500_100, now: date, showSums: true)
        check(!shown.sameContent(as: changed), "changed sum is new content")
        let nextDay = WidgetShared.summary(reserve: -1_297_800, spentToday: 0, spentMonth: 4_500_000, now: date.addingTimeInterval(86_400), showSums: true)
        check(!shown.sameContent(as: nextDay), "a new day is new content")
        check(!shown.sameContent(as: hidden), "switching the sums off is new content")
        // A file of 46.34 (no sumsHidden field) still opens.
        let old = #"{"schemaVersion":1,"currency":"RUB","reserveEndOfMonthKopecks":123456,"updatedAt":"2025-10-09T08:53:20Z","dayKey":"2025-10-09","monthKey":"2025-10","timeZoneIdentifier":"UTC","label":"A"}"#
        let oldSummary = try? decoder.decode(WidgetSummary.self, from: Data(old.utf8))
        check(oldSummary?.reserveEndOfMonthKopecks == 123_456 && oldSummary?.sumsHidden == nil, "old file opens")

        if failures > 0 {
            print("WidgetSummaryTests: \(failures) failed")
            exit(1)
        }
        print("WidgetSummaryTests: all passed")
    }
}
