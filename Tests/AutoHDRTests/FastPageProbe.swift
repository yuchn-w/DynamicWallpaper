import Foundation
@main
struct FastPageProbe {
    static func main() throws {
        for argument in CommandLine.arguments.dropFirst() {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let result = YTDLPMetadataProvider.classifyWatchPage(
                data: try Data(contentsOf: URL(fileURLWithPath: parts[1])), expectedVideoID: parts[0]
            )
            print("\(parts[0])=\(result?.range ?? (result == nil ? "Unknown" : "SDR"))")
        }
    }
}
