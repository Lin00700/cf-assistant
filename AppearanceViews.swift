import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import UIKit

extension View {
    func chineseNavigationChrome() -> some View {
        self.toolbarBackground(InkTheme.paper.opacity(0.96), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(InkTheme.chromeScheme, for: .navigationBar)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
    }
}

// MARK: - 宣纸与水墨背景

struct AppBackdropView: View {
    @AppStorage("appearance.wallpaperFilename") private var wallpaperFilename = ""
    @AppStorage("appearance.wallpaperWash") private var wallpaperWash = 0.68
    @ObservedObject private var theme = ThemeStore.shared

    private var skin: ChineseSkin { theme.skin }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                paperBackdrop(size: proxy.size)

                if let url = WallpaperStore.url(for: wallpaperFilename) {
                    WallpaperMediaView(url: url)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .overlay(washColor.opacity(wallpaperWash))
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(.easeInOut(duration: 0.28), value: wallpaperFilename)
            .animation(.easeInOut(duration: 0.35), value: theme.skin.rawValue)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var washColor: Color {
        skin == .moon ? Color(red: 0.08, green: 0.10, blue: 0.14) : Color(.systemBackground)
    }

    @ViewBuilder
    private func paperBackdrop(size: CGSize) -> some View {
        ZStack {
            InkTheme.paperGradient

            switch skin {
            case .moon:
                RadialGradient(
                    colors: [Color(red: 0.18, green: 0.22, blue: 0.30).opacity(0.55), .clear],
                    center: .topTrailing, startRadius: 20, endRadius: size.width * 0.85
                )
            case .cyan:
                RadialGradient(
                    colors: [Color(red: 0.55, green: 0.72, blue: 0.68).opacity(0.22), .clear],
                    center: .topLeading, startRadius: 10, endRadius: size.width * 0.7
                )
            case .cinnabar:
                Circle()
                    .stroke(InkTheme.cinnabar.opacity(0.18), lineWidth: 1.5)
                    .frame(width: 120, height: 120)
                    .overlay(
                        Image(systemName: "seal")
                            .font(.system(size: 36))
                            .foregroundColor(InkTheme.cinnabar.opacity(0.22))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 28)
                    .padding(.top, 72)
                    .overlay(
                        Circle()
                        .stroke(InkTheme.cinnabar.opacity(0.10), lineWidth: 1)
                        .frame(width: 160, height: 160)
                        .overlay(Circle().stroke(InkTheme.cinnabar.opacity(0.05), lineWidth: 18).padding(19))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.trailing, 8)
                        .padding(.top, 52)
                    )
            case .ink:
                EmptyView()
            }

            RadialGradient(
                colors: [InkTheme.gold.opacity(skin == .moon ? 0.06 : 0.12), .clear],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: max(size.width, size.height) * 0.65
            )

            InkMountainShape()
                .fill(mountainColor)
                .frame(height: size.height * 0.28)
                .frame(maxHeight: .infinity, alignment: .bottom)
            InkMountainShape()
                .fill(mountainSoft)
                .frame(height: size.height * 0.20)
                .offset(x: size.width * 0.12)
                .frame(maxHeight: .infinity, alignment: .bottom)

            LinearGradient(
                colors: [.clear, InkTheme.paper.opacity(skin == .moon ? 0.35 : 0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: size.height * 0.35)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var mountainColor: Color {
        switch skin {
        case .ink: return InkTheme.pine.opacity(0.08)
        case .cyan: return Color(red: 0.25, green: 0.42, blue: 0.40).opacity(0.10)
        case .cinnabar: return Color(red: 0.45, green: 0.28, blue: 0.16).opacity(0.10)
        case .moon: return Color.white.opacity(0.05)
        }
    }

    private var mountainSoft: Color {
        switch skin {
        case .ink: return InkTheme.inkSoft.opacity(0.05)
        case .cyan: return Color(red: 0.30, green: 0.50, blue: 0.48).opacity(0.07)
        case .cinnabar: return InkTheme.gold.opacity(0.08)
        case .moon: return Color.white.opacity(0.03)
        }
    }
}

private struct InkMountainShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.maxY))
        p.addLine(to: CGPoint(x: 0, y: rect.height * 0.55))
        p.addCurve(to: CGPoint(x: rect.width * 0.35, y: rect.height * 0.25),
                   control1: CGPoint(x: rect.width * 0.12, y: rect.height * 0.5),
                   control2: CGPoint(x: rect.width * 0.22, y: rect.height * 0.22))
        p.addCurve(to: CGPoint(x: rect.width * 0.62, y: rect.height * 0.42),
                   control1: CGPoint(x: rect.width * 0.48, y: rect.height * 0.28),
                   control2: CGPoint(x: rect.width * 0.52, y: rect.height * 0.48))
        p.addCurve(to: CGPoint(x: rect.width, y: rect.height * 0.32),
                   control1: CGPoint(x: rect.width * 0.78, y: rect.height * 0.32),
                   control2: CGPoint(x: rect.width * 0.88, y: rect.height * 0.28))
        p.addLine(to: CGPoint(x: rect.width, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Wallpaper helpers

enum WallpaperStore {
    static var directory: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func url(for filename: String) -> URL? {
        guard !filename.isEmpty else { return nil }
        let u = directory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func save(data: Data, suggestedName: String) throws -> String {
        let ext = (suggestedName as NSString).pathExtension.lowercased()
        let safeExt = ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext) ? ext : "jpg"
        let name = "bg-\(UUID().uuidString).\(safeExt)"
        let dest = directory.appendingPathComponent(name)
        try data.write(to: dest, options: .atomic)
        return name
    }

    static func remove(_ filename: String) {
        guard let u = url(for: filename) else { return }
        try? FileManager.default.removeItem(at: u)
    }
}

struct WallpaperMediaView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if url.pathExtension.lowercased() == "gif",
           let data = try? Data(contentsOf: url),
           let source = CGImageSourceCreateWithData(data as CFData, nil) {
            uiView.image = UIImage.animatedImage(withAnimatedGIFData: data, source: source)
        } else {
            uiView.image = UIImage(contentsOfFile: url.path)
        }
    }
}

private extension UIImage {
    static func animatedImage(withAnimatedGIFData data: Data, source: CGImageSource) -> UIImage? {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(data: data) }
        var images: [UIImage] = []
        var duration: Double = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            images.append(UIImage(cgImage: cg))
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0.1
            duration += max(d, 0.02)
        }
        return UIImage.animatedImage(with: images, duration: duration)
    }
}

// MARK: - 外观设置

struct AppearanceSettingsView: View {
    @AppStorage("appearance.wallpaperFilename") private var wallpaperFilename = ""
    @AppStorage("appearance.wallpaperWash") private var wallpaperWash = 0.68
    @ObservedObject private var theme = ThemeStore.shared
    @State private var selectedItem: PhotosPickerItem?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var skinRaw: String { theme.skin.rawValue }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preview

                VStack(alignment: .leading, spacing: 12) {
                    Label("中国风皮肤", systemImage: "paintpalette")
                        .font(.headline)
                        .foregroundColor(InkTheme.ink)

                    ForEach(ChineseSkin.allCases) { skin in
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                ThemeStore.shared.setSkin(skin)
                            }
                        } label: {
                            HStack(spacing: 14) {
                                skinSwatch(skin)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skin.title)
                                        .font(.system(.body, design: .serif).weight(.medium))
                                        .foregroundColor(InkTheme.ink)
                                    Text(skin.subtitle)
                                        .font(.caption)
                                        .foregroundColor(InkTheme.inkSoft)
                                }
                                Spacer()
                                if skinRaw == skin.rawValue {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(InkTheme.cinnabar)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(skinRaw == skin.rawValue
                                          ? InkTheme.cinnabar.opacity(0.08)
                                          : InkTheme.paper.opacity(0.55))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(skinRaw == skin.rawValue
                                            ? InkTheme.cinnabar.opacity(0.45)
                                            : InkTheme.gold.opacity(0.15), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .background(InkTheme.paper.opacity(0.86))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(InkTheme.gold.opacity(0.20), lineWidth: 1))

                VStack(alignment: .leading, spacing: 12) {
                    Label("自定义背景图", systemImage: "photo")
                        .font(.headline)
                        .foregroundColor(InkTheme.ink)
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        Text(isLoading ? "导入中…" : (wallpaperFilename.isEmpty ? "从相册选择" : "更换图片"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(InkTheme.cinnabar)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(isLoading)
                    if !wallpaperFilename.isEmpty {
                        Button(role: .destructive, action: clearWallpaper) {
                            Label("恢复主题默认背景", systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("图片淡化", systemImage: "sun.max")
                            .foregroundColor(InkTheme.ink)
                        Spacer()
                        Text("\(Int(wallpaperWash * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(InkTheme.inkSoft)
                    }
                    Slider(value: $wallpaperWash, in: 0.35...0.90, step: 0.01)
                        .tint(InkTheme.cinnabar)
                    Text("淡化越高，背景越浅，文字更清晰。")
                        .font(.caption)
                        .foregroundColor(InkTheme.inkSoft)
                }
                .padding(16)
                .background(InkTheme.paper.opacity(0.86))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(InkTheme.gold.opacity(0.20), lineWidth: 1))

                Label("支持常见照片格式与 GIF。图片只保存在本机。切换皮肤后界面会立即刷新。", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundColor(InkTheme.inkSoft)
                    .padding(.horizontal, 2)
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle("背景与主题")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedItem) { item in
            guard let item else { return }
            Task { await importWallpaper(from: item) }
        }
        .alert("背景图片", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func skinSwatch(_ skin: ChineseSkin) -> some View {
        let colors: [Color] = {
            switch skin {
            case .ink: return [Color(red: 0.97, green: 0.94, blue: 0.88), Color(red: 0.72, green: 0.18, blue: 0.16), Color(red: 0.22, green: 0.42, blue: 0.35)]
            case .cyan: return [Color(red: 0.90, green: 0.95, blue: 0.93), Color(red: 0.30, green: 0.55, blue: 0.52), Color(red: 0.55, green: 0.22, blue: 0.18)]
            case .cinnabar: return [Color(red: 0.98, green: 0.93, blue: 0.85), Color(red: 0.78, green: 0.14, blue: 0.12), Color(red: 0.82, green: 0.62, blue: 0.20)]
            case .moon: return [Color(red: 0.12, green: 0.14, blue: 0.18), Color(red: 0.82, green: 0.32, blue: 0.28), Color(red: 0.78, green: 0.68, blue: 0.38)]
            }
        }()
        return HStack(spacing: 0) {
            ForEach(0..<colors.count, id: \.self) { i in
                colors[i].frame(width: 18, height: 36)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.black.opacity(0.08), lineWidth: 0.5))
    }

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            AppBackdropView()
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            LinearGradient(colors: [.clear, Color.black.opacity(skinRaw == ChineseSkin.moon.rawValue ? 0.45 : 0.28)], startPoint: .center, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text((ChineseSkin(rawValue: skinRaw) ?? .ink).title + " · 主题预览")
                    .font(.system(.headline, design: .serif))
                    .foregroundColor(.white)
            }
            .padding(16)
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(InkTheme.gold.opacity(0.3), lineWidth: 1))
    }

    private func importWallpaper(from item: PhotosPickerItem) async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "无法读取图片"
                return
            }
            let name = try WallpaperStore.save(data: data, suggestedName: "photo.jpg")
            if !wallpaperFilename.isEmpty { WallpaperStore.remove(wallpaperFilename) }
            wallpaperFilename = name
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearWallpaper() {
        if !wallpaperFilename.isEmpty {
            WallpaperStore.remove(wallpaperFilename)
            wallpaperFilename = ""
        }
    }
}
