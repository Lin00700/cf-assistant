import SwiftUI
import Combine

final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    private init() {}
}
