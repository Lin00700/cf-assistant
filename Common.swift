import SwiftUI

/// 中国风皮肤：用 AppStorage 持久化，避免复杂 ThemeStore 链路
enum ChineseSkin: String, CaseIterable, Identifiable {
    case ink      // 水墨
    case cyan     // 青绿
    case cinnabar // 朱砂
    case moon     // 月夜

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ink: return "水墨"
        case .cyan: return "青绿"
        case .cinnabar: return "朱砂"
        case .moon: return "月夜"
        }
    }

    var accent: Color {
        switch self {
        case .ink: return Color(red: 0.16, green: 0.13, blue: 0.11)
        case .cyan: return Color(red: 0.18, green: 0.42, blue: 0.40)
        case .cinnabar: return Color(red: 0.72, green: 0.18, blue: 0.16)
        case .moon: return Color(red: 0.45, green: 0.52, blue: 0.70)
        }
    }

    var paper: Color {
        switch self {
        case .ink: return Color(red: 0.97, green: 0.94, blue: 0.88)
        case .cyan: return Color(red: 0.93, green: 0.96, blue: 0.94)
        case .cinnabar: return Color(red: 0.98, green: 0.94, blue: 0.90)
        case .moon: return Color(red: 0.12, green: 0.13, blue: 0.18)
        }
    }

    var paperDeep: Color {
        switch self {
        case .ink: return Color(red: 0.93, green: 0.87, blue: 0.76)
        case .cyan: return Color(red: 0.82, green: 0.90, blue: 0.86)
        case .cinnabar: return Color(red: 0.94, green: 0.85, blue: 0.80)
        case .moon: return Color(red: 0.08, green: 0.09, blue: 0.14)
        }
    }

    var isDark: Bool { self == .moon }

    static var current: ChineseSkin {
        let raw = UserDefaults.standard.string(forKey: "appearance.chineseSkin") ?? ChineseSkin.ink.rawValue
        return ChineseSkin(rawValue: raw) ?? .ink
    }
}

enum InkTheme {
    static var cinnabar: Color { ChineseSkin.current.accent }
    static var cinnabarDeep: Color { ChineseSkin.current.accent.opacity(0.85) }
    static var ink: Color {
        ChineseSkin.current.isDark
            ? Color(red: 0.90, green: 0.90, blue: 0.92)
            : Color(red: 0.16, green: 0.13, blue: 0.11)
    }
    static var inkSoft: Color {
        ChineseSkin.current.isDark
            ? Color(red: 0.65, green: 0.66, blue: 0.72)
            : Color(red: 0.38, green: 0.32, blue: 0.27)
    }
    static var gold: Color { Color(red: 0.72, green: 0.55, blue: 0.22) }
    static var pine: Color { Color(red: 0.22, green: 0.42, blue: 0.35) }
    static var paper: Color { ChineseSkin.current.paper }
    static var paperDeep: Color { ChineseSkin.current.paperDeep }
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
