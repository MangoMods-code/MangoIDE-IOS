import Foundation

/// Picks the holiday theme for today when "Automatic Holiday Themes" is on.
enum Holidays {
    private static var cachedDay: Int = -1
    private static var cachedID: String?

    /// Theme id for today's holiday, or nil. Cached per day so it's free to call while drawing.
    static func current(_ date: Date = Date()) -> String? {
        let cal = Calendar(identifier: .gregorian)
        let day = cal.ordinality(of: .day, in: .era, for: date) ?? 0
        if day == cachedDay { return cachedID }
        cachedDay = day
        cachedID = compute(date, cal)
        return cachedID
    }

    private static func compute(_ date: Date, _ cal: Calendar) -> String? {
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        let d = cal.component(.day, from: date)
        func on(_ month: Int, _ from: Int, _ to: Int) -> Bool { m == month && d >= from && d <= to }
        func near(_ target: DateComponents?, before: Int, after: Int) -> Bool {
            guard let target, let t = cal.date(from: target) else { return false }
            let diff = cal.dateComponents([.day], from: cal.startOfDay(for: t), to: cal.startOfDay(for: date)).day ?? 99
            return diff >= -before && diff <= after
        }
        func ymd(_ y: Int, _ m: Int, _ d: Int) -> DateComponents { DateComponents(year: y, month: m, day: d) }

        // Dates that move each year.
        let lunarNewYear: [Int: DateComponents] = [2026: ymd(2026, 2, 17), 2027: ymd(2027, 2, 6), 2028: ymd(2028, 1, 26),
                                                  2029: ymd(2029, 2, 13), 2030: ymd(2030, 2, 3), 2031: ymd(2031, 1, 23)]
        let diwali: [Int: DateComponents] = [2026: ymd(2026, 11, 8), 2027: ymd(2027, 10, 29), 2028: ymd(2028, 10, 17),
                                            2029: ymd(2029, 11, 5), 2030: ymd(2030, 10, 26), 2031: ymd(2031, 11, 14)]
        let hanukkahStart: [Int: DateComponents] = [2026: ymd(2026, 12, 4), 2027: ymd(2027, 12, 24), 2028: ymd(2028, 12, 12),
                                                   2029: ymd(2029, 12, 1), 2030: ymd(2030, 12, 20), 2031: ymd(2031, 12, 9)]

        if on(12, 31, 31) || on(1, 1, 2) { return "new-years" }
        if near(hanukkahStart[y], before: 0, after: 8) || near(hanukkahStart[y - 1], before: 0, after: 8) { return "hanukkah" }
        if on(12, 1, 26) { return "christmas" }
        if on(1, 3, 20) || on(12, 27, 30) { return "winter" }
        if near(lunarNewYear[y], before: 2, after: 7) { return "lunar-new-year" }
        if on(2, 10, 14) { return "valentines" }
        if on(3, 14, 17) { return "st-patricks" }
        if near(easter(y), before: 4, after: 1) { return "easter" }
        if on(4, 20, 22) { return "earth-day" }
        if on(6, 1, 30) { return "pride" }
        if on(7, 1, 4) { return "fourth-of-july" }
        if on(10, 15, 31) { return "halloween" }
        if on(11, 1, 2) { return "day-of-the-dead" }
        if near(diwali[y], before: 2, after: 2) { return "diwali" }
        if let tg = thanksgiving(y, cal), near(tg, before: 3, after: 3) { return "thanksgiving" }
        return nil
    }

    /// Western Easter (Anonymous Gregorian algorithm).
    static func easter(_ y: Int) -> DateComponents {
        let a = y % 19, b = y / 100, c = y % 100, d = b / 4, e = b % 4
        let f = (b + 8) / 25, g = (b - f + 1) / 3, h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1
        return DateComponents(year: y, month: month, day: day)
    }

    /// US Thanksgiving: fourth Thursday of November.
    static func thanksgiving(_ y: Int, _ cal: Calendar) -> DateComponents? {
        var c = DateComponents(year: y, month: 11)
        c.weekday = 5
        c.weekdayOrdinal = 4
        guard let date = cal.date(from: c) else { return nil }
        return cal.dateComponents([.year, .month, .day], from: date)
    }
}
