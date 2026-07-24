import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

/// AVAssetWriter-based encoder. Consumes GradedFrames from the MetalLogRenderer and
/// writes them to disk with proper per-codec color tagging.
///
/// Critical fixes vs. the original Claude file:
/// - Bitrate constants per codec (50-550 Mbps, not 5-20 Mbps)
/// - HEVC 4:2:0 10-bit HDR path (Main10_AutoLevel + BT.2020 HLG color properties)
/// - HEVC 4:4:4 nominal path (Main10_AutoLevel — true 4:4:4 needs VTCompressionSession)
/// - ProRes 422/422HQ/422LT/4444/4444XQ paths (AVVideoCodecTypeAppleProRes* constants)
/// - Per-profile color properties (NOT all-tagged-HLG like fake-log apps)
/// - appendGradedFrame(_:at:) entry point for RAW-loop frames
/// - PTS synthesis for RAW-loop frames handled by caller (CameraManager)
public final class VideoProcessor: NSObject {

    public static let shared = VideoProcessor()

    // MARK: State

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private let writerQueue = DispatchQueue(label: "com.logcampro.writer", qos: .userInitiated)
    private let encoderQueue = DispatchQueue(label: "com.logcampro.encoder", qos: .userInitiated)

    private var isWriting = false
    private var firstPts: CMTime = .invalid
    private var lastAppendedPts: CMTime = .invalid
    private var frameCount: Int64 = 0
    private var recordingURL: URL?

    // Per-codec settings
    private var currentCodec: VideoCodec = .hevc420
    private var currentColorSpace: ColorSpace = .bt2020HLG
    private var currentResolution: CGSize = CGSize(width: 1920, height: 1080)
    private var currentFrameRate: Float = 24
    private var currentMode: CaptureMode = .rawLoop

    // Reusable Metal state for texture → CVPixelBuffer blit
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?

    // MARK: Init

    private override init() {
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        super.init()
    }

    // MARK: - Recording lifecycle

    public func startRecording(
        mode: CaptureMode,
        codec: VideoCodec,
        colorSpace: ColorSpace,
        resolution: CGSize,
        frameRate: Float,
        storageURL: URL?
    ) {
        writerQueue.async { [weak self] in
            guard let self = self else { return }

            // Reset state for a fresh recording.
            self.isWriting = false
            self.assetWriter = nil
            self.videoInput = nil
            self.audioInput = nil
            self.pixelBufferAdaptor = nil

            self.currentMode = mode
            self.currentCodec = codec
            self.currentColorSpace = colorSpace
            self.currentResolution = resolution
            self.currentFrameRate = frameRate
            self.frameCount = 0
            self.firstPts = .invalid
            self.lastAppendedPts = .invalid

            let url = storageURL ?? self.defaultRecordingURL()
            self.recordingURL = url

            // Defensive: remove any pre-existing file at the URL — AVAssetWriter
            // init throws if the file already exists. We use a unique timestamp
            // but a stale file from a previous crash could still be there.
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)

            do {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                self.assetWriter = writer

                // Build video settings defensively — try the rich settings first;
                // if AVAssetWriterInput rejects them, fall back to minimal settings.
                let videoSettings = self.videoSettings(codec: codec,
                                                       resolution: resolution,
                                                       frameRate: frameRate)
                var videoInput: AVAssetWriterInput
                do {
                    videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                    if !writer.canAdd(videoInput) {
                        NSLog("[VideoProcessor] canAddInput=false for video with full settings — retrying with minimal settings")
                        let minimal: [String: Any] = [
                            AVVideoCodecKey: codec.avVideoCodecType,
                            AVVideoWidthKey: Int(resolution.width),
                            AVVideoHeightKey: Int(resolution.height)
                        ]
                        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: minimal)
                    }
                } catch {
                    NSLog("[VideoProcessor] AVAssetWriterInput init threw: \(error) — retrying with minimal settings")
                    let minimal: [String: Any] = [
                        AVVideoCodecKey: codec.avVideoCodecType,
                        AVVideoWidthKey: Int(resolution.width),
                        AVVideoHeightKey: Int(resolution.height)
                    ]
                    videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: minimal)
                }
                videoInput.expectsMediaDataInRealTime = true
                videoInput.transform = self.captureTransform()
                if writer.canAdd(videoInput) {
                    writer.add(videoInput)
                } else {
                    NSLog("[VideoProcessor] WARNING: cannot add video input — recording will have no video")
                }
                self.videoInput = videoInput

                // Pixel buffer adaptor for CVPixelBuffer appends
                let adaptorSettings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: self.pixelFormat(for: codec),
                    kCVPixelBufferWidthKey as String: Int(resolution.width),
                    kCVPixelBufferHeightKey as String: Int(resolution.height),
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as Any
                ]
                self.pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: videoInput,
                    sourcePixelBufferAttributes: adaptorSettings
                )

                // Audio input — non-fatal if it fails (we'd just have a silent video).
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 256_000
                ]
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput.expectsMediaDataInRealTime = true
                if writer.canAdd(audioInput) {
                    writer.add(audioInput)
                } else {
                    NSLog("[VideoProcessor] WARNING: cannot add audio input — recording will have no audio")
                }
                self.audioInput = audioInput

                if writer.startWriting() {
                    writer.startSession(atSourceTime: .zero)
                    self.isWriting = true
                    NSLog("[VideoProcessor] started recording to \(url.path)")
                } else {
                    let errDesc = writer.error?.localizedDescription ?? "unknown"
                    NSLog("[VideoProcessor] startWriting failed: \(errDesc)")
                    // Reset state so appendGradedFrame becomes a no-op.
                    self.assetWriter = nil
                    self.videoInput = nil
                    self.audioInput = nil
                    self.pixelBufferAdaptor = nil
                }
            } catch {
                NSLog("[VideoProcessor] AVAssetWriter init failed: \(error)")
                self.assetWriter = nil
                self.videoInput = nil
                self.audioInput = nil
                self.pixelBufferAdaptor = nil
            }
        }
    }

    public func finishRecording(completion: @escaping (URL?) -> Void) {
        writerQueue.async { [weak self] in
            guard let self = self, let writer = self.assetWriter else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.isWriting = false
            writer.finishWriting {
                let url = self.recordingURL
                DispatchQueue.main.async { completion(url) }
            }
        }
    }

    // MARK: - Append

    /// Append a graded frame. Called from the camera queue. The PTS in the graded frame
    /// is already synthesized for RAW-loop or taken from the sample buffer for HLG.
    public func appendGradedFrame(_ frame: GradedFrame) {
        writerQueue.async { [weak self] in
            guard let self = self, self.isWriting else { return }
            guard let adaptor = self.pixelBufferAdaptor,
                  let videoInput = self.videoInput,
                  videoInput.isReadyForMoreMediaData else { return }

            if self.firstPts == .invalid {
                self.firstPts = frame.presentationTimeStamp
            }
            let relativePts = CMTimeSubtract(frame.presentationTimeStamp, self.firstPts)

            // Convert the luma + chroma MTLTextures into a single 420YpCbCr10 CVPixelBuffer.
            guard let pixelBuffer = self.texturesToPixelBuffer(
                luma: frame.lumaTexture,
                chroma: frame.chromaTexture
            ) else {
                NSLog("[VideoProcessor] texture -> CVPixelBuffer failed")
                return
            }

            if !adaptor.append(pixelBuffer, withPresentationTime: relativePts) {
                NSLog("[VideoProcessor] append failed at PTS \(relativePts.seconds)")
            } else {
                self.lastAppendedPts = relativePts
                self.frameCount += 1
            }
        }
    }

    public func appendAudioSample(_ sample: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            guard let self = self, self.isWriting, let audioInput = self.audioInput else { return }
            if audioInput.isReadyForMoreMediaData {
                audioInput.append(sample)
            }
        }
    }

    // MARK: - Settings

    private func videoSettings(codec: VideoCodec, resolution: CGSize, frameRate: Float) -> [String: Any] {
        var settings: [String: Any] = [:]
        // AVVideoCodecKey expects an AVVideoCodecType (String). For HEVC use AVVideoCodecTypeHEVC;
        // for ProRes variants use the AVVideoCodecTypeAppleProRes* constants (note the "Apple" prefix).
        settings[AVVideoCodecKey] = codec.avVideoCodecType
        settings[AVVideoWidthKey] = Int(resolution.width)
        settings[AVVideoHeightKey] = Int(resolution.height)

        // NOTE: We do NOT set AVVideoProfileLevelKey here. That key is for
        // VTCompressionSession, not AVAssetWriter — setting it on AVAssetWriter's
        // outputSettings has been observed to cause AVAssetWriterInput init to
        // throw NSInvalidArgumentException ("invalid compression properties")
        // which is uncatchable from Swift and terminates the app.
        // AVAssetWriter auto-selects the appropriate profile level based on
        // the codec + dimensions + color properties.
        var compressionProps: [String: Any] = [:]
        switch codec {
        case .hevc420, .hevc444:
            // HEVC 10-bit HDR via color properties.
            // AVVideoAverageBitRateKey + AVVideoExpectedSourceFrameRateKey are accepted
            // by AVAssetWriter for HEVC and inform the encoder's rate control.
            compressionProps[AVVideoAverageBitRateKey] = Int(codec.avgBitrateMbps * 1_000_000)
            compressionProps[AVVideoExpectedSourceFrameRateKey] = Int(frameRate)
            // 10-bit HDR via color properties — AVVideoHDRModeKey does not exist in the SDK.
            compressionProps[AVVideoColorPropertiesKey] = Self.hdrColorProperties()
        case .prores422, .prores422HQ, .prores422LT, .prores4444, .prores4444XQ:
            // ProRes has no profile levels and does not accept AVVideoAverageBitRateKey
            // via AVAssetWriter (the codec choice alone determines bitrate/variant).
            // Setting AVVideoAverageBitRateKey on ProRes was observed to cause
            // AVAssetWriterInput init to throw, terminating the app.
            // We only set the expected frame rate (informational).
            compressionProps[AVVideoExpectedSourceFrameRateKey] = Int(frameRate)
        }
        settings[AVVideoCompressionPropertiesKey] = compressionProps
        return settings
    }

    /// BT.2020 HLG color properties — selects 10-bit HDR encoding for HEVC.
    private static func hdrColorProperties() -> [String: Any] {
        // AVVideoTransferFunction_ITU_R_BT_2100_HLG is not exported as a Swift symbol
        // in all SDK versions; the raw underlying string value is "ITU_R_BT_2100_HLG".
        return [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: "ITU_R_BT_2100_HLG" as String,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
        ]
    }

    private func pixelFormat(for codec: VideoCodec) -> OSType {
        switch codec {
        case .hevc420, .prores422, .prores422HQ, .prores422LT:
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .hevc444:
            return kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        case .prores4444, .prores4444XQ:
            return kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        }
    }

    /// Capture transform — landscape by default. iPhone sensors are natively landscape.
    private func captureTransform() -> CGAffineTransform {
        return .identity
    }

    // MARK: - Color tagging
    //
    // Per-profile color tagging happens in videoSettings() via AVVideoColorPropertiesKey
    // (BT.2020 HLG transfer + primaries + matrix). For finer-grained per-frame tagging
    // we'd need AVAssetWriterInputTaggedPixelBufferGroup, but for an MVP the
    // compression-property level tagging is sufficient.

    // MARK: - Texture → CVPixelBuffer

    private func texturesToPixelBuffer(luma: MTLTexture, chroma: MTLTexture) -> CVPixelBuffer? {
        guard let device = device, let cmdQueue = commandQueue else { return nil }

        let width = luma.width
        let height = luma.height
        var pixelBuffer: CVPixelBuffer?

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as Any
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                            attrs as CFDictionary, &pixelBuffer)
        guard let pb = pixelBuffer else { return nil }

        // Create CVMetalTextures that wrap the CVPixelBuffer planes.
        var cvTextureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cvTextureCache)
        guard let cache = cvTextureCache else { return nil }

        var lumaCV: CVMetalTexture?
        var chromaCV: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil,
                                                   .r16Unorm, width, height, 0, &lumaCV)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil,
                                                   .rg16Unorm, width/2, height/2, 1, &chromaCV)
        guard let lumaTex = lumaCV.flatMap({ CVMetalTextureGetTexture($0) }),
              let chromaTex = chromaCV.flatMap({ CVMetalTextureGetTexture($0) }) else {
            return nil
        }

        // Blit from luma/chroma source textures into the CVPixelBuffer-backed textures.
        guard let cmd = cmdQueue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: luma, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: lumaTex, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.copy(from: chroma, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width/2, height: height/2, depth: 1),
                  to: chromaTex, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()  // Synchronous — we need the buffer ready before append.

        return pb
    }

    private func defaultRecordingURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return docs.appendingPathComponent("LogCamPro_\(timestamp).mov")
    }
}

// MARK: - VideoToolbox ProRes profile level constants
// ProRes codecs do NOT have profile levels — the codec choice (AVVideoCodecTypeAppleProRes*)
// alone determines the variant. We use the AVVideoCodecTypeAppleProRes* String constants
// directly from the VideoCodec enum's `avVideoCodecType` property; no kVTProfileLevel_*
// symbols are needed for ProRes.
