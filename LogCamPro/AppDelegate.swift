import UIKit
import SwiftUI
import AVFoundation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // CRITICAL: Install an uncaught-exception handler FIRST, before anything
        // else. AVFoundation raises NSInvalidArgumentException in many edge cases
        // (unsupported pixel format, session not running, missing permission,
        // etc.) and Swift cannot catch Obj-C exceptions. Without this handler,
        // the exception is silently turned into an abort() and the crash report
        // shows only the abort() stack — not the actual exception name/reason.
        // With this handler, the exception name and reason are logged to NSLog
        // BEFORE the abort, so they appear in the device's Console.app log and
        // in subsequent .ips crash reports (under "ASI" → "Application Specific
        // Information"). This won't prevent the crash but makes future debugging
        // dramatically easier.
        NSSetUncaughtExceptionHandler { exception in
            NSLog("[UNCAUGHT EXCEPTION] name=%@ reason=%@",
                  exception.name.rawValue, exception.reason ?? "<no reason>")
            NSLog("[UNCAUGHT EXCEPTION] callStackSymbols:")
            for symbol in exception.callStackSymbols {
                NSLog("  %@", symbol)
            }
        }

        // CRITICAL: AVAudioSession MUST be configured before AVCaptureSession
        // adds an audio input. Otherwise AVFoundation throws an uncaught
        // Objective-C exception ("required condition is false: IsFormatSampleRateRangeValid")
        // which terminates the process. This matches the symptom of "UI shows
        // briefly then crashes" because configureSession runs async on a
        // background queue — the SwiftUI view renders first, then the audio
        // input add throws.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers]
            )
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.005)
        } catch {
            NSLog("[AppDelegate] AVAudioSession config failed: \(error.localizedDescription)")
            // Non-fatal: continue without configured audio session. The audio
            // path may not work but the video path will, and the app won't crash.
        }

        // Pre-warm Metal device and texture caches so the first preview frame is fast.
        _ = MetalLogRenderer.shared
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {
        // No-op: scenes are short-lived, no persistent state to clean.
    }
}
