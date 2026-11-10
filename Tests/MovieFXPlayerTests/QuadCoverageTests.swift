import Metal
import XCTest
@testable import MovieFXPlayer

/// Regression test for the letterbox artifact: the draw pass must rasterize
/// only the aspect-fit quad. A scaled fullscreen triangle instead covers a
/// diagonal wedge beyond the quad, and clampToEdge smears edge pixels into
/// the letterbox instead of leaving it black.
final class QuadCoverageTests: XCTestCase {

    private let targetSize = 100

    func testQuadStaysInsideAspectFitRect() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let library = try device.makeLibrary(source: videoQuadShaderSource, options: nil)
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = library.makeFunction(name: "videoVS")
        pipelineDesc.fragmentFunction = library.makeFunction(name: "videoFS")
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDesc)

        // Solid white source, so any leaked coverage is unambiguous.
        let sourceDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false
        )
        sourceDesc.storageMode = .shared
        let source = try XCTUnwrap(device.makeTexture(descriptor: sourceDesc))
        source.replace(
            region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0,
            withBytes: [UInt8](repeating: 255, count: 16 * 16 * 4), bytesPerRow: 16 * 4
        )

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        let sampler = try XCTUnwrap(device.makeSamplerState(descriptor: samplerDesc))

        // (scale.x, scale.y, letterbox pixel that the wedge used to cover)
        //   letterbox: wide video in tall window -> upper-left wedge
        //   pillarbox: tall video in wide window -> lower-right wedge
        let cases: [(Float, Float, Int, Int)] = [
            (1.0, 0.5625, 5, 5),
            (0.5625, 1.0, 94, 94),
        ]
        for (sx, sy, px, py) in cases {
            let target = try render(
                device: device, pipeline: pipeline,
                source: source, sampler: sampler, scale: SIMD2(sx, sy)
            )
            var px3 = try pixel(target, x: px, y: py)
            XCTAssertEqual(px3, [0, 0, 0], "letterbox pixel (\(px),\(py)) leaked video content at scale (\(sx),\(sy))")

            px3 = try pixel(target, x: targetSize / 2, y: targetSize / 2)
            XCTAssertEqual(px3, [255, 255, 255], "quad center should sample the source")
        }
    }

    private func render(
        device: MTLDevice, pipeline: MTLRenderPipelineState,
        source: MTLTexture, sampler: MTLSamplerState, scale: SIMD2<Float>
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
        var uvLin = SIMD4<Float>(1, 0, 0, 1)
        var uvTrans = SIMD2<Float>.zero
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

    private func pixel(_ texture: MTLTexture, x: Int, y: Int) throws -> [UInt8] {
        var bgra = [UInt8](repeating: 0, count: 4)
        texture.getBytes(
            &bgra, bytesPerRow: targetSize * 4,
            from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0
        )
        return Array(bgra[0...2])
    }
}
