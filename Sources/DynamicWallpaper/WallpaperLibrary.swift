import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class WallpaperLibrary: ObservableObject {
    @Published private(set) var items: [WallpaperItem] = []
    @Published private(set) var playlists: [WallpaperPlaylist] = []
    @Published var isImporting = false
    @Published var message = "準備就緒"

    private let fileManager = FileManager.default
    private let rootURL: URL
    private let videosURL: URL
    private let thumbnailsURL: URL
    private let databaseURL: URL

    init() {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rootURL = support.appendingPathComponent("動態壁紙", isDirectory: true)
        videosURL = rootURL.appendingPathComponent("影片", isDirectory: true)
        thumbnailsURL = rootURL.appendingPathComponent("縮圖", isDirectory: true)
        databaseURL = rootURL.appendingPathComponent("媒體庫.json")

        prepareDirectories()
        load()
    }

    func importVideos(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        message = "正在建立本機媒體庫…"

        let videosDirectory = videosURL
        let thumbnailsDirectory = thumbnailsURL

        Task {
            let imported = await Task.detached(priority: .userInitiated) {
                await WallpaperImporter.importVideos(
                    urls,
                    videosDirectory: videosDirectory,
                    thumbnailsDirectory: thumbnailsDirectory
                )
            }.value

            items.append(contentsOf: imported)
            items.sort { $0.dateAdded > $1.dateAdded }
            save()
            isImporting = false
            message = imported.isEmpty ? "沒有可匯入的影片" : "已加入 \(imported.count) 部影片"
        }
    }

    func toggleFavorite(_ item: WallpaperItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isFavorite.toggle()
        save()
    }

    func rename(_ item: WallpaperItem, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].title = trimmed
        save()
    }

    func createPlaylist(title: String, kind: WallpaperPlaylistKind = .standard) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists.append(WallpaperPlaylist(
            id: UUID(),
            title: trimmed,
            itemIDs: [],
            dateCreated: Date(),
            kind: kind
        ))
        save()
        message = "已建立播放清單「\(trimmed)」"
    }

    func add(_ item: WallpaperItem, to playlist: WallpaperPlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        guard playlists[index].kind == .standard else { return }
        if !playlists[index].itemIDs.contains(item.id) {
            playlists[index].itemIDs.append(item.id)
            save()
            message = "已將「\(item.title)」加入「\(playlist.title)」"
        }
    }

    func add(
        _ item: WallpaperItem,
        to playlist: WallpaperPlaylist,
        period: WallpaperSchedulePeriod
    ) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }),
              playlists[index].kind == .dayNight else { return }

        switch period {
        case .day:
            if !playlists[index].dayItemIDs.contains(item.id) {
                playlists[index].dayItemIDs.append(item.id)
            }
        case .night:
            if !playlists[index].nightItemIDs.contains(item.id) {
                playlists[index].nightItemIDs.append(item.id)
            }
        }
        save()
        message = "已將「\(item.title)」加入「\(playlist.title)」的\(period.rawValue)分區"
    }

    func renamePlaylist(_ playlist: WallpaperPlaylist, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].title = trimmed
        save()
        message = "播放清單已重新命名"
    }

    func removePlaylist(_ playlist: WallpaperPlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        save()
        message = "已移除播放清單「\(playlist.title)」"
    }

    func remove(_ item: WallpaperItem, from playlist: WallpaperPlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].itemIDs.removeAll { $0 == item.id }
        save()
        message = "已從「\(playlist.title)」移除「\(item.title)」"
    }

    func remove(
        _ item: WallpaperItem,
        from playlist: WallpaperPlaylist,
        period: WallpaperSchedulePeriod
    ) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        switch period {
        case .day: playlists[index].dayItemIDs.removeAll { $0 == item.id }
        case .night: playlists[index].nightItemIDs.removeAll { $0 == item.id }
        }
        save()
        message = "已從「\(playlist.title)」的\(period.rawValue)分區移除「\(item.title)」"
    }

    func items(in playlist: WallpaperPlaylist) -> [WallpaperItem] {
        let ids: [UUID]
        if playlist.kind == .dayNight {
            var seen: Set<UUID> = []
            ids = (playlist.dayItemIDs + playlist.nightItemIDs).filter { seen.insert($0).inserted }
        } else {
            ids = playlist.itemIDs
        }
        return ids.compactMap { id in items.first(where: { $0.id == id }) }
    }

    func items(in playlist: WallpaperPlaylist, period: WallpaperSchedulePeriod) -> [WallpaperItem] {
        let ids = period == .day ? playlist.dayItemIDs : playlist.nightItemIDs
        return ids.compactMap { id in items.first(where: { $0.id == id }) }
    }

    func scheduledItems(
        in playlistID: WallpaperPlaylist.ID?,
        period: WallpaperSchedulePeriod
    ) -> [WallpaperItem] {
        let playlist = playlistID
            .flatMap { id in playlists.first(where: { $0.id == id && $0.kind == .dayNight }) }
            ?? playlists.first(where: { $0.kind == .dayNight })
        guard let playlist else { return [] }
        return items(in: playlist, period: period)
    }

    func remove(_ item: WallpaperItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let targets = [item.videoPath, item.thumbnailPath].compactMap { $0 }.map(URL.init(fileURLWithPath:))

        for target in targets where fileManager.fileExists(atPath: target.path) {
            _ = try? fileManager.trashItem(at: target, resultingItemURL: nil)
        }

        items.remove(at: index)
        for playlistIndex in playlists.indices {
            playlists[playlistIndex].itemIDs.removeAll { $0 == item.id }
            playlists[playlistIndex].dayItemIDs.removeAll { $0 == item.id }
            playlists[playlistIndex].nightItemIDs.removeAll { $0 == item.id }
        }
        save()
        message = "已將「\(item.title)」移到垃圾桶"
    }

    private func prepareDirectories() {
        for directory in [rootURL, videosURL, thumbnailsURL] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: databaseURL),
              let database = try? JSONDecoder().decode(LibraryDatabase.self, from: data) else { return }

        items = database.items
            .filter { fileManager.fileExists(atPath: $0.videoPath) }
            .map { item in
                var updated = item
                if updated.fileSizeBytes == nil {
                    updated.fileSizeBytes = Self.fileSize(atPath: item.videoPath)
                }
                return updated
            }
        playlists = database.playlists ?? []
        if migrateLegacyScheduledPlaylistsIfNeeded() {
            save()
        }
    }

    @discardableResult
    private func migrateLegacyScheduledPlaylistsIfNeeded() -> Bool {
        let legacy = playlists.filter { $0.schedulePeriod != nil }
        guard !legacy.isEmpty else { return false }

        var dayIDs: [UUID] = []
        var nightIDs: [UUID] = []
        for playlist in legacy {
            if playlist.schedulePeriod == .day {
                dayIDs.append(contentsOf: playlist.itemIDs)
            } else if playlist.schedulePeriod == .night {
                nightIDs.append(contentsOf: playlist.itemIDs)
            }
        }
        dayIDs = unique(dayIDs)
        nightIDs = unique(nightIDs)
        playlists.removeAll { $0.schedulePeriod != nil }

        if let index = playlists.firstIndex(where: { $0.kind == .dayNight }) {
            playlists[index].dayItemIDs = unique(playlists[index].dayItemIDs + dayIDs)
            playlists[index].nightItemIDs = unique(playlists[index].nightItemIDs + nightIDs)
        } else {
            playlists.append(WallpaperPlaylist(
                id: UUID(),
                title: "日夜輪播",
                itemIDs: [],
                dateCreated: legacy.map(\.dateCreated).min() ?? Date(),
                kind: .dayNight,
                dayItemIDs: dayIDs,
                nightItemIDs: nightIDs
            ))
        }
        message = "已將舊白天與夜晚清單整合為「日夜輪播」"
        return true
    }

    private func unique(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    private func save() {
        let database = LibraryDatabase(items: items, playlists: playlists)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(database) else { return }
        try? data.write(to: databaseURL, options: .atomic)
    }

    private static func fileSize(atPath path: String) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }
}

private struct LibraryDatabase: Codable {
    var items: [WallpaperItem]
    var playlists: [WallpaperPlaylist]?
}

private enum WallpaperImporter {
    static func importVideos(
        _ urls: [URL],
        videosDirectory: URL,
        thumbnailsDirectory: URL
    ) async -> [WallpaperItem] {
        var imported: [WallpaperItem] = []

        for source in urls {
            let id = UUID()
            let extensionName = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
            let destination = videosDirectory.appendingPathComponent("\(id.uuidString).\(extensionName)")
            let thumbnail = thumbnailsDirectory.appendingPathComponent("\(id.uuidString).jpg")

            do {
                try FileManager.default.copyItem(at: source, to: destination)
                let metadata = await videoMetadata(for: destination, thumbnailURL: thumbnail)
                imported.append(WallpaperItem(
                    id: id,
                    title: source.deletingPathExtension().lastPathComponent,
                    videoPath: destination.path,
                    thumbnailPath: metadata.hasThumbnail ? thumbnail.path : nil,
                    duration: metadata.duration,
                    width: metadata.width,
                    height: metadata.height,
                    fileSizeBytes: fileSize(at: destination),
                    isFavorite: false,
                    dateAdded: Date()
                ))
            } catch {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.removeItem(at: thumbnail)
            }
        }

        return imported
    }

    private static func videoMetadata(
        for url: URL,
        thumbnailURL: URL
    ) async -> (duration: Double, width: Int, height: Int, hasThumbnail: Bool) {
        let asset = AVURLAsset(url: url)
        let loadedDuration = try? await asset.load(.duration)
        let duration = loadedDuration.map(CMTimeGetSeconds) ?? 0
        let track = try? await asset.loadTracks(withMediaType: .video).first
        let naturalSize = try? await track?.load(.naturalSize)
        let preferredTransform = try? await track?.load(.preferredTransform)
        let transformedSize = naturalSize?.applying(preferredTransform ?? .identity) ?? .zero
        let width = Int(abs(transformedSize.width))
        let height = Int(abs(transformedSize.height))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 600)

        let captureTime = CMTime(seconds: min(max(duration * 0.15, 0.1), 3), preferredTimescale: 600)
        var hasThumbnail = false

        if let image = try? generator.copyCGImage(at: captureTime, actualTime: nil) {
            let representation = NSBitmapImageRep(cgImage: image)
            if let data = representation.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) {
                hasThumbnail = (try? data.write(to: thumbnailURL, options: .atomic)) != nil
            }
        }

        return (duration.isFinite ? duration : 0, width, height, hasThumbnail)
    }

    private static func fileSize(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }
}
