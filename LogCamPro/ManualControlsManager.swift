import AVFoundation
import Foundation

/// Wraps AVCaptureDevice manual control API. Mirrors Blackmagic Cam's controls.
///
/// Critical: every setter must lock the device before configuring. We use a dedicated
/// serial queue so device locks don't block the main thread.
public final class ManualControlsManager {

    private weak var device: AVCaptureDevice?
    private let queue = DispatchQueue(label: "com.logcampro.controls", qos: .userInitiated)

    public init() {}

    public func attach(to device: AVCaptureDevice?) {
        self.device = device
        queue.async {
            guard let device = device else { return }
            do {
                try device.lockForConfiguration()
                // Enable manual modes where supported.
                if device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                }
                if device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                }
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                }
                device.unlockForConfiguration()
            } catch {
                NSLog("[Controls] attach failed: \(error)")
            }
        }
    }

    // MARK: - ISO

    public func setISO(_ iso: Float) {
        queue.async { [weak self] in
            guard let self = self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                let clamped = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
                if device.exposureMode != .custom {
                    device.exposureMode = .custom
                }
                // ISO is set via setExposureModeCustom — `device.iso` is read-only.
                device.setExposureModeCustom(duration: device.exposureDuration,
                                             iso: clamped,
                                             completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                NSLog("[Controls] setISO failed: \(error)")
            }
        }
    }

    // MARK: - Shutter speed

    public func setShutter(_ duration: CMTime) {
        queue.async { [weak self] in
            guard let self = self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                let clamped = min(max(duration, device.activeFormat.minExposureDuration),
                                  device.activeFormat.maxExposureDuration)
                if device.exposureMode != .custom {
                    device.exposureMode = .custom
                }
                // Exposure duration is set via setExposureModeCustom — `device.exposureDuration` is read-only.
                device.setExposureModeCustom(duration: clamped,
                                             iso: device.iso,
                                             completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                NSLog("[Controls] setShutter failed: \(error)")
            }
        }
    }

    // MARK: - White balance

    public func setWhiteBalance(_ gains: AVCaptureDevice.WhiteBalanceGains) {
        queue.async { [weak self] in
            guard let self = self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                let r = min(max(gains.redGain, 1), 4)
                let g = min(max(gains.greenGain, 1), 4)
                let b = min(max(gains.blueGain, 1), 4)
                if device.whiteBalanceMode != .locked {
                    device.whiteBalanceMode = .locked
                }
                // WB gains are set via setWhiteBalanceModeLocked — `device.deviceWhiteBalanceGains` is read-only.
                let clampedGains = AVCaptureDevice.WhiteBalanceGains(redGain: r, greenGain: g, blueGain: b)
                device.setWhiteBalanceModeLocked(with: clampedGains, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                NSLog("[Controls] setWB failed: \(error)")
            }
        }
    }

    /// Convenience: set WB by color temperature (Kelvin).
    public func setWhiteBalance(kelvin: Float) {
        queue.async { [weak self] in
            guard let self = self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if device.whiteBalanceMode != .locked {
                    device.whiteBalanceMode = .locked
                }
                // AVCaptureDevice's chromaticity conversion API
                let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
                let gains = device.deviceWhiteBalanceGains(for: tempAndTint)
                let r = min(max(gains.redGain, 1), 4)
                let g = min(max(gains.greenGain, 1), 4)
                let b = min(max(gains.blueGain, 1), 4)
                let clampedGains = AVCaptureDevice.WhiteBalanceGains(redGain: r, greenGain: g, blueGain: b)
                device.setWhiteBalanceModeLocked(with: clampedGains, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                NSLog("[Controls] setWB kelvin failed: \(error)")
            }
        }
    }

    // MARK: - Focus

    public func setFocus(_ position: Float) {
        queue.async { [weak self] in
            guard let self = self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if device.focusMode != .locked {
                    device.focusMode = .locked
                }
                let clamped = min(max(position, 0), 1)
                // Lens position is set via setFocusModeLocked(lensPosition:completionHandler:) —
                // `device.lensPosition` is read-only.
                device.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                NSLog("[Controls] setFocus failed: \(error)")
            }
        }
    }

    /// Auto-focus on a specific point. Used when the user taps the preview.
    public func focusAtPoint(_ point: CGPoint) {
        queue.async { [weak self] in
            guard let self = self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                }
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                }
                if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                NSLog("[Controls] focusAtPoint failed: \(error)")
            }
        }
    }

    // MARK: - Exposure bias

    public func setExposureBias(_ bias: Float) {
        queue.async { [weak self] in
            guard let self = self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                let clamped = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
                device.setExposureTargetBias(clamped, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                NSLog("[Controls] setExposureBias failed: \(error)")
            }
        }
    }

    // MARK: - Zoom (lens zoom, not digital)

    public func setZoom(_ factor: Float) {
        queue.async { [weak self] in
            guard let self = self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                // videoZoomFactor is CGFloat; convert Float <-> CGFloat explicitly.
                let maxZoom = Float(device.maxAvailableVideoZoomFactor)
                let clamped = min(max(factor, 1), maxZoom)
                device.videoZoomFactor = CGFloat(clamped)
                device.unlockForConfiguration()
            } catch {
                NSLog("[Controls] setZoom failed: \(error)")
            }
        }
    }

    // MARK: - Frame rate

    public func setFrameRate(_ fps: Float) {
        queue.async { [weak self] in
            guard let self = self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(fps))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(fps))
                device.unlockForConfiguration()
            } catch {
                NSLog("[Controls] setFrameRate failed: \(error)")
            }
        }
    }

    // MARK: - Apply all (used at session start)

    public func applyAll(
        iso: Float?,
        shutter: CMTime?,
        whiteBalance: AVCaptureDevice.WhiteBalanceGains?,
        focus: Float?,
        bias: Float,
        zoom: Float
    ) {
        if let iso = iso { setISO(iso) }
        if let shutter = shutter { setShutter(shutter) }
        if let wb = whiteBalance { setWhiteBalance(wb) }
        if let focus = focus { setFocus(focus) }
        setExposureBias(bias)
        setZoom(zoom)
    }

    // MARK: - Query device capabilities

    public func deviceCapabilities() -> DeviceCapabilities? {
        guard let device = device else { return nil }
        return DeviceCapabilities(
            minISO: device.activeFormat.minISO,
            maxISO: device.activeFormat.maxISO,
            minExposureDuration: device.activeFormat.minExposureDuration,
            maxExposureDuration: device.activeFormat.maxExposureDuration,
            minExposureBias: device.minExposureTargetBias,
            maxExposureBias: device.maxExposureTargetBias,
            maxZoomFactor: Float(device.maxAvailableVideoZoomFactor),
            supportsFocus: device.isFocusModeSupported(.locked),
            supportsExposure: device.isExposureModeSupported(.locked),
            supportsWhiteBalance: device.isWhiteBalanceModeSupported(.locked)
        )
    }
}

public struct DeviceCapabilities {
    public let minISO: Float
    public let maxISO: Float
    public let minExposureDuration: CMTime
    public let maxExposureDuration: CMTime
    public let minExposureBias: Float
    public let maxExposureBias: Float
    public let maxZoomFactor: Float
    public let supportsFocus: Bool
    public let supportsExposure: Bool
    public let supportsWhiteBalance: Bool
}
