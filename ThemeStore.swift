import SwiftUI
import Combine

final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published var skin: ChineseSkin

    private static let storageKey = "appearance.chineseSkin"

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? ChineseSkin.ink.rawValue
        skin = ChineseSkin(rawValue: raw) ?? .ink
    }

    func setSkin(_ new: ChineseSkin) {
        skin = new
        UserDefaults.standard.set(new.rawValue, forKey: Self.storageKey)
    }
}
