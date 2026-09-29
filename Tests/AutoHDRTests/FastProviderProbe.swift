import Foundation
@main
struct FastProviderProbe {
    static func main() async {
        let defaults = UserDefaults(suiteName: "AutoHDR.FastProbe.\(UUID())")!
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/yt-dlp_macos")
        let provider = YTDLPMetadataProvider(preferences: defaults, executableOverride: executable,
                                             metadataTimeout: 5, fastPathEnabled: true)
        for id in ["BN5dc3FbY3U", "jNQXAC9IVRw"] {
            let start = Date()
            let result = await withCheckedContinuation { continuation in
                provider.lookup(videoID: id) { continuation.resume(returning: $0) }
            }
            print("\(id)=\(result.state.rawValue) range=\(result.dynamicRange ?? "SDR") elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s processes=\(provider.diagnostics().metadataLaunchCount)")
        }
    }
}
