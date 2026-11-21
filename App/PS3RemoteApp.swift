import SwiftUI
import UIKit

@main
struct PS3RemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Portrait for the hub, landscape while the Remote Play picture is on screen.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var lock: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.lock
    }

    static func rotate(_ mask: UIInterfaceOrientationMask, _ orientation: UIInterfaceOrientation) {
        lock = mask
        if #available(iOS 16.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                guard let ws = scene as? UIWindowScene else { continue }
                ws.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
                for w in ws.windows { w.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            }
        } else {
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}
