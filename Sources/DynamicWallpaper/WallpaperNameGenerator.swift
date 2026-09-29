import Foundation

/// 為沒有語意名稱的匯入影片提供適合 lofi 陪伴感的壁紙名稱。
/// 已手動命名的項目不會經過這個產生器覆寫。
enum WallpaperNameGenerator {
    // 舊版曾以本機媒體識別碼作為 key。這些識別碼屬於私人資料，
    // 公開來源不保留該對照表；檔名與來源名稱仍由下方安全 mapping 處理。
    private static let knownTitles: [String: String] = [:]

    /// 依原始匯入檔名保留穩定的中文名稱。這些對照不會依賴目前媒體庫
    /// 使用的 UUID，因此重新匯入同一支影片時仍能得到相同名稱。
    private static let sourceTitles: [String: String] = [
        "phoebe-chibi-cozy-bedroom-wuthering-waves-moewalls-com": "雨夜房間裡的微光陪伴",
        "umbrella-anime-school-girl-flower-shop-moewalls-com": "花店雨幕下的晚歸少女",
        "anime-girl-on-cherry-blossom-street-moewalls-com": "櫻雨古街的提傘漫步",
        "cartethyiasunlight-reading-wuthering-waves-moewalls-com": "日光落在書頁之間",
        "chisa-cozy-room-wuthering-waves-moewalls-com": "紅沙發上的午後絮語",
        "frieren-quiet-ripples": "水光裡的精靈微夢"
    ]

    private static let keywordTitles: [(keywords: [String], title: String)] = [
        (["coffee", "cafe", "咖啡"], "雨聲裡的慢咖啡"),
        (["train", "tram", "電車", "列車"], "遠方駛來的安靜電車"),
        (["rain", "rainy", "雨"], "雨落城市的微光"),
        (["night", "midnight", "夜"], "午夜窗邊的藍色光")
    ]

    static func title(for item: WallpaperItem) -> String? {
        let storedFileKey = URL(fileURLWithPath: item.videoPath)
            .deletingPathExtension()
            .lastPathComponent
            .uppercased()
        if let title = knownTitles[storedFileKey] {
            return title
        }

        // 舊版本有些項目已經把原始檔名存進 title，但影片本身後來
        // 被改成另一個媒體庫 UUID；這時要用舊 title 再查一次場景名稱。
        let legacySourceKey = URL(fileURLWithPath: item.title)
            .deletingPathExtension()
            .lastPathComponent
            .uppercased()
        if let title = knownTitles[legacySourceKey] {
            return title
        }

        return sourceTitles[normalizedStem(item.title)]
    }

    static func title(for source: URL) -> String {
        let stem = source.deletingPathExtension().lastPathComponent
        let key = stem.uppercased()
        if let knownTitle = knownTitles[key] {
            return knownTitle
        }

        if let sourceTitle = sourceTitles[normalizedStem(stem)] {
            return sourceTitle
        }

        let normalized = stem.lowercased()
        if let match = keywordTitles.first(where: { entry in
            entry.keywords.contains { keyword in normalized.contains(keyword) }
        }) {
            return match.title
        }
        return stem
    }

    static func isKnownEnglishTitle(_ title: String) -> Bool {
        sourceTitles[normalizedStem(title)] != nil
    }

    private static func normalizedStem(_ value: String) -> String {
        URL(fileURLWithPath: value)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()
    }

    static func isPlaceholderTitle(_ title: String) -> Bool {
        let pattern = "^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|[0-9A-Fa-f]{32})(拷貝)?$"
        return title.range(of: pattern, options: .regularExpression) != nil
    }
}
