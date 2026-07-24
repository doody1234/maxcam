import Foundation
import SwiftUI
import Metal
import simd

/// Monitoring assists — the pro camera monitoring deck.
/// This is a SwiftUI overlay; the actual pixel-accurate assists (zebras, peaking, false
/// color) are rendered IN the Metal preview pipeline via the `monitoring assist` uniform
/// that toggles them on/off in the preview fragment shader.
public final class MonitoringOverlayView {

    /// State holder published to SwiftUI. Singleton so it survives view rebuilds.
    public final class Monitor: ObservableObject {
        @Published public var zebrasEnabled: Bool = true
        @Published public var zebraLower: Float = 70.0   // IRE
        @Published public var zebraUpper: Float = 100.0  // IRE
        @Published public var focusPeakingEnabled: Bool = true
        @Published public var focusPeakingThreshold: Float = 0.15
        @Published public var falseColorEnabled: Bool = false
        @Published public var histogramEnabled: Bool = true
        @Published public var waveformEnabled: Bool = false
        @Published public var vectorscopeEnabled: Bool = false
        @Published public var audioMetersEnabled: Bool = true
        @Published public var gridEnabled: Bool = true
        @Published public var framingGuide: FramingGuide = .none
        @Published public var histogramData: HistogramData = HistogramData()
        @Published public var audioLevels: (Float, Float) = (-160, -160)  // dBFS L, R

        public init() {}
    }

    public enum FramingGuide: String, CaseIterable, Identifiable, Sendable {
        case none, ruleOfThirds, center, square, goldenRatio, safeArea, actionSafe, titleSafe
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .none:          return "None"
            case .ruleOfThirds:  return "Rule of Thirds"
            case .center:        return "Center Cross"
            case .square:        return "Square"
            case .goldenRatio:   return "Golden Ratio"
            case .safeArea:      return "Safe Area"
            case .actionSafe:    return "Action Safe"
            case .titleSafe:     return "Title Safe"
            }
        }
    }

    public struct HistogramData {
        public var luma: [Float] = Array(repeating: 0, count: 256)
        public var red: [Float] = Array(repeating: 0, count: 256)
        public var green: [Float] = Array(repeating: 0, count: 256)
        public var blue: [Float] = Array(repeating: 0, count: 256)

        public var isEmpty: Bool {
            luma.allSatisfy { $0 == 0 }
        }

        public var maxLuma: Float {
            luma.max() ?? 1
        }
    }
}

// MARK: - SwiftUI overlay views

public struct MonitoringOverlay: View {
    @ObservedObject var monitor = CameraManager.shared.monitoring

    public init() {}

    public var body: some View {
        ZStack {
            // Grid / framing guide
            if monitor.gridEnabled {
                GridOverlay()
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
            }
            if monitor.framingGuide != .none {
                FramingGuideOverlay(guide: monitor.framingGuide)
                    .stroke(Color.yellow.opacity(0.6), lineWidth: 1.0)
            }
            // Histogram
            if monitor.histogramEnabled {
                VStack {
                    Spacer()
                    HistogramView(data: monitor.histogramData)
                        .frame(maxWidth: 200, maxHeight: 100)
                        .background(Color.black.opacity(0.6))
                        .padding(10)
                }
            }
            // Audio meters (bottom corners)
            if monitor.audioMetersEnabled {
                VStack {
                    Spacer()
                    HStack {
                        AudioMeterView(level: monitor.audioLevels.0, label: "L")
                        Spacer()
                        AudioMeterView(level: monitor.audioLevels.1, label: "R")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 60)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Grid

private struct GridOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let thirdW = rect.width / 3
        let thirdH = rect.height / 3
        // Vertical lines
        path.move(to: CGPoint(x: thirdW, y: 0))
        path.addLine(to: CGPoint(x: thirdW, y: rect.height))
        path.move(to: CGPoint(x: thirdW * 2, y: 0))
        path.addLine(to: CGPoint(x: thirdW * 2, y: rect.height))
        // Horizontal lines
        path.move(to: CGPoint(x: 0, y: thirdH))
        path.addLine(to: CGPoint(x: rect.width, y: thirdH))
        path.move(to: CGPoint(x: 0, y: thirdH * 2))
        path.addLine(to: CGPoint(x: rect.width, y: thirdH * 2))
        return path
    }
}

private struct FramingGuideOverlay: Shape {
    let guide: MonitoringOverlayView.FramingGuide

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch guide {
        case .none:
            break
        case .ruleOfThirds:
            return GridOverlay().path(in: rect)
        case .center:
            let cx = rect.midX, cy = rect.midY
            path.move(to: CGPoint(x: cx - 30, y: cy))
            path.addLine(to: CGPoint(x: cx + 30, y: cy))
            path.move(to: CGPoint(x: cx, y: cy - 30))
            path.addLine(to: CGPoint(x: cx, y: cy + 30))
        case .square:
            let side = min(rect.width, rect.height) * 0.8
            let originX = rect.midX - side / 2
            let originY = rect.midY - side / 2
            path.addRect(CGRect(x: originX, y: originY, width: side, height: side))
        case .goldenRatio:
            let phi = 1.618
            let w = rect.width / phi
            let h = rect.height / phi
            path.addRect(CGRect(x: rect.midX - w/2, y: rect.midY - h/2, width: w, height: h))
        case .safeArea:
            let inset = min(rect.width, rect.height) * 0.05
            path.addRect(rect.insetBy(dx: inset, dy: inset))
        case .actionSafe:
            let inset = min(rect.width, rect.height) * 0.07
            path.addRect(rect.insetBy(dx: inset, dy: inset))
        case .titleSafe:
            let inset = min(rect.width, rect.height) * 0.10
            path.addRect(rect.insetBy(dx: inset, dy: inset))
        }
        return path
    }
}

// MARK: - Histogram

private struct HistogramView: View {
    let data: MonitoringOverlayView.HistogramData

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // Luma
                histogramPath(values: data.luma, max: data.maxLuma, size: geo.size, color: .white.opacity(0.6))
                // RGB
                histogramPath(values: data.red,   max: data.maxLuma, size: geo.size, color: .red.opacity(0.5))
                histogramPath(values: data.green, max: data.maxLuma, size: geo.size, color: .green.opacity(0.5))
                histogramPath(values: data.blue,  max: data.maxLuma, size: geo.size, color: .blue.opacity(0.5))
            }
        }
    }

    private func histogramPath(values: [Float], max: Float, size: CGSize, color: Color) -> some View {
        Path { path in
            let stepX = size.width / CGFloat(values.count - 1)
            let safeMax = max <= 0 ? 1 : max
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * stepX
                let y = size.height - (CGFloat(v) / CGFloat(safeMax)) * size.height
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        .stroke(color, lineWidth: 0.7)
    }
}

// MARK: - Audio meter

private struct AudioMeterView: View {
    let level: Float
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            // Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.black.opacity(0.6))
                    Rectangle()
                        .fill(barColor)
                        .frame(width: geo.size.width * barFraction, height: geo.size.height)
                }
            }
            .frame(width: 80, height: 8)
            .cornerRadius(2)
            // dB readout
            Text(String(format: "%.0fdB", level))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var barFraction: CGFloat {
        let clamped = max(min(level, 0), -60)
        return CGFloat((clamped + 60) / 60)
    }

    private var barColor: Color {
        switch level {
        case 0...:        return .red
        case -6..<0:      return .yellow
        case -18 ..< -6:  return .green
        default:          return .green
        }
    }
}

// MARK: - Frame info overlay

public struct FrameInfoOverlay: View {
    @ObservedObject var cam = CameraManager.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            infoRow(label: "MODE", value: cam.captureMode.displayName)
            infoRow(label: "CODEC", value: cam.codec.displayName)
            infoRow(label: "LOG", value: cam.logCurve.displayName)
            infoRow(label: "RES", value: "\(Int(cam.currentResolution.width))×\(Int(cam.currentResolution.height))")
            infoRow(label: "FPS", value: String(format: "%.0f", cam.currentFrameRate))
            if cam.isCapturing {
                infoRow(label: "REC", value: formatDuration(cam.recordingDuration), color: .red)
            }
            if cam.droppedFrames > 0 {
                infoRow(label: "DROP", value: "\(cam.droppedFrames)", color: .orange)
            }
            // Thermal
            switch cam.thermalState {
            case .nominal:      infoRow(label: "TEMP", value: "OK", color: .green)
            case .fair:         infoRow(label: "TEMP", value: "FAIR", color: .yellow)
            case .serious:      infoRow(label: "TEMP", value: "SERIOUS", color: .orange)
            case .critical:     infoRow(label: "TEMP", value: "CRIT", color: .red)
            @unknown default:   infoRow(label: "TEMP", value: "?", color: .gray)
            }
            // Disk
            if cam.diskSpaceRemaining > 0 {
                infoRow(label: "DISK", value: formatBytes(cam.diskSpaceRemaining))
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.55))
        .cornerRadius(6)
    }

    private func infoRow(label: String, value: String, color: Color = .white) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        }
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        let hours = Int(s) / 3600
        let mins = (Int(s) % 3600) / 60
        let secs = Int(s) % 60
        return String(format: "%02d:%02d:%02d", hours, mins, secs)
    }

    private func formatBytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }
}
