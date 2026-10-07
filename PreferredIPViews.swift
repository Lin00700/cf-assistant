import SwiftUI

struct ShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - 主界面

struct PreferredIPView: View {
    @EnvironmentObject var session: Session
    @StateObject private var engine = PreferredIPEngine()
    @State private var showConfig = false
    @State private var showSources = false
    @State private var showLog = false
    @State private var showDNS = false
    @State private var shareItems: ShareItems?
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(engine.phase).font(.subheadline)
                        Spacer()
                        if engine.running { ProgressView() }
                    }
                    if engine.running {
                        ProgressView(value: engine.progress)
                    }
                    if let t = engine.lastRun {
                        Text("上次运行：\(t.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Button {
                    if engine.running { engine.stop() } else { engine.start() }
                } label: {
                    HStack {
                        Spacer()
                        Label(engine.running ? "停止" : "开始优选",
                              systemImage: engine.running ? "stop.fill" : "play.fill").bold()
                        Spacer()
                    }
                }
                .tint(engine.running ? .red : .orange)
            }

            Section("结果（\(engine.results.count)）") {
                ForEach(engine.results) { r in
                    ResultRow(r: r)
                        .contentShape(Rectangle())
                        .onTapGesture { copy(r.address) }
                        .contextMenu {
                            Button("复制地址") { copy(r.address) }
                            Button("复制 IP") { copy(r.ip) }
                            Button("复制整行") { copy(PreferredIPEngine.formatLine(r, engine.config.txtFormat)) }
                        }
                }
                if engine.results.isEmpty {
                    Text("点“开始优选”测试；点结果可复制地址").font(.footnote).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("优选 IP")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showSources = true } label: { Label("优选源", systemImage: "list.bullet") }
                    Button { showConfig = true } label: { Label("参数设置", systemImage: "slider.horizontal.3") }
                    Button { showLog = true } label: { Label("运行日志", systemImage: "terminal") }
                    Divider()
                    Button {
                        copy(engine.txtText(engine.results))
                    } label: { Label("复制全部（TXT）", systemImage: "doc.on.doc") }
                    .disabled(engine.results.isEmpty)
                    Button {
                        let urls = engine.writeExportFiles()
                        if !urls.isEmpty { shareItems = ShareItems(urls: urls) }
                    } label: { Label("导出 TXT / CSV / JSON", systemImage: "square.and.arrow.up") }
                    .disabled(engine.results.isEmpty)
                    if session.client != nil {
                        Button { showDNS = true } label: {
                            Label("写入 Cloudflare DNS", systemImage: "icloud.and.arrow.up")
                        }
                        .disabled(engine.results.isEmpty)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showConfig) { BestCFConfigView(engine: engine) }
        .sheet(isPresented: $showSources) { BestCFSourcesView(engine: engine) }
        .sheet(isPresented: $showLog) { BestCFLogView(engine: engine) }
        .sheet(isPresented: $showDNS) { BestCFDNSPushView(results: engine.results) }
        .sheet(item: $shareItems) { ShareSheet(items: $0.urls) }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t).font(.footnote).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thinMaterial).clipShape(Capsule()).padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    private func copy(_ s: String) {
        UIPasteboard.general.string = s
        toast = "已复制"
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            toast = nil
        }
    }
}

struct ResultRow: View {
    let r: IPResult

    private var latencyColor: Color {
        guard let l = r.latency else { return .secondary }
        return l < 100 ? .green : (l < 200 ? .orange : .red)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(r.address).font(.system(.subheadline, design: .monospaced)).lineLimit(1)
                Spacer()
                Text(r.latency.map { "\(Int($0)) ms" } ?? "-")
                    .font(.subheadline.bold()).foregroundColor(latencyColor)
            }
            HStack(spacing: 6) {
                if !r.tag.isEmpty { chip(r.tag) }
                if !r.colo.isEmpty { chip("\(r.country) \(r.colo)") }
                Text("抖动 \(String(format: "%.1f", r.jitter))").font(.caption2).foregroundColor(.secondary)
                Text("丢包 \(Int(r.loss))%").font(.caption2).foregroundColor(.secondary)
                Text("纯度 \(r.purity)").font(.caption2).foregroundColor(.secondary)
                if let s = r.speed, s > 0 {
                    Text("\(String(format: "%.1f", s)) MB/s").font(.caption2.bold()).foregroundColor(.blue)
                }
            }
            if r.kind == "domain" {
                Text("→ \(r.ip)").font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private func chip(_ s: String) -> some View {
        Text(s).font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.orange.opacity(0.15)).cornerRadius(4)
    }
}

// MARK: - 设置

struct IntStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit = ""
    var zeroText: String? = nil

    var body: some View {
        let shown = (value == 0 && zeroText != nil) ? zeroText! : "\(value)\(unit)"
        Stepper("\(title)：\(shown)", value: $value, in: range, step: step)
    }
}

struct BestCFConfigView: View {
    @ObservedObject var engine: PreferredIPEngine
    @Environment(\.dismiss) private var dismiss

    private func csv(_ keyPath: WritableKeyPath<BestCFConfig, [String]>) -> Binding<String> {
        Binding(get: { engine.config[keyPath: keyPath].joined(separator: ",") },
                set: { engine.config[keyPath: keyPath] = $0.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty } })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("连接测试") {
                    IntStepper(title: "超时", value: $engine.config.timeoutMs, range: 200...5000, step: 100, unit: " ms")
                    IntStepper(title: "并发", value: $engine.config.threads, range: 4...64, step: 4)
                    IntStepper(title: "TCP 次数", value: $engine.config.tries, range: 1...10)
                    IntStepper(title: "固定端口", value: $engine.config.port, range: 0...65535, step: 1, zeroText: "随机")
                    IntStepper(title: "每个网段抽样", value: $engine.config.cidrSample, range: 1...64)
                    IntStepper(title: "目标上限", value: $engine.config.maxTargets, range: 100...10000, step: 100)
                    Toggle("处理 IPv6", isOn: $engine.config.ipv6)
                    TextField("探测域名（SNI）", text: $engine.config.probeHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("GitHub 加速前缀（可空）", text: $engine.config.ghProxy)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }

                Section(header: Text("过滤"), footer: Text("国家用两位代码，如 US,HK,JP；Colo 如 SJC,LAX,HKG；留空表示不限。")) {
                    IntStepper(title: "最低纯度", value: $engine.config.minPurity, range: 0...100, step: 5)
                    IntStepper(title: "复测最大丢包", value: $engine.config.maxLoss, range: 0...100, step: 5, unit: "%")
                    TextField("只保留国家", text: csv(\.allowCountry))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField("只保留 Colo", text: csv(\.allowColo))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                }

                Section(header: Text("复测与测速"), footer: Text("下载测速会消耗流量，默认关闭。")) {
                    IntStepper(title: "复测前 N 名", value: $engine.config.retestTop, range: 0...200, step: 10, zeroText: "关闭")
                    IntStepper(title: "复测次数", value: $engine.config.retestTries, range: 2...30)
                    IntStepper(title: "下载测速前 N 名", value: $engine.config.speedtestTop, range: 0...50, zeroText: "关闭")
                    TextField("测速域名", text: $engine.config.speedHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Stepper("单个测速大小：\(engine.config.speedBytes / 1_000_000) MB",
                            value: Binding(get: { engine.config.speedBytes / 1_000_000 },
                                           set: { engine.config.speedBytes = $0 * 1_000_000 }),
                            in: 1...100)
                    IntStepper(title: "单个测速时长", value: $engine.config.speedSecs, range: 1...15, unit: " 秒")
                }

                Section(header: Text("排序与输出"),
                        footer: Text("TXT 格式可用占位符：{address} {ip} {port} {tag} {country} {colo} {latency} {speed} {purity}")) {
                    Picker("排序", selection: $engine.config.sortBy) {
                        Text("综合").tag("score")
                        Text("延迟").tag("latency")
                        Text("速度").tag("speed")
                    }
                    IntStepper(title: "每个 Colo 最多", value: $engine.config.perColo, range: 0...20, zeroText: "不限")
                    IntStepper(title: "只保留前 N 个", value: $engine.config.top, range: 0...500, step: 10, zeroText: "全部")
                    TextField("TXT 格式", text: $engine.config.txtFormat)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    IntStepper(title: "自动循环", value: $engine.config.loopMinutes, range: 0...720, step: 5,
                               unit: " 分钟", zeroText: "关闭")
                }

                Section {
                    Button("恢复默认设置", role: .destructive) { engine.resetConfig() }
                }
            }
            .navigationTitle("参数设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: - 优选源

struct BestCFSourcesView: View {
    @ObservedObject var engine: PreferredIPEngine
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                ForEach($engine.sources) { $s in
                    Toggle(isOn: $s.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(s.tag)（\(s.name)）").font(.headline)
                            Text(s.inlineText != nil ? "本地文本" : s.url)
                                .font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
                .onDelete { engine.sources.remove(atOffsets: $0) }

                Section {
                    Button("恢复默认源") { engine.resetSources() }
                }
            }
            .navigationTitle("优选源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $adding) { BestCFSourceEditView(engine: engine) }
        }
    }
}

struct BestCFSourceEditView: View {
    @ObservedObject var engine: PreferredIPEngine
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var tag = ""
    @State private var isText = false
    @State private var url = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（英文短名）", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("标签（显示用，如 移动）", text: $tag)
                    Picker("类型", selection: $isText) {
                        Text("网址").tag(false)
                        Text("粘贴文本").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                Section(footer: Text("支持域名、IPv4/IPv6、ip:port、[ipv6]:port、CIDR、JSON、带 # 备注的文本。")) {
                    if isText {
                        TextEditor(text: $text).frame(minHeight: 140)
                            .font(.system(size: 13, design: .monospaced))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        TextField("https://…", text: $url)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                }
            }
            .navigationTitle("添加优选源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        let t = tag.trimmingCharacters(in: .whitespaces)
                        engine.sources.append(BestCFSource(
                            name: n.isEmpty ? "src\(engine.sources.count + 1)" : n,
                            tag: t.isEmpty ? (n.isEmpty ? "自定义" : n) : t,
                            url: isText ? "" : url.trimmingCharacters(in: .whitespaces),
                            inlineText: isText ? text : nil))
                        dismiss()
                    }
                    .disabled(isText ? text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     : url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - 日志

struct BestCFLogView: View {
    @ObservedObject var engine: PreferredIPEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(engine.logs.isEmpty ? "还没有日志" : engine.logs.joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { engine.logs = [] }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 写入 Cloudflare DNS

struct BestCFDNSPushView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let results: [IPResult]

    @State private var zones: [Zone] = []
    @State private var zoneId = ""
    @State private var sub = "best"
    @State private var count = 4
    @State private var ttl = 60
    @State private var proxied = false
    @State private var overwrite = true
    @State private var running = false
    @State private var confirm = false
    @State private var message: String?
    @State private var error: String?

    private var picks: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for r in results where !r.ip.isEmpty {
            if seen.insert(r.ip).inserted { out.append(r.ip) }
            if out.count >= count { break }
        }
        return out
    }

    private var fullName: String {
        guard let z = zones.first(where: { $0.id == zoneId }) else { return "" }
        let s = sub.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty || s == "@" { return z.name }
        return s.hasSuffix(z.name) ? s : "\(s).\(z.name)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("目标"), footer: Text("把当前结果里最优的 IP 写成 A / AAAA 记录，可用来做自己的优选域名。")) {
                    Picker("域名", selection: $zoneId) {
                        ForEach(zones) { Text($0.name).tag($0.id) }
                    }
                    TextField("子域名（@ 表示根域名）", text: $sub)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !fullName.isEmpty { LabeledContent("完整记录名", value: fullName) }
                }
                Section("选项") {
                    Stepper("写入前 \(count) 个 IP", value: $count, in: 1...20)
                    Picker("TTL", selection: $ttl) {
                        Text("自动").tag(1)
                        Text("60 秒").tag(60)
                        Text("5 分钟").tag(300)
                    }
                    Toggle("开启 Cloudflare 代理", isOn: $proxied)
                    Toggle("先删除同名 A / AAAA 记录", isOn: $overwrite)
                }
                Section("将写入") {
                    ForEach(picks, id: \.self) { Text($0).font(.system(.footnote, design: .monospaced)) }
                }
                Section {
                    Button {
                        confirm = true
                    } label: {
                        HStack {
                            Spacer()
                            if running { ProgressView() } else { Text("写入").bold() }
                            Spacer()
                        }
                    }
                    .disabled(running || zoneId.isEmpty || picks.isEmpty)
                }
            }
            .navigationTitle("写入 DNS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await loadZones() }
            .confirmationDialog("确认写入 \(picks.count) 条记录到 \(fullName)？\(overwrite ? "同名 A/AAAA 记录会先被删除。" : "")",
                                isPresented: $confirm, titleVisibility: .visible) {
                Button("写入", role: .destructive) { Task { await push() } }
                Button("取消", role: .cancel) {}
            }
            .alert("完成", isPresented: Binding(get: { message != nil }, set: { _ in })) {
                Button("好") { message = nil; dismiss() }
            } message: { Text(message ?? "") }
            .errorAlert($error)
        }
    }

    private func loadZones() async {
        let ctx = session.ctx
        do {
            let z: [Zone] = try await ctx.c.get("zones", query: ["per_page": "50"])
            zones = z
            if zoneId.isEmpty { zoneId = z.first?.id ?? "" }
        } catch { self.error = error.localizedDescription }
    }

    private func push() async {
        running = true
        defer { running = false }
        let ctx = session.ctx
        let name = fullName
        let zid = zoneId
        do {
            var removed = 0
            if overwrite {
                let existing: [DNSRecord] = try await ctx.c.get(
                    "zones/\(zid)/dns_records", query: ["name": name, "per_page": "100"])
                for rec in existing where rec.type == "A" || rec.type == "AAAA" {
                    try await ctx.c.delete("zones/\(zid)/dns_records/\(rec.id)")
                    removed += 1
                }
            }
            var added = 0
            for ip in picks {
                let body = DNSBody(type: ip.contains(":") ? "AAAA" : "A", name: name,
                                   content: ip, ttl: ttl, proxied: proxied)
                try await ctx.c.send("POST", "zones/\(zid)/dns_records", json: body)
                added += 1
            }
            message = "已写入 \(added) 条记录到 \(name)" + (removed > 0 ? "，删除旧记录 \(removed) 条" : "")
        } catch { self.error = error.localizedDescription }
    }
}
