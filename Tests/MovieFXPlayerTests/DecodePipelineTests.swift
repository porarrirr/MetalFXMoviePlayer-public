import AVFoundation
import CoreVideo
import Metal
import QuartzCore
import XCTest

/// Exercises the same decode path the player uses:
/// AVPlayer + AVPlayerItemVideoOutput → CVPixelBuffer → CVMetalTextureCache → MTLTexture.
final class DecodePipelineTests: XCTestCase {

    func testDecodedFrameBecomesMetalTexture() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "testclip", withExtension: "mp4"),
            "test clip missing from test resources"
        )

        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()

        var pixelBuffer: CVPixelBuffer?
        for _ in 0..<50 {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                pixelBuffer = buffer
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        player.pause()

        let buffer = try XCTUnwrap(pixelBuffer, "no decoded frame after 5s")
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(buffer),
            OSType(kCVPixelFormatType_32BGRA)
        )

        var cache: CVMetalTextureCache?
        XCTAssertEqual(CVMetalTextureCacheCreate(nil, nil, device, nil, &cache), kCVReturnSuccess)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache!, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        XCTAssertNotNil(cvTexture.flatMap { CVMetalTextureGetTexture($0) })
    }
}
