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
    @AppStorage("appearance.chineseSkin") private var skinRaw = ChineseSkin.ink.rawValue

    private var skin: ChineseSkin { ChineseSkin(rawValue: skinRaw) ?? .ink }

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
            .animation(.easeInOut(duration: 0.35), value: skinRaw)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var washColor: Color {
        skin == .moon ? Color(red: 0.08, green: 0.10, blue: 0.14) : Color(.systemBackground)
    }

    private func paperBackdrop(size: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            InkTheme.paperGradient

            // 右上角朱印 / 月晕
            Group {
                switch skin {
                case .moon:
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.18), Color.white.opacity(0.04), .clear],
                                center: .center,
                                startRadius: 4,
                                endRadius: 90
                            )
                        )
                        .frame(width: 160, height: 160)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(x: 40, y: -30)
                case .cinnabar:
                    Circle()
                        .stroke(InkTheme.cinnabar.opacity(0.18), lineWidth: 1.5)
                        .frame(width: 120, height: 120)
                        .overlay(
                            Text("雲")
                                .font(.system(size: 36, weight: .medium, design: .serif))
                                .foregroundColor(InkTheme.cinnabar.opacity(0.22))
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(x: 28, y: -18)
                default:
                    Circle()
                        .stroke(InkTheme.cinnabar.opacity(0.10), lineWidth: 1)
                        .frame(width: 178, height: 178)
                        .overlay(Circle().stroke(InkTheme.cinnabar.opacity(0.05), lineWidth: 18).padding(19))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(x: 65, y: -42)
                }
            }

            // 金色光晕
            RadialGradient(
                colors: [InkTheme.gold.opacity(skin == .moon ? 0.06 : 0.12), .clear],
                center: .topTrailing,
                startRadius: 8,
                endRadius: size.width * 0.72
            )

            // 远山两层
            InkMountainShape()
                .fill(mountainPrimary)
                .frame(height: size.height * 0.26)
            InkMountainShape()
                .fill(mountainSecondary)
                .scaleEffect(x: -1, y: 1)
                .frame(height: size.height * 0.18)
                .offset(y: 14)

            // 底部淡雾
            LinearGradient(
                colors: [.clear, InkTheme.paper.opacity(skin == .moon ? 0.35 : 0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: size.height * 0.22)
        }
    }

    private var mountainPrimary: Color {
        switch skin {
        case .ink: return InkTheme.pine.opacity(0.08)
        case .cyan: return Color(red: 0.20, green: 0.45, blue: 0.40).opacity(0.14)
        case .cinnabar: return Color(red: 0.45, green: 0.28, blue: 0.16).opacity(0.10)
        case .moon: return Color.white.opacity(0.05)
        }
    }

    private var mountainSecondary: Color {
        switch skin {
        case .ink: return InkTheme.inkSoft.opacity(0.05)
        case .cyan: return Color(red: 0.25, green: 0.38, blue: 0.48).opacity(0.10)
        case .cinnabar: return InkTheme.gold.opacity(0.08)
        case .moon: return Color.white.opacity(0.03)
        }
    }
}

private struct InkMountainShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height * 0.78))
        path.addCurve(to: CGPoint(x: rect.width * 0.46, y: rect.height * 0.30),
                      control1: CGPoint(x: rect.width * 0.14, y: rect.height * 0.66),
                      control2: CGPoint(x: rect.width * 0.28, y: rect.height * 0.16))
        path.addCurve(to: CGPoint(x: rect.width, y: rect.height * 0.58),
                      control1: CGPoint(x: rect.width * 0.68, y: rect.height * 0.48),
                      control2: CGPoint(x: rect.width * 0.82, y: rect.height * 0.82))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

private struct WallpaperMediaView: View {
    let url: URL

    var body: some View {
        Group {
            if url.pathExtension.lowercased() == "gif" {
                AnimatedGIFView(url: url)
            } else if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
    }
}

private struct AnimatedGIFView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        guard view.accessibilityIdentifier != url.path else { return }
        view.accessibilityIdentifier = url.path
        view.image = Self.animatedImage(at: url)
    }

    private static func animatedImage(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return UIImage(cgImage: image)
        }

        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: cgImage))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let unclamped = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            let clamped = (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            duration += max(unclamped ?? clamped ?? 0.1, 0.04)
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
    }
}

// MARK: - 壁纸保存

private enum WallpaperStore {
    static func url(for filename: String) -> URL? {
        guard !filename.isEmpty,
              let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return directory.appendingPathComponent("CFAssistant", isDirectory: true).appendingPathComponent(filename)
    }

    static func save(_ data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let rawType = CGImageSourceGetType(source) else { throw WallpaperError.invalidImage }
        let typeIdentifier = rawType as String
        guard let type = UTType(typeIdentifier), type.conforms(to: .image) else { throw WallpaperError.invalidImage }

        let filename = "wallpaper-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "img")"
        guard let destination = url(for: filename) else { throw WallpaperError.cannotSave }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            var storedURL = destination
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? storedURL.setResourceValues(resourceValues)
            return filename
        } catch {
            throw WallpaperError.cannotSave
        }
    }

    static func remove(_ filename: String) {
        guard let file = url(for: filename) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}

private enum WallpaperError: LocalizedError {
    case invalidImage
    case cannotSave

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取这张图片，请换一张图片或 GIF 再试。"
        case .cannotSave: return "背景图片保存失败，请检查设备储存空间后重试。"
        }
    }
}

// MARK: - 外观设置

struct AppearanceSettingsView: View {
    @AppStorage("appearance.wallpaperFilename") private var wallpaperFilename = ""
    @AppStorage("appearance.wallpaperWash") private var wallpaperWash = 0.68
    @AppStorage("appearance.chineseSkin") private var skinRaw = ChineseSkin.ink.rawValue
    @State private var selectedItem: PhotosPickerItem?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var selectedSkin: ChineseSkin {
        get { ChineseSkin(rawValue: skinRaw) ?? .ink }
        set { skinRaw = newValue.rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preview

                // 中国风皮肤
                VStack(alignment: .leading, spacing: 12) {
                    Label("中国风皮肤", systemImage: "paintpalette")
                        .font(.headline)
                        .foregroundColor(InkTheme.ink)

                    ForEach(ChineseSkin.allCases) { skin in
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                skinRaw = skin.rawValue
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
                                    Image(systemName: "checkmark.seal.fill")
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

                VStack(spacing: 12) {
                    PhotosPicker(selection: $selectedItem, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
                        Label(isLoading ? "正在载入…" : "从相册选择图片或 GIF", systemImage: "photo.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .foregroundColor(.white)
                            .background(InkTheme.cinnabar)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

                Label("支持常见照片格式与 GIF。图片只保存在本机。皮肤切换后部分页面需返回再进即可完全刷新。", systemImage: "lock.shield")
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
            case .cyan: return [Color(red: 0.82, green: 0.92, blue: 0.88), Color(red: 0.18, green: 0.48, blue: 0.42), Color(red: 0.25, green: 0.40, blue: 0.50)]
            case .cinnabar: return [Color(red: 0.98, green: 0.93, blue: 0.85), Color(red: 0.78, green: 0.14, blue: 0.12), Color(red: 0.82, green: 0.62, blue: 0.20)]
            case .moon: return [Color(red: 0.12, green: 0.14, blue: 0.18), Color(red: 0.82, green: 0.32, blue: 0.28), Color(red: 0.78, green: 0.68, blue: 0.38)]
            }
        }()
        return HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                colors[i]
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.black.opacity(0.08), lineWidth: 0.5))
    }

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            AppBackdropView()
            LinearGradient(colors: [.clear, Color.black.opacity(skinRaw == ChineseSkin.moon.rawValue ? 0.45 : 0.28)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text("云起山水间")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                Text((ChineseSkin(rawValue: skinRaw) ?? .ink).title + " · 主题预览")
                    .font(.caption)
            }
            .foregroundColor(.white)
            .padding(16)
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(InkTheme.gold.opacity(0.3), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.12), radius: 14, y: 6)
    }

    @MainActor
    private func importWallpaper(from item: PhotosPickerItem) async {
        isLoading = true
        defer {
            isLoading = false
            selectedItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw WallpaperError.invalidImage
            }
            let filename = try WallpaperStore.save(data)
            let previous = wallpaperFilename
            wallpaperFilename = filename
            WallpaperStore.remove(previous)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearWallpaper() {
        WallpaperStore.remove(wallpaperFilename)
        wallpaperFilename = ""
        selectedItem = nil
    }
}
