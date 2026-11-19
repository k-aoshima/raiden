import Foundation
import ServiceManagement

/// ログイン時に起動する設定。まず SMAppService.mainApp（システム設定の「ログイン項目」に出る）で登録し、
/// 失敗したら ~/Library/LaunchAgents/com.kosuke.raiden.plist（`open -a <Raiden.app>` を RunAtLoad）に逃げる。
///
/// ad-hoc 署名（build.sh の `codesign --sign -`）の .app は、ビルドのたびに cdhash が変わり、
/// システムの登録（BTM）が前の版を指したまま「登録なし」に見えることがある。そのため起動のたびに
/// 状態を見て、オンのはずなのに .enabled でなければ登録し直し、それでも駄目なら LaunchAgent を置く。
/// LaunchAgent は `open -a` で開くので、両方が効いても 2 つ目は立ち上がらない（LaunchServices が前面に出すだけ）。
enum LoginItem {
    static let label = "com.kosuke.raiden"
    private static let prefKey = "launchAtLogin"
    private static let defaults = UserDefaults.standard

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// 利用者が選んだ設定（未設定なら nil）
    static var preference: Bool? {
        get { defaults.object(forKey: prefKey) as? Bool }
        set { defaults.set(newValue, forKey: prefKey) }
    }

    /// いまログイン時に起動するか（SMAppService が有効か、LaunchAgent が置いてあるか）
    static var isOn: Bool {
        SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// 起動時に呼ぶ。初回（設定が無い）は「アプリケーション」フォルダから起動したときだけオンにする
    /// （build/Raiden.app を試しに開いたときに、その場所を登録しないため）。設定があればそれに合わせ直す
    static func syncAtLaunch() {
        let pref = preference ?? {
            let inApps = Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications"
            guard inApps else { return false }
            preference = true
            return true
        }()
        if pref { enable() } else if preference == false { disable() }
    }

    /// メニューから。切られている（承認待ち）ならシステム設定の「ログイン項目」を開く
    static func set(_ on: Bool) {
        preference = on
        if on { enable() } else { disable() }
        if on && SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// 登録する。SMAppService で .enabled になれば LaunchAgent は片付ける。
    /// .requiresApproval は利用者がシステム設定で切ったということなので、LaunchAgent で上書きしない
    private static func enable() {
        let s = SMAppService.mainApp
        if s.status != .enabled && s.status != .requiresApproval {
            do {
                try s.register()
            } catch {
                NSLog("Raiden: ログイン項目に登録できませんでした %@（状態 %d）", "\(error)", s.status.rawValue)
            }
        }
        switch s.status {
        case .enabled:
            removeAgent()
            NSLog("Raiden: ログイン項目（SMAppService）に登録済み")
        case .requiresApproval:
            NSLog("Raiden: ログイン項目はシステム設定で切られています（承認待ち）")
        default:
            writeAgent()
        }
    }

    private static func disable() {
        let s = SMAppService.mainApp
        if s.status == .enabled || s.status == .requiresApproval {
            do { try s.unregister() } catch { NSLog("Raiden: ログイン項目を外せませんでした %@", "\(error)") }
        }
        removeAgent()
    }

    /// SMAppService が使えないときの代わり。次のログインで launchd が `open -a <この .app>` を 1 回実行する
    private static func writeAgent() {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundleURL.path],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        do {
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
            NSLog("Raiden: SMAppService が使えないので LaunchAgent を置きました %@", agentURL.path)
        } catch {
            NSLog("Raiden: LaunchAgent を置けませんでした %@", "\(error)")
        }
    }

    private static func removeAgent() {
        if FileManager.default.fileExists(atPath: agentURL.path) { try? FileManager.default.removeItem(at: agentURL) }
    }
}
