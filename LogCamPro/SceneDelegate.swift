import UIKit
import SwiftUI

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        let root = UIHostingController(rootView: CameraRootView())
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window

        // Lock to landscape — pro camera UI is landscape-only.
        // requestGeometryUpdate is iOS 16+ (we target 16.0+).
        let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscape)
        windowScene.requestGeometryUpdate(prefs) { error in
            NSLog("[Scene] geometry update failed: \(error.localizedDescription)")
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Recording is forcibly stopped on background — iOS kills camera anyway.
        CameraManager.shared.stopCapture(reason: .background)
    }
}
