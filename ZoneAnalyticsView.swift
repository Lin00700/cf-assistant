import SwiftUI
import Charts

struct DayStat: Identifiable {
    let id = UUID()
    let date: Date
    let requests: Double
    let cachedRequests: Double
    let bytes: Double
    let cachedBytes: Double
    let threats: Double
    let uniques: Double
}

struct ChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let kind: String
    let value: Double
}

struct ZoneAnalyticsView: View {
    @EnvironmentObject var session: Session
    let zone: Zone
    @State private var days = 7

    var body: some View {
        let ctx = session.ctx
        let zid = zone.id
        let n = days
        VStack(spacing: 0) {
            Picker("范围", selection: $days) {
                Text("7 天").tag(7)
                Text("14 天").tag(14)
                Text("30 天").tag(30)
            }
            .pickerStyle(.segmented)
            .padding()

            LoadView(load: { () async throws -> [DayStat] in
                try await Self.fetch(ctx, zid, n)
            }) { stats, reload in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        summary(stats)
                        requestsChart(stats)
                        bandwidthChart(stats)
                        threatsChart(stats)
                    }
                    .padding()
                }
                .refreshable { await reload() }
            }
            .id(days)
        }
        .navigationTitle("流量分析")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 数据

    static func fetch(_ ctx: Ctx, _ zoneId: String, _ days: Int) async throws -> [DayStat] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let end = Date()
        let start = end.addingTimeInterval(-Double(days - 1) * 86_400)

        let q = """
        query($zone: String!, $start: Date!, $end: Date!) {
          viewer { zones(filter: {zoneTag: $zone}) {
            httpRequests1dGroups(limit: 40, orderBy: [date_ASC], filter: {date_geq: $start, date_leq: $end}) {
              dimensions { date }
              sum { requests cachedRequests bytes cachedBytes threats }
              uniq { uniques }
            }
          } }
        }
        """
        let v = try await ctx.c.graphql(q, variables: ["zone": zoneId, "start": f.string(from: start),
                                                       "end": f.string(from: end)])
        guard let rows = v["data"]?["viewer"]?["zones"]?[0]?["httpRequests1dGroups"]?.array else {
            throw CFClientError.message("没有读取到流量数据（Token 需要 Analytics 读取权限）")
        }
        return rows.compactMap { r -> DayStat? in
            guard let ds = r["dimensions"]?["date"]?.description, let d = f.date(from: ds) else { return nil }
            return DayStat(date: d,
                           requests: r["sum"]?["requests"]?.number ?? 0,
                           cachedRequests: r["sum"]?["cachedRequests"]?.number ?? 0,
                           bytes: r["sum"]?["bytes"]?.number ?? 0,
                           cachedBytes: r["sum"]?["cachedBytes"]?.number ?? 0,
                           threats: r["sum"]?["threats"]?.number ?? 0,
                           uniques: r["uniq"]?["uniques"]?.number ?? 0)
        }
    }

    // MARK: 子视图

    private func bytesText(_ b: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .binary)
    }

    private func summary(_ s: [DayStat]) -> some View {
        let req = s.reduce(0) { $0 + $1.requests }
        let cached = s.reduce(0) { $0 + $1.cachedRequests }
        let bytes = s.reduce(0) { $0 + $1.bytes }
        let uniques = s.reduce(0) { $0 + $1.uniques }
        let ratio = req > 0 ? Int((cached / req * 100).rounded()) : 0
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            tile("请求", formatCount(req))
            tile("缓存命中率", "\(ratio)%")
            tile("流量", bytesText(bytes))
            tile("独立访客（日合计）", formatCount(uniques))
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundColor(.secondary)
            Text(value).font(.system(size: 26, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .cardStyle()
    }

    private func requestsChart(_ s: [DayStat]) -> some View {
        var pts: [ChartPoint] = []
        for d in s {
            pts.append(ChartPoint(date: d.date, kind: "已缓存", value: d.cachedRequests))
            pts.append(ChartPoint(date: d.date, kind: "未缓存", value: max(d.requests - d.cachedRequests, 0)))
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("请求数").font(.headline)
            Chart(pts) { p in
                BarMark(x: .value("日期", p.date, unit: .day), y: .value("请求", p.value))
                    .foregroundStyle(by: .value("类型", p.kind))
            }
            .chartForegroundStyleScale(["已缓存": Color.orange, "未缓存": Color.gray.opacity(0.5)])
            .frame(height: 190)
        }
    }

    private func bandwidthChart(_ s: [DayStat]) -> some View {
        var pts: [ChartPoint] = []
        for d in s {
            pts.append(ChartPoint(date: d.date, kind: "已缓存", value: d.cachedBytes / 1_048_576))
            pts.append(ChartPoint(date: d.date, kind: "未缓存", value: max(d.bytes - d.cachedBytes, 0) / 1_048_576))
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("流量（MB）").font(.headline)
            Chart(pts) { p in
                BarMark(x: .value("日期", p.date, unit: .day), y: .value("MB", p.value))
                    .foregroundStyle(by: .value("类型", p.kind))
            }
            .chartForegroundStyleScale(["已缓存": Color.blue, "未缓存": Color.gray.opacity(0.5)])
            .frame(height: 190)
        }
    }

    private func threatsChart(_ s: [DayStat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("拦截的威胁").font(.headline)
            Chart(s) { d in
                LineMark(x: .value("日期", d.date, unit: .day), y: .value("威胁", d.threats))
                    .foregroundStyle(Color.red)
                PointMark(x: .value("日期", d.date, unit: .day), y: .value("威胁", d.threats))
                    .foregroundStyle(Color.red)
            }
            .frame(height: 140)
        }
    }
}
