import SwiftUI
import Combine

/// 全局主题状态：切换皮肤时所有观察它的界面会刷新。
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published var skin: ChineseSkin {
        didSet {
            UserDefaults.standard.set(skin.rawValue, forKey: Self.storageKey)
        }
    }

    private static let storageKey = "appearance.chineseSkin"

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? ChineseSkin.ink.rawValue
        skin = ChineseSkin(rawValue: raw) ?? .ink
    }

    func setSkin(_ new: ChineseSkin) {
        objectWillChange.send()
        skin = new
        UserDefaults.standard.set(new.rawValue, forKey: Self.storageKey)
    }
}
