import AppKit
import CoreVideo
import MetalKit
import XCTest
@testable import MovieFXPlayer

@MainActor
private final class CountingView: MTKView, PlayerSeekUpdating {
    func updateSeek(current: Double, duration: Double) {}
    var renderPassRequests = 0
    var availableRenderPasses = 0
    var suppressDrawable = false
    override var currentRenderPassDescriptor: MTLRenderPassDescriptor? {
        renderPassRequests += 1
        guard !suppressDrawable else { return nil }
        let descriptor = super.currentRenderPassDescriptor
        if descriptor != nil { availableRenderPasses += 1 }
        return descriptor
    }
}

final class RenderSchedulingTests: XCTestCase {
    @MainActor
    func testNativeSizeBypassesScalerAndResizeRestoresIt() throws {
        let renderer = try XCTUnwrap(MetalFXRenderer.make())
        let view = CountingView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), device: renderer.device)
        view.isPaused = true
        view.delegate = renderer
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary, &buffer), kCVReturnSuccess)
        let nextFrame = try XCTUnwrap(buffer)
        renderer.frameProvider = { nextFrame }
        var status = ""
        renderer.onStatusChange = { status = $0 }
        view.drawableSize = CGSize(width: 640, height: 360)
        view.draw()
        XCTAssertEqual(status, "640×360 → 640×360  direct")
        renderer.frameProvider = { nil }
        view.drawableSize = CGSize(width: 1280, height: 720)
        view.draw()
        XCTAssertEqual(status, "640×360 → 1280×720  MetalFX ×2.00")
        view.drawableSize = CGSize(width: 640, height: 360)
        view.draw()
        XCTAssertEqual(status, "640×360 → 640×360  direct")
        // A new decoded frame at the same size must stay on the direct path.
        renderer.frameProvider = { nextFrame }
        view.draw()
        XCTAssertEqual(status, "640×360 → 640×360  direct")
        XCTAssertEqual(view.availableRenderPasses, 4)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for video output", file: file, line: line)
    }

    @MainActor
    func testPausedPlaybackSleepsAndWakesForContentChanges() async throws {
        let renderer = try XCTUnwrap(MetalFXRenderer.make())
        let view = CountingView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), device: renderer.device)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        let player = VideoPlayer(renderer: renderer)
        defer { player.player?.pause(); view.isPaused = true; window.orderOut(nil) }
        player.attach(view: view)
        let provider = try XCTUnwrap(renderer.frameProvider)
        var callbacks = 0
        var frames = 0
        renderer.frameProvider = {
            callbacks += 1
            let frame = provider()
            if frame != nil { frames += 1 }
            return frame
        }
        player.open(url: try XCTUnwrap(Bundle.module.url(forResource: "testclip", withExtension: "mp4")))
        player.setVolume(0)
        try await waitUntil { frames >= 3 }
        // Exercise changes made through AVPlayer as well as our controls.
        player.player?.pause()
        try await Task.sleep(for: .milliseconds(700))
        let before = callbacks
        let draws = view.availableRenderPasses
        try await Task.sleep(for: .seconds(1))
        print("PAUSED_BENCHMARK callbacksPerSecond=\(callbacks - before)")
        XCTAssertLessThanOrEqual(callbacks - before, 2)
        XCTAssertTrue(view.isPaused)
        XCTAssertEqual(view.availableRenderPasses, draws)

        player.isMetalFXEnabled = false
        try await waitUntil { view.availableRenderPasses > draws }
        XCTAssertTrue(view.isPaused, "FX changes must draw without restarting continuous polling")
        let beforeResize = view.availableRenderPasses
        view.setFrameSize(NSSize(width: 800, height: 450))
        try await waitUntil { view.availableRenderPasses > beforeResize }

        var previous = frames
        player.seek(to: 1)
        try await waitUntil { frames > previous }
        try await waitUntil { view.isPaused }
        previous = frames
        player.stepFrame(1)
        try await waitUntil { frames > previous }
        try await waitUntil { view.isPaused }
        previous = frames
        player.player?.play()
        try await waitUntil { frames >= previous + 3 }
        XCTAssertFalse(view.isPaused)

        // Switching files must ignore notifications from the previous output.
        player.open(url: try XCTUnwrap(Bundle.module.url(forResource: "testclip", withExtension: "mp4")))
        previous = frames
        try await waitUntil { frames >= previous + 3 }
    }

    @MainActor
    func testIdleDisplayCallbacks() async throws {
        let renderer = try XCTUnwrap(MetalFXRenderer.make())
        let view = CountingView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), device: renderer.device)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { view.isPaused = true; window.orderOut(nil) }
        let player = VideoPlayer(renderer: renderer)
        player.attach(view: view)
        let provider = try XCTUnwrap(renderer.frameProvider)
        var callbacks = 0
        renderer.frameProvider = { callbacks += 1; return provider() }
        try await Task.sleep(for: .milliseconds(600))
        let before = callbacks
        try await Task.sleep(for: .seconds(1))
        print("IDLE_BENCHMARK callbacksPerSecond=\(callbacks - before)")
        XCTAssertLessThanOrEqual(callbacks - before, 2)
        withExtendedLifetime(player) {}
    }

    @MainActor
    func testRepeatedFrameBenchmark() throws {
        let renderer = try XCTUnwrap(MetalFXRenderer.make())
        let view = CountingView(frame: NSRect(x: 0, y: 0, width: 960, height: 540), device: renderer.device)
        view.isPaused = true
        view.delegate = renderer
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        window.orderFront(nil)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary, &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        var frameAvailable = true
        renderer.frameProvider = {
            defer { frameAvailable = false }
            return frameAvailable ? frame : nil
        }
        view.draw()
        XCTAssertEqual(view.availableRenderPasses, 1, "benchmark requires a real drawable")
        let start = CACurrentMediaTime()
        let requests = view.renderPassRequests
        for _ in 0..<120 {
            autoreleasepool { view.draw() }
        }
        let elapsed = CACurrentMediaTime() - start
        print("RENDER_BENCHMARK repeated=120 drawableRequests=\(view.renderPassRequests - requests) elapsedMs=\(elapsed * 1000)")
        XCTAssertEqual(view.renderPassRequests, requests, "unchanged frames must not acquire drawables")

        // 24 new frames per 120 display ticks: all new frames must draw,
        // while 80% of the previous render submissions are eliminated.
        let playbackRequests = view.renderPassRequests
        for tick in 0..<120 {
            frameAvailable = tick.isMultiple(of: 5)
            autoreleasepool { view.draw() }
        }
        XCTAssertEqual(view.renderPassRequests - playbackRequests, 24)

        func expectRedraw(_ change: () -> Void, file: StaticString = #filePath, line: UInt = #line) {
            let before = view.availableRenderPasses
            change()
            view.draw()
            XCTAssertEqual(view.availableRenderPasses, before + 1, file: file, line: line)
            view.draw()
            XCTAssertEqual(view.availableRenderPasses, before + 1, file: file, line: line)
        }

        expectRedraw { renderer.isMetalFXEnabled = false }
        expectRedraw { renderer.isMetalFXEnabled = true }
        expectRedraw { view.drawableSize = CGSize(width: 800, height: 600) }
        expectRedraw {
            renderer.displayGeometryProvider = {
                DisplayGeometry(sourceSize: CGSize(width: 640, height: 360),
                                transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0))
            }
        }

        // A temporarily unavailable drawable must not consume the new
        // frame: retry it even though the provider has no second buffer.
        view.suppressDrawable = true
        frameAvailable = true
        view.draw()
        expectRedraw { view.suppressDrawable = false }
        expectRedraw { renderer.reset() }
        withExtendedLifetime(window) {}
    }
}
