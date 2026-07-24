import SwiftUI
import AVFoundation

// MARK: - Root view

public struct CameraRootView: View {
    @StateObject private var cam = CameraManager.shared
    @State private var showSettings: Bool = false

    public init() {}

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Preview
            PreviewViewRepresentable()
                .ignoresSafeArea()

            // Monitoring overlay — must NOT intercept touches (so HUD buttons work).
            MonitoringOverlay()
                .allowsHitTesting(false)

            // HUD
            VStack {
                TopHUD()
                Spacer()
                BottomHUD(showSettings: $showSettings)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Right-side manual controls
            HStack {
                Spacer()
                ManualControlsPanel()
                    .padding(.trailing, 8)
            }

            // Left-side info — must NOT intercept touches.
            HStack {
                FrameInfoOverlay()
                    .allowsHitTesting(false)
                    .padding(.leading, 8)
                Spacer()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            cam.configureSession(mode: cam.captureMode) { _ in
                cam.startSession()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(isPresented: $showSettings)
        }
    }
}

// MARK: - Top HUD

private struct TopHUD: View {
    @StateObject var cam = CameraManager.shared

    var body: some View {
        HStack(spacing: 12) {
            // Capture mode picker
            Picker("Mode", selection: Binding(get: { cam.captureMode },
                                              set: { cam.switchMode(to: $0) })) {
                ForEach(CaptureMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            // Codec picker
            Picker("Codec", selection: $cam.codec) {
                ForEach(VideoCodec.allCases) { codec in
                    Text(codecShort(codec)).tag(codec)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 110)

            // Resolution + FPS
            Menu {
                Button("1920×1080 @ 24") { cam.setFrameRate(24); cam.setResolution(CGSize(width: 1920, height: 1080)) }
                Button("1920×1080 @ 25") { cam.setFrameRate(25); cam.setResolution(CGSize(width: 1920, height: 1080)) }
                Button("1920×1080 @ 30") { cam.setFrameRate(30); cam.setResolution(CGSize(width: 1920, height: 1080)) }
                Button("3840×2160 @ 24") { cam.setFrameRate(24); cam.setResolution(CGSize(width: 3840, height: 2160)) }
                Button("3840×2160 @ 30") { cam.setFrameRate(30); cam.setResolution(CGSize(width: 3840, height: 2160)) }
            } label: {
                Label("\(Int(cam.currentResolution.width))p \(Int(cam.currentFrameRate))",
                      systemImage: "aspectratio")
            }

            Spacer()

            // Log curve
            Picker("Log", selection: $cam.logCurve) {
                ForEach(LogCurve.allCases) { c in
                    Text(c.displayName).tag(c)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 140)

            // Color space
            Picker("Color", selection: $cam.colorSpace) {
                ForEach(ColorSpace.allCases) { cs in
                    Text(csShort(cs)).tag(cs)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 100)

            // LUT picker
            Menu {
                Button("No LUT") { cam.activeLUT = nil }
                Divider()
                ForEach(LUTManager.shared.builtinLUTs()) { lut in
                    Button(lut.name) { cam.activeLUT = lut }
                }
            } label: {
                Label(cam.activeLUT?.name ?? "LUT", systemImage: "wand.and.stars")
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.45))
        .cornerRadius(10)
    }

    private func codecShort(_ c: VideoCodec) -> String {
        switch c {
        case .hevc420:      return "HEVC 4:2:0"
        case .hevc444:      return "HEVC 4:4:4"
        case .prores422:    return "ProRes 422"
        case .prores422HQ:  return "ProRes HQ"
        case .prores422LT:  return "ProRes LT"
        case .prores4444:   return "ProRes 4444"
        case .prores4444XQ: return "ProRes XQ"
        }
    }

    private func csShort(_ cs: ColorSpace) -> String {
        switch cs {
        case .bt2020HLG:           return "BT.2020 HLG"
        case .bt2020PQ:            return "BT.2020 PQ"
        case .bt709:               return "Rec.709"
        case .appleWideGamut:      return "AWG"
        }
    }
}

// MARK: - Bottom HUD

private struct BottomHUD: View {
    @StateObject var cam = CameraManager.shared
    @ObservedObject var monitor = CameraManager.shared.monitoring
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 16) {
            // Gallery
            Button(action: {
                NSLog("[BottomHUD] gallery tapped (not yet implemented)")
            }) {
                Image(systemName: "photo.on.rectangle")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)

            Spacer()

            // Monitoring toggles
            HStack(spacing: 8) {
                toggleButton("chart.bar", isOn: $monitor.histogramEnabled)
                toggleButton("waveform.path", isOn: $monitor.waveformEnabled)
                toggleButton("circle.grid.cross", isOn: $monitor.focusPeakingEnabled)
                toggleButton("rectangle.dashed", isOn: $monitor.zebrasEnabled)
                toggleButton("square.grid.3x3", isOn: $monitor.gridEnabled)
                toggleButton("paintpalette", isOn: $monitor.falseColorEnabled)
            }

            Spacer()

            // Record button
            Button(action: {
                NSLog("[BottomHUD] record button tapped, isCapturing=\(cam.isCapturing)")
                if cam.isCapturing {
                    cam.stopCapture(reason: .user)
                } else {
                    cam.startRecording()
                }
            }) {
                ZStack {
                    Circle()
                        .stroke(cam.isCapturing ? Color.red : Color.white, lineWidth: 4)
                        .frame(width: 70, height: 70)
                    if cam.isCapturing {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.red)
                            .frame(width: 24, height: 24)
                    } else {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 56, height: 56)
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(minWidth: 70, minHeight: 70)

            Spacer()

            // Gyro toggle (Gyroflow)
            Button(action: {
                NSLog("[BottomHUD] gyro tapped, isRecording=\(cam.gyro.isRecording)")
                if cam.gyro.isRecording {
                    cam.gyro.stopRecording { _ in }
                } else {
                    cam.gyro.setFrameRate(cam.currentFrameRate)
                    cam.gyro.setResolution(cam.currentResolution)
                    cam.gyro.startRecording()
                }
            }) {
                Image(systemName: cam.gyro.isRecording ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.title2)
                    .foregroundColor(cam.gyro.isRecording ? .green : .white)
                    .padding(10)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)

            // Settings
            Button(action: {
                NSLog("[BottomHUD] settings tapped")
                showSettings = true
            }) {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
        }
        .padding(8)
    }

    private func toggleButton(_ icon: String, isOn: Binding<Bool>) -> some View {
        Button(action: {
            NSLog("[BottomHUD] toggle \(icon) tapped, was \(isOn.wrappedValue)")
            isOn.wrappedValue.toggle()
        }) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(isOn.wrappedValue ? .yellow : .white)
                .padding(8)
                .background(Color.black.opacity(0.5))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
    }
}

// MARK: - Manual controls panel (with sliders)

private struct ManualControlsPanel: View {
    @StateObject var cam = CameraManager.shared

    var body: some View {
        VStack(spacing: 8) {
            // ISO slider
            SliderControl(
                label: "ISO",
                value: Binding(get: { cam.manualISO ?? 100 },
                               set: { cam.setISO($0) }),
                range: 25...6400,
                display: { String(format: "%.0f", $0) }
            )
            // Shutter slider (displayed as 1/N)
            SliderControl(
                label: "SHUT",
                value: Binding(get: { shutterDisplay(cam.manualShutterDuration) },
                               set: { cam.setShutter(shutterParse($0)) }),
                range: 1...8000,
                display: { String(format: "1/%.0f", $0) }
            )
            // WB slider
            SliderControl(
                label: "WB",
                value: Binding(get: { 5600 },
                               set: { cam.controls.setWhiteBalance(kelvin: $0) }),
                range: 2500...10000,
                display: { String(format: "%.0fK", $0) }
            )
            // Focus slider
            SliderControl(
                label: "FOCUS",
                value: Binding(get: { cam.manualFocusPosition ?? 0.5 },
                               set: { cam.setFocus($0) }),
                range: 0...1,
                display: { String(format: "%.2f", $0) }
            )
            // Zoom slider
            SliderControl(
                label: "ZOOM",
                value: Binding(get: { cam.lensZoom },
                               set: { cam.setZoom($0) }),
                range: 1...8,
                display: { String(format: "%.1fx", $0) }
            )
            // Exposure bias slider
            SliderControl(
                label: "EXP",
                value: Binding(get: { cam.exposureTargetBias },
                               set: { cam.setExposureBias($0) }),
                range: -3...3,
                display: { String(format: "%+.1fev", $0) }
            )
        }
        .padding(10)
        .background(Color.black.opacity(0.55))
        .cornerRadius(10)
    }

    private func shutterDisplay(_ duration: CMTime?) -> Float {
        guard let d = duration, d.isValid && d.seconds > 0 else { return 48 }
        return Float(1.0 / d.seconds)
    }

    private func shutterParse(_ deg: Float) -> CMTime {
        let secs = 1.0 / Double(deg)
        return CMTime(seconds: secs, preferredTimescale: 600)
    }
}

/// A horizontal slider control with label + live value readout.
/// Drag the slider to set the value directly; tap the – / + buttons
/// for fine-step adjustments.
private struct SliderControl: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let display: (Float) -> String

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                    .frame(width: 36, alignment: .leading)
                Text(display(value))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(minWidth: 56, alignment: .leading)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button(action: { step(-1) }) {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.gray.opacity(0.4))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Slider(
                    value: Binding(
                        get: { value },
                        set: { newValue in
                            // Snap to integer if range looks like ISO/WB/shutter,
                            // otherwise keep continuous. Simple heuristic: if
                            // upperBound - lowerBound > 100, snap.
                            let span = range.upperBound - range.lowerBound
                            let snapped = span > 100 ? Float(Int(newValue)) : newValue
                            value = min(max(snapped, range.lowerBound), range.upperBound)
                        }
                    ),
                    in: range
                )
                .accentColor(.yellow)

                Button(action: { step(1) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.gray.opacity(0.4))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func step(_ direction: Int) {
        let span = range.upperBound - range.lowerBound
        // Coarser step for wide ranges (ISO, WB, shutter), finer for narrow (focus, zoom, exp).
        let increment: Float
        if span > 4000 {
            increment = span / 20   // ISO: ~320 step, WB: ~375 step
        } else if span > 100 {
            increment = span / 30   // Shutter: ~270 step
        } else {
            increment = span / 50   // Focus/zoom/exp: ~0.06 step
        }
        let snapped: Float
        if span > 100 {
            // Round to nearest "nice" step value.
            let stepped = (value + Float(direction) * increment).rounded()
            snapped = stepped
        } else {
            snapped = value + Float(direction) * increment
        }
        value = min(max(snapped, range.lowerBound), range.upperBound)
    }
}

// MARK: - Settings sheet

private struct SettingsSheet: View {
    @StateObject var cam = CameraManager.shared
    @ObservedObject var monitor = CameraManager.shared.monitoring
    @Binding var isPresented: Bool
    @State private var showPermissionsInfo: Bool = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Recording")) {
                    Picker("Default codec", selection: $cam.codec) {
                        ForEach(VideoCodec.allCases) { codec in
                            Text(codec.displayName).tag(codec)
                        }
                    }
                    Picker("Default color space", selection: $cam.colorSpace) {
                        ForEach(ColorSpace.allCases) { cs in
                            Text(cs.displayName).tag(cs)
                        }
                    }
                    Picker("Default log curve", selection: $cam.logCurve) {
                        ForEach(LogCurve.allCases) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    HStack {
                        Text("Resolution")
                        Spacer()
                        Text("\(Int(cam.currentResolution.width))×\(Int(cam.currentResolution.height))")
                            .foregroundColor(.gray)
                    }
                    HStack {
                        Text("Frame rate")
                        Spacer()
                        Text("\(Int(cam.currentFrameRate)) fps")
                            .foregroundColor(.gray)
                    }
                }

                Section(header: Text("Monitoring")) {
                    Toggle("Histogram", isOn: $monitor.histogramEnabled)
                    Toggle("Waveform", isOn: $monitor.waveformEnabled)
                    Toggle("Focus peaking", isOn: $monitor.focusPeakingEnabled)
                    Toggle("Zebras", isOn: $monitor.zebrasEnabled)
                    Toggle("Grid", isOn: $monitor.gridEnabled)
                    Toggle("False color", isOn: $monitor.falseColorEnabled)
                    Toggle("Audio meters", isOn: $monitor.audioMetersEnabled)
                }

                Section(header: Text("Storage")) {
                    HStack {
                        Text("Free space")
                        Spacer()
                        Text(formatBytes(cam.diskSpaceRemaining))
                            .foregroundColor(.gray)
                    }
                    HStack {
                        Text("Recordings location")
                        Spacer()
                        Text("App Documents (Files app)")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                }

                Section(header: Text("Permissions")) {
                    Button("Open Settings app") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    Text("Camera, microphone, photo library, motion, and Bluetooth permissions can be reviewed in the iOS Settings app.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("App")
                        Spacer()
                        Text("LogCamPro")
                            .foregroundColor(.gray)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0 (build 1)")
                            .foregroundColor(.gray)
                    }
                    HStack {
                        Text("Target device")
                        Spacer()
                        Text(UIDevice.current.model)
                            .foregroundColor(.gray)
                    }
                    HStack {
                        Text("iOS")
                        Spacer()
                        Text(UIDevice.current.systemVersion)
                            .foregroundColor(.gray)
                    }
                    Text("Dual-mode pro camera: RAW Bayer DNG loop + HLG bypass. 7 published log curves, LUT import, Gyroflow GCSV export, multi-codec recording (HEVC + ProRes family).")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }

    private func formatBytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }
}

// MARK: - LUTManager built-in LUTs (used by top HUD)

extension LUTManager {
    public func builtinLUTs() -> [LUTDescriptor] {
        // Return a small set of built-in display LUTs for monitoring.
        return [
            makeBuiltinDisplayLUT(name: "Log → Display (Apple Log)", size: 33, logCurve: .appleLog),
            makeBuiltinDisplayLUT(name: "Log → Display (S-Log3)", size: 33, logCurve: .sLog3),
            makeBuiltinDisplayLUT(name: "Log → Display (LogC3)", size: 33, logCurve: .logC3),
            makeBuiltinDisplayLUT(name: "Log → Display (V-Log)", size: 33, logCurve: .vLog),
        ]
    }
}

// MARK: - Gyroflow recorder publishable state
//
// GyroflowRecorder is now an ObservableObject with @Published isRecording.
// CameraViewController observes it directly via `cam.gyro.isRecording` — no
// extension needed.
