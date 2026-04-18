import SwiftUI

protocol PatchLifetimeFormatting {}

extension PatchLifetimeFormatting {
    func processPatchLifetime(_ startDate: Date, _ endDate: Date) -> String {
        let lifetime = max(0, endDate.timeIntervalSince(startDate))

        let days = Int(lifetime.days.rounded(.towardZero))
        let hours = Int(lifetime.hours.truncatingRemainder(dividingBy: 24).rounded(.towardZero))
        let minutes = Int(lifetime.minutes.truncatingRemainder(dividingBy: 60).rounded(.towardZero))

        if days > 0 {
            if hours == 0 {
                return [
                    "\(days) \(days == 1 ? LocalizedString("day", comment: "Unit for singular day") : LocalizedString("days", comment: "Unit for plural days"))",
                    "\(minutes) \(minutes == 1 ? LocalizedString("minute", comment: "Unit for singular minute") : LocalizedString("minutes", comment: "Unit for plural minutes"))"
                ].joined(separator: " ")
            }

            return [
                "\(days) \(days == 1 ? LocalizedString("day", comment: "Unit for singular day") : LocalizedString("days", comment: "Unit for plural days"))",
                "\(hours) \(hours == 1 ? LocalizedString("hour", comment: "Unit for singular hour") : LocalizedString("hours", comment: "Unit for plural hours"))"
            ].joined(separator: " ")
        }

        if hours == 0 {
            return "\(minutes) \(minutes == 1 ? LocalizedString("minute", comment: "Unit for singular minute") : LocalizedString("minutes", comment: "Unit for plural minutes"))"
        }

        return [
            "\(hours) \(hours == 1 ? LocalizedString("hour", comment: "Unit for singular hour") : LocalizedString("hours", comment: "Unit for plural hours"))",
            "\(minutes) \(minutes == 1 ? LocalizedString("minute", comment: "Unit for singular minute") : LocalizedString("minutes", comment: "Unit for plural minutes"))"
        ].joined(separator: " ")
    }
}
