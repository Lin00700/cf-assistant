import SwiftUI
import Combine

/// 全局主题状态（不标 @MainActor，避免 Swift 6 静态初始化隔离错误）
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

    @MainActor
    func setSkin(_ new: ChineseSkin) {
        skin = new
        UserDefaults.standard.set(new.rawValue, forKey: Self.storageKey)
    }
}
