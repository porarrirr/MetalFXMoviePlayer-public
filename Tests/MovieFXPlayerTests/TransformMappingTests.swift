import CoreGraphics
import Metal
import XCTest
@testable import MovieFXPlayer

/// Verifies the affine UV map that applies a track's preferredTransform at
/// draw time — both the math and the pixels the actual shader produces.
final class TransformMappingTests: XCTestCase {

    private let targetSize = 100

    func testIdentityTransformGivesIdentityUV() {
        let r = quadUVTransform(
            preSize: CGSize(width: 640, height: 480),
            transform: .identity
        )
        XCTAssertEqual(r.displayRect, CGRect(x: 0, y: 0, width: 640, height: 480))
        XCTAssertEqual(r.lin.x, 1, accuracy: 1e-6)
        XCTAssertEqual(r.lin.y, 0, accuracy: 1e-6)
        XCTAssertEqual(r.lin.z, 0, accuracy: 1e-6)
        XCTAssertEqual(r.lin.w, 1, accuracy: 1e-6)
        XCTAssertEqual(r.trans.x, 0, accuracy: 1e-6)
        XCTAssertEqual(r.trans.y, 0, accuracy: 1e-6)
    }

    func testRotation90MapsUVs() {
        // Landscape-coded track with a 90° display transform
        // (e.g. a portrait iPhone recording).
        let r = quadUVTransform(
            preSize: CGSize(width: 640, height: 480),
            transform: CGAffineTransform(rotationAngle: .pi / 2)
        )
        // Display space becomes portrait.
        XCTAssertEqual(r.displayRect.width, 480, accuracy: 1e-4)
        XCTAssertEqual(r.displayRect.height, 640, accuracy: 1e-4)
        // uv = (q.y, 1 - q.x): display top-left samples coded bottom-left.
        XCTAssertEqual(r.lin.x, 0, accuracy: 1e-5)   // a
        XCTAssertEqual(r.lin.y, -1, accuracy: 1e-5)  // b
        XCTAssertEqual(r.lin.z, 1, accuracy: 1e-5)   // c
        XCTAssertEqual(r.lin.w, 0, accuracy: 1e-5)   // d
        XCTAssertEqual(r.trans.x, 0, accuracy: 1e-5) // tx
        XCTAssertEqual(r.trans.y, 1, accuracy: 1e-5) // ty
    }

    func testScaledTextureSizeFollowsRotation() {
        // Identity: scaler output == fit rect.
        var tex = scaledTextureSize(
            fit: CGSize(width: 100, height: 200), lin: SIMD4(1, 0, 0, 1))
        XCTAssertEqual(tex.width, 100, accuracy: 1e-4)
        XCTAssertEqual(tex.height, 200, accuracy: 1e-4)

        // 90°: the scaler output must be transposed so the rotated draw
        // still samples ~1 texel per display pixel.
        tex = scaledTextureSize(
            fit: CGSize(width: 100, height: 200), lin: SIMD4(0, -1, 1, 0))
        XCTAssertEqual(tex.width, 200, accuracy: 1e-4)
        XCTAssertEqual(tex.height, 100, accuracy: 1e-4)
    }

    /// Renders the app's quad through the rotation UV map on the GPU and
    /// checks that corner texels land where the transform puts them.
    func testRotatedRenderProducesRotatedImage() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let library = try device.makeLibrary(source: videoQuadShaderSource, options: nil)
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = library.makeFunction(name: "videoVS")
        pipelineDesc.fragmentFunction = library.makeFunction(name: "videoFS")
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDesc)

        // 2x2 source with a distinct color per corner (BGRA):
        //   (0,0)=red  (1,0)=green
        //   (0,1)=blue (1,1)=white
        let sourceDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false
        )
        sourceDesc.storageMode = .shared
        let source = try XCTUnwrap(device.makeTexture(descriptor: sourceDesc))
        let pixels: [UInt8] = [
            0, 0, 255, 255,     0, 255, 0, 255,
            255, 0, 0, 255,     255, 255, 255, 255,
        ]
        source.replace(
            region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
            withBytes: pixels, bytesPerRow: 2 * 4
        )

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        let sampler = try XCTUnwrap(device.makeSamplerState(descriptor: samplerDesc))

        let uv = quadUVTransform(
            preSize: CGSize(width: 640, height: 480),
            transform: CGAffineTransform(rotationAngle: .pi / 2)
        )
        let target = try render(
            device: device, pipeline: pipeline, source: source, sampler: sampler,
            scale: SIMD2(1, 1), uvLin: uv.lin, uvTrans: uv.trans
        )

        // Rotated 90°: screen TL ← coded BL (blue), TR ← TL (red),
        // BR ← TR (green), BL ← BR (white).
        try assertPixel(target, x: 5, y: 5, equals: (255, 0, 0), "top-left")
        try assertPixel(target, x: 94, y: 5, equals: (0, 0, 255), "top-right")
        try assertPixel(target, x: 94, y: 94, equals: (0, 255, 0), "bottom-right")
        try assertPixel(target, x: 5, y: 94, equals: (255, 255, 255), "bottom-left")
    }

    // MARK: - Helpers

    private func render(
        device: MTLDevice, pipeline: MTLRenderPipelineState,
        source: MTLTexture, sampler: MTLSamplerState,
        scale: SIMD2<Float>, uvLin: SIMD4<Float>, uvTrans: SIMD2<Float>
    ) throws -> MTLTexture {
        let targetDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: targetSize, height: targetSize, mipmapped: false
        )
        targetDesc.storageMode = .shared
        targetDesc.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDesc))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store

        let commandBuffer = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        var scale = scale
        var uvLin = uvLin
        var uvTrans = uvTrans
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setVertexBytes(&uvLin, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        encoder.setVertexBytes(&uvTrans, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
        return target
    }

    private func assertPixel(
        _ texture: MTLTexture, x: Int, y: Int,
        equals expected: (UInt8, UInt8, UInt8), _ label: String
    ) throws {
        var bgra = [UInt8](repeating: 0, count: 4)
        texture.getBytes(
            &bgra, bytesPerRow: targetSize * 4,
            from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0
        )
        for (channel, (actual, want)) in zip(bgra.prefix(3), [expected.0, expected.1, expected.2]).enumerated() {
            XCTAssertEqual(
                Int(actual), Int(want), accuracy: 10,
                "\(label) channel \(channel) expected \(want), got \(actual)"
            )
        }
    }
}
