import SwiftUI
import Charts

struct VPNDashboardView: View {
    @StateObject private var model = VPNDashModel()
    @AppStorage("vpn.dash.mask") private var mask = true
    @AppStorage("vpn.globe.style") private var styleRaw = GlobeStyle.night.rawValue
    @State private var is3D = true
    @State private var paused = false
    @State private var locate = 0
    @State private var full = false
    @State private var inspect = false

    private var style: GlobeStyle { GlobeStyle(rawValue: styleRaw) ?? .night }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                networkCard
                globeCard
                speedRow
                connectionCard
                latencyCard
                links
            }
            .padding(16)
        }
        .navigationTitle("连接仪表盘")
        .refreshable {
            await model.refreshGeo()
            await model.pingOnce()
        }
        .task { await model.run() }
        .fullScreenCover(isPresented: $full) { fullscreen }
        .alert("本机 IP", isPresented: $inspect) {
            Button("复制") { UIPasteboard.general.string = model.geoA?.ip ?? model.geoB?.ip }
            Button("好", role: .cancel) {}
        } message: {
            Text(model.geoA?.ip ?? model.geoB?.ip ?? "还没有拿到出口地址")
        }
    }

    private var networkCard: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("网络信息").font(.headline)
                    Spacer()
                    Button { mask.toggle() } label: {
                        Image(systemName: mask ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(mask ? "显示 IP" : "隐藏 IP")
                    Button { Task { await model.refreshGeo() } } label: {
                        Image(systemName: "bolt.fill")
                    }
                    .accessibilityLabel("刷新网络信息")
                }
                providerBlock(model.providerA, model.geoA) { model.setProviderA($0) }
                providerBlock(model.providerB, model.geoB) { model.setProviderB($0) }
                if let note = model.geoNote {
                    Text(note).font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func providerBlock(_ provider: GeoProvider, _ fix: GeoFix?, _ select: @escaping (GeoProvider) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                ForEach(GeoProvider.allCases) { item in
                    Button(item.title) { select(item) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(provider.title).font(.subheadline)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Text(placeLine(fix))
                .font(.title3.weight(.semibold))
            Text(ispLine(fix))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var globeCard: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("全球连接").font(.headline)
                    Spacer()
                }
                globeControls
                globeBody
                    .frame(minHeight: is3D ? 280 : 180)
                HStack(spacing: 6) {
                    providerMenu(model.providerA) { model.setProviderA($0) }
                    Text(maskedIP(model.geoA?.ip))
                        .font(.caption.monospacedDigit())
                    Button { inspect = true } label: { Image(systemName: "magnifyingglass") }
                        .font(.caption)
                    Spacer()
                }
                legend
                Text("地球纹理：NASA Visible Earth（公有领域）。地理位置：ip.sb、ipip.net、ipwho.is、ipapi.co。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(arcCaption)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var globeControls: some View {
        HStack(spacing: 8) {
            Picker("视图", selection: $is3D) {
                Text("3D").tag(true)
                Text("2D").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            Menu {
                ForEach(GlobeStyle.allCases) { item in
                    Button(item.title) { styleRaw = item.rawValue }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(style.title)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
            Button { paused = true; locate += 1 } label: { Image(systemName: "location.fill") }
                .accessibilityLabel("定位到本机")
            Button { paused.toggle() } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }
                .accessibilityLabel(paused ? "继续旋转" : "暂停旋转")
            Button { full = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .accessibilityLabel("全屏")
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var globeBody: some View {
        if is3D {
            ZStack {
                GlobeSCN(model: model, style: style, paused: paused, locate: locate)
                ForEach(model.labels) { label in
                    Text(label.text)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .position(x: label.x, y: max(14, label.y - 14))
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            FlatEarthMap(style: style, origin: model.origin, arcs: model.arcs)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(style == .ink ? Color(red: 0.12, green: 0.1, blue: 0.09) : .white, "本机")
            legendItem(.blue, "经代理")
            legendItem(.orange, "直连")
            Spacer()
        }
        .font(.caption)
    }

    private var speedRow: some View {
        HStack(alignment: .top, spacing: 12) {
            speedCard("上传", VPNTraffic.shared.uploadRate, VPNTraffic.shared.sessionUp, model.upHistory, Color.gray)
            speedCard("下载", VPNTraffic.shared.downloadRate, VPNTraffic.shared.sessionDown, model.downHistory, Color.gray)
        }
    }

    private func speedCard(_ title: String, _ rate: Int64, _ total: Int64, _ history: [Double], _ color: Color) -> some View {
        let parts = dashRate(Double(rate))
        return DashCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.subheadline).foregroundColor(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(parts.0).font(.system(.largeTitle, design: .rounded))
                    Text(parts.1).font(.subheadline).foregroundColor(.secondary)
                }
                .accessibilityLabel("\(title) \(parts.0) \(parts.1)")
                Sparkline(values: history, color: color)
                    .frame(height: 46)
                Text("总计 \(dashTotal(total))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("累计 \(dashTotal(title == "上传" ? VPNTraffic.shared.totalUp : VPNTraffic.shared.totalDown))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var connectionCard: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("连接").font(.subheadline).foregroundColor(.secondary)
                Text("\(model.liveCount)")
                    .font(.system(size: 48, weight: .medium, design: .rounded))
                Sparkline(values: model.countHistory, color: .gray)
                    .frame(height: 64)
                Text(memoryLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var latencyCard: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("延迟").font(.headline)
                    Spacer()
                    Button { Task { await model.pingOnce() } } label: { Image(systemName: "bolt.fill") }
                        .accessibilityLabel("立即测速")
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 16) {
                    ForEach(model.targets) { target in
                        latencyCell(target)
                    }
                }
                Text("低于 200ms 为绿，低于 500ms 为黄，其余为红。测量走当前网络出口，VPN 连接时即代理路径。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func latencyCell(_ target: PingTarget) -> some View {
        let stats = pingStats(target.samples)
        return VStack(alignment: .leading, spacing: 6) {
            Text(target.name).font(.subheadline.weight(.semibold))
            if target.samples.isEmpty {
                Text("测量中…").font(.caption).foregroundColor(.secondary).frame(height: 36)
            } else {
                LatencyBars(samples: target.samples).frame(height: 36)
            }
            HStack {
                Text("min \(stats.ok ? "\(stats.min)ms" : "—")").foregroundColor(pingColor(Double(stats.min)))
                Spacer()
                Text("avg \(stats.ok ? "\(stats.avg)ms" : "—")").foregroundColor(pingColor(Double(stats.avg)))
            }
            .font(.caption.monospacedDigit())
            Text("max \(stats.ok ? "\(stats.max)ms" : "—")")
                .font(.caption.monospacedDigit())
                .foregroundColor(stats.ok ? pingColor(Double(stats.max)) : .secondary)
        }
    }

    private var links: some View {
        VStack(spacing: 8) {
            NavigationLink { ProxyHomeView() } label: { linkRow("节点、分流与订阅", "lock.shield") }
            NavigationLink { ConnectivityDiagnosticsView() } label: { linkRow("连接诊断", "stethoscope") }
            NavigationLink { PreferredIPView() } label: { linkRow("优选 IP", "speedometer") }
        }
    }

    private func linkRow(_ title: String, _ icon: String) -> some View {
        DashCard {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var fullscreen: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                globeControls
                globeBody.frame(maxHeight: .infinity)
                legend
            }
            .padding()
            .background(InkTheme.paper.ignoresSafeArea())
            .navigationTitle("全球连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { full = false } }
            }
        }
    }

    private var memoryLine: String {
        if let memory = model.memory, memory > 0 {
            return "内存使用 \(dashMiB(memory))"
        }
        return "内存使用 —"
    }

    private var arcCaption: String {
        let cities = Set(model.arcs.map(\.city)).count
        if model.liveCount == 0 { return "连接 VPN 后，这里画出活动连接的目的地城市。" }
        return "\(model.liveCount) 条连接 · \(cities) 个城市"
    }

    private func placeLine(_ fix: GeoFix?) -> String {
        let place = fix?.place.isEmpty == false ? fix!.place : "获取中…"
        return "\(place)  \(maskedIP(fix?.ip))"
    }

    private func ispLine(_ fix: GeoFix?) -> String {
        let isp = fix?.isp.isEmpty == false ? fix!.isp : "—"
        let ip = mask ? "***********" : (fix?.ip ?? "—")
        return "\(isp)（\(ip)）"
    }

    private func maskedIP(_ ip: String?) -> String {
        guard let ip, !ip.isEmpty else { return mask ? "***.***.*.*" : "—" }
        if !mask { return ip }
        let parts = ip.split(separator: ".")
        if parts.count == 4 { return "\(parts[0]).\(parts[1]).*.*" }
        return "***.***.*.*"
    }

    private func providerMenu(_ provider: GeoProvider, _ select: @escaping (GeoProvider) -> Void) -> some View {
        Menu {
            ForEach(GeoProvider.allCases) { item in Button(item.title) { select(item) } }
        } label: {
            HStack(spacing: 4) {
                Text(provider.title).font(.caption)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.tertiarySystemFill))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func legendItem(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
            Text(title)
        }
    }
}

struct DashCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(InkTheme.seal.opacity(0.16), lineWidth: 1)
            )
    }
}

struct Sparkline: View {
    var values: [Double]
    var color: Color
    var body: some View {
        let points = values.enumerated().map { PlotPt(i: $0.offset, y: $0.element) }
        Chart(points) { point in
            AreaMark(x: .value("i", point.i), y: .value("y", point.y))
                .foregroundStyle(color.opacity(0.18))
            LineMark(x: .value("i", point.i), y: .value("y", point.y))
                .foregroundStyle(color)
                .interpolationMethod(.linear)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

struct LatencyBars: View {
    var samples: [Double]
    var body: some View {
        let points = samples.enumerated().map { BarPt(i: $0.offset, y: max($0.element, 0.5), color: pingColor($0.element)) }
        Chart(points) { point in
            BarMark(x: .value("i", point.i), y: .value("ms", point.y))
                .foregroundStyle(point.color)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

struct PlotPt: Identifiable {
    let i: Int
    var id: Int { i }
    let y: Double
}

struct BarPt: Identifiable {
    let i: Int
    var id: Int { i }
    let y: Double
    let color: Color
}

func pingColor(_ ms: Double) -> Color {
    if ms <= 0 { return Color(red: 0.84, green: 0.28, blue: 0.25) }
    if ms < 200 { return Color(red: 0.18, green: 0.62, blue: 0.35) }
    if ms < 500 { return Color(red: 0.85, green: 0.62, blue: 0.13) }
    return Color(red: 0.84, green: 0.28, blue: 0.25)
}

func pingStats(_ samples: [Double]) -> (min: Int, avg: Int, max: Int, ok: Bool) {
    let good = samples.filter { $0 > 0 }
    guard !good.isEmpty else { return (0, 0, 0, false) }
    let avg = good.reduce(0, +) / Double(good.count)
    return (Int(good.min() ?? 0), Int(avg), Int(good.max() ?? 0), true)
}

func dashRate(_ bps: Double) -> (String, String) {
    let n = abs(bps)
    if n < 1000 { return (String(format: "%.0f", n), "B/s") }
    if n < 1_000_000 { return (String(format: n < 10_000 ? "%.0f" : "%.1f", n / 1000), "kB/s") }
    if n < 1_000_000_000 { return (String(format: "%.1f", n / 1_000_000), "MB/s") }
    return (String(format: "%.2f", n / 1_000_000_000), "GB/s")
}

func dashTotal(_ bytes: Int64) -> String { cfByteCount(bytes) }

func dashMiB(_ bytes: Int64) -> String {
    let mib = Double(bytes) / 1024 / 1024
    if mib < 10 { return String(format: "%.1f MiB", mib) }
    return String(format: "%.0f MiB", mib)
}
