import AVFoundation
import Combine
import CoreMedia
import CoreMotion
import SwiftUI
import UIKit

// MARK: - Capture Mode

/// The two capture paths Log Cam Pro supports.
///
/// - `rawLoop`: The real "Log Cam" trick. AVCapturePhotoOutput is driven in a backpressured
///   RAW Bayer DNG loop, bypassing the ISP almost entirely. Each RAW frame is debayered,
///   reshaped to the chosen log curve in scene-linear, and encoded to HEVC/ProRes. This is
///   the only path that produces true scene-referred log with maximum dynamic range.
///
/// - `hlgBypass`: AVCaptureVideoDataOutput in 10-bit HLG (420YpCbCr10BiPlanarVideoRange).
///   This is the ISP-processed "fake log" path used by simpler apps — it doesn't reach as
///   deep into the shadows or highlights as RAW-loop, but it runs cooler, supports HFR
///   (60/120/240fps) and doesn't require per-frame debayer. It's the thermal/HFR fallback.
public enum CaptureMode: String, CaseIterable, Identifiable {
    case rawLoop
    case hlgBypass

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rawLoop:   return "RAW Loop"
        case .hlgBypass: return "HLG Bypass"
        }
    }

    public var explanation: String {
        switch self {
        case .rawLoop:
            return "Photo-output RAW Bayer loop. True scene-referred log. Max DR. ~30fps cap."
        case .hlgBypass:
            return "Video-output 10-bit HLG. ISP-processed log. HFR up to 240. Cool & safe."
        }
    }
}

// MARK: - Stop Reason

public enum CaptureStopReason {
    case user
    case background
    case thermalCritical
    case diskFull
    case error(Error)
}

// MARK: - Frame Delivered

/// A graded frame ready for both on-screen preview and AVAssetWriter append.
public struct GradedFrame {
    /// PTS in the asset writer's clock. For RAW-loop this is synthesized; for HLG it is
    /// taken directly from the sample buffer.
    public let presentationTimeStamp: CMTime
    /// Luminance Y plane (10-bit, video range, BT.2020) for AVAssetWriter input.
    public let lumaTexture: MTLTexture
    /// Chroma CbCr plane (10-bit, video range, BT.2020) for AVAssetWriter input.
    public let chromaTexture: MTLTexture
    /// Optional RGBA preview texture for the on-screen MetalKit view (already tonemapped).
    public let previewTexture: MTLTexture?
    /// Per-frame metadata for the UI (ISO/shutter/white balance reported by device).
    public let metadata: FrameMetadata
}

public struct FrameMetadata {
    public let iso: Float
    public let exposureDuration: CMTime
    public let whiteBalanceGains: AVCaptureDevice.WhiteBalanceGains
    public let lensPosition: Float
    public let exposureTargetBias: Float
    public let timestamp: CFTimeInterval
}

// MARK: - CameraManager

/// Singleton camera controller. Owns the AVCaptureSession, dispatches graded frames to
/// the VideoProcessor and to the preview renderer, and exposes manual control setters
/// that mirror Blackmagic Cam's behaviour.
public final class CameraManager: NSObject, ObservableObject {

    public static let shared = CameraManager()

    // MARK: Published state

    @Published public private(set) var captureMode: CaptureMode = .rawLoop
    @Published public private(set) var isCapturing: Bool = false
    @Published public private(set) var isSessionRunning: Bool = false
    @Published public private(set) var currentFrameRate: Float = 24
    @Published public private(set) var currentResolution: CGSize = CGSize(width: 1920, height: 1080)
    @Published public private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published public private(set) var lastError: String?
    @Published public private(set) var diskSpaceRemaining: Int64 = 0
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var droppedFrames: Int = 0

    // Manual control state
    @Published public var manualISO: Float? = nil
    @Published public var manualShutterDuration: CMTime? = nil
    @Published public var manualWhiteBalance: AVCaptureDevice.WhiteBalanceGains? = nil
    @Published public var manualFocusPosition: Float? = nil
    @Published public var exposureTargetBias: Float = 0.0
    @Published public var lensZoom: Float = 1.0

    // LUT + log curve
    @Published public var logCurve: LogCurve = .appleLog
    @Published public var activeLUT: LUTDescriptor? = nil
    @Published public var lutIntensity: Float = 1.0

    // Codec + container
    @Published public var codec: VideoCodec = .hevc420
    @Published public var colorSpace: ColorSpace = .bt2020HLG

    // MARK: Internal state

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.logcampro.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.logcampro.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.logcampro.audio", qos: .userInitiated)

    private var photoOutput: AVCapturePhotoOutput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?

    private(set) var currentDevice: AVCaptureDevice?
    private(set) var rawFormat: CMFormatDescription?
    private(set) var videoFormat: CMFormatDescription?

    public let rawLoop = RawFrameCaptureManager()
    public let controls = ManualControlsManager()
    public let monitoring = MonitoringOverlayView.Monitor()
    public let gyro = GyroflowRecorder()
    public let storage = StorageManager()
    public let lutManager = LUTManager()

    /// Frame sink called from the video/RAW queue. The VideoProcessor subscribes to this.
    public var frameSink: ((GradedFrame) -> Void)?
    /// Preview sink called from the video/RAW queue with the RGBA preview texture.
    public var previewSink: ((MTLTexture) -> Void)?

    private var frameCounter: Int64 = 0
    private let frameCounterLock = NSLock()
    private var recordingStartTime: CMTime = .invalid
    private var recordingTimer: Timer?

    private override init() {
        super.init()
        // CRITICAL: Wire up the frame sink so graded frames actually reach the
        // video encoder. Without this, recordings are empty (no frames appended
        // to AVAssetWriter). The previous version was missing this connection —
        // the user could press record, AVAssetWriter would open, but no frames
        // would ever arrive, so the resulting .mov was 0 frames.
        frameSink = { [weak self] graded in
            // Only append when actively recording — saves CPU otherwise.
            guard self?.isCapturing == true else { return }
            VideoProcessor.shared.appendGradedFrame(graded)
        }
        observeThermalState()
        observeAppLifecycle()
    }

    // MARK: - Session configuration

    public func configureSession(mode: CaptureMode, completion: @escaping (Result<Void, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            // CRITICAL: Request camera permission BEFORE configuring the session.
            // AVCaptureDeviceInput(device:) will return a non-functional input
            // (and canAddInput returns false) if permission hasn't been granted,
            // which means the user sees a UI but no camera — confusing. Worse,
            // on some iOS versions the implicit permission prompt triggered by
            // device input creation races with session.commitConfiguration() and
            // can crash. So we ask explicitly first.
            let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
            switch authStatus {
            case .authorized:
                break
            case .notDetermined:
                // Synchronously wait for the user's response. We're already on a
                // background queue, so blocking here is fine.
                let semaphore = DispatchSemaphore(value: 0)
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    semaphore.signal()
                }
                semaphore.wait()
                // Re-check after the prompt.
                if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                    DispatchQueue.main.async {
                        completion(.failure(CameraError.permissionDenied))
                    }
                    return
                }
            case .denied, .restricted:
                DispatchQueue.main.async {
                    completion(.failure(CameraError.permissionDenied))
                }
                return
            @unknown default:
                DispatchQueue.main.async {
                    completion(.failure(CameraError.permissionDenied))
                }
                return
            }

            do {
                try self._configureSessionSync(mode: mode)
                DispatchQueue.main.async {
                    self.captureMode = mode
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func _configureSessionSync(mode: CaptureMode) throws {
        session.beginConfiguration()
        // NOTE: controls.attach() and controls.applyAll() are called AFTER
        // commitConfiguration() below — not inside the begin/commit block.
        // Calling them inside caused a race where the controls queue would
        // lockForConfiguration() on the device while session.commitConfiguration()
        // was running on the session queue, leading to AVFoundation assertion
        // failures and crashes.

        // Tear down everything first.
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        photoOutput = nil
        videoOutput = nil
        audioOutput = nil

        // iPhone 12+ has a triple cam on Pro, dual on base. Always prefer the wide
        // (1x) lens for log — its sensor has the largest photo-site pitch.
        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            // commitConfiguration() runs in the defer — but we removed it because
            // we need to commit BEFORE controls.attach. Wrap the cleanup in a
            // try-catch friendly pattern: commit on the way out either way.
            session.commitConfiguration()
            throw CameraError.cameraNotFound
        }
        currentDevice = camera

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.inputNotSupported
        }
        session.addInput(input)

        // Audio input — shared between modes.
        if let mic = AVCaptureDevice.default(for: .audio) {
            do {
                let micInput = try AVCaptureDeviceInput(device: mic)
                if session.canAddInput(micInput) {
                    session.addInput(micInput)
                }
            } catch {
                NSLog("[CameraManager] mic input failed (non-fatal): \(error)")
            }
            let audioOut = AVCaptureAudioDataOutput()
            if session.canAddOutput(audioOut) {
                session.addOutput(audioOut)
                audioOut.setSampleBufferDelegate(self, queue: audioQueue)
                audioOutput = audioOut
            }
        }

        switch mode {
        case .rawLoop:
            let photo = AVCapturePhotoOutput()
            guard session.canAddOutput(photo) else {
                session.commitConfiguration()
                throw CameraError.outputNotSupported
            }
            session.addOutput(photo)
            photo.isHighResolutionCaptureEnabled = true
            photo.isLivePhotoCaptureEnabled = false
            photo.maxPhotoQualityPrioritization = .quality

            // Demand RAW Bayer DNG — the whole point of the loop.
            // `availableRawPhotoPixelFormatTypes` is a read-only property (array),
            // not a function — there is no `(for:)` variant.
            if photo.availableRawPhotoPixelFormatTypes.count > 0 {
                photo.isDualCameraDualPhotoDeliveryEnabled = false
            }
            photoOutput = photo
            // Note: actual RAW pixel format selection happens per-capture in
            // RawFrameCaptureManager.makeRawPhotoSettings() via AVCapturePhotoSettings.
            // We store the available RAW types here for diagnostics.
            // (We don't need a full CMFormatDescription — just the OSType is enough
            // for RawFrameCaptureManager to use when building AVCapturePhotoSettings.)
            if let firstRaw = photo.availableRawPhotoPixelFormatTypes.first {
                var desc: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    codecType: firstRaw,
                    width: 0, height: 0,
                    extensions: nil,
                    formatDescriptionOut: &desc
                )
                rawFormat = desc
            }

        case .hlgBypass:
            let video = AVCaptureVideoDataOutput()
            video.alwaysDiscardsLateVideoFrames = true
            video.setSampleBufferDelegate(self, queue: videoQueue)

            // Find the best 10-bit HLG format — 420YpCbCr10BiPlanarVideoRange.
            let targetPixel = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            let preferred = camera.formats.first { format in
                let pix = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return pix == targetPixel
                    && dims.width >= 1920
                    && format.supportedColorSpaces.contains(.HLG_BT2020)
            } ?? camera.formats.first { $0.supportedColorSpaces.contains(.HLG_BT2020) }

            if let preferred = preferred {
                do {
                    try camera.lockForConfiguration()
                    camera.activeFormat = preferred
                    camera.activeColorSpace = .HLG_BT2020
                    camera.unlockForConfiguration()
                } catch {
                    NSLog("[CameraManager] HLG format lock failed: \(error)")
                }
                videoFormat = preferred.formatDescription
            }

            guard session.canAddOutput(video) else {
                session.commitConfiguration()
                throw CameraError.outputNotSupported
            }
            session.addOutput(video)
            videoOutput = video
        }

        // Commit the session structure FIRST — before touching the device
        // via ManualControlsManager. This avoids a race between the controls
        // queue's device.lockForConfiguration() and the session queue's
        // commitConfiguration(), which previously caused intermittent
        // crashes on app launch.
        session.commitConfiguration()

        // Now that the session is committed and stable, apply manual control
        // defaults. These run async on the controls queue and are safe to
        // call here because the session is no longer mid-configuration.
        controls.attach(to: camera)
        controls.applyAll(
            iso: manualISO,
            shutter: manualShutterDuration,
            whiteBalance: manualWhiteBalance,
            focus: manualFocusPosition,
            bias: exposureTargetBias,
            zoom: lensZoom
        )
    }

    public func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async {
                self.isSessionRunning = self.session.isRunning
            }
            if self.captureMode == .rawLoop {
                // CRITICAL: Do NOT call rawLoop.startLoop() synchronously here.
                // session.startRunning() is asynchronous — it returns immediately
                // but the session takes 200-500ms to actually start. If we kick
                // the loop now, photoOutput.availableRawPhotoPixelFormatTypes will
                // be empty (AVFoundation hasn't negotiated with the sensor yet),
                // and AVCapturePhotoSettings init will throw NSInvalidArgumentException.
                //
                // The retry logic in RawFrameCaptureManager.kickLoop() will handle
                // the wait if we get here too early, but it's cleaner to give the
                // session a brief grace period before kicking. We use asyncAfter
                // here as a first line of defense; the retry loop in kickLoop is
                // the second.
                self.sessionQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self else { return }
                    guard self.captureMode == .rawLoop else { return }
                    self.rawLoop.startLoop(photoOutput: self.photoOutput,
                                           device: self.currentDevice,
                                           frameSink: { [weak self] frame in
                        self?.handleRawFrame(frame)
                    })
                }
            }
        }
    }

    public func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.rawLoop.stopLoop()
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isSessionRunning = false
            }
        }
    }

    // MARK: - Recording

    public func startRecording() {
        guard !isCapturing else { return }
        isCapturing = true
        droppedFrames = 0
        recordingDuration = 0
        recordingStartTime = CMClockGetHostTimeClock().time

        // Pre-generate a recording URL so VideoProcessor doesn't have to fall
        // back to its default. StorageManager.nextRecordingURL() also refreshes
        // the disk-space cache so the UI shows current free space.
        let recordingURL = storage.nextRecordingURL(extension: "mov")

        VideoProcessor.shared.startRecording(
            mode: captureMode,
            codec: codec,
            colorSpace: colorSpace,
            resolution: currentResolution,
            frameRate: currentFrameRate,
            storageURL: recordingURL
        )

        gyro.startRecording()
        startRecordingTimer()
    }

    public func stopCapture(reason: CaptureStopReason) {
        guard isCapturing else { return }
        isCapturing = false
        stopRecordingTimer()
        VideoProcessor.shared.finishRecording { [weak self] url in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.storage.didFinishRecording(at: url)
            }
        }
        gyro.stopRecording { [weak self] gcsvURL in
            self?.storage.didFinishGCSV(at: gcsvURL)
        }
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, self.isCapturing else { return }
            let now = CMClockGetHostTimeClock().time
            self.recordingDuration = CMTimeGetSeconds(CMTimeSubtract(now, self.recordingStartTime))
            self.diskSpaceRemaining = self.storage.remainingBytes
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - Frame handling

    /// A RAW frame arrived from the photo-output loop.
    private func handleRawFrame(_ raw: RawFrameCaptureManager.RawFrame) {
        // Synthetic PTS — photo output does not provide one.
        frameCounterLock.lock()
        frameCounter += 1
        let counter = frameCounter
        frameCounterLock.unlock()

        let fps = Double(currentFrameRate)
        let pts = CMTime(seconds: Double(counter) / fps, preferredTimescale: 600)
        MetalLogRenderer.shared.processRawFrame(raw, pts: pts, logCurve: logCurve, lut: activeLUT) { [weak self] graded in
            self?.frameSink?(graded)
            if let preview = graded.previewTexture {
                self?.previewSink?(preview)
            }
        }
    }

    /// An HLG video frame arrived from AVCaptureVideoDataOutput.
    private func handleHLGFrame(_ sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        MetalLogRenderer.shared.processHLGSample(sample, pts: pts, logCurve: logCurve, lut: activeLUT) { [weak self] graded in
            self?.frameSink?(graded)
            if let preview = graded.previewTexture {
                self?.previewSink?(preview)
            }
        }
    }

    // MARK: - Mode switch

    public func switchMode(to newMode: CaptureMode) {
        guard newMode != captureMode else { return }
        let wasRunning = isSessionRunning
        let wasRecording = isCapturing
        if wasRecording { stopCapture(reason: .user) }
        stopSession()
        configureSession(mode: newMode) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                if wasRunning { self.startSession() }
            case .failure(let err):
                self.lastError = err.localizedDescription
            }
        }
    }

    // MARK: - Thermal

    private func observeThermalState() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.thermalState = ProcessInfo.processInfo.thermalState
            if self.thermalState == .critical && self.isCapturing {
                self.stopCapture(reason: .thermalCritical)
            }
            // Auto-fallback: at .serious on RAW-loop, switch to HLG bypass.
            if self.thermalState == .serious && self.captureMode == .rawLoop {
                self.switchMode(to: .hlgBypass)
            }
        }
        thermalState = ProcessInfo.processInfo.thermalState
    }

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.stopCapture(reason: .background)
        }
    }

    // MARK: - Manual control setters

    public func setISO(_ iso: Float) {
        manualISO = iso
        controls.setISO(iso)
    }
    public func setShutter(_ duration: CMTime) {
        manualShutterDuration = duration
        controls.setShutter(duration)
    }
    public func setWhiteBalance(_ gains: AVCaptureDevice.WhiteBalanceGains) {
        manualWhiteBalance = gains
        controls.setWhiteBalance(gains)
    }
    public func setFocus(_ position: Float) {
        manualFocusPosition = position
        controls.setFocus(position)
    }
    public func setExposureBias(_ bias: Float) {
        exposureTargetBias = bias
        controls.setExposureBias(bias)
    }
    public func setZoom(_ factor: Float) {
        lensZoom = factor
        controls.setZoom(factor)
    }
    public func setFrameRate(_ fps: Float) {
        currentFrameRate = fps
        controls.setFrameRate(fps)
    }
    public func setResolution(_ size: CGSize) {
        currentResolution = size
        // Resolution changes require re-configuring active format.
        configureSession(mode: captureMode) { _ in }
    }
}

// MARK: - Sample buffer delegate (HLG path + audio)

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === videoOutput {
            handleHLGFrame(sampleBuffer)
        } else if output === audioOutput {
            VideoProcessor.shared.appendAudioSample(sampleBuffer)
        }
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.droppedFrames += 1
        }
    }
}

// MARK: - Errors

public enum CameraError: LocalizedError {
    case cameraNotFound
    case inputNotSupported
    case outputNotSupported
    case configurationFailed
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .cameraNotFound:       return "No suitable camera found (iPhone 12+ required)."
        case .inputNotSupported:    return "Cannot add camera input."
        case .outputNotSupported:   return "Cannot add capture output."
        case .configurationFailed:  return "Session configuration failed."
        case .permissionDenied:     return "Camera permission denied. Enable it in Settings → Privacy → Camera."
        }
    }
}

// MARK: - Codec + color space enums

public enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc420        // HEVC 4:2:0 10-bit
    case hevc444        // HEVC 4:4:4 10-bit (Main422444 AutoLevel)
    case prores422      // ProRes 422 Standard
    case prores422HQ    // ProRes 422 HQ
    case prores422LT    // ProRes 422 LT
    case prores4444     // ProRes 4444
    case prores4444XQ   // ProRes 4444 XQ

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hevc420:      return "HEVC 4:2:0 10-bit"
        case .hevc444:      return "HEVC 4:4:4 10-bit"
        case .prores422:    return "ProRes 422"
        case .prores422HQ:  return "ProRes 422 HQ"
        case .prores422LT:  return "ProRes 422 LT"
        case .prores4444:   return "ProRes 4444"
        case .prores4444XQ: return "ProRes 4444 XQ"
        }
    }

    public var fileExtension: String {
        switch self {
        case .hevc420, .hevc444: return "mov"
        case .prores422, .prores422HQ, .prores422LT, .prores4444, .prores4444XQ: return "mov"
        }
    }

    public var avgBitrateMbps: Float {
        switch self {
        case .hevc420:      return 100
        case .hevc444:      return 220
        case .prores422:    return 220
        case .prores422HQ:  return 330
        case .prores422LT:  return 155
        case .prores4444:   return 400
        case .prores4444XQ: return 550
        }
    }

    public var vtCodecType: CMVideoCodecType {
        switch self {
        case .hevc420, .hevc444: return kCMVideoCodecType_HEVC
        case .prores422:    return kCMVideoCodecType_AppleProRes422
        case .prores422HQ:  return kCMVideoCodecType_AppleProRes422HQ
        case .prores422LT:  return kCMVideoCodecType_AppleProRes422LT
        case .prores4444:   return kCMVideoCodecType_AppleProRes4444
        case .prores4444XQ: return kCMVideoCodecType_AppleProRes4444XQ
        }
    }

    /// AVVideoCodecType string for use with `AVVideoCodecKey` in AVAssetWriter settings.
    /// Note the "Apple" prefix on the ProRes constants — this is required; the unprefixed
    /// `AVVideoCodecTypeProRes422` does NOT exist in the SDK.
    public var avVideoCodecType: AVVideoCodecType {
        switch self {
        case .hevc420, .hevc444: return AVVideoCodecType.hevc
        case .prores422:    return AVVideoCodecType.proRes422
        case .prores422HQ:  return AVVideoCodecType.proRes422HQ
        case .prores422LT:  return AVVideoCodecType.proRes422LT
        case .prores4444:   return AVVideoCodecType.proRes4444
        // AVVideoCodecType.proRes4444XQ is not a static member in the iOS 17 SDK.
        // It IS a valid raw value, so we construct it via init(rawValue:).
        case .prores4444XQ: return AVVideoCodecType(rawValue: "proRes4444XQ")
        }
    }
}

public enum ColorSpace: String, CaseIterable, Identifiable {
    case bt2020HLG
    case bt2020PQ
    case bt709
    case appleWideGamut

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bt2020HLG:      return "BT.2020 HLG"
        case .bt2020PQ:       return "BT.2020 PQ"
        case .bt709:          return "Rec.709"
        case .appleWideGamut: return "Apple Wide Gamut"
        }
    }

    public var cfString: CFString {
        switch self {
        // kCMFormatDescriptionColorSpace_HLG / _BT2020_PQ do NOT exist in CoreMedia —
        // the color space is BT.2020 regardless of transfer function. HLG vs PQ is
        // a transfer-function distinction, not a color-space one.
        // kCMFormatDescriptionColorSpace_* C constants are not exported to Swift in the
        // iOS 17.5 SDK. The raw CFString values are stable public ABI (documented in
        // CMFormatDescription.h), so we use them directly.
        case .bt2020HLG:           return "ITU_R_2020" as CFString
        case .bt2020PQ:            return "ITU_R_2020" as CFString
        case .bt709:               return "ITU_R_709_2" as CFString
        case .appleWideGamut:      return "UseNative" as CFString
        }
    }

    public var transferFunction: CFString {
        switch self {
        // kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ_HLG does NOT exist —
        // HLG is its own transfer function constant: ITU_R_2100_HLG.
        case .bt2020HLG:      return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        case .bt2020PQ:       return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case .bt709:          return kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case .appleWideGamut: return kCMFormatDescriptionTransferFunction_sRGB
        }
    }
}
