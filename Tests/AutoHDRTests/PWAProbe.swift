import Foundation
@main
struct PWAProbe {
    static func main() {
        let start = Date()
        let bounds = CommandLine.arguments.count == 5 ? CommandLine.arguments.dropFirst().compactMap(Int.init) : nil
        let snapshot = YouTubeBrowserMonitor.read(.chromeYouTubeApp, preferredBounds: bounds)
        print("browser=\(snapshot.browser.title) url=\(snapshot.urlString ?? "none") watch=\(YouTubeWatchContext(snapshot: snapshot)?.videoID ?? "none") window=\(snapshot.windowID) tab=\(snapshot.tabID) available=\(snapshot.isBrowserAvailable) error=\(snapshot.errorMessage ?? "none") elapsed=\(Date().timeIntervalSince(start))")
    }
}
