import UIKit

/// 车钥匙 · iOS 壳应用
/// 采用传统 AppDelegate + UIWindow 生命周期（Info.plist 中不声明 SceneManifest），
/// 这样在 TrollStore / 巨魔安装的未签名 App 上兼容性最好，也不需要 SceneDelegate。
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        let bg = UIColor(red: 11.0 / 255.0, green: 12.0 / 255.0, blue: 14.0 / 255.0, alpha: 1.0)

        let win = UIWindow(frame: UIScreen.main.bounds)
        win.backgroundColor = bg
        win.rootViewController = RootViewController()
        win.makeKeyAndVisible()
        window = win

        return true
    }
}
