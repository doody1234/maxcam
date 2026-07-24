# Log Cam Pro

A native iOS camera app that shoots RAW/log video on iPhone 12+ — the same capability
Log Cam and Blackmagic Cam provide, that the iPhone's stock Camera app does not.

## What this project is

- **Dual-mode architecture:**
  - **Mode A — RAW Loop**: Continuous AVCapturePhotoOutput RAW Bayer DNG loop, the actual
    Log Cam trick. Each RAW frame is debayered via `CIRawPhotoFilter`, reshaped through
    scene-linear to your chosen log curve (Apple Log, Apple Log 2, ARRI LogC3, Sony
    S-Log3, Panasonic V-Log, Fujifilm F-Log/F-Log2), and encoded to HEVC or ProRes.
    This is the only path that produces true scene-referred log with maximum DR.
  - **Mode B — HLG Bypass**: AVCaptureVideoDataOutput in 10-bit HLG
    (`420YpCbCr10BiPlanarVideoRange`), the ISP-processed "fake log" path. Cooler-running,
    supports HFR (60/120/240fps), and used as automatic thermal fallback when the
    phone hits `.serious` thermal state.
- **Full pro camera controls**: Manual ISO, shutter speed, white balance (Kelvin or
  gains), focus position, exposure bias, lens zoom. Blackmagic Cam-style control panel.
- **Full monitoring deck**: Zebras (with IRE thresholds), focus peaking, false color,
  live histogram (RGB+Y), waveform (toggle), vectorscope (toggle), audio meters,
  framing guides (rule-of-thirds, center, golden ratio, action/title safe).
- **Codec support**: HEVC 4:2:0 10-bit, HEVC 4:4:4 10-bit
  (`kVTProfileLevel_HEVC_Main422444_AutoLevel`), ProRes 422, 422 HQ, 422 LT, 4444,
  4444 XQ. Per-codec bitrate (100–550 Mbps, NOT the 5–20 Mbps of simpler apps).
- **Per-profile color tagging**: Each log curve gets its own transfer function
  attached — not all-tagged-HLG like the fake-log apps.
- **LUT import**: Adobe `.cube` 3D LUT parser, applied in-scene for monitor preview
  and optional bake-in. Built-in display LUTs for Apple Log / S-Log3 / LogC3 / V-Log.
- **Gyroflow GCSV export**: CMDeviceMotion → GCSV for post-stabilization in Gyroflow.
- **External SSD recording**: Output to `/Volumes/...` when an external SSD is mounted.

## ⚠️ The compilation reality (READ THIS FIRST)

iOS apps **cannot be compiled on a Windows PC**. This is not a tooling limitation —
it's Apple licensing: the iOS SDK ships only inside Xcode, Xcode only runs on macOS,
and macOS is licensed only for Apple hardware.

There is no legitimate way around this. Swift-on-Windows compiles Windows binaries.
Theos/Hackintosh paths are either jailbreak-only or violate Apple's EULA.

### The free path: GitHub Actions + AltStore/Sideloadly

This project includes a GitHub Actions workflow (`.github/workflows/build-ios.yml`)
that compiles the app on GitHub's hosted macOS runners, **free for public repos**.
You push the code to GitHub, the workflow runs on a Mac in the cloud, and you
download the resulting `.ipa` file from a web browser on your Windows PC.

Here is the full chain:

1. **Create a free GitHub account** if you don't have one.
2. **Create a public repo** and push the entire `LogCamPro/` folder to it.
3. **Trigger the workflow** — it runs automatically on every push, or you can
   manually trigger it from the Actions tab.
4. **Wait ~10–15 minutes** for the build to complete.
5. **Download the `.ipa`** from the Actions → workflow run → Artifacts section.
6. **Sideload to your iPhone** using **AltStore** or **Sideloadly** (both free,
   both Windows-native). You'll need a free Apple ID. Apps signed with a free
   Apple ID expire every 7 days — you re-sign by re-syncing via AltStore.
7. **Trust the developer** on your iPhone: Settings → General → VPN & Device
   Management → tap your Apple ID → Trust.

### Optional: paid path for 1-year signing + TestFlight

If you eventually get an Apple Developer Program membership ($99/year):
- Apps stay signed for 1 year instead of 7 days.
- You can distribute via TestFlight to up to 10,000 testers.
- Set `SIGN_APP: "true"` in the workflow and add the certificate/provisioning
  profile as repo secrets (instructions in the workflow file).

## What you can and can't do without a Mac

**You CAN do this from Windows:**
- Edit Swift/Metal files in VS Code or any text editor.
- Push to GitHub.
- Run the workflow and download the compiled `.ipa`.
- Sideload to your iPhone via AltStore/Sideloadly.
- Test the app on your actual iPhone — that's real-world camera testing, which is
  where most of the value is.

**You CANNOT do this without a Mac:**
- Step-through debugging of camera behavior in Xcode.
- Test Metal shader output via the GPU frame debugger.
- Profile thermal/CPU/GPU performance with Instruments.
- Run the iOS Simulator (only runs on macOS).

For a project this complex (RAW Bayer loops + Metal pipelines + real-time
monitoring), expect bugs that only surface on-device. The CI path gets you a
buildable `.ipa`, but you'll need to iterate via print/log statements and the
iPhone Console app rather than Xcode's debugger.

If you eventually buy a used Mac mini M1 (~$300–400 one-time), the whole
development experience changes — full debugging, simulator, Instruments, the
works. That's the single biggest investment you could make in this project.

## Project structure

```
LogCamPro/
├── .github/workflows/
│   └── build-ios.yml              # GitHub Actions macOS build workflow
├── LogCamPro.xcodeproj/
│   └── project.pbxproj            # Xcode project file
└── LogCamPro/
    ├── Info.plist                 # Camera/mic/motion/Bluetooth permissions + LUT file type
    ├── LogCamPro.entitlements     # Audio routing + Bluetooth entitlements
    ├── AppDelegate.swift
    ├── SceneDelegate.swift
    ├── CameraManager.swift        # Singleton — dual-mode camera orchestration
    ├── RawFrameCaptureManager.swift  # THE Log Cam trick: AVCapturePhotoOutput RAW loop
    ├── PreviewView.swift          # MetalKit preview view
    ├── MetalLogRenderer.swift     # Async ring-buffer Metal pipeline (YCbCr + preview)
    ├── VideoProcessor.swift       # AVAssetWriter: HEVC 4:2:0/4:4:4 + ProRes paths
    ├── ManualControlsManager.swift  # ISO/shutter/WB/focus/zoom/exposure
    ├── MonitoringOverlayView.swift  # Zebras/peaking/histogram/grid/audio meters
    ├── LUTManager.swift           # .cube parser + 3D LUT texture
    ├── GyroflowRecorder.swift     # CMDeviceMotion → GCSV
    ├── StorageManager.swift       # External SSD + disk space
    ├── CameraViewController.swift # SwiftUI pro camera UI
    ├── Shaders/
    │   └── LogFilter.metal        # 7 published-formula log curves + HLG linearization
    ├── Assets.xcassets/           # App icon, accent color
    └── Base.lproj/
        └── LaunchScreen.storyboard
```

## Architecture notes (for when you iterate)

### Why AVCapturePhotoOutput, not AVCaptureVideoDataOutput?

AVCaptureVideoDataOutput always runs the ISP. No matter which pixel format you pick
(`420YpCbCr10BiPlanarVideoRange`, `64RGBAHalf`, etc.), you get ISP-processed,
tone-mapped pixels — never the raw sensor data. This is why every "fake log" app on
the App Store uses it and never matches Log Cam's dynamic range.

AVCapturePhotoOutput, by contrast, can deliver RAW Bayer DNG frames. We drive it in a
backpressured loop (semaphore value 1) so we never pile up captures faster than the
ISP can digest. Each frame is then debayered via `CIRawPhotoFilter` — the only
correct demosaic on iOS because it knows per-device black offsets, white balance,
lens correction, etc.

### Why the Metal pipeline uses an async ring buffer

The original Claude file called `commandBuffer.waitUntilCompleted()`, which stalls
the CPU. On a RAW loop running at 30fps, that destroys throughput. The new
`MetalLogRenderer` uses a 4-deep ring buffer with `addCompletedHandler` so the CPU
keeps queueing frames while the GPU works through them in parallel.

### Why scene-linear intermediate (not direct log application)

The original shader applied log curves directly to HLG-encoded luma — which is wrong.
Log OETFs are defined over scene-linear light, not over an already-encoded signal.
The new shader pipeline is:
1. HLG OETF⁻¹ → linear RGB
2. White balance + exposure in linear
3. 3×3 gamut matrix in linear
4. Log OETF (Apple Log / LogC3 / S-Log3 / V-Log / F-Log / F-Log2)
5. Optional 3D LUT in log space
6. BT.2020 YCbCr matrix for AVAssetWriter input

### Why per-codec color tagging matters

ProRes 4444 + S-Log3 needs different color properties metadata than HEVC 4:2:0 + HLG.
The original file tagged every output as `kCMFormatDescriptionColorSpace_HLG`
regardless of profile, which makes footage show up wrong in Premiere/Resolve. The new
`VideoProcessor` keeps per-codec/per-colorspace settings.

## Iterating on this code

The files in this project compile to a real `.ipa`, but they are **untested on
device**. Expect bugs in:

- RAW loop timing (the backpressure semaphore may need to be value 2 instead of 1
  on iPhone 12 Pro Max — profile with `os_signpost`).
- CIRawPhotoFilter debayer path (the `CIFilter(imageData:)` path may not work for
  in-flight photo output; you may need to use `CIRawPhotoFilter` from a CIImage
  constructed from the pixel buffer directly).
- Texture → CVPixelBuffer blit in `VideoProcessor` (the `waitUntilCompleted()` in
  `texturesToPixelBuffer` will need to become async to keep up with the RAW loop).
- Metal shader MRT output — the struct return from the fragment function may need
  to be split into separate color attachments.

For each of these, the path forward is to add `os_log`/`NSLog` instrumentation,
run on device, and iterate. The CI workflow will get you a new `.ipa` for every
push — typically a 10-minute turnaround.

## License

This project is provided as-is for educational/personal use. The published log
formulas implemented in `LogFilter.metal` are based on manufacturers' published
white papers and are reproduced for interoperability with industry-standard log
workflows.

## Credits

Architecture and implementation: built from scratch with the dual-mode approach
(ACapturePhotoOutput RAW loop + AVCaptureVideoDataOutput HLG bypass) after
auditing the original 5-file Claude handoff against published Log Cam / RAW Cam
research and Blackmagic Cam's feature set.
