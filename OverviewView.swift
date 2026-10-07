import SwiftUI

// MARK: - 数据模型

struct UsageNumbers {
    var workers: Double?   // Workers 请求数（今日）
    var kv: Double?        // KV 读取（今日）
    var d1: Double?        // D1 行读取（今日）
    var r2: Double?        // R2 A 类操作（本月）
}

@MainActor
final class OverviewModel: ObservableObject {
    @Published var loaded = false
    @Published var zones: [Zone] = []
    @Published var workerCount = 0
    @Published var dnsCount = 0
    @Published var d1Count = 0
    @Published var badTunnels: [CFTunnel] = []
    @Published var usage = UsageNumbers()

    func load(_ ctx: Ctx) async {
        async let z: [Zone]? = try? ctx.c.get("zones", query: ["per_page": "50"])
        async let w: [WorkerScript]? = try? ctx.c.get("accounts/\(ctx.acc)/workers/scripts")
        async let d: [D1Database]? = try? ctx.c.get("accounts/\(ctx.acc)/d1/database", query: ["per_page": "100"])
        async let t: [CFTunnel]? = try? ctx.c.get("accounts/\(ctx.acc)/cfd_tunnel", query: ["is_deleted": "false"])
        async let u = Self.loadUsage(ctx)

        zones = await z ?? []
        workerCount = (await w ?? []).count
        d1Count = (await d ?? []).count
        badTunnels = (await t ?? []).filter { $0.status != "healthy" }
        usage = await u
        loaded = true

        var total = 0
        for zone in zones {
            total += (try? await ctx.c.totalCount("zones/\(zone.id)/dns_records")) ?? 0
        }
        dnsCount = total
    }

    /// 四项用量，单项失败（例如 Token 没有 Analytics 权限）只会显示 “—”
    nonisolated static func loadUsage(_ ctx: Ctx) async -> UsageNumbers {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let dayStart = cal.startOfDay(for: now)
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!

        let iso = ISO8601DateFormatter()
        let dayFmt = DateFormatter()
        dayFmt.calendar = cal
        dayFmt.timeZone = cal.timeZone
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"

        let timeVars = ["acc": ctx.acc, "start": iso.string(from: dayStart), "end": iso.string(from: now)]
        let monthVars = ["acc": ctx.acc, "start": iso.string(from: monthStart), "end": iso.string(from: now)]
        let dateVars = ["acc": ctx.acc, "start": dayFmt.string(from: now), "end": dayFmt.string(from: now)]

        async let w = try? ctx.c.graphql("""
        query($acc: String!, $start: Time!, $end: Time!) {
          viewer { accounts(filter: {accountTag: $acc}) {
            workersInvocationsAdaptive(limit: 10000, filter: {datetime_geq: $start, datetime_leq: $end}) {
              sum { requests }
            }
          } }
        }
        """, variables: timeVars)

        async let k = try? ctx.c.graphql("""
        query($acc: String!, $start: Time!, $end: Time!) {
          viewer { accounts(filter: {accountTag: $acc}) {
            kvOperationsAdaptiveGroups(limit: 10000, filter: {datetime_geq: $start, datetime_leq: $end}) {
              dimensions { actionType }
              sum { requests }
            }
          } }
        }
        """, variables: timeVars)

        async let d = try? ctx.c.graphql("""
        query($acc: String!, $start: Date!, $end: Date!) {
          viewer { accounts(filter: {accountTag: $acc}) {
            d1AnalyticsAdaptiveGroups(limit: 10000, filter: {date_geq: $start, date_leq: $end}) {
              sum { rowsRead }
            }
          } }
        }
        """, variables: dateVars)

        async let r = try? ctx.c.graphql("""
        query($acc: String!, $start: Time!, $end: Time!) {
          viewer { accounts(filter: {accountTag: $acc}) {
            r2OperationsAdaptiveGroups(limit: 10000, filter: {datetime_geq: $start, datetime_leq: $end}) {
              dimensions { actionType }
              sum { requests }
            }
          } }
        }
        """, variables: monthVars)

        func rows(_ v: JSONValue?, _ field: String) -> [JSONValue]? {
            v?["data"]?["viewer"]?["accounts"]?[0]?[field]?.array
        }

        var out = UsageNumbers()
        if let g = rows(await w, "workersInvocationsAdaptive") {
            out.workers = g.reduce(0) { $0 + ($1["sum"]?["requests"]?.number ?? 0) }
        }
        if let g = rows(await k, "kvOperationsAdaptiveGroups") {
            out.kv = g.filter { $0["dimensions"]?["actionType"]?.description == "read" }
                      .reduce(0) { $0 + ($1["sum"]?["requests"]?.number ?? 0) }
        }
        if let g = rows(await d, "d1AnalyticsAdaptiveGroups") {
            out.d1 = g.reduce(0) { $0 + ($1["sum"]?["rowsRead"]?.number ?? 0) }
        }
        let classA: Set<String> = [
            "ListBuckets", "PutBucket", "ListObjects", "PutObject", "CopyObject",
            "CompleteMultipartUpload", "CreateMultipartUpload", "ListMultipartUploads",
            "UploadPart", "UploadPartCopy", "ListParts", "PutBucketEncryption",
            "PutBucketCors", "PutBucketLifecycleConfiguration"
        ]
        if let g = rows(await r, "r2OperationsAdaptiveGroups") {
            out.r2 = g.filter { classA.contains($0["dimensions"]?["actionType"]?.description ?? "") }
                      .reduce(0) { $0 + ($1["sum"]?["requests"]?.number ?? 0) }
        }
        return out
    }
}

// MARK: - 概览页

struct OverviewView: View {
    @EnvironmentObject var session: Session
    @StateObject private var m = OverviewModel()

    @AppStorage("limit.workers") private var limWorkers = 100_000
    @AppStorage("limit.kv") private var limKV = 100_000
    @AppStorage("limit.d1") private var limD1 = 5_000_000
    @AppStorage("limit.r2") private var limR2 = 1_000_000
    @State private var showLimits = false

    private var isFreeLimits: Bool {
        limWorkers == 100_000 && limKV == 100_000 && limD1 == 5_000_000 && limR2 == 1_000_000
    }

    var body: some View {
        let ctx = session.ctx
        let accountName = session.accounts.first { $0.id == session.accountId }?.name ?? ""

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(accountName)
                statCards
                if !m.badTunnels.isEmpty { alertSection }
                usageSection
                domainsSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(
            LinearGradient(colors: [Color.orange.opacity(0.12), Color(.systemBackground)],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        )
        .overlay { if !m.loaded { ProgressView() } }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: ctx.acc) { await m.load(ctx) }
        .refreshable { await m.load(ctx) }
        .sheet(isPresented: $showLimits) { LimitsEditor() }
    }

    // MARK: 头部

    private func header(_ accountName: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.dateText).font(.subheadline).foregroundColor(.secondary)
            Text("\(Self.greeting)，\(accountName)")
                .font(.title2.bold()).lineLimit(2)
            Text(zoneSummary).font(.subheadline).foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }

    private var zoneSummary: String {
        if m.zones.isEmpty { return "还没有域名" }
        let bad = m.zones.filter { $0.status != "active" }.count
        return bad == 0 ? "\(m.zones.count) 个域名全部正常" : "\(bad) 个域名需要关注"
    }

    private static var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "早上好"
        case 12..<18: return "下午好"
        default: return "晚上好"
        }
    }

    private static var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: Date())
    }

    // MARK: 统计卡片

    private var statCards: some View {
        let active = m.zones.filter { $0.status == "active" }.count
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            StatCard(title: "域名", value: m.zones.count, caption: "\(active) 已启用")
            StatCard(title: "Workers", value: m.workerCount, caption: "已部署脚本")
            StatCard(title: "DNS 记录", value: m.dnsCount, caption: "跨 \(m.zones.count) 个域名")
            StatCard(title: "D1", value: m.d1Count, caption: "数据库")
        }
    }

    // MARK: 告警

    private var alertSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("告警").font(.title3.bold())
                Spacer()
                Text("\(m.badTunnels.count)").foregroundColor(.secondary)
            }
            ForEach(m.badTunnels) { t in
                NavigationLink {
                    TunnelDetailView(tunnel: t)
                } label: {
                    HStack(spacing: 12) {
                        Circle().fill(Color.blue).frame(width: 12, height: 12)
                            .padding(8).background(Color.blue.opacity(0.15)).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(.headline).foregroundColor(.primary)
                            Text("隧道状态：\(Self.statusText(t.status))")
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundColor(.secondary)
                    }
                    .cardStyle()
                }
            }
        }
    }

    private static func statusText(_ s: String?) -> String {
        switch s {
        case "inactive": return "未激活"
        case "degraded": return "降级"
        case "down": return "离线"
        default: return s ?? "未知"
        }
    }

    // MARK: 用量

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("用量").font(.title3.bold())
                Spacer()
                Button { showLimits = true } label: {
                    Label(isFreeLimits ? "W Free · R2 Free" : "自定义额度", systemImage: "slider.horizontal.3")
                        .font(.subheadline)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                UsageRing(title: "Workers · 请求 · 今日", value: m.usage.workers, limit: limWorkers)
                UsageRing(title: "R2 · A 类 · 本月", value: m.usage.r2, limit: limR2)
                UsageRing(title: "D1 · 行读取 · 今日", value: m.usage.d1, limit: limD1)
                UsageRing(title: "KV · 读取 · 今日", value: m.usage.kv, limit: limKV)
            }
            Text("每日用量按 UTC 0 点重置；显示 “—” 表示 Token 缺少 Account Analytics 读取权限。")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: 域名

    private var domainsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("域名").font(.title3.bold())
                Spacer()
                NavigationLink("全部") { ZonesView() }.font(.subheadline)
            }
            ForEach(m.zones.prefix(5)) { z in
                NavigationLink {
                    DNSRecordsView(zone: z)
                } label: {
                    HStack(spacing: 12) {
                        Text(String(z.name.prefix(1)).uppercased())
                            .font(.headline).foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.blue))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(z.name).font(.headline).foregroundColor(.primary)
                            Text("\(planName(z)) · \(z.status == "active" ? "已启用" : (z.status ?? "未知"))")
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                        Spacer()
                        Circle().fill(z.status == "active" ? Color.green : Color.orange)
                            .frame(width: 10, height: 10)
                    }
                    .cardStyle()
                }
            }
            if m.zones.isEmpty && m.loaded { EmptyHint(text: "没有域名") }
        }
    }

    private func planName(_ z: Zone) -> String {
        z.plan?.name?.components(separatedBy: " ").first ?? "-"
    }
}

// MARK: - 子组件

extension View {
    func cardStyle() -> some View {
        self.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct StatCard: View {
    let title: String
    let value: Int
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundColor(.secondary)
            Text("\(value)").font(.system(size: 34, weight: .bold))
            Text(caption).font(.caption).foregroundColor(.secondary)
        }
        .cardStyle()
    }
}

func formatCount(_ n: Double) -> String {
    if n >= 10_000 {
        let w = n / 10_000
        return w == w.rounded() ? "\(Int(w))万" : String(format: "%.1f万", w)
    }
    return "\(Int(n))"
}

struct UsageRing: View {
    let title: String
    let value: Double?
    let limit: Int

    private var fraction: Double {
        guard let v = value, limit > 0 else { return 0 }
        return min(v / Double(limit), 1)
    }
    private var ringColor: Color {
        fraction >= 0.9 ? .red : (fraction >= 0.7 ? .yellow : .orange)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption).foregroundColor(.secondary).lineLimit(1)
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color.gray.opacity(0.3), lineWidth: 7)
                    if value != nil {
                        Circle().trim(from: 0, to: max(fraction, 0.03))
                            .stroke(ringColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }
                .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.map { formatCount($0) } ?? "—").font(.title3.bold())
                    Text("/ \(formatCount(Double(limit)))").font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .cardStyle()
    }
}

struct LimitsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("limit.workers") private var limWorkers = 100_000
    @AppStorage("limit.kv") private var limKV = 100_000
    @AppStorage("limit.d1") private var limD1 = 5_000_000
    @AppStorage("limit.r2") private var limR2 = 1_000_000

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("用量环以这里的额度作为分母。付费计划请改成自己的额度。")) {
                    field("Workers 请求 / 日", $limWorkers)
                    field("KV 读取 / 日", $limKV)
                    field("D1 行读取 / 日", $limD1)
                    field("R2 A 类操作 / 月", $limR2)
                }
                Section {
                    Button("恢复免费版默认值") {
                        limWorkers = 100_000; limKV = 100_000; limD1 = 5_000_000; limR2 = 1_000_000
                    }
                }
            }
            .navigationTitle("用量额度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    private func field(_ title: String, _ value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: value, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 120)
        }
    }
}
