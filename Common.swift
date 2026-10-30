import SwiftUI

/// 中国风主题预设。
enum ChineseSkin: String, CaseIterable, Identifiable {
    case ink
    case cyan
    case cinnabar
    case moon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ink: return "水墨宣纸"
        case .cyan: return "青绿山水"
        case .cinnabar: return "朱砂金笺"
        case .moon: return "月夜玄青"
        }
    }

    var subtitle: String {
        switch self {
        case .ink: return "素纸淡墨 · 山影隐现"
        case .cyan: return "石青石绿 · 云烟缥缈"
        case .cinnabar: return "朱印鎏金 · 暖笺流光"
        case .moon: return "玄青月白 · 夜色沉静"
        }
    }

    var accent: Color { cinnabar }

    var cinnabar: Color {
        switch self {
        case .ink: return Color(red: 0.72, green: 0.18, blue: 0.16)
        case .cyan: return Color(red: 0.55, green: 0.22, blue: 0.18)
        case .cinnabar: return Color(red: 0.78, green: 0.14, blue: 0.12)
        case .moon: return Color(red: 0.82, green: 0.32, blue: 0.28)
        }
    }

    var cinnabarDeep: Color {
        switch self {
        case .ink: return Color(red: 0.55, green: 0.11, blue: 0.10)
        case .cyan: return Color(red: 0.40, green: 0.16, blue: 0.14)
        case .cinnabar: return Color(red: 0.58, green: 0.08, blue: 0.08)
        case .moon: return Color(red: 0.55, green: 0.18, blue: 0.16)
        }
    }

    var ink: Color {
        switch self {
        case .ink: return Color(red: 0.16, green: 0.13, blue: 0.11)
        case .cyan: return Color(red: 0.14, green: 0.18, blue: 0.16)
        case .cinnabar: return Color(red: 0.20, green: 0.12, blue: 0.08)
        case .moon: return Color(red: 0.92, green: 0.93, blue: 0.95)
        }
    }

    var inkSoft: Color {
        switch self {
        case .ink: return Color(red: 0.38, green: 0.32, blue: 0.27)
        case .cyan: return Color(red: 0.32, green: 0.40, blue: 0.36)
        case .cinnabar: return Color(red: 0.42, green: 0.30, blue: 0.22)
        case .moon: return Color(red: 0.62, green: 0.66, blue: 0.72)
        }
    }

    var gold: Color {
        switch self {
        case .ink: return Color(red: 0.72, green: 0.55, blue: 0.22)
        case .cyan: return Color(red: 0.65, green: 0.58, blue: 0.28)
        case .cinnabar: return Color(red: 0.82, green: 0.62, blue: 0.20)
        case .moon: return Color(red: 0.78, green: 0.68, blue: 0.38)
        }
    }

    var pine: Color {
        switch self {
        case .ink: return Color(red: 0.22, green: 0.42, blue: 0.35)
        case .cyan: return Color(red: 0.18, green: 0.48, blue: 0.42)
        case .cinnabar: return Color(red: 0.28, green: 0.40, blue: 0.28)
        case .moon: return Color(red: 0.35, green: 0.55, blue: 0.52)
        }
    }

    var paper: Color {
        switch self {
        case .ink: return Color(red: 0.97, green: 0.94, blue: 0.88)
        case .cyan: return Color(red: 0.93, green: 0.96, blue: 0.94)
        case .cinnabar: return Color(red: 0.98, green: 0.93, blue: 0.85)
        case .moon: return Color(red: 0.12, green: 0.14, blue: 0.18)
        }
    }

    var paperDeep: Color {
        switch self {
        case .ink: return Color(red: 0.93, green: 0.87, blue: 0.76)
        case .cyan: return Color(red: 0.82, green: 0.90, blue: 0.86)
        case .cinnabar: return Color(red: 0.94, green: 0.84, blue: 0.68)
        case .moon: return Color(red: 0.08, green: 0.10, blue: 0.14)
        }
    }

    var isDark: Bool { self == .moon }

    var cardFill: Color {
        isDark ? Color.white.opacity(0.06) : paper.opacity(0.72)
    }

    var paperGradient: LinearGradient {
        switch self {
        case .ink:
            return LinearGradient(
                colors: [paperDeep.opacity(0.55), paper, Color(.systemBackground)],
                startPoint: .top,
                endPoint: .center
            )
        case .cyan:
            return LinearGradient(
                colors: [Color(red: 0.78, green: 0.90, blue: 0.86).opacity(0.7), paper,
                         Color(red: 0.94, green: 0.97, blue: 0.95)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .cinnabar:
            return LinearGradient(
                colors: [Color(red: 0.95, green: 0.86, blue: 0.72).opacity(0.85), paper,
                         Color(red: 0.98, green: 0.95, blue: 0.90)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .moon:
            return LinearGradient(
                colors: [Color(red: 0.06, green: 0.08, blue: 0.12), paper,
                         Color(red: 0.14, green: 0.16, blue: 0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    static var current: ChineseSkin {
        let raw = UserDefaults.standard.string(forKey: "appearance.chineseSkin") ?? ChineseSkin.ink.rawValue
        return ChineseSkin(rawValue: raw) ?? .ink
    }
}

enum InkTheme {
    static var currentSkin: ChineseSkin { ChineseSkin.current }
    static var cinnabar: Color { currentSkin.cinnabar }
    static var cinnabarDeep: Color { currentSkin.cinnabarDeep }
    static var ink: Color { currentSkin.ink }
    static var inkSoft: Color { currentSkin.inkSoft }
    static var gold: Color { currentSkin.gold }
    static var pine: Color { currentSkin.pine }
    static var paper: Color { currentSkin.paper }
    static var paperDeep: Color { currentSkin.paperDeep }
    static var seal: Color { currentSkin.cinnabar }
    static var cardFill: Color { currentSkin.cardFill }
    static var paperGradient: LinearGradient { currentSkin.paperGradient }
    static var chromeScheme: ColorScheme { currentSkin.isDark ? .dark : .light }
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
            if let value {
                content(value, { await reload() })
            } else if let error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(InkTheme.cinnabar)
                    Text(error).multilineTextAlignment(.center).foregroundColor(.secondary)
                    Button("重试") { Task { await reload() } }
                        .buttonStyle(.borderedProminent)
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
        alert("出错了", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("好") { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

struct EmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding()
    }
}
