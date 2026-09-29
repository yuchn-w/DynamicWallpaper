import Foundation

@main
@MainActor
final class AutoHDRTests {
    static func main() async {
        let suite = AutoHDRTests()
        await suite.testLeavingWatchHasOneDeadlineDespiteRepeatedPolling()
        print("CHECK testLeavingWatchHasOneDeadlineDespiteRepeatedPolling")
        await suite.testModeOffThenAutoRechecksSameVideo()
        print("CHECK testModeOffThenAutoRechecksSameVideo")
        await suite.testManualOnToAutoSDRIsImmediateAfterMetadata()
        print("CHECK testManualOnToAutoSDRIsImmediateAfterMetadata")
        await suite.testHDRToHDRKeepsOnAndDoesNotReload()
        print("CHECK testHDRToHDRKeepsOnAndDoesNotReload")
        await suite.testSDRGraceCancelledByNewHDR()
        print("CHECK testSDRGraceCancelledByNewHDR")
        await suite.testUnknownKeepsStateThenTurnsOff()
        print("CHECK testUnknownKeepsStateThenTurnsOff")
        await suite.testStaleMetadataCannotOverrideManualMode()
        print("CHECK testStaleMetadataCannotOverrideManualMode")
        await suite.testOnlyStableVideoIDQueriesAndParameterChangeDoesNot()
        print("CHECK testOnlyStableVideoIDQueriesAndParameterChangeDoesNot")
        await suite.testSleepInvalidatesResultAndWakeRestartsMonitor()
        print("CHECK testSleepInvalidatesResultAndWakeRestartsMonitor")
        await suite.testReloadOnlyAfterVerifiedTransitionAndOnce()
        print("CHECK testReloadOnlyAfterVerifiedTransitionAndOnce")
        suite.testHomeSearchShortsMiniPlayerAndSpoofedHostExcluded()
        print("CHECK testHomeSearchShortsMiniPlayerAndSpoofedHostExcluded")
        suite.testFormatClassificationExcludesAudioAndRecognizesAllHDRLabels()
        print("CHECK testFormatClassificationExcludesAudioAndRecognizesAllHDRLabels")
        suite.testReloadScriptUsesActualTabIdentityAndReportsResult()
        print("CHECK testReloadScriptUsesActualTabIdentityAndReportsResult")
        suite.testBackgroundChromeWatchUsesTrackedTabInsteadOfFrontWindow()
        print("CHECK testBackgroundChromeWatchUsesTrackedTabInsteadOfFrontWindow")
        suite.testPWAFrontWindowMatchRejectsOrdinaryVisibleChromeWindow()
        print("CHECK testPWAFrontWindowMatchRejectsOrdinaryVisibleChromeWindow")
        suite.testChromeYouTubeAppIdentificationAndFastMetadata()
        print("CHECK testChromeYouTubeAppIdentificationAndFastMetadata")
        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        await suite.testPersistentCacheAndTimeout()
        if failures > 0 { exit(1) }
        print("All 17 Auto HDR regressions passed")
    }

    func testChromeYouTubeAppIdentificationAndFastMetadata() {
        XCTAssertEqual(YouTubeBrowser.identify(bundleID: "com.google.Chrome.app.test",
                                               shortcutURL: "https://www.youtube.com/?feature=ytca"), .chromeYouTubeApp)
        XCTAssertEqual(YouTubeBrowser.identify(bundleID: "com.google.Chrome.app.test",
                                               shortcutURL: "https://example.com/"), nil)
        let videoID = "BN5dc3FbY3U"
        let hdr = "<script>var ytInitialPlayerResponse = {\"streamingData\":{\"adaptiveFormats\":[{\"mimeType\":\"video/webm\",\"colorInfo\":{\"primaries\":\"COLOR_PRIMARIES_BT2020\",\"transferCharacteristics\":\"COLOR_TRANSFER_CHARACTERISTICS_ARIB_STD_B67\"}}]},\"videoDetails\":{\"videoId\":\"\(videoID)\"}};</script>"
        let sdr = "<script>var ytInitialPlayerResponse = {\"streamingData\":{\"formats\":[{\"mimeType\":\"video/mp4\",\"colorInfo\":{\"transferCharacteristics\":\"COLOR_TRANSFER_CHARACTERISTICS_BT709\"}}]},\"videoDetails\":{\"videoId\":\"\(videoID)\"}};</script>"
        XCTAssertEqual(YTDLPMetadataProvider.classifyWatchPage(data: Data(hdr.utf8), expectedVideoID: videoID)?.range, "HLG")
        XCTAssertEqual(YTDLPMetadataProvider.classifyWatchPage(data: Data(sdr.utf8), expectedVideoID: videoID)?.range, nil)
        XCTAssertTrue(YTDLPMetadataProvider.classifyWatchPage(data: Data(hdr.utf8), expectedVideoID: "AAAAAAAAAAA") == nil)
    }
    private func snapshot(_ id: String?, browser: YouTubeBrowser = .chrome, suffix: String = "") -> BrowserTabSnapshot {
        BrowserTabSnapshot(browser: browser, urlString: id.map { "https://www.youtube.com/watch?v=\($0)\(suffix)" } ?? "https://www.youtube.com/",
                           windowID: 10, tabID: 20, isBrowserAvailable: true, errorMessage: nil)
    }
    private func system(_ initial: AutoHDRMode = .auto) -> (AutoHDRController, FakeDisplay, FakeBrowser, FakeMetadata) {
        let defaults = UserDefaults(suiteName: "AutoHDRTests.\(UUID())")!
        defaults.set(initial.rawValue, forKey: "AutoHDR.mode")
        let display = FakeDisplay(), browser = FakeBrowser(), metadata = FakeMetadata()
        let controller = AutoHDRController(displayController: display, browserMonitor: browser,
                                           metadataProvider: metadata, preferences: defaults,
                                           graceDelay: 120_000_000, stabilityDelay: 10_000_000, observeLifecycle: false)
        controller.start()
        return (controller, display, browser, metadata)
    }
    private func tick(_ ms: UInt64 = 30) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    func testPersistentCacheAndTimeout() async {
        let defaults = UserDefaults(suiteName: "AutoHDRTests.Cache.\(UUID())")!
        let file = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/AutoHDRTests/ytdlp-fixture.sh")
        let provider = YTDLPMetadataProvider(preferences: defaults, executableOverride: file,
                                             metadataTimeout: 0.2, fastPathEnabled: false)
        func lookup(_ provider: YTDLPMetadataProvider, _ id: String) async -> YouTubeMetadataResult {
            await withCheckedContinuation { continuation in
                provider.lookup(videoID: id) { continuation.resume(returning: $0) }
            }
        }
        let first = await lookup(provider, "HDRvideo001")
        XCTAssertEqual(first.state, .hdr)
        XCTAssertFalse(first.cacheHit)
        XCTAssertEqual(provider.diagnostics().metadataLaunchCount, 1)
        let freshProvider = YTDLPMetadataProvider(preferences: defaults, executableOverride: file,
                                                  metadataTimeout: 0.2, fastPathEnabled: false)
        let second = await lookup(freshProvider, "HDRvideo001")
        XCTAssertTrue(second.cacheHit)
        XCTAssertEqual(freshProvider.diagnostics().metadataLaunchCount, 0)
        let start = Date()
        let timeout = await lookup(provider, "SLOWvideo01")
        XCTAssertEqual(timeout.state, .unknown)
        XCTAssertTrue(timeout.failureReason?.contains("timeout") == true)
        XCTAssertTrue(Date().timeIntervalSince(start) < 3, "child process must not hold pipe open")
        print("CHECK persistent cache + metadata-only flags + timeout child cleanup")
    }

    func testLeavingWatchHasOneDeadlineDespiteRepeatedPolling() async {
        let (c, d, b, m) = system()
        b.emit(snapshot("HDRvideo001")); await tick()
        m.finish("HDRvideo001", .hdr); await tick()
        XCTAssertTrue(d.isExternalHDREnabled)
        b.emit(snapshot(nil))
        for _ in 0..<6 { await tick(30); b.emit(snapshot(nil)) }
        XCTAssertFalse(d.isExternalHDREnabled)
        XCTAssertEqual(d.changes, [true, false])
        withExtendedLifetime(c) {}
    }
    func testModeOffThenAutoRechecksSameVideo() async {
        let (c, d, b, m) = system()
        b.emit(snapshot("HDRvideo001")); await tick(); m.finish("HDRvideo001", .hdr); await tick()
        c.setMode(.off)
        XCTAssertFalse(d.isExternalHDREnabled)
        c.setMode(.auto)
        b.emit(snapshot("HDRvideo001")); await tick(); m.finish("HDRvideo001", .hdr); await tick()
        XCTAssertTrue(d.isExternalHDREnabled)
        XCTAssertEqual(m.lookups.count, 2)
    }
    func testManualOnToAutoSDRIsImmediateAfterMetadata() async {
        let (c, d, b, m) = system(.on)
        XCTAssertTrue(d.isExternalHDREnabled)
        c.setMode(.auto); b.emit(snapshot("SDRvideo001")); await tick()
        m.finish("SDRvideo001", .sdr); await tick()
        XCTAssertFalse(d.isExternalHDREnabled)
    }
    func testHDRToHDRKeepsOnAndDoesNotReload() async {
        let (c, d, b, m) = system()
        d.isExternalHDREnabled = true
        b.emit(snapshot("HDRvideo001")); await tick(); m.finish("HDRvideo001", .hdr); await tick()
        b.emit(snapshot("HDRvideo002")); await tick()
        XCTAssertTrue(d.isExternalHDREnabled)
        m.finish("HDRvideo002", .hdr); await tick(450)
        XCTAssertEqual(d.changes, [])
        XCTAssertEqual(b.reloads, [])
        withExtendedLifetime(c) {}
    }
    func testSDRGraceCancelledByNewHDR() async {
        let (c, d, b, m) = system()
        b.emit(snapshot("HDRvideo001")); await tick(); m.finish("HDRvideo001", .hdr); await tick()
        b.emit(snapshot("SDRvideo001")); await tick(); m.finish("SDRvideo001", .sdr); await tick()
        b.emit(snapshot("HDRvideo002")); await tick(); m.finish("HDRvideo002", .hdr); await tick(180)
        XCTAssertEqual(d.changes, [true])
        withExtendedLifetime(c) {}
    }
    func testUnknownKeepsStateThenTurnsOff() async {
        let (c, d, b, m) = system()
        d.isExternalHDREnabled = true
        b.emit(snapshot("BADvideo001")); await tick(); m.finish("BADvideo001", .unknown); await tick()
        XCTAssertTrue(d.isExternalHDREnabled)
        await tick(140)
        XCTAssertFalse(d.isExternalHDREnabled)
        XCTAssertTrue(c.diagnosticsText().contains("failure fixture"))
    }
    func testStaleMetadataCannotOverrideManualMode() async {
        let (c, d, b, m) = system()
        b.emit(snapshot("HDRvideo001")); await tick()
        c.setMode(.off); m.finish("HDRvideo001", .hdr); await tick()
        XCTAssertFalse(d.isExternalHDREnabled)
    }
    func testOnlyStableVideoIDQueriesAndParameterChangeDoesNot() async {
        let (c, _, b, m) = system()
        b.emit(snapshot("HDRvideo001"))
        b.emit(snapshot("HDRvideo002"))
        await tick()
        XCTAssertEqual(m.lookups, ["HDRvideo002"])
        m.finish("HDRvideo002", .hdr); await tick()
        b.emit(snapshot("HDRvideo002", suffix: "&t=10&list=abc")); await tick()
        XCTAssertEqual(m.lookups, ["HDRvideo002"])
        withExtendedLifetime(c) {}
    }
    func testSleepInvalidatesResultAndWakeRestartsMonitor() async {
        let (c, d, b, m) = system()
        b.emit(snapshot("HDRvideo001")); await tick()
        c.handleSleep(); m.finish("HDRvideo001", .hdr); await tick()
        XCTAssertFalse(d.isExternalHDREnabled)
        c.handleWake(); await tick(1600)
        XCTAssertEqual(b.starts, 2)
        b.emit(snapshot("HDRvideo001")); await tick(); m.finish("HDRvideo001", .hdr); await tick()
        XCTAssertTrue(d.isExternalHDREnabled)
    }
    func testReloadOnlyAfterVerifiedTransitionAndOnce() async {
        let (c, _, b, m) = system()
        b.emit(snapshot("HDRvideo001")); await tick(); m.finish("HDRvideo001", .hdr); await tick(400)
        XCTAssertEqual(b.reloads, ["HDRvideo001"])
        b.emit(snapshot("HDRvideo001")); await tick(400)
        XCTAssertEqual(b.reloads, ["HDRvideo001"])
        withExtendedLifetime(c) {}
    }
    func testHomeSearchShortsMiniPlayerAndSpoofedHostExcluded() {
        for url in ["https://www.youtube.com/", "https://www.youtube.com/results?search_query=HDR",
                    "https://www.youtube.com/shorts/HDRvideo001", "https://www.youtube.com/@channel",
                    "https://youtube.com.evil.test/watch?v=HDRvideo001", "https://www.youtube.com/watch?v=x",
                    "https://www.youtube.com/feed/subscriptions"] {
            let s = BrowserTabSnapshot(urlString: url, windowID: 1, tabID: 1, isBrowserAvailable: true, errorMessage: nil)
            XCTAssertNil(YouTubeWatchContext(snapshot: s), url)
        }
    }
    func testFormatClassificationExcludesAudioAndRecognizesAllHDRLabels() {
        for label in ["HDR10", "HDR10+", "HLG", "Dolby Vision", "HDR"] {
            XCTAssertNotNil(YTDLPMetadataProvider.hdrRange(in: ["vcodec": "vp9", "dynamic_range": label]))
            XCTAssertNil(YTDLPMetadataProvider.hdrRange(in: ["vcodec": "none", "dynamic_range": label]))
        }
        XCTAssertNil(YTDLPMetadataProvider.hdrRange(in: ["vcodec": "avc1", "dynamic_range": "SDR"]))
    }
    func testReloadScriptUsesActualTabIdentityAndReportsResult() {
        let context = YouTubeWatchContext(snapshot: snapshot("HDRvideo001"))!
        let script = YouTubeBrowserMonitor.reloadScript(context)
        XCTAssertTrue(script.contains("window id 10"))
        XCTAssertTrue(script.contains("tab id 20"))
        XCTAssertTrue(script.contains("HDRvideo001"))
        XCTAssertFalse(script.contains("windowID)"))
    }
    func testBackgroundChromeWatchUsesTrackedTabInsteadOfFrontWindow() {
        let script = YouTubeBrowserMonitor.readScript(.chrome, preferredWindowID: 10, preferredTabID: 20)
        XCTAssertTrue(script.contains("set w to window id 10"))
        XCTAssertTrue(script.contains("set t to tab id 20 of w"))
        XCTAssertTrue(script.contains("return \"inactive\""))
    }
    func testPWAFrontWindowMatchRejectsOrdinaryVisibleChromeWindow() {
        let script = YouTubeBrowserMonitor.readScript(.chromeYouTubeApp, preferredWindowID: 10,
                                                       preferredBounds: [0, 30, 1920, 990],
                                                       requirePreferredMatch: true)
        XCTAssertTrue(script.contains("visible of w is true"))
        XCTAssertTrue(script.contains("if w is missing value and true then return \"inactive\""))
    }
}
@MainActor
private final class FakeDisplay: HDRDisplayControlling {
    var isExternalHDRAvailable = true
    var isExternalHDREnabled = false
    var targetDisplayName = "Test External Display"
    var desiredHDRState: Bool?
    var lastErrorMessage: String?
    var changes: [Bool] = []
    func refresh() {}
    func cancelPending() {}
    func setHDR(_ enabled: Bool, completion: @escaping (Result<Bool, Error>) -> Void) {
        desiredHDRState = enabled
        let changed = enabled != isExternalHDREnabled
        if changed { changes.append(enabled) }
        isExternalHDREnabled = enabled
        completion(.success(changed))
    }
}
@MainActor
private final class FakeBrowser: YouTubeBrowserMonitoring {
    var handler: ((BrowserTabSnapshot) -> Void)?
    var starts = 0
    var reloads: [String] = []
    func start(onSnapshot: @escaping (BrowserTabSnapshot) -> Void) { handler = onSnapshot; starts += 1 }
    func stop() { handler = nil }
    func pollNow() {}
    func emit(_ snapshot: BrowserTabSnapshot) { handler?(snapshot) }
    func reloadWatchTab(context: YouTubeWatchContext, completion: @escaping (String?) -> Void) {
        reloads.append(context.videoID); completion(nil)
    }
}
private final class FakeMetadata: YouTubeMetadataProviding {
    var lookups: [String] = []
    var callbacks: [String: (YouTubeMetadataResult) -> Void] = [:]
    func warmup() {}
    func cancelAll() {}
    func lookup(videoID: String, completion: @escaping (YouTubeMetadataResult) -> Void) {
        lookups.append(videoID); callbacks[videoID] = completion
    }
    func finish(_ id: String, _ state: YouTubeMetadataState) {
        callbacks[id]?(YouTubeMetadataResult(videoID: id, state: state, dynamicRange: state == .hdr ? "HDR10" : nil,
            cacheHit: false, detail: "fixture", executableSource: "Test", executablePath: nil,
            executableVersion: nil, exitCode: 0, failureReason: state == .unknown ? "failure fixture" : nil))
    }
    func diagnostics() -> YTDLPDiagnostics {
        YTDLPDiagnostics(source: "Test", path: "", version: "", versionResult: "", metadataResult: "", metadataExitCode: 0)
    }
}

@MainActor private var failures = 0
@MainActor private func XCTAssertTrue(_ value: Bool, _ message: String = "") {
    if !value { failures += 1; print("ASSERTION FAILED true: \(message)") }
}
@MainActor private func XCTAssertFalse(_ value: Bool, _ message: String = "") { XCTAssertTrue(!value, message) }
@MainActor private func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { XCTAssertTrue(a == b, "\(a) != \(b)") }
@MainActor private func XCTAssertNil<T>(_ value: T?, _ message: String = "") { XCTAssertTrue(value == nil, message) }
@MainActor private func XCTAssertNotNil<T>(_ value: T?, _ message: String = "") { XCTAssertTrue(value != nil, message) }
