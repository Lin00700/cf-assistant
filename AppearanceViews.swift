import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import WebKit

struct AppBackdropView: View {
    @AppStorage("appearance.wallpaperFilename") private var wallpaperFilename = ""
    @AppStorage("appearance.wallpaperWash") private var wallpaperWash = 0.28
    @AppStorage("appearance.chineseSkin") private var skinRaw = ChineseSkin.ink.rawValue

    private var skin: ChineseSkin {
        ChineseSkin(rawValue: skinRaw) ?? .ink
    }

    var body: some View {
        ZStack {
            InkWashBackground()
            if WallpaperStore.fileURL(filename: wallpaperFilename) != nil {
                WallpaperWebView(filename: wallpaperFilename)
                    .ignoresSafeArea()
                Color(skin.isDark ? .black : .white)
                    .opacity(wallpaperWash)
                    .ignoresSafeArea()
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

    static func save(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return nil }
        let type = (CGImageSourceGetType(source) as String?) ?? UTType.jpeg.identifier
        let ext = UTType(type)?.preferredFilenameExtension ?? "jpg"
        let name = UUID().uuidString + "." + ext
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func fileURL(filename: String) -> URL? {
        guard !filename.isEmpty,
              URL(fileURLWithPath: filename).lastPathComponent == filename else { return nil }
        let url = dir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func delete(filename: String) {
        guard let url = fileURL(filename: filename) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

private struct WallpaperWebView: UIViewRepresentable {
    let filename: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        load(filename, into: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedFilename != filename else { return }
        load(filename, into: view, coordinator: context.coordinator)
    }

    private func load(_ filename: String, into view: WKWebView, coordinator: Coordinator) {
        guard let url = WallpaperStore.fileURL(filename: filename) else { return }
        let escapedName = url.lastPathComponent
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "'", with: "&#39;")
        let html = """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
        html, body { width:100%; height:100%; margin:0; padding:0; overflow:hidden; background:transparent; }
        img { position:fixed; inset:0; width:100vw; height:100vh; object-fit:cover; object-position:center; }
        </style></head><body><img src="\(escapedName)" alt=""></body></html>
        """
        view.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        coordinator.loadedFilename = filename
    }

    final class Coordinator {
        var loadedFilename = ""
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("appearance.wallpaperFilename") private var wallpaperFilename = ""
    @AppStorage("appearance.wallpaperWash") private var wallpaperWash = 0.28
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

            Section(footer: Text("支持静态图片和 GIF 动图，壁纸会铺满屏幕；超出屏幕比例的部分会裁切。页面内容仍可滚动和操作。")) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(wallpaperFilename.isEmpty ? "从相册选择壁纸" : "更换壁纸", systemImage: "photo.on.rectangle")
                }
                .preferredItemEncoding(.current)
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
                    Slider(value: $wallpaperWash, in: 0.0...0.75, step: 0.02)
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
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else {
                error = "无法读取图片"
                return
            }
            guard let name = WallpaperStore.save(data) else {
                error = "保存失败"
                return
            }
            let old = wallpaperFilename
            wallpaperFilename = name
            if !old.isEmpty { WallpaperStore.delete(filename: old) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
