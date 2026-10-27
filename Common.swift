import SwiftUI

enum InkTheme {
    static let cinnabar = Color(red: 0.72, green: 0.18, blue: 0.16)
    static let cinnabarDeep = Color(red: 0.55, green: 0.11, blue: 0.10)
    static let ink = Color(red: 0.16, green: 0.13, blue: 0.11)
    static let inkSoft = Color(red: 0.38, green: 0.32, blue: 0.27)
    static let gold = Color(red: 0.72, green: 0.55, blue: 0.22)
    static let pine = Color(red: 0.22, green: 0.42, blue: 0.35)
    static let paper = Color(red: 0.97, green: 0.94, blue: 0.88)
    static let paperDeep = Color(red: 0.93, green: 0.87, blue: 0.76)
    static let seal = Color(red: 0.78, green: 0.16, blue: 0.14)

    static var paperGradient: LinearGradient {
        LinearGradient(colors: [paperDeep.opacity(0.55), paper, Color(.systemBackground)],
                       startPoint: .top, endPoint: .center)
    }
}

/// 把 client 和 accountId 打包，便于在 async 闭包里使用（避免跨 actor 访问 Session）
struct Ctx {
    let c: CFClient
    let acc: String
}

extension Session {
    var ctx: Ctx { Ctx(c: client!, acc: accountId) }
}

/// 通用“加载 → 展示 / 报错重试”容器
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
