import Foundation

enum DayNightScheduleLogic {
    static func period(
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> WallpaperSchedulePeriod {
        let hour = calendar.component(.hour, from: date)
        return (6..<18).contains(hour) ? .day : .night
    }

    static func dailyRotationIndex(
        at date: Date,
        period: WallpaperSchedulePeriod,
        itemCount: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Int {
        guard itemCount > 1 else { return 0 }
        let hour = calendar.component(.hour, from: date)
        let anchorDate: Date
        if period == .night, hour < 6 {
            anchorDate = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        } else {
            anchorDate = date
        }
        let dayNumber = calendar.ordinality(of: .day, in: .era, for: anchorDate) ?? 1
        return (dayNumber - 1) % itemCount
    }
}
