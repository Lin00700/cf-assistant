import SwiftUI
import PhotosUI

struct AppBackdropView: View {
    @AppStorage("appearance.wallpaperFilename") private var wallpaperFilename = ""
    @AppStorage("appearance.wallpaperWash") private var wallpaperWash = 0.68
    @AppStorage("appearance.chineseSkin") private var skinRaw = ChineseSkin.ink.rawValue

    private var skin: ChineseSkin {
        ChineseSkin(rawValue: skinRaw) ?? .ink
    }

    var body: some View {
        ZStack {
            InkWashBackground()
            if let ui = WallpaperStore.load(filename: wallpaperFilename) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                Color(skin.isDark ? .black : .white).opacity(wallpaperWash).ignoresSafeArea()
            }
        }
        .allowsHitTesting(false)
        .id(skinRaw)
    }
}

enum WallpaperStore {
    private static var dir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func save(_ image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let name = UUID().uuidString + ".jpg"
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func load(filename: String) -> UIImage? {
        guard !filename.isEmpty else { return nil }
        let url = dir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func delete(filename: String) {
        guard !filename.isEmpty else { return }
        let url = dir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("appearance.wallpaperFilename") private var wallpaperFilename = ""
    @AppStorage("appearance.wallpaperWash") private var wallpaperWash = 0.68
    @AppStorage("appearance.chineseSkin") private var skinRaw = ChineseSkin.ink.rawValue
    @State private var pickerItem: PhotosPickerItem?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(ChineseSkin.allCases) { s in
                    Button {
                        skinRaw = s.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(s.accent)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                            Text(s.title)
                                .foregroundColor(.primary)
                            Spacer()
                            if skinRaw == s.rawValue {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(s.accent)
                            }
                        }
                    }
                }
            } header: {
                Text("中国风主题")
            } footer: {
                Text("水墨跟随系统深色模式，米纸和墨色都会保持可读。墨夜固定为深色。强调色是朱砂红。青绿、朱砂、月夜仍然可用。")
            }

            Section(footer: Text("自定义壁纸会显示在所有页面背后。")) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(wallpaperFilename.isEmpty ? "从相册选择壁纸" : "更换壁纸", systemImage: "photo.on.rectangle")
                }
                if !wallpaperFilename.isEmpty {
                    Button(role: .destructive) {
                        WallpaperStore.delete(filename: wallpaperFilename)
                        wallpaperFilename = ""
                    } label: {
                        Label("移除壁纸", systemImage: "trash")
                    }
                }
            }
            if !wallpaperFilename.isEmpty {
                Section("遮罩浓度") {
                    Slider(value: $wallpaperWash, in: 0.2...0.9, step: 0.02)
                }
            }
        }
        .navigationTitle("背景与主题")
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .errorAlert($error)
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: data) else {
                error = "无法读取图片"
                return
            }
            if !wallpaperFilename.isEmpty {
                WallpaperStore.delete(filename: wallpaperFilename)
            }
            guard let name = WallpaperStore.save(img) else {
                error = "保存失败"
                return
            }
            wallpaperFilename = name
        } catch {
            self.error = error.localizedDescription
        }
    }
}
