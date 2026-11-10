import Metal
import MetalFX
import XCTest

/// Verifies the decode → texture → MetalFX Spatial → output pipeline
/// headlessly by running a real upscale pass on the GPU.
final class ScalerTests: XCTestCase {

    func testSpatialScalerProducesUpscaledOutput() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              MTLFXSpatialScalerDescriptor.supportsDevice(device)
        else {
            throw XCTSkip("MetalFX Spatial requires Apple silicon")
        }

        let inputW = 64, inputH = 64
        let outputW = 256, outputH = 256 // 4x upscale

        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputW
        descriptor.inputHeight = inputH
        descriptor.outputWidth = outputW
        descriptor.outputHeight = outputH
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual

        let scaler = try XCTUnwrap(
            descriptor.makeSpatialScaler(device: device),
            "MetalFX rejected the descriptor"
        )

        // Solid red input frame.
        let inputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: inputW, height: inputH, mipmapped: false
        )
        inputDesc.storageMode = .shared
        inputDesc.usage = scaler.colorTextureUsage
        let input = try XCTUnwrap(device.makeTexture(descriptor: inputDesc))
        var pixels = [UInt8](repeating: 0, count: inputW * inputH * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 255; pixels[i + 3] = 255
        }
        input.replace(
            region: MTLRegionMake2D(0, 0, inputW, inputH),
            mipmapLevel: 0, withBytes: pixels, bytesPerRow: inputW * 4
        )

        // Private MetalFX output texture with the usage bits it requests.
        let outputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: outputW, height: outputH, mipmapped: false
        )
        outputDesc.storageMode = .private
        outputDesc.usage = scaler.outputTextureUsage.union(.shaderRead)
        let output = try XCTUnwrap(device.makeTexture(descriptor: outputDesc))

        scaler.colorTexture = input
        scaler.outputTexture = output
        scaler.inputContentWidth = inputW
        scaler.inputContentHeight = inputH

        // Shared readback texture + blit copy of the private scaler output.
        let readDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: outputW, height: outputH, mipmapped: false
        )
        readDesc.storageMode = .shared
        readDesc.usage = .shaderRead
        let readable = try XCTUnwrap(device.makeTexture(descriptor: readDesc))

        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        scaler.encode(commandBuffer: commandBuffer)
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: output, to: readable)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        XCTAssertEqual(commandBuffer.status, .completed)
        var center = [UInt8](repeating: 0, count: 4)
        readable.getBytes(
            &center, bytesPerRow: outputW * 4,
            from: MTLRegionMake2D(outputW / 2, outputH / 2, 1, 1), mipmapLevel: 0
        )
        XCTAssertGreaterThan(center[2], 200, "upscaled center pixel should be red")
        XCTAssertLessThan(center[0], 40)
        XCTAssertLessThan(center[1], 40)
    }
}
