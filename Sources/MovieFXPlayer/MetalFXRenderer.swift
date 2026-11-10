import CoreVideo
import Metal
#if canImport(MetalFX)
import MetalFX
#endif
import MetalKit

/// Lets a non-Sendable reference cross into a @Sendable completion handler.
/// Only used to extend the lifetime of a CVMetalTexture — retaining and
/// releasing CoreFoundation objects is thread-safe.
private struct UnsafeSendableRef<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// Runtime-compiled MSL keeps the executable self-contained for `swift run`.
// Module-level so the tests can render with the exact shader the app uses.
let videoQuadShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 pos [[position]];
    float2 uv;
};

/// scale: aspect-fit NDC scale of the display rect.
/// uvLin = (a, b, c, d), uvTrans = (tx, ty): affine map from normalized quad
/// coordinates (x right, y down, (0,0) = top-left of the drawn rect) to
/// source texture UV. Carries the track's preferredTransform so rotated or
/// flipped video is sampled correctly.
vertex VSOut videoVS(uint vid [[vertex_id]],
                     constant float2& scale [[buffer(0)]],
                     constant float4& uvLin [[buffer(1)]],
                     constant float2& uvTrans [[buffer(2)]]) {
    const float2 verts[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 v = verts[vid];
    VSOut out;
    out.pos = float4(v * scale, 0, 1);
    float2 q = float2(v.x * 0.5 + 0.5, 0.5 - v.y * 0.5);
    out.uv = float2(q.x * uvLin.x + q.y * uvLin.z + uvTrans.x,
                    q.x * uvLin.y + q.y * uvLin.w + uvTrans.y);
    return out;
}

fragment float4 videoFS(VSOut in [[stage_in]],
                        texture2d<float> tex [[texture(0)]],
                        sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.uv);
}
"""

/// How a decoded frame must be displayed. `sourceSize` is the size the
/// track's `preferredTransform` applies to (the track's presentation
/// dimensions — pixel aspect ratio and clean aperture included when the
/// format description carries them); `transform` is the transform itself
/// (rotation, flip, anamorphic scale).
struct DisplayGeometry: Sendable {
    var sourceSize: CGSize
    var transform: CGAffineTransform
    static let zero = DisplayGeometry(sourceSize: .zero, transform: .identity)
}

/// Affine UV mapping produced by `quadUVTransform`.
struct QuadUVTransform: Sendable {
    /// The rect (origin included — it can be negative) the video occupies in
    /// display space: `preferredTransform` applied to the source rect.
    var displayRect: CGRect
    /// (a, b, c, d) of the affine map from quad coordinates to texture UV.
    var lin: SIMD4<Float>
    /// (tx, ty) of the same map.
    var trans: SIMD2<Float>
    static let identity = QuadUVTransform(
        displayRect: .zero, lin: SIMD4(1, 0, 0, 1), trans: .zero)
}

/// Affine map from normalized quad coordinates (x right, y down, (0,0) =
/// top-left of the drawn rect) to source texture UV, honoring the track's
/// `preferredTransform`.
///
/// The transform maps the rect (0, 0, preSize) onto `displayRect` in display
/// space (both spaces are y-down). Display sampling applies the inverse:
/// each point of the display rect is mapped back through the inverse
/// transform into the [0,1] texture space of the coded frame.
func quadUVTransform(preSize: CGSize, transform: CGAffineTransform) -> QuadUVTransform {
    let det = transform.a * transform.d - transform.b * transform.c
    let t = det == 0 ? CGAffineTransform.identity : transform
    let rect = CGRect(origin: .zero, size: preSize).applying(t)
    guard preSize.width > 0, preSize.height > 0,
          rect.width > 0, rect.height > 0 else {
        return .identity
    }
    let m = CGAffineTransform(scaleX: rect.width, y: rect.height)
        .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        .concatenating(t.inverted())
        .concatenating(CGAffineTransform(scaleX: 1 / preSize.width, y: 1 / preSize.height))
    return QuadUVTransform(
        displayRect: rect,
        lin: SIMD4(Float(m.a), Float(m.b), Float(m.c), Float(m.d)),
        trans: SIMD2(Float(m.tx), Float(m.ty)))
}

/// Texture resolution the scaler must produce so the draw pass samples
/// ~1 texel per display pixel: the size of the axis-aligned bounding box of
/// the `fit` rect mapped through the UV matrix. Exact for axis-aligned
/// transforms (including 90° rotations, where it transposes the fit rect)
/// and slightly conservative — supersampled but still correct — for
/// arbitrary affine transforms.
func scaledTextureSize(fit: CGSize, lin: SIMD4<Float>) -> CGSize {
    CGSize(
        width: ceil(fit.width * CGFloat(abs(lin.x)) + fit.height * CGFloat(abs(lin.z))),
        height: ceil(fit.width * CGFloat(abs(lin.y)) + fit.height * CGFloat(abs(lin.w))))
}

/// Equal-size video already has one source texel per display pixel.
/// Only run MetalFX when at least one dimension actually grows.
func requiresSpatialUpscaling(input: CGSize, output: CGSize) -> Bool {
    input.width > 0 && input.height > 0 &&
        output.width >= input.width && output.height >= input.height && output != input
}

/// Renders decoded video frames through MetalFX Spatial upscaling.
///
/// Pipeline per frame:
///   CVPixelBuffer → MTLTexture (CVMetalTextureCache, zero copy)
///   → MTLFXSpatialScaler (upscale to the aspect-fit resolution)
///   → aspect-fit quad render pass → MTKView drawable (1:1 pixels)
///
/// The quad applies the track's preferredTransform to the sampled UVs, so
/// rotated/flipped/anamorphic video displays correctly on both the
/// MetalFX-upscaled path and the direct downscale path.
@MainActor
final class MetalFXRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    /// When false, no scaler is created and the draw pass samples the
    /// decoded texture directly; the status line reports `direct
    /// (MetalFX off)` for sizes that would otherwise upscale.
    var isMetalFXEnabled = true {
        didSet {
            guard isMetalFXEnabled != oldValue, lastSourceSize.width > 0 else { return }
            configureScaler(input: lastSourceSize, output: lastTargetSize)
            pendingScaleSource = sourceTexture
            needsRedraw = true
            onNeedsRedraw?()
        }
    }
    /// Provides a new decoded pixel buffer, or nil if the video clock
    /// has not advanced to a new frame since the last call.
    var frameProvider: (() -> CVPixelBuffer?)?
    /// The video's display geometry (source size + preferred transform).
    var displayGeometryProvider: (() -> DisplayGeometry)?
    var onStatusChange: ((String) -> Void)?
    /// Invalidates a sleeping view after an explicit content change.
    var onNeedsRedraw: (() -> Void)?

    // MARK: Frame state

    /// Latest CVMetalTexture wrapper. It is also captured by each command
    /// buffer's completion handler so the IOSurface backing stays alive
    /// until the GPU finishes sampling the texture it wraps.
    private var currentCVTexture: CVMetalTexture?
    /// Latest decoded frame as a Metal texture.
    private var sourceTexture: MTLTexture?
    /// Texture handed to the draw pass: the MetalFX output when upscaling,
    /// or the decoded texture itself when a downscale is required.
    private var drawTexture: MTLTexture?
    /// Set when a new frame was decoded but the scaler hasn't encoded yet.
    private var pendingScaleSource: MTLTexture?
    // The drawable retains the last presented image. Poll the video clock
    // on active vsyncs, but only acquire/present when content changes.
    private var needsRedraw = true
    private var lastDrawnSize = CGSize.zero
    private var lastDrawnGeometry = DisplayGeometry.zero

    // MARK: Scaler state

    // The MetalFX framework only ships in the device SDKs; on platforms
    // without it `make()` returns nil so this state is never reached.
    #if canImport(MetalFX)
    private var scaler: MTLFXSpatialScaler?
    private var scaledTexture: MTLTexture?
    private var scalerInputSize = CGSize.zero
    private var scalerOutputSize = CGSize.zero
    #endif
    private var scalerActive = false

    // Sizes for the status line, tracked independently of the scaler
    // so reporting stays correct when the direct (downscale) path is used.
    private var lastSourceSize = CGSize.zero
    private var lastTargetSize = CGSize.zero
    /// Whether the last configuration wanted an upscale; distinguishes the
    /// error status from the legitimate direct (downscale) path.
    private var lastCouldUpscale = false
    /// Config that previously failed scaler creation; prevents retrying
    /// (and re-logging the same error) on every subsequent frame.
    private var failedConfig: (input: CGSize, output: CGSize)?

    private var lastErrorReported: String?
    /// Last string handed to `onStatusChange`; suppresses identical updates
    /// that would otherwise fire on every decoded frame.
    private var lastReportedStatus: String?

    private init(device: MTLDevice, queue: MTLCommandQueue,
                 textureCache: CVMetalTextureCache,
                 pipeline: MTLRenderPipelineState, sampler: MTLSamplerState) {
        self.device = device
        self.queue = queue
        self.textureCache = textureCache
        self.pipeline = pipeline
        self.sampler = sampler
        super.init()
    }

    /// Creates a renderer, or nil when Metal or MetalFX Spatial is
    /// unavailable (e.g. a Mac without Apple silicon).
    static func make() -> MetalFXRenderer? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              spatialScalerSupported(on: device),
              let library = try? device.makeLibrary(source: videoQuadShaderSource, options: nil),
              let vertexFunction = library.makeFunction(name: "videoVS"),
              let fragmentFunction = library.makeFunction(name: "videoFS")
        else { return nil }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let textureCache = cache else { return nil }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        else { return nil }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        else { return nil }

        return MetalFXRenderer(device: device, queue: queue,
                               textureCache: textureCache,
                               pipeline: pipeline, sampler: sampler)
    }

    private static func spatialScalerSupported(on device: MTLDevice) -> Bool {
        #if canImport(MetalFX)
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
        #else
        return false
        #endif
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsRedraw = true
    }

    func draw(in view: MTKView) {
        let drawableSize = view.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        let geometry = displayGeometryProvider?() ?? .zero

        if let pixelBuffer = frameProvider?() {
            ingest(pixelBuffer)
        }

        guard needsRedraw || pendingScaleSource != nil ||
                drawableSize != lastDrawnSize ||
                geometry.sourceSize != lastDrawnGeometry.sourceSize ||
                geometry.transform != lastDrawnGeometry.transform else { return }

        // Drawable acquisition can block on the display. Defer it until we
        // know there is a new frame, geometry, size, or explicit invalidation.
        guard let renderPass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }

        let (displaySize, uvLin, uvTrans) = resolveUVTransform(
            geometry: geometry, source: sourceTexture)
        let fit = quadSize(drawableSize: drawableSize, displayAspect: displaySize)
        let outputSize = scaledTextureSize(fit: fit, lin: uvLin)

        // Configuration and status depend on dimensions, not frame content.
        if let source = sourceTexture {
            let inputSize = CGSize(width: source.width, height: source.height)
            let sizesChanged = outputSize != lastTargetSize || inputSize != lastSourceSize
            if sizesChanged {
                configureScaler(input: inputSize, output: outputSize)
                pendingScaleSource = source
            }
        }

        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let commandBuffer = queue.makeCommandBuffer() else { return }

        if let source = pendingScaleSource {
            #if canImport(MetalFX)
            if scalerActive, let scaler, let scaledTexture {
                scaler.colorTexture = source
                scaler.outputTexture = scaledTexture
                scaler.inputContentWidth = Int(scalerInputSize.width)
                scaler.inputContentHeight = Int(scalerInputSize.height)
                scaler.encode(commandBuffer: commandBuffer)
                drawTexture = scaledTexture
            } else {
                drawTexture = source
            }
            #else
            drawTexture = source
            #endif
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }
        if let texture = drawTexture {
            encoder.setRenderPipelineState(pipeline)
            var scale = SIMD2<Float>(
                Float(fit.width / drawableSize.width),
                Float(fit.height / drawableSize.height)
            )
            var lin = uvLin
            var trans = uvTrans
            encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            encoder.setVertexBytes(&lin, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            encoder.setVertexBytes(&trans, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()

        commandBuffer.present(drawable)
        if let cvTexture = currentCVTexture {
            // Releasing the CVMetalTexture would let the decode pool recycle
            // its IOSurface while the GPU is still sampling the texture it
            // wraps; hold it until this command buffer completes.
            let held = UnsafeSendableRef(cvTexture)
            commandBuffer.addCompletedHandler { _ in
                withExtendedLifetime(held.value) {}
            }
        }
        commandBuffer.commit()
        pendingScaleSource = nil
        needsRedraw = false
        lastDrawnSize = drawableSize
        lastDrawnGeometry = geometry
    }

    /// Clears decoded-frame state when a different video is opened so no
    /// stale texture is presented while the first frame is decoded.
    /// Scaler state is kept: it is reused if the new video matches.
    func reset() {
        needsRedraw = true
        currentCVTexture = nil
        sourceTexture = nil
        drawTexture = nil
        pendingScaleSource = nil
        scalerActive = false
        lastSourceSize = .zero
        lastTargetSize = .zero
        lastCouldUpscale = false
        lastErrorReported = nil
        lastReportedStatus = nil
        emitStatus("")
        onNeedsRedraw?()
    }

    // MARK: - Frame ingest

    private func ingest(_ pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture)
        else {
            reportError("CVMetalTextureCacheCreateTextureFromImage failed (\(status))")
            return
        }

        currentCVTexture = cvTexture
        sourceTexture = texture
        pendingScaleSource = texture
    }

    /// Resolves the display rect size and the affine UV map for this frame.
    /// While the track geometry is still loading, the texture's own size
    /// (or a neutral 16:9) supplies the aspect and the identity map.
    private func resolveUVTransform(geometry: DisplayGeometry, source: MTLTexture?)
        -> (display: CGSize, lin: SIMD4<Float>, trans: SIMD2<Float>) {
        var pre = geometry.sourceSize
        if (pre.width <= 0 || pre.height <= 0), let source {
            pre = CGSize(width: source.width, height: source.height)
        }
        let uv = quadUVTransform(preSize: pre, transform: geometry.transform)
        if uv.displayRect.width > 0, uv.displayRect.height > 0 {
            return (uv.displayRect.size, uv.lin, uv.trans)
        }
        let fallback = pre.width > 0 ? pre : CGSize(width: 16, height: 9)
        return (fallback, SIMD4(1, 0, 0, 1), .zero)
    }

    /// Aspect-fit rect (in drawable pixels) the video occupies inside the drawable.
    private func quadSize(drawableSize: CGSize, displayAspect: CGSize) -> CGSize {
        let video = displayAspect.width > 0 && displayAspect.height > 0 ? displayAspect : CGSize(width: 16, height: 9)
        let scale = min(drawableSize.width / video.width, drawableSize.height / video.height)
        return CGSize(
            width: (video.width * scale).rounded(.toNearestOrEven),
            height: (video.height * scale).rounded(.toNearestOrEven)
        )
    }

    // MARK: - MetalFX scaler

    private func configureScaler(input: CGSize, output: CGSize) {
        lastSourceSize = input
        lastTargetSize = output

        // MetalFX is an upscaler: every output dimension must be at least the
        // corresponding input dimension. When the window is smaller than the
        // video the draw pass samples the decoded texture directly (the
        // correct downscale path, not a workaround).
        // At equal size the source already supplies the required resolution.
        let canUpscale = requiresSpatialUpscaling(input: input, output: output)
        #if canImport(MetalFX)
        let alreadyFailed = failedConfig?.input == input && failedConfig?.output == output
        let needsNewScaler = isMetalFXEnabled && canUpscale && !alreadyFailed &&
            (input != scalerInputSize || output != scalerOutputSize || scaler == nil)

        if needsNewScaler {
            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.inputWidth = Int(input.width)
            descriptor.inputHeight = Int(input.height)
            descriptor.outputWidth = Int(output.width)
            descriptor.outputHeight = Int(output.height)
            descriptor.colorTextureFormat = .bgra8Unorm
            descriptor.outputTextureFormat = .bgra8Unorm
            descriptor.colorProcessingMode = .perceptual

            guard let newScaler = descriptor.makeSpatialScaler(device: device) else {
                scaler = nil
                scaledTexture = nil
                scalerActive = false
                failedConfig = (input, output)
                reportError("MetalFX scaler creation failed for \(Int(input.width))×\(Int(input.height)) → \(Int(output.width))×\(Int(output.height))")
                return
            }

            let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: Int(output.width),
                height: Int(output.height),
                mipmapped: false
            )
            texDesc.storageMode = .private
            texDesc.usage = newScaler.outputTextureUsage.union(.shaderRead)

            guard let tex = device.makeTexture(descriptor: texDesc) else {
                scaler = nil
                scaledTexture = nil
                scalerActive = false
                failedConfig = (input, output)
                reportError("Failed to allocate MetalFX output texture")
                return
            }

            scaler = newScaler
            scaledTexture = tex
            scalerInputSize = input
            scalerOutputSize = output
            lastErrorReported = nil
            failedConfig = nil
        }

        lastCouldUpscale = canUpscale
        // The scaler may only encode when it is configured for exactly this
        // input/output — a stale scaler left over from another config would
        // silently produce a wrongly sized intermediate.
        scalerActive = isMetalFXEnabled && canUpscale && scaler != nil &&
            scalerInputSize == input && scalerOutputSize == output
        #else
        lastCouldUpscale = canUpscale
        scalerActive = false
        #endif
        reportStatus()
    }

    private func reportStatus() {
        let input = lastSourceSize
        let target = lastTargetSize
        guard input.width > 0 else { return }
        let dims = "\(Int(input.width))×\(Int(input.height)) → \(Int(target.width))×\(Int(target.height))"
        if scalerActive {
            let factor = target.width / input.width
            emitStatus("\(dims)  MetalFX ×\(String(format: "%.2f", factor))")
        } else if lastCouldUpscale {
            if isMetalFXEnabled {
                emitStatus("ERROR: \(lastErrorReported ?? "MetalFX scaler unavailable")")
            } else {
                emitStatus("\(dims)  direct (MetalFX off)")
            }
        } else {
            emitStatus("\(dims)  direct")
        }
    }

    private func emitStatus(_ status: String) {
        guard status != lastReportedStatus else { return }
        lastReportedStatus = status
        onStatusChange?(status)
    }

    private func reportError(_ message: String) {
        lastErrorReported = message
        NSLog("MetalFXRenderer: %@", message)
        emitStatus("ERROR: \(message)")
    }
}
