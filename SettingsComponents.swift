import SwiftUI

extension JSONValue {
    var object: [String: JSONValue] {
        if case .object(let o) = self { return o }
        return [:]
    }
}

// MARK: - 变量编辑

enum VarKind: String, CaseIterable, Identifiable {
    case text, secret
    var id: String { rawValue }
    var title: String { self == .text ? "文本" : "机密" }
}

struct VarTarget: Identifiable {
    let id = UUID()
    let name: String?        // nil 表示新建
    let value: String
    let kind: VarKind
}

struct VariableEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let isEdit: Bool
    let allowSecret: Bool
    let onSave: (String, String, VarKind) async throws -> Void

    @State private var name: String
    @State private var value: String
    @State private var kind: VarKind
    @State private var saving = false
    @State private var error: String?

    init(isEdit: Bool, allowSecret: Bool, name: String = "", value: String = "",
         kind: VarKind = .text, onSave: @escaping (String, String, VarKind) async throws -> Void) {
        self.isEdit = isEdit
        self.allowSecret = allowSecret
        self.onSave = onSave
        _name = State(initialValue: name)
        _value = State(initialValue: value)
        _kind = State(initialValue: kind)
    }

    var body: some View {
        NavigationStack {
            Form {
                if allowSecret && !isEdit {
                    Picker("类型", selection: $kind) {
                        ForEach(VarKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    TextField("变量名，例如 API_KEY", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(isEdit)
                    if kind == .secret {
                        SecureField(isEdit ? "新的机密值" : "值", text: $value)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        TextField("值", text: $value, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .lineLimit(1...6)
                    }
                } footer: {
                    if kind == .secret { Text("机密保存后无法再查看，只能覆盖或删除。") }
                }
            }
            .navigationTitle(isEdit ? "编辑变量" : "添加变量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || value.isEmpty)
                }
            }
            .errorAlert($error)
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await onSave(name.trimmingCharacters(in: .whitespaces), value, kind)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - 域名输入

struct HostnameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let hint: String
    let onSubmit: (String) async throws -> Void

    @State private var host = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如 www.example.com", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text(hint)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "添加中…" : "添加") { Task { await submit() } }
                        .disabled(saving || host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .errorAlert($error)
        }
        .presentationDetents([.medium])
    }

    private func submit() async {
        saving = true
        defer { saving = false }
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        do {
            try await onSubmit(h)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
