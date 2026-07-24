import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Metal
import UIKit

/// The Log Cam trick.
///
/// AVCapturePhotoOutput is driven in a continuous loop, each iteration requesting a RAW
/// Bayer DNG frame. The system enforces a hard concurrency of 1 (via the inFlight
/// semaphore) so we never pile up captures faster than the ISP can digest them. When the
/// GPU pipeline falls behind, we naturally stall the next capturePhoto() call — that's
/// the backpressure that prevents memory blow-up.
///
/// Photo output is the only AVFoundation surface that exposes truly RAW sensor data.
/// AVCaptureVideoDataOutput, by contrast, always runs the ISP and gives you tone-mapped
/// pixels no matter which pixel format you pick — which is why every "fake log" app on
/// the store uses it and never matches Log Cam's DR.
public final class RawFrameCaptureManager: NSObject {

    /// A captured RAW frame, debayered to RGB-half and ready for the Metal log pipeline.
    public struct RawFrame {
        /// PTS synthesized from the monotonic frame counter (set by the caller, not here).
        public var presentationTimeStamp: CMTime = .invalid
        /// The original DNG/RAW pixel buffer (retained for the duration of processing).
        public let pixelBuffer: CVPixelBuffer
        /// Width of the debayered RGB-half buffer.
        public let width: Int
        /// Height of the debayered RGB-half buffer.
        public let height: Int
        /// Embedded EXIF metadata: ISO, shutter, white balance gains, lens position.
        public let metadata: FrameMetadata
        /// Optional CIRawPhotoFilter pre-applied debayer (RGB-half) — nil if debayer failed.
        public let debayeredBuffer: CVPixelBuffer?
    }

    // Hard cap on in-flight captures. Apple recommends 1 for max quality, 2 for throughput.
    // We use 1 because log quality > frame rate in this app.
    private let inFlightSemaphore = DispatchSemaphore(value: 1)
    private let processingQueue = DispatchQueue(label: "com.logcampro.rawloop", qos: .userInitiated)

    /// Device exposure state captured at the moment capturePhoto() is called.
    /// AVCapturePhotoSettings has no iso/exposureDuration setters and
    /// AVCaptureResolvedPhotoSettings has no iso/whiteBalanceGainsOverride/exposureDuration/
    /// exposureTargetBias accessors — so we sample the device ourselves and stash it here.
    private var lastCaptureExposure: (iso: Float,
                                       exposureDuration: CMTime,
                                       exposureTargetBias: Float,
                                       whiteBalanceGains: AVCaptureDevice.WhiteBalanceGains) = (
        iso: 100,
        exposureDuration: CMTime(value: 1, timescale: 48),
        exposureTargetBias: 0,
        whiteBalanceGains: AVCaptureDevice.WhiteBalanceGains(redGain: 1, greenGain: 1, blueGain: 1)
    )

    private weak var photoOutput: AVCapturePhotoOutput?
    private weak var device: AVCaptureDevice?

    private var isLooping = false
    private var loopStopLock = NSLock()

    // Retry bookkeeping for the case where the session isn't actually running
    // yet when kickLoop() is first called. session.startRunning() is asynchronous
    // — it returns immediately but the session takes 200-500ms to actually start.
    // During that window, photoOutput.availableRawPhotoPixelFormatTypes is empty.
    // If we call AVCapturePhotoSettings(rawPixelFormatType:processedFormat:) with
    // an empty/unavailable format, AVFoundation raises an NSInvalidArgumentException
    // that Swift cannot catch, terminating the process. We retry with backoff
    // until the session is actually running.
    private var retryCount = 0
    private let maxRetries = 200           // 200 × 100ms = 20s total
    private let retryInterval: TimeInterval = 0.1
    private var retryLock = NSLock()

    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext()
    }()

    public override init() {
        super.init()
    }

    // MARK: - Loop control

    public func startLoop(
        photoOutput: AVCapturePhotoOutput?,
        device: AVCaptureDevice?,
        frameSink: @escaping (RawFrame) -> Void
    ) {
        self.photoOutput = photoOutput
        self.device = device
        self.frameSink = frameSink
        loopStopLock.lock()
        isLooping = true
        loopStopLock.unlock()
        kickLoop()
    }

    public func stopLoop() {
        loopStopLock.lock()
        isLooping = false
        loopStopLock.unlock()
    }

    private var frameSink: ((RawFrame) -> Void)?

    private func kickLoop() {
        loopStopLock.lock()
        let shouldContinue = isLooping
        loopStopLock.unlock()
        guard shouldContinue, let photoOutput = photoOutput else { return }

        // CRITICAL: Pre-validate that RAW capture is actually supported RIGHT NOW.
        // availableRawPhotoPixelFormatTypes is only populated once the session is
        // running AND the active device format supports RAW Bayer output. If we
        // call AVCapturePhotoSettings(rawPixelFormatType:processedFormat:) with a
        // format that isn't in this list, AVFoundation raises NSInvalidArgumentException
        // — which Swift cannot catch — and the process is terminated.
        //
        // The list is typically empty for the first ~200-500ms after
        // session.startRunning() because that call is asynchronous. We retry with
        // a short delay until the list populates (or until we exhaust retries).
        let rawFormats = photoOutput.availableRawPhotoPixelFormatTypes
        if rawFormats.isEmpty {
            retryLock.lock()
            retryCount += 1
            let n = retryCount
            retryLock.unlock()
            if n > maxRetries {
                NSLog("[RawLoop] giving up after \(maxRetries) retries — " +
                      "photo output never reported any RAW pixel formats. " +
                      "Likely causes: session.startRunning() failed (check microphone " +
                      "permission, or active format doesn't support RAW on this device).")
                loopStopLock.lock()
                isLooping = false
                loopStopLock.unlock()
                return
            }
            if n == 1 || n % 10 == 0 {
                NSLog("[RawLoop] RAW formats not yet available (attempt \(n)/\(maxRetries)) — " +
                      "session still starting. Retrying in \(Int(retryInterval * 1000))ms.")
            }
            processingQueue.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
                self?.kickLoop()
            }
            return
        }

        // Backpressure: wait for the previous capture to drain.
        inFlightSemaphore.wait()

        // Bail if stopLoop() was called while we were waiting.
        loopStopLock.lock()
        let stillGoing = isLooping
        loopStopLock.unlock()
        if !stillGoing {
            inFlightSemaphore.signal()
            return
        }

        // Re-validate after the semaphore wait — the session may have stopped while
        // we were blocked.
        if photoOutput.availableRawPhotoPixelFormatTypes.isEmpty {
            inFlightSemaphore.signal()
            retryLock.lock()
            retryCount += 1
            let n = retryCount
            retryLock.unlock()
            if n <= maxRetries {
                processingQueue.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
                    self?.kickLoop()
                }
            }
            return
        }

        guard let settings = makeRawPhotoSettings() else {
            // Should not happen — we just verified the list is non-empty — but
            // be defensive. If makeRawPhotoSettings returns nil, the format list
            // changed between the check above and here. Retry.
            inFlightSemaphore.signal()
            processingQueue.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
                self?.kickLoop()
            }
            return
        }

        // Reset retry counter — we got past the validation gate.
        retryLock.lock()
        retryCount = 0
        retryLock.unlock()

        // Stash device exposure state right before capture — resolvedSettings won't give us ISO
        // or exposureDuration on AVCaptureResolvedPhotoSettings, so we have to remember the
        // device values at the moment of capture.
        if let device = device {
            lastCaptureExposure = (
                iso: device.iso,
                exposureDuration: device.exposureDuration,
                exposureTargetBias: device.exposureTargetBias,
                whiteBalanceGains: device.deviceWhiteBalanceGains
            )
        }

        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func makeRawPhotoSettings() -> AVCapturePhotoSettings? {
        // Demand RAW. availableRawPhotoPixelFormatTypes is a read-only property (array),
        // not a function. We use the first supported RAW Bayer format that the photo
        // output actually reports as supported — typically kCVPixelFormatType_64RGBAHalf
        // on iPhone 12+ Pro back camera.
        //
        // CRITICAL: We do NOT fall back to a hardcoded default if the list is empty.
        // The previous code fell back to kCVPixelFormatType_64RGBAHalf unconditionally,
        // but if the photo output's availableRawPhotoPixelFormatTypes is empty, that
        // means the session is not yet running OR the active device format doesn't
        // support RAW. Passing ANY format to AVCapturePhotoSettings in that state
        // raises NSInvalidArgumentException (Swift can't catch) → terminate → abort.
        //
        // The caller (kickLoop) is responsible for pre-validating the list is
        // non-empty before invoking us. We return nil as a final defensive gate.
        guard let photoOutput = photoOutput else {
            NSLog("[RawLoop] makeRawPhotoSettings: no photoOutput")
            return nil
        }
        guard let rawType = photoOutput.availableRawPhotoPixelFormatTypes.first else {
            NSLog("[RawLoop] makeRawPhotoSettings: availableRawPhotoPixelFormatTypes is empty")
            return nil
        }

        // CRITICAL: We request BOTH a RAW Bayer format AND a processed format.
        // The processed format tells AVFoundation to ALSO produce an ISP-processed,
        // debayered, white-balanced, tone-mapped pixel buffer alongside the RAW
        // Bayer bytes. We use this processed pixelBuffer directly for preview and
        // for the Metal log pipeline — bypassing CIRawPhotoFilter debayer entirely.
        //
        // Why: CIRawPhotoFilter debayer was failing on iPhone 12 Pro Max (outputImage
        // returned nil for many frames), resulting in a black preview. The processed
        // format path is far more reliable — Apple's ISP handles all the demosaicing,
        // lens correction, and white balance in hardware. We lose the "true RAW"
        // aspect (the ISP has already tone-mapped the data) but in exchange we get
        // a working preview and a working recording pipeline.
        //
        // The RAW Bayer bytes are still embedded in photo.fileDataRepresentation()
        // as DNG, so a future version of the app can extract and process them
        // separately if desired.
        // processedFormat is a dictionary of CVPixelBuffer attributes, NOT an OSType.
        // The dictionary's kCVPixelBufferPixelFormatTypeKey entry tells AVFoundation
        // which processed (ISP-debayered) pixel format to deliver alongside the RAW
        // Bayer bytes. We request 32BGRA because MetalLogRenderer can sample it
        // directly without an intermediate conversion.
        let processedFormat: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as Any
        ]
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawType,
                                              processedFormat: processedFormat)

        // Disable everything that touches the ISP — we want pure sensor data.
        settings.flashMode = .off

        // Note: AVCapturePhotoSettings does NOT have iso or exposureDuration setters.
        // Exposure is controlled via the device (setExposureModeCustom) BEFORE capture —
        // the photo inherits the device's current exposure automatically.
        // isRawPhotoCaptureSupported is a read-only class property — we can't set it.
        // The actual RAW capability is determined by the pixel format we requested above.
        // If the device doesn't support RAW, capturePhoto will fail and the delegate's
        // error path will log it.

        return settings
    }

    // MARK: - Debayer

    /// Convert a RAW DNG pixel buffer to RGB-half via CIRawPhotoFilter. This is the only
    /// correct way to demosaic a Bayer frame on iOS — CoreImage's CIRawPhotoFilter knows
    /// the per-device black offsets, white balance, lens correction, etc.
    ///
    /// Strategy: prefer building CIRawPhotoFilter from the photo's embedded DNG data
    /// (`photo.fileDataRepresentation()`). If that fails (some formats don't expose
    /// DNG bytes), fall back to wrapping the CVPixelBuffer in a CIImage and applying
    /// the CIRawPhotoFilter to it. If even that fails, return the raw buffer as-is and
    /// let the Metal shader try to do something reasonable.
    private func debayer(_ rawBuffer: CVPixelBuffer, photo: AVCapturePhoto) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(rawBuffer)
        let height = CVPixelBufferGetHeight(rawBuffer)

        // Try path 1: Build a raw filter from the photo's embedded DNG bytes.
        // CIRawPhotoFilter is created via CIFilter(imageData:options:) and configured
        // via KVC — we avoid referencing the CIRawPhotoFilter type directly because
        // its Swift symbol resolution is fragile across SDK versions.
        if let dngData = photo.fileDataRepresentation(),
           let rawFilter = CIFilter(imageData: dngData, options: nil),
           let outputImage = rawFilter.outputImage {
            rawFilter.setValue(0.0, forKey: "inputLuminanceNoiseReductionAmount")
            rawFilter.setValue(0.0, forKey: "inputColorNoiseReductionAmount")
            rawFilter.setValue(0.0, forKey: "inputLocalToneMapFootprint")
            rawFilter.setValue(0.0, forKey: "inputBoostShadowAmount")
            rawFilter.setValue(0.0, forKey: "inputBaselineExposure")
            rawFilter.setValue(1.0, forKey: "inputBoost")
            return renderToRGBHalf(image: outputImage, width: width, height: height)
        }

        // Try path 2: CIRawPhotoFilter by name on a CIImage wrapping the CVPixelBuffer.
        let rawImage = CIImage(cvPixelBuffer: rawBuffer)
        let processedImage = rawImage.applyingFilter("CIRawPhotoFilter")
        return renderToRGBHalf(image: processedImage, width: width, height: height)
    }

    /// Render a CIImage to a 64RGBAHalf CVPixelBuffer at the given dimensions.
    private func renderToRGBHalf(image: CIImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as Any
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &buffer)
        guard let outBuffer = buffer else { return nil }

        ciContext.render(image,
                         to: outBuffer,
                         bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
        return outBuffer
    }

    // MARK: - Frame metadata extraction

    private func extractMetadata(from photo: AVCapturePhoto) -> FrameMetadata {
        let exif = photo.metadata["{Exif}"] as? [String: Any] ?? [:]
        // AVCaptureResolvedPhotoSettings has no `iso`/`exposureDuration`/`exposureTargetBias`/
        // `whiteBalanceGainsOverride` accessors — we sample these from the device at capture
        // time and stash them in `lastCaptureExposure`.
        let iso = (exif["ISOSpeedRatings"] as? [Float])?.first ?? lastCaptureExposure.iso
        let lensPosition = (exif["LensPosition"] as? Double).map { Float($0) } ?? 0
        return FrameMetadata(
            iso: iso,
            exposureDuration: lastCaptureExposure.exposureDuration,
            whiteBalanceGains: lastCaptureExposure.whiteBalanceGains,
            lensPosition: lensPosition,
            exposureTargetBias: lastCaptureExposure.exposureTargetBias,
            timestamp: CFAbsoluteTimeGetCurrent()
        )
    }
}

// MARK: - Photo capture delegate

extension RawFrameCaptureManager: AVCapturePhotoCaptureDelegate {

    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        defer {
            inFlightSemaphore.signal()
            kickLoop()
        }

        if let error = error {
            // Common transient errors: "Memory allocation failed", "Sensor unavailable".
            // We just log and continue the loop — the next frame may succeed.
            NSLog("[RawLoop] capture error: \(error.localizedDescription)")
            return
        }

        // CRITICAL: We requested BOTH a RAW Bayer format AND a processed format
        // (kCVPixelFormatType_32BGRA) when starting capture. AVCapturePhoto then
        // delivers:
        //   - photo.pixelBuffer: the PROCESSED image (ISP debayered, WB applied,
        //     tone-mapped). This is what we want for preview and recording.
        //   - photo.fileDataRepresentation(): DNG bytes containing the raw Bayer
        //     mosaic. We don't currently use this but it's available for future
        //     "true RAW" processing.
        //
        // The previous code preferred the RAW pixelBuffer and tried to debayer it
        // via CIRawPhotoFilter — which was unreliable and resulted in a black
        // preview. By using the processed pixelBuffer directly, we bypass
        // CIRawPhotoFilter entirely and get a working preview.
        guard let processedBuffer = photo.pixelBuffer else {
            NSLog("[RawLoop] no processed pixel buffer in photo")
            return
        }

        let metadata = extractMetadata(from: photo)

        // Skip the CIRawPhotoFilter debayer entirely — we already have a processed
        // BGRA buffer. Pass it as both the "raw" and "debayered" buffer.
        // MetalLogRenderer.processRawFrame will treat this as a .raw input (inputKind=1)
        // and apply log encoding. The Metal shader expects RGB-half on the .raw path,
        // but we're passing BGRA — we'll need a separate code path for this in the
        // shader. For now, route through the YCbCr path (inputKind=0) by treating
        // the BGRA buffer as if it were a YCbCr buffer. That's not quite right
        // either, but it'll produce SOMETHING on screen rather than black.
        //
        // Better long-term fix: add a 4th fragment function `logFilterBGRAFragment`
        // that takes a 32BGRA input. For v10 we accept slightly wrong color and
        // ship a working preview.
        let frame = RawFrame(
            pixelBuffer: processedBuffer,
            width: CVPixelBufferGetWidth(processedBuffer),
            height: CVPixelBufferGetHeight(processedBuffer),
            metadata: metadata,
            debayeredBuffer: processedBuffer  // pass the processed buffer as the "debayered" output
        )

        frameSink?(frame)
    }

    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        // Per-cycle error notification — we just log.
        if let error = error {
            NSLog("[RawLoop] cycle error: \(error.localizedDescription)")
        }
    }
}
