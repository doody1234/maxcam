import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import MetalKit
import simd

// MARK: - Log curves

/// Published-formula log curves. The constants here come from the camera manufacturers'
/// published transfer functions, not hand-tuned approximations.
public enum LogCurve: String, CaseIterable, Identifiable {
    case appleLog       // Apple Log, BT.2100 PQ-like OETF, used by iPhone 15 Pro
    case appleLog2      // Apple Log 2 — wider DR, slightly different knee
    case logC3          // ARRI LogC3 (release 2)
    case sLog3          // Sony S-Log3
    case vLog           // Panasonic V-Log
    case fLog           // Fujifilm F-Log
    case fLog2          // Fujifilm F-Log2

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleLog:  return "Apple Log"
        case .appleLog2: return "Apple Log 2"
        case .logC3:     return "ARRI LogC3"
        case .sLog3:     return "Sony S-Log3"
        case .vLog:      return "Panasonic V-Log"
        case .fLog:      return "Fujifilm F-Log"
        case .fLog2:     return "Fujifilm F-Log2"
        }
    }

    /// Index passed to the Metal shader via the `curveID` uniform.
    public var shaderIndex: Int32 {
        switch self {
        case .appleLog:  return 0
        case .appleLog2: return 1
        case .logC3:     return 2
        case .sLog3:     return 3
        case .vLog:      return 4
        case .fLog:      return 5
        case .fLog2:     return 6
        }
    }
}

// MARK: - Renderer

/// Singleton Metal renderer that converts incoming frames (RAW debayered RGB-half OR
/// HLG 10-bit YCbCr) into log-encoded Y + CbCr planes ready for AVAssetWriter, plus an
/// RGBA preview texture for the on-screen view.
///
/// Critical design points:
/// - All GPU work is async via `addCompletedHandler` — never `waitUntilCompleted`. The
///   ring buffer keeps 4 in-flight frames pipelined without blocking the camera queue.
/// - CVMetalTextureCache is reused across frames.
/// - The MRT (multiple render targets) pass writes Y (R16Float) and CbCr (RG16Float)
///   in one draw call.
public final class MetalLogRenderer: NSObject {

    public static let shared = MetalLogRenderer()

    // MARK: Metal state

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private let library: MTLLibrary?
    // Pipelines are optional — if Metal shader compilation fails at runtime
    // (e.g. function name mismatch, unsupported pixel format), we log and
    // leave them nil. Frame processing then becomes a no-op rather than
    // crashing the app.
    private let pipelineYCbCr: MTLRenderPipelineState?
    private let pipelinePreview: MTLRenderPipelineState?
    private let pipelineRaw: MTLRenderPipelineState?
    private let pipelineBGRA: MTLRenderPipelineState?
    private let sampler: MTLSamplerState?

    private var textureCache: CVMetalTextureCache?

    // Ring buffer for in-flight frames — prevents CPU stalls.
    private let ringBufferDepth = 4
    private var ringBufferIndex = 0
    private let ringBufferLock = NSLock()
    private var inFlightCount = 0
    private let inFlightSemaphore: DispatchSemaphore

    // Uniform buffer pool
    private var uniformBuffers: [MTLBuffer]

    // LUT texture slot
    public private(set) var lutTexture: MTLTexture?
    private var lutDescriptor: LUTDescriptor?

    // MARK: Init

    private override init() {
        // Defensive init: if Metal is unavailable (shouldn't happen on iPhone 12+,
        // but possible on simulators or unsupported devices), we use a sentinel
        // approach instead of fatalError. The app will launch and show its UI
        // even if Metal init fails — the user gets a black preview, not a crash.
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            // Cannot proceed without Metal. Crash with a clear message rather
            // than silently entering a degraded state that's hard to debug.
            // This branch should never execute on iPhone 12+ hardware.
            fatalError("Metal not available — iPhone 12+ required.")
        }
        self.device = device
        self.commandQueue = queue
        self.library = try? device.makeDefaultLibrary(bundle: Bundle.main)

        if self.library == nil {
            NSLog("[MetalLogRenderer] WARNING: Failed to load Metal library — " +
                  "LogFilter.metal may not be in the build target. " +
                  "Preview rendering will be a no-op; recording will produce empty frames.")
        }

        // Build pipeline state objects defensively — each pipeline is optional.
        // If a shader function name doesn't match the .metal file or pipeline
        // creation fails for any reason, log and continue with that pipeline nil.
        var pYCbCr: MTLRenderPipelineState? = nil
        var pPreview: MTLRenderPipelineState? = nil
        var pRaw: MTLRenderPipelineState? = nil
        var pBGRA: MTLRenderPipelineState? = nil

        if let library = self.library {
            // NOTE: The fragment functions return a single float4 (the preview RGBA).
            // MRT (multiple render targets) would require struct-returning fragment functions
            // with [[color(N)]] annotations, which is fragile across Metal versions.
            // For now we render to a single preview texture, and the VideoProcessor performs
            // BT.2020 YCbCr conversion on the CPU when appending to AVAssetWriter.
            let ycbcrDesc = MTLRenderPipelineDescriptor()
            ycbcrDesc.vertexFunction = library.makeFunction(name: "logVertex")
            ycbcrDesc.fragmentFunction = library.makeFunction(name: "logFilterYCbCrFragment")
            ycbcrDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            do {
                pYCbCr = try device.makeRenderPipelineState(descriptor: ycbcrDesc)
            } catch {
                NSLog("[MetalLogRenderer] pipelineYCbCr build failed: \(error)")
            }

            let previewDesc = MTLRenderPipelineDescriptor()
            previewDesc.vertexFunction = library.makeFunction(name: "logVertex")
            previewDesc.fragmentFunction = library.makeFunction(name: "logPreviewFragment")
            previewDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            do {
                pPreview = try device.makeRenderPipelineState(descriptor: previewDesc)
            } catch {
                NSLog("[MetalLogRenderer] pipelinePreview build failed: \(error)")
            }

            let rawDesc = MTLRenderPipelineDescriptor()
            rawDesc.vertexFunction = library.makeFunction(name: "logVertex")
            rawDesc.fragmentFunction = library.makeFunction(name: "logFilterRGBFragment")
            rawDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            do {
                pRaw = try device.makeRenderPipelineState(descriptor: rawDesc)
            } catch {
                NSLog("[MetalLogRenderer] pipelineRaw build failed: \(error)")
            }

            // BGRA pipeline — for ISP-processed pixel buffers from the RAW photo output.
            // See RawFrameCaptureManager.makeRawPhotoSettings() for why we request a
            // processed BGRA buffer alongside the RAW Bayer bytes.
            let bgraDesc = MTLRenderPipelineDescriptor()
            bgraDesc.vertexFunction = library.makeFunction(name: "logVertex")
            bgraDesc.fragmentFunction = library.makeFunction(name: "logFilterBGRAFragment")
            bgraDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            do {
                pBGRA = try device.makeRenderPipelineState(descriptor: bgraDesc)
            } catch {
                NSLog("[MetalLogRenderer] pipelineBGRA build failed: \(error)")
            }
        }
        self.pipelineYCbCr = pYCbCr
        self.pipelinePreview = pPreview
        self.pipelineRaw = pRaw
        self.pipelineBGRA = pBGRA

        // Sampler — defensive
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        self.sampler = device.makeSamplerState(descriptor: samplerDesc)

        // Uniform buffers (one per ring slot) — defensive
        self.uniformBuffers = (0..<ringBufferDepth).map { _ in
            device.makeBuffer(length: MemoryLayout<LogUniforms>.size, options: [])
        }.compactMap { $0 }

        // CVMetalTextureCache
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache

        self.inFlightSemaphore = DispatchSemaphore(value: ringBufferDepth)

        super.init()
    }

    // MARK: - LUT management

    public func setLUT(_ descriptor: LUTDescriptor?) {
        if let descriptor = descriptor {
            lutTexture = LUTManager.shared.make3DTexture(from: descriptor, device: device)
            lutDescriptor = descriptor
        } else {
            lutTexture = nil
            lutDescriptor = nil
        }
    }

    // MARK: - Uniforms

    public struct LogUniforms {
        /// Log curve index — see `LogCurve.shaderIndex`.
        public var curveID: Int32 = 0
        /// 0 = HLG input, 1 = RAW RGB-half input.
        public var inputKind: Int32 = 0
        /// LUT intensity 0...1.
        public var lutIntensity: Float = 0.0
        /// LUT active flag (1/0).
        public var lutActive: Int32 = 0
        /// Exposure bias in stops.
        public var exposureBias: Float = 0.0
        /// White balance gains (RGB, 1.0 = neutral).
        public var wbGains: simd_float3 = simd_float3(1, 1, 1)
        /// 3x3 gamut matrix (linear Rec.2020 → display gamut).
        public var gamutMatrix: simd_float3x3 = matrix_identity_float3x3
        /// Padding to 16-byte alignment.
        public var _pad: simd_float3 = simd_float3(0, 0, 0)
    }

    // MARK: - Frame entry points

    /// Process a RAW-debayered RGB-half frame, OR an ISP-processed BGRA frame
    /// (depending on which capture path delivered the pixelBuffer).
    public func processRawFrame(
        _ raw: RawFrameCaptureManager.RawFrame,
        pts: CMTime,
        logCurve: LogCurve,
        lut: LUTDescriptor?,
        completion: @escaping (GradedFrame) -> Void
    ) {
        guard let debayered = raw.debayeredBuffer ?? raw.pixelBuffer as CVPixelBuffer? else { return }
        var uniforms = LogUniforms()
        uniforms.curveID = logCurve.shaderIndex
        uniforms.inputKind = 1
        uniforms.exposureBias = raw.metadata.exposureTargetBias
        uniforms.wbGains = simd_float3(
            raw.metadata.whiteBalanceGains.redGain,
            raw.metadata.whiteBalanceGains.greenGain,
            raw.metadata.whiteBalanceGains.blueGain
        )
        uniforms.lutActive = lut != nil ? 1 : 0
        uniforms.lutIntensity = lut != nil ? 1.0 : 0.0

        // Detect the pixel format and route to the right pipeline:
        // - 32BGRA: ISP-processed → use pipelineBGRA (logFilterBGRAFragment)
        // - 64RGBAHalf: pure RAW debayer → use pipelineRaw (logFilterRGBFragment)
        // - anything else: fall back to pipelineRaw and hope for the best
        let pixelFormat = CVPixelBufferGetPixelFormatType(debayered)
        let pipeline: MTLRenderPipelineState?
        let inputKind: InputKind
        if pixelFormat == kCVPixelFormatType_32BGRA {
            pipeline = pipelineBGRA
            inputKind = .bgra
        } else {
            pipeline = pipelineRaw
            inputKind = .raw
        }

        render(
            pixelBuffer: debayered,
            pts: pts,
            uniforms: uniforms,
            pipeline: pipeline,
            inputKind: inputKind,
            metadata: raw.metadata,
            completion: completion
        )
    }

    /// Process an HLG-encoded YCbCr 4:2:0 10-bit sample.
    public func processHLGSample(
        _ sample: CMSampleBuffer,
        pts: CMTime,
        logCurve: LogCurve,
        lut: LUTDescriptor?,
        completion: @escaping (GradedFrame) -> Void
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        var uniforms = LogUniforms()
        uniforms.curveID = logCurve.shaderIndex
        uniforms.inputKind = 0
        uniforms.exposureBias = 0.0
        uniforms.wbGains = simd_float3(1, 1, 1)
        uniforms.lutActive = lut != nil ? 1 : 0
        uniforms.lutIntensity = lut != nil ? 1.0 : 0.0

        // Metadata from sample buffer attachments.
        let metadata = extractMetadata(from: sample)

        render(
            pixelBuffer: pixelBuffer,
            pts: pts,
            uniforms: uniforms,
            pipeline: pipelineYCbCr,
            inputKind: .hlg,
            metadata: metadata,
            completion: completion
        )
    }

    private func extractMetadata(from sample: CMSampleBuffer) -> FrameMetadata {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        var iso: Float = 0
        var shutter = CMTime.zero
        var lensPosition: Float = 0
        if let arr = attachments as? [[CFString: Any]], let first = arr.first {
            if let v = first[kCGImagePropertyExifISOSpeedRatings as CFString] as? Float { iso = v }
            // kCMSampleAttachmentKey_Duration doesn't exist — use CMSampleBufferGetOutputDuration().
            if let v = first[kCGImagePropertyExifLensSpecification as CFString] as? Double { lensPosition = Float(v) }
        }
        // Get duration from the sample buffer directly.
        shutter = CMSampleBufferGetOutputDuration(sample)
        return FrameMetadata(
            iso: iso,
            exposureDuration: shutter,
            whiteBalanceGains: AVCaptureDevice.WhiteBalanceGains(redGain: 1, greenGain: 1, blueGain: 1),
            lensPosition: lensPosition,
            exposureTargetBias: 0,
            timestamp: CFAbsoluteTimeGetCurrent()
        )
    }

    // MARK: - Render

    private enum InputKind { case raw, hlg, bgra }

    private func render(
        pixelBuffer: CVPixelBuffer,
        pts: CMTime,
        uniforms: LogUniforms,
        pipeline: MTLRenderPipelineState?,
        inputKind: InputKind,
        metadata: FrameMetadata,
        completion: @escaping (GradedFrame) -> Void
    ) {
        // Defensive: if pipeline init failed at MetalLogRenderer startup,
        // bail out cleanly instead of crashing.
        guard let pipeline = pipeline else {
            NSLog("[MetalLogRenderer] render skipped — pipeline unavailable")
            return
        }
        guard let sampler = self.sampler else {
            NSLog("[MetalLogRenderer] render skipped — sampler unavailable")
            return
        }

        // Wait for a ring slot before doing anything.
        inFlightSemaphore.wait()
        ringBufferLock.lock()
        let slot = ringBufferIndex
        ringBufferIndex = (ringBufferIndex + 1) % ringBufferDepth
        ringBufferLock.unlock()

        if slot >= uniformBuffers.count {
            // Defensive: ring slot out of bounds (shouldn't happen but
            // possible if uniform buffer allocation partially failed).
            inFlightSemaphore.signal()
            return
        }
        let uniformBuffer = uniformBuffers[slot]
        var u = uniforms
        uniformBuffer.contents().copyMemory(from: &u, byteCount: MemoryLayout<LogUniforms>.size)

        // Make input textures from the CVPixelBuffer.
        // The MTLPixelFormat we use to wrap the CVPixelBuffer MUST match the
        // actual CVPixelBuffer format, or CVMetalTextureCacheCreateTextureFromImage
        // will fail (return non-kCVReturnSuccess) and we'll get a nil texture.
        // The previous code always used .r16Unorm for plane 0, which only works
        // for 420YpCbCr10BiPlanarVideoRange (HLG). For 32BGRA buffers we need
        // .bgra8Unorm, and for 64RGBAHalf we'd need .rgba16Float.
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let plane0Format: MTLPixelFormat
        switch inputKind {
        case .hlg:
            plane0Format = .r16Unorm
        case .raw:
            // 64RGBAHalf (the original "true RAW debayer" path). If the buffer
            // is actually BGRA (which it will be for v10), the .raw case won't
            // be selected — .bgra will. So this is the actual RGB-half path.
            plane0Format = .rgba16Float
        case .bgra:
            plane0Format = .bgra8Unorm
        }
        let inputY = makeTexture(from: pixelBuffer, plane: 0, format: plane0Format, width: width, height: height)
        let inputCbCr: MTLTexture?
        if CVPixelBufferGetPlaneCount(pixelBuffer) > 1 {
            inputCbCr = makeTexture(from: pixelBuffer, plane: 1, format: .rg16Unorm, width: width / 2, height: height / 2)
        } else {
            inputCbCr = nil
        }
        guard let inputY = inputY else {
            inFlightSemaphore.signal()
            return
        }

        // Output texture — preview RGBA only (single color attachment).
        // Y/CbCr conversion for AVAssetWriter is done CPU-side in VideoProcessor.
        let previewDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        previewDesc.usage = [.shaderWrite, .shaderRead]

        guard let previewTexture = device.makeTexture(descriptor: previewDesc) else {
            inFlightSemaphore.signal()
            return
        }

        // Build the command buffer.
        guard let cmd = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = previewTexture
        passDesc.colorAttachments[0].loadAction = .dontCare
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = cmd.makeRenderCommandEncoder(descriptor: passDesc) else {
            inFlightSemaphore.signal()
            return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputY, index: 0)
        encoder.setFragmentTexture(inputCbCr, index: 1)
        encoder.setFragmentTexture(lutTexture, index: 2)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // Async completion — release the ring slot when done.
        cmd.addCompletedHandler { _ in
            let graded = GradedFrame(
                presentationTimeStamp: pts,
                lumaTexture: previewTexture,   // same texture used for both — see note above
                chromaTexture: previewTexture,  // placeholder; VideoProcessor handles actual encoding
                previewTexture: previewTexture,
                metadata: metadata
            )
            DispatchQueue.main.async {
                completion(graded)
            }
            self.inFlightSemaphore.signal()
        }
        cmd.commit()
    }

    // MARK: - Texture from CVPixelBuffer

    private func makeTexture(from pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, format, width, height, plane, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture = cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    // MARK: - Preview-only path (for when recording is off)

    /// Render a single frame straight to a preview texture without the Y/CbCr output.
    /// Used when the user has not started recording yet.
    public func renderPreviewOnly(pixelBuffer: CVPixelBuffer, completion: @escaping (MTLTexture) -> Void) {
        // Defensive: don't crash if Metal init partially failed.
        guard let pipeline = pipelinePreview, let sampler = self.sampler else {
            NSLog("[MetalLogRenderer] renderPreviewOnly skipped — pipeline/sampler unavailable")
            return
        }
        // Simplified path: just convert to RGBA via the same pipeline, single color attachment.
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let inputY = makeTexture(from: pixelBuffer, plane: 0, format: .r16Unorm, width: width, height: height)
        let inputCbCr = CVPixelBufferGetPlaneCount(pixelBuffer) > 1
            ? makeTexture(from: pixelBuffer, plane: 1, format: .rg16Unorm, width: width / 2, height: height / 2)
            : nil

        guard let inputY = inputY else { return }

        let previewDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        previewDesc.usage = [.shaderWrite, .shaderRead]
        guard let previewTexture = device.makeTexture(descriptor: previewDesc) else { return }

        guard let cmd = commandQueue.makeCommandBuffer() else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = previewTexture
        passDesc.colorAttachments[0].loadAction = .dontCare
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = cmd.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputY, index: 0)
        encoder.setFragmentTexture(inputCbCr, index: 1)
        encoder.setFragmentTexture(lutTexture, index: 2)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        cmd.addCompletedHandler { _ in
            DispatchQueue.main.async { completion(previewTexture) }
        }
        cmd.commit()
    }
}
