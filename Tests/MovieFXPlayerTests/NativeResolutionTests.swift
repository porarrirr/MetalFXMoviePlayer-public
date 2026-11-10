import CoreGraphics
import Metal
import MetalFX
import XCTest
@testable import MovieFXPlayer

final class NativeResolutionTests: XCTestCase {
    func testOnlyActualUpscalingUsesMetalFX() {
        let input = CGSize(width: 1920, height: 1080)
        XCTAssertFalse(requiresSpatialUpscaling(input: input, output: input))
        XCTAssertFalse(requiresSpatialUpscaling(input: input, output: CGSize(width: 960, height: 540)))
        XCTAssertFalse(requiresSpatialUpscaling(input: input, output: CGSize(width: 3840, height: 540)))
        XCTAssertTrue(requiresSpatialUpscaling(input: input, output: CGSize(width: 3840, height: 2160)))
        XCTAssertTrue(requiresSpatialUpscaling(input: input, output: CGSize(width: 1920, height: 2160)))
        XCTAssertFalse(requiresSpatialUpscaling(input: .zero, output: input))
    }

    /// Headless GPU comparison: the previous equal-size MetalFX + quad path
    /// versus the new direct quad path. Excludes decode, presentation and CPU
    /// setup; alternates paths after warmup to reduce clock/thermal bias.
    func testNativeResolutionGPUBenchmark() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
            throw XCTSkip("MetalFX unavailable")
        }
        let width = 1920, height = 1080
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = width
        descriptor.inputHeight = height
        descriptor.outputWidth = width
        descriptor.outputHeight = height
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual
        let scaler = try XCTUnwrap(descriptor.makeSpatialScaler(device: device))
        func texture(usage: MTLTextureUsage, storage: MTLStorageMode) throws -> MTLTexture {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: width, height: height, mipmapped: false)
            desc.usage = usage
            desc.storageMode = storage
            return try XCTUnwrap(device.makeTexture(descriptor: desc))
        }
        let source = try texture(usage: scaler.colorTextureUsage.union(.shaderRead), storage: .shared)
        let pixels = [UInt8](repeating: 128, count: width * height * 4)
        source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                       withBytes: pixels, bytesPerRow: width * 4)
        let scaled = try texture(usage: scaler.outputTextureUsage.union(.shaderRead), storage: .private)
        let target = try texture(usage: [.renderTarget], storage: .private)
        scaler.colorTexture = source
        scaler.outputTexture = scaled
        scaler.inputContentWidth = width
        scaler.inputContentHeight = height
        let library = try device.makeLibrary(source: videoQuadShaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "videoVS")
        desc.fragmentFunction = library.makeFunction(name: "videoFS")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: desc)
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        let sampler = try XCTUnwrap(device.makeSamplerState(descriptor: samplerDesc))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        func sample(previousPath: Bool) throws -> Double {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let size = CGSize(width: width, height: height)
            let upscale = previousPath || requiresSpatialUpscaling(input: size, output: size)
            if upscale { scaler.encode(commandBuffer: buffer) }
            let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline)
            var scale = SIMD2<Float>(1, 1)
            var lin = SIMD4<Float>(1, 0, 0, 1)
            var trans = SIMD2<Float>.zero
            encoder.setVertexBytes(&scale, length: MemoryLayout.size(ofValue: scale), index: 0)
            encoder.setVertexBytes(&lin, length: MemoryLayout.size(ofValue: lin), index: 1)
            encoder.setVertexBytes(&trans, length: MemoryLayout.size(ofValue: trans), index: 2)
            encoder.setFragmentTexture(upscale ? scaled : source, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            XCTAssertEqual(buffer.status, .completed)
            return buffer.gpuEndTime - buffer.gpuStartTime
        }
        var previous: [Double] = [], current: [Double] = []
        for i in 0..<120 {
            let first = try sample(previousPath: i.isMultiple(of: 2))
            let second = try sample(previousPath: !i.isMultiple(of: 2))
            if i >= 20 {
                previous.append(i.isMultiple(of: 2) ? first : second)
                current.append(i.isMultiple(of: 2) ? second : first)
            }
        }
        let old = previous.sorted()[previous.count / 2]
        let new = current.sorted()[current.count / 2]
        XCTAssertGreaterThan(old, 0)
        XCTAssertGreaterThan(new, 0)
        print("NATIVE_GPU_BENCHMARK device=\(device.name) size=1920x1080 samples=100 previousMedianMs=\(old * 1000) currentMedianMs=\(new * 1000) reductionPercent=\((1 - new / old) * 100)")
    }
}
