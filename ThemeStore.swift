import SwiftUI
import Combine

/// 全局主题状态：切换皮肤时所有观察它的界面会刷新。
@MainActor
final class ThemeStore: ObservableObject {
    /// Swift 6：允许从非隔离上下文读取 shared（颜色主题等）
    nonisolated(unsafe) static let shared = ThemeStore()

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
