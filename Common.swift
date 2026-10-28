import SwiftUI

/// 中国风皮肤：用 AppStorage 持久化，避免复杂 ThemeStore 链路
enum ChineseSkin: String, CaseIterable, Identifiable {
    case ink      // 水墨（跟随系统：米纸 / 墨色）
    case inkNight // 墨夜
    case cyan     // 青绿
    case cinnabar // 朱砂
    case moon     // 月夜

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ink: return "水墨"
        case .inkNight: return "墨夜"
        case .cyan: return "青绿"
        case .cinnabar: return "朱砂"
        case .moon: return "月夜"
        }
    }

    /// 点缀一律用朱砂；水墨正文颜色走 InkTheme.ink，不靠 accent。
    var accent: Color {
        switch self {
        case .ink: return Color(red: 0.72, green: 0.20, blue: 0.16)
        case .inkNight: return Color(red: 0.90, green: 0.36, blue: 0.30)
        case .cyan: return Color(red: 0.18, green: 0.42, blue: 0.40)
        case .cinnabar: return Color(red: 0.72, green: 0.18, blue: 0.16)
        case .moon: return Color(red: 0.45, green: 0.52, blue: 0.70)
        }
    }

    var paper: Color {
        switch self {
        case .ink: return Color(red: 0.965, green: 0.945, blue: 0.90)
        case .inkNight: return Color(red: 0.09, green: 0.09, blue: 0.10)
        case .cyan: return Color(red: 0.93, green: 0.96, blue: 0.94)
        case .cinnabar: return Color(red: 0.98, green: 0.94, blue: 0.90)
        case .moon: return Color(red: 0.12, green: 0.13, blue: 0.18)
        }
    }

    var paperDeep: Color {
        switch self {
        case .ink: return Color(red: 0.93, green: 0.87, blue: 0.76)
        case .inkNight: return Color(red: 0.14, green: 0.13, blue: 0.12)
        case .cyan: return Color(red: 0.82, green: 0.90, blue: 0.86)
        case .cinnabar: return Color(red: 0.94, green: 0.85, blue: 0.80)
        case .moon: return Color(red: 0.08, green: 0.09, blue: 0.14)
        }
    }

    var isDark: Bool { self == .moon || self == .inkNight }

    /// nil = 跟随系统。水墨用动态颜色，深浅都可读。
    var lockedScheme: ColorScheme? {
        switch self {
        case .ink: return nil
        case .cyan, .cinnabar: return .light
        case .moon, .inkNight: return .dark
        }
    }

    static var current: ChineseSkin {
        let raw = UserDefaults.standard.string(forKey: "appearance.chineseSkin") ?? ChineseSkin.ink.rawValue
        return ChineseSkin(rawValue: raw) ?? .ink
    }
}

enum InkTheme {
    static var cinnabar: Color { ChineseSkin.current.accent }
    static var cinnabarDeep: Color { ChineseSkin.current.accent.opacity(0.85) }

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { trait in
            let skin = ChineseSkin.current
            let night = skin.isDark || (skin == .ink && trait.userInterfaceStyle == .dark)
            return night ? dark : light
        })
    }

    static var ink: Color {
        if ChineseSkin.current == .moon {
            return Color(red: 0.90, green: 0.91, blue: 0.95)
        }
        return adaptive(
            light: UIColor(red: 0.15, green: 0.12, blue: 0.10, alpha: 1),
            dark: UIColor(red: 0.93, green: 0.91, blue: 0.86, alpha: 1)
        )
    }
    static var inkSoft: Color {
        if ChineseSkin.current == .moon {
            return Color(red: 0.65, green: 0.66, blue: 0.72)
        }
        return adaptive(
            light: UIColor(red: 0.38, green: 0.32, blue: 0.27, alpha: 1),
            dark: UIColor(red: 0.70, green: 0.67, blue: 0.62, alpha: 1)
        )
    }
    static var gold: Color { Color(red: 0.72, green: 0.55, blue: 0.22) }
    static var pine: Color { Color(red: 0.22, green: 0.42, blue: 0.35) }
    static var paper: Color {
        if ChineseSkin.current == .ink {
            return adaptive(
                light: UIColor(red: 0.965, green: 0.945, blue: 0.90, alpha: 1),
                dark: UIColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
            )
        }
        return ChineseSkin.current.paper
    }
    static var paperDeep: Color {
        if ChineseSkin.current == .ink {
            return adaptive(
                light: UIColor(red: 0.93, green: 0.87, blue: 0.76, alpha: 1),
                dark: UIColor(red: 0.16, green: 0.15, blue: 0.14, alpha: 1)
            )
        }
        return ChineseSkin.current.paperDeep
    }
    static var seal: Color { Color(red: 0.78, green: 0.16, blue: 0.14) }

    static var paperGradient: LinearGradient {
        LinearGradient(
            colors: [paperDeep.opacity(0.55), paper, Color(.systemBackground)],
            startPoint: .top,
            endPoint: .center
        )
    }
}

struct Ctx {
    let c: CFClient
    let acc: String
}

extension Session {
    var ctx: Ctx { Ctx(c: client!, acc: accountId) }
}

struct LoadView<T, Content: View>: View {
    let load: () async throws -> T
    let content: (T, @escaping () async -> Void) -> Content

    @State private var value: T?
    @State private var error: String?

    init(load: @escaping () async throws -> T,
         @ViewBuilder content: @escaping (T, @escaping () async -> Void) -> Content) {
        self.load = load
        self.content = content
    }

    var body: some View {
        Group {
            if let v = value {
                content(v, { await self.reload() })
            } else if let e = error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(InkTheme.cinnabar)
                    Text(e).multilineTextAlignment(.center).foregroundColor(.secondary)
                    Button("重试") { Task { await reload() } }.buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                ProgressView()
            }
        }
        .task { await reload() }
    }

    @MainActor
    func reload() async {
        do {
            value = try await load()
            error = nil
        } catch is CancellationError {
        } catch {
            if value == nil { self.error = error.localizedDescription }
        }
    }
}

extension View {
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("出错了", isPresented: Binding(get: { message.wrappedValue != nil },
                                              set: { if !$0 { message.wrappedValue = nil } })) {
            Button("好") { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View {
        Text(text).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .center).padding()
    }
}
