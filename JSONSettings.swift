import SwiftUI

/// 单对象设置：Bot、DNSSEC、Argo、Cache Reserve 这类 GET 回来一个 JSON 对象的接口。
struct JSONSettingsView: View {
    @EnvironmentObject var session: Session
    let title: String
    let path: String
    var write: String = "PUT"
    var only: [String]? = nil
    var omit: [String] = ["id", "modified_on"]
    var footer: String = "保存会把当前表单写回接口。只读字段不会提交。"

    @State private var order: [String] = []
    @State private var modes: [String: String] = [:]
    @State private var bools: [String: Bool] = [:]
    @State private var texts: [String: String] = [:]
    @State private var numeric: Set<String> = []
    @State private var readonly: [(String, String)] = []
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Form {
            if order.isEmpty && loaded {
                Section { EmptyHint(text: "接口没有返回可编辑字段") }
            }
            Section {
                ForEach(order, id: \.self) { key in
                    field(key)
                }
            }
            if !readonly.isEmpty {
                Section("只读") {
                    ForEach(readonly, id: \.0) { row in
                        LabeledContent(row.0) {
                            Text(row.1).font(.footnote).textSelection(.enabled).multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            Section { Text(footer).font(.footnote) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if !loaded { ProgressView() } }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "保存中…" : "保存") { Task { await save() } }
                    .disabled(saving || !loaded)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .errorAlert($error)
    }

    @ViewBuilder
    private func field(_ key: String) -> some View {
        switch modes[key] {
        case "bool", "onOff", "active":
            Toggle(key, isOn: Binding(
                get: { bools[key] ?? false },
                set: { value in
                    var copy = bools
                    copy[key] = value
                    bools = copy
                }
            ))
        default:
            HStack {
                Text(key).lineLimit(1)
                Spacer()
                TextField("", text: Binding(
                    get: { texts[key] ?? "" },
                    set: { value in
                        var copy = texts
                        copy[key] = value
                        texts = copy
                    }
                ))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(numeric.contains(key) ? .numbersAndPunctuation : .default)
            }
        }
    }

    private func load() async {
        do {
            let value = try await session.ctx.c.resultValue("GET", path)
            apply(value)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func apply(_ value: JSONValue) {
        var nextOrder: [String] = []
        var nextModes: [String: String] = [:]
        var nextBools: [String: Bool] = [:]
        var nextTexts: [String: String] = [:]
        var nextNumeric: Set<String> = []
        var nextRead: [(String, String)] = []
        for key in value.object.keys.sorted() {
            let child = value[key] ?? .null
            if omit.contains(key) && only == nil {
                if let s = child.string { nextRead.append((key, s)) }
                continue
            }
            switch child {
            case .bool(let b):
                nextOrder.append(key)
                nextModes[key] = "bool"
                nextBools[key] = b
            case .int, .double:
                nextOrder.append(key)
                nextModes[key] = "text"
                nextTexts[key] = child.string ?? ""
                nextNumeric.insert(key)
            case .string(let s):
                nextOrder.append(key)
                if s == "on" || s == "off" {
                    nextModes[key] = "onOff"
                    nextBools[key] = s == "on"
                } else if s == "active" || s == "disabled" || s == "enabled" {
                    nextModes[key] = "active"
                    nextBools[key] = s == "active" || s == "enabled"
                } else {
                    nextModes[key] = "text"
                    nextTexts[key] = s
                }
            default:
                if !child.isNull {
                    nextRead.append((key, jsonPretty(child)))
                }
            }
        }
        order = nextOrder
        modes = nextModes
        bools = nextBools
        texts = nextTexts
        numeric = nextNumeric
        readonly = nextRead
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var body: [String: Any] = [:]
        let keys = only ?? order
        for key in keys {
            switch modes[key] {
            case "bool":
                body[key] = bools[key] ?? false
            case "onOff":
                body[key] = (bools[key] ?? false) ? "on" : "off"
            case "active":
                body[key] = (bools[key] ?? false) ? "active" : "disabled"
            default:
                let text = texts[key] ?? ""
                if numeric.contains(key) {
                    if let i = Int(text) { body[key] = i }
                    else if let d = Double(text) { body[key] = d }
                    else { body[key] = text }
                } else {
                    body[key] = text
                }
            }
        }
        do {
            _ = try await session.ctx.c.resultValue(write, path, body: try jsonBody(body))
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
