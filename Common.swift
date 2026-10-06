import SwiftUI

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
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
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
    /// 简单的错误弹窗
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
