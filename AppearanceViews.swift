import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import UIKit

struct AppBackdropView: View {
    @AppStorage("appearance.wallpaperFilename") private var wallpaperFilename = ""
    @AppStorage("appearance.wallpaperWash") private var wallpaperWash = 0.68
    @AppStorage("appearance.chineseSkin") private var skinRaw = ChineseSkin.ink.rawValue

    private var skin: ChineseSkin { ChineseSkin(rawValue: skinRaw) ?? .ink }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ThemeBackdropArtwork(skin: skin, size: geometry.size)
                if let url = WallpaperStore.url(for: wallpaperFilename) {
                    WallpaperMediaView(url: url)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .overlay(washColor.opacity(wallpaperWash))
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.easeInOut(duration: 0.28), value: wallpaperFilename)
            .animation(.easeInOut(duration: 0.35), value: skinRaw)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var washColor: Color {
        skin.isDark ? Color(red: 0.08, green: 0.10, blue: 0.14) : Color(.systemBackground)
    }
}

private struct ThemeBackdropArtwork: View {
    let skin: ChineseSkin
    let size: CGSize

    var body: some View {
        ZStack {
            skin.paperGradient
            themeDecoration
            RadialGradient(
                colors: [skin.gold.opacity(skin.isDark ? 0.06 : 0.12), .clear],
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
                colors: [.clear, skin.paper.opacity(skin.isDark ? 0.35 : 0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: size.height * 0.35)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    @ViewBuilder
    private var themeDecoration: some View {
        switch skin {
        case .moon:
            RadialGradient(
                colors: [Color(red: 0.18, green: 0.22, blue: 0.30).opacity(0.55), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: size.width * 0.85
            )
        case .cyan:
            RadialGradient(
                colors: [Color(red: 0.55, green: 0.72, blue: 0.68).opacity(0.22), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: size.width * 0.7
            )
        case .cinnabar:
            CinnabarSealArtwork()
        case .ink:
            EmptyView()
        }
    }

    private var mountainColor: Color {
        switch skin {
        case .ink: return skin.pine.opacity(0.08)
        case .cyan: return Color(red: 0.25, green: 0.42, blue: 0.40).opacity(0.10)
        case .cinnabar: return Color(red: 0.45, green: 0.28, blue: 0.16).opacity(0.10)
        case .moon: return Color.white.opacity(0.05)
        }
    }

    private var mountainSoft: Color {
        switch skin {
        case .ink: return skin.inkSoft.opacity(0.05)
        case .cyan: return Color(red: 0.30, green: 0.50, blue: 0.48).opacity(0.07)
        case .cinnabar: return skin.gold.opacity(0.08)
        case .moon: return Color.white.opacity(0.03)
        }
    }
}

private struct CinnabarSealArtwork: View {
    var body: some View {
        Circle()
            .stroke(InkTheme.cinnabar.opacity(0.18), lineWidth: 1.5)
            .frame(width: 120, height: 120)
            .overlay {
                Image(systemName: "seal")
                    .font(.system(size: 36))
                    .foregroundColor(InkTheme.cinnabar.opacity(0.22))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 28)
            .padding(.top, 72)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .stroke(InkTheme.cinnabar.opacity(0.10), lineWidth: 1)
                    .frame(width: 160, height: 160)
                    .overlay {
                        Circle()
                            .stroke(InkTheme.cinnabar.opacity(0.05), lineWidth: 18)
                            .padding(19)
                    }
                    .padding(.trailing, 8)
                    .padding(.top, 52)
            }
    }
}

private struct InkMountainShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.maxY))
        path.addLine(to: CGPoint(x: 0, y: rect.height * 0.55))
        path.addCurve(
            to: CGPoint(x: rect.width * 0.35, y: rect.height * 0.25),
            control1: CGPoint(x: rect.width * 0.12, y: rect.height * 0.5),
            control2: CGPoint(x: rect.width * 0.22, y: rect.height * 0.22)
        )
        path.addCurve(
            to: CGPoint(x: rect.width * 0.62, y: rect.height * 0.42),
            control1: CGPoint(x: rect.width * 0.48, y: rect.height * 0.28),
            control2: CGPoint(x: rect.width * 0.52, y: rect.height * 0.48)
        )
        path.addCurve(
            to: CGPoint(x: rect.width, y: rect.height * 0.32),
            control1: CGPoint(x: rect.width * 0.78, y: rect.height * 0.32),
            control2: CGPoint(x: rect.width * 0.88, y: rect.height * 0.28)
        )
        path.addLine(to: CGPoint(x: rect.width, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

enum WallpaperStore {
    static var directory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func url(for filename: String) -> URL? {
        guard !filename.isEmpty else { return nil }
        let fileURL = directory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    static func save(data: Data, suggestedName: String) throws -> String {
        let extensionName = (suggestedName as NSString).pathExtension.lowercased()
        let allowed = ["jpg", "jpeg", "png", "heic", "gif", "webp"]
        let safeExtension = allowed.contains(extensionName) ? extensionName : "jpg"
        let filename = "bg-\(UUID().uuidString).\(safeExtension)"
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        return filename
    }

    static func remove(_ filename: String) {
        guard let fileURL = url(for: filename) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private struct WallpaperMediaView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .clear
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        if url.pathExtension.lowercased() == "gif",
           let data = try? Data(contentsOf: url) {
            imageView.image = UIImage.animatedGIF(data: data)
        } else {
            imageView.image = UIImage(contentsOfFile: url.path)
        }
    }
}

private extension UIImage {
    static func animatedGIF(data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else {
            return UIImage(data: data)
        }

        var frames: [UIImage] = []
        var duration: Double = 0
        for index in 0..<frameCount {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: image))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let frameDelay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0.1
            duration += max(frameDelay, 0.02)
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: duration) ?? frames.first
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("appearance.wallpaperFilename") private var wallpaperFilename = ""
    @AppStorage("appearance.wallpaperWash") private var wallpaperWash = 0.68
    @AppStorage("appearance.chineseSkin") private var skinRaw = ChineseSkin.ink.rawValue
    @State private var selectedItem: PhotosPickerItem?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var selectedSkin: ChineseSkin { ChineseSkin(rawValue: skinRaw) ?? .ink }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AppearancePreviewCard(skin: selectedSkin)
                SkinSelectionCard(selection: $skinRaw)
                WallpaperSelectionCard(
                    filename: wallpaperFilename,
                    selectedItem: $selectedItem,
                    isLoading: isLoading,
                    onClear: clearWallpaper
                )
                WallpaperWashCard(wash: $wallpaperWash, skin: selectedSkin)
                Label("支持常见照片格式与 GIF。图片只保存在本机，切换皮肤后界面会立即刷新。",
                      systemImage: "lock.shield")
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
        .alert("背景图片", isPresented: errorAlertPresented) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorAlertPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func importWallpaper(from item: PhotosPickerItem) async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "无法读取图片"
                return
            }
            let extensionName = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            let filename = try WallpaperStore.save(data: data, suggestedName: "photo.\(extensionName)")
            if !wallpaperFilename.isEmpty { WallpaperStore.remove(wallpaperFilename) }
            wallpaperFilename = filename
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

private struct AppearancePreviewCard: View {
    let skin: ChineseSkin

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AppBackdropView()
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            LinearGradient(
                colors: [.clear, Color.black.opacity(skin.isDark ? 0.45 : 0.28)],
                startPoint: .center,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("\(skin.title) · 主题预览")
                .font(.system(.headline, design: .serif))
                .foregroundColor(.white)
                .padding(16)
        }
        .frame(height: 150)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(InkTheme.gold.opacity(0.3), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct SkinSelectionCard: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("中国风皮肤", systemImage: "paintpalette")
                .font(.headline)
                .foregroundColor(InkTheme.ink)
            ForEach(ChineseSkin.allCases) { skin in
                SkinChoiceButton(
                    skin: skin,
                    isSelected: selection == skin.rawValue,
                    onSelect: { selection = skin.rawValue }
                )
            }
        }
        .padding(16)
        .background(InkTheme.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(InkTheme.gold.opacity(0.2), lineWidth: 1)
        }
    }
}

private struct SkinChoiceButton: View {
    let skin: ChineseSkin
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                SkinSwatch(skin: skin)
                VStack(alignment: .leading, spacing: 2) {
                    Text(skin.title)
                        .font(.system(.body, design: .serif).weight(.medium))
                        .foregroundColor(InkTheme.ink)
                    Text(skin.subtitle)
                        .font(.caption)
                        .foregroundColor(InkTheme.inkSoft)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(skin.accent)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? skin.accent.opacity(0.08) : skin.paper.opacity(0.55))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? skin.accent.opacity(0.45) : skin.gold.opacity(0.15), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SkinSwatch: View {
    let skin: ChineseSkin

    var body: some View {
        HStack(spacing: 0) {
            skin.paper.frame(width: 18, height: 36)
            skin.accent.frame(width: 18, height: 36)
            skin.pine.frame(width: 18, height: 36)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        }
    }
}

private struct WallpaperSelectionCard: View {
    let filename: String
    @Binding var selectedItem: PhotosPickerItem?
    let isLoading: Bool
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("自定义背景图", systemImage: "photo")
                .font(.headline)
                .foregroundColor(InkTheme.ink)
            PhotosPicker(selection: $selectedItem, matching: .images) {
                Text(isLoading ? "导入中…" : (filename.isEmpty ? "从相册选择" : "更换图片"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(InkTheme.cinnabar)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(isLoading)
            if !filename.isEmpty {
                Button(role: .destructive, action: onClear) {
                    Label("恢复主题默认背景", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(InkTheme.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(InkTheme.gold.opacity(0.2), lineWidth: 1)
        }
    }
}

private struct WallpaperWashCard: View {
    @Binding var wash: Double
    let skin: ChineseSkin

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("图片淡化", systemImage: "sun.max")
                    .foregroundColor(InkTheme.ink)
                Spacer()
                Text("\(Int(wash * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(InkTheme.inkSoft)
            }
            Slider(value: $wash, in: 0.35...0.90, step: 0.01)
                .tint(skin.accent)
            Text("淡化越高，背景越浅，文字更清晰。")
                .font(.caption)
                .foregroundColor(InkTheme.inkSoft)
        }
        .padding(16)
        .background(InkTheme.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(InkTheme.gold.opacity(0.2), lineWidth: 1)
        }
    }
}
