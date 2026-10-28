import SwiftUI

enum InkChrome {
    static func apply() {
        let title = UIColor { trait in
            let skin = ChineseSkin.current
            let night = skin.isDark || (skin == .ink && trait.userInterfaceStyle == .dark)
            if skin == .moon && night {
                return UIColor(red: 0.90, green: 0.91, blue: 0.95, alpha: 1)
            }
            return night
                ? UIColor(red: 0.93, green: 0.91, blue: 0.86, alpha: 1)
                : UIColor(red: 0.15, green: 0.12, blue: 0.10, alpha: 1)
        }
        let paper = UIColor { trait in
            let skin = ChineseSkin.current
            let night = skin.isDark || (skin == .ink && trait.userInterfaceStyle == .dark)
            if skin == .moon {
                return UIColor(red: 0.12, green: 0.13, blue: 0.18, alpha: 1)
            }
            if night {
                return UIColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
            }
            switch skin {
            case .cyan: return UIColor(red: 0.93, green: 0.96, blue: 0.94, alpha: 1)
            case .cinnabar: return UIColor(red: 0.98, green: 0.94, blue: 0.90, alpha: 1)
            default: return UIColor(red: 0.965, green: 0.945, blue: 0.90, alpha: 1)
            }
        }
        let large = UIFont(name: "SongtiSC-Bold", size: 34) ?? UIFont.preferredFont(forTextStyle: .largeTitle)
        let inline = UIFont(name: "SongtiSC-Bold", size: 17) ?? UIFont.preferredFont(forTextStyle: .headline)

        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        edge.largeTitleTextAttributes = [.font: large, .foregroundColor: title]
        edge.titleTextAttributes = [.font: inline, .foregroundColor: title]
        edge.shadowColor = .clear

        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = paper
        bar.shadowColor = .clear
        bar.largeTitleTextAttributes = edge.largeTitleTextAttributes
        bar.titleTextAttributes = edge.titleTextAttributes

        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = edge
        UINavigationBar.appearance().compactAppearance = bar

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = paper
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

struct InkNavModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance.chineseSkin") private var skinRaw = ChineseSkin.ink.rawValue

    private var dark: Bool {
        let skin = ChineseSkin(rawValue: skinRaw) ?? .ink
        return skin.isDark || (skin == .ink && scheme == .dark)
    }

    func body(content: Content) -> some View {
        content
            .toolbarBackground(InkTheme.paper.opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(dark ? .dark : .light, for: .navigationBar)
    }
}

extension View {
    func chineseNavigationChrome() -> some View {
        modifier(InkNavModifier())
    }
}

struct SealMark: View {
    var text: String = "云助"
    var body: some View {
        Text(text)
            .font(.custom("SongtiSC-Bold", size: 13, relativeTo: .caption))
            .foregroundColor(InkTheme.seal)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(InkTheme.seal, lineWidth: 1.4))
            .rotationEffect(.degrees(-8))
            .accessibilityLabel("印章 \(text)")
    }
}

struct InkWashBackground: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance.chineseSkin") private var skinRaw = ChineseSkin.ink.rawValue

    private var dark: Bool {
        let skin = ChineseSkin(rawValue: skinRaw) ?? .ink
        return skin.isDark || (skin == .ink && scheme == .dark)
    }

    var body: some View {
        ZStack(alignment: .top) {
            InkTheme.paper.ignoresSafeArea()
            InkLandscape(dark: dark, prominent: false)
                .frame(height: 460)
                .mask(
                    LinearGradient(colors: [.black, .black.opacity(0.8), .clear],
                                   startPoint: .top, endPoint: .bottom)
                )
                .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }
}

struct InkBanner<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance.chineseSkin") private var skinRaw = ChineseSkin.ink.rawValue
    var height: CGFloat = 168
    @ViewBuilder var content: () -> Content

    private var dark: Bool {
        let skin = ChineseSkin(rawValue: skinRaw) ?? .ink
        return skin.isDark || (skin == .ink && scheme == .dark)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            InkTheme.paper
            InkLandscape(dark: dark, prominent: true)
            LinearGradient(colors: [.clear, InkTheme.paper.opacity(0.25)],
                           startPoint: .center, endPoint: .bottom)
            content().padding(16)
            VStack {
                HStack {
                    Spacer()
                    SealMark().padding(12)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(InkTheme.seal.opacity(0.35), lineWidth: 1)
        )
    }
}

struct InkLandscape: View {
    var dark: Bool
    var prominent: Bool

    var body: some View {
        Canvas { context, size in
            drawLandscape(&context, size: size, dark: dark, prominent: prominent)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private func drawLandscape(_ ctx: inout GraphicsContext, size: CGSize, dark: Bool, prominent: Bool) {
    let far = dark ? Color.white.opacity(0.10) : Color(red: 0.25, green: 0.22, blue: 0.20).opacity(0.16)
    let mid = dark ? Color.white.opacity(0.18) : Color(red: 0.18, green: 0.15, blue: 0.13).opacity(0.28)
    let near = dark ? Color.white.opacity(prominent ? 0.34 : 0.22) : Color(red: 0.12, green: 0.10, blue: 0.09).opacity(prominent ? 0.55 : 0.30)
    let ink = dark ? Color.white.opacity(0.72) : Color(red: 0.10, green: 0.08, blue: 0.07).opacity(0.86)

    mountain(&ctx, size, far, 0.62, [CGPoint(x: 0.12, y: 0.48), CGPoint(x: 0.28, y: 0.36),
                                      CGPoint(x: 0.46, y: 0.50), CGPoint(x: 0.66, y: 0.32),
                                      CGPoint(x: 0.84, y: 0.46), CGPoint(x: 1.0, y: 0.40)])
    mountain(&ctx, size, mid, 0.74, [CGPoint(x: 0.08, y: 0.58), CGPoint(x: 0.24, y: 0.44),
                                      CGPoint(x: 0.40, y: 0.60), CGPoint(x: 0.58, y: 0.42),
                                      CGPoint(x: 0.78, y: 0.56), CGPoint(x: 0.95, y: 0.48)])
    mountain(&ctx, size, near, 0.88, [CGPoint(x: 0.0, y: 0.78), CGPoint(x: 0.18, y: 0.62),
                                       CGPoint(x: 0.36, y: 0.76), CGPoint(x: 0.55, y: 0.58),
                                       CGPoint(x: 0.74, y: 0.72), CGPoint(x: 0.92, y: 0.64)])

    mist(&ctx, size, dark: dark)

    if prominent {
        pine(&ctx, CGPoint(x: size.width * 0.14, y: size.height * 0.92), scale: min(size.width, size.height) / 180, color: ink)
        plum(&ctx, CGPoint(x: size.width * 0.78, y: size.height * 0.78), scale: min(size.width, size.height) / 220, color: ink)
        crane(&ctx, CGPoint(x: size.width * 0.62, y: size.height * 0.28), scale: min(size.width, size.height) / 260, dark: dark)
    }
}

private func mountain(_ ctx: inout GraphicsContext, _ size: CGSize, _ color: Color, _ baseline: CGFloat, _ peaks: [CGPoint]) {
    var path = Path()
    path.move(to: CGPoint(x: 0, y: size.height))
    path.addLine(to: CGPoint(x: 0, y: baseline * size.height))
    var prev = CGPoint(x: 0, y: baseline * size.height)
    for pk in peaks {
        let pt = CGPoint(x: pk.x * size.width, y: pk.y * size.height)
        let ctrl = CGPoint(x: (prev.x + pt.x) / 2, y: min(prev.y, pt.y) - size.height * 0.03)
        path.addQuadCurve(to: pt, control: ctrl)
        prev = pt
    }
    path.addLine(to: CGPoint(x: size.width, y: baseline * size.height))
    path.addLine(to: CGPoint(x: size.width, y: size.height))
    path.closeSubpath()
    ctx.fill(path, with: .color(color))
}

private func mist(_ ctx: inout GraphicsContext, _ size: CGSize, dark: Bool) {
    let color = dark ? Color.white.opacity(0.06) : Color.white.opacity(0.45)
    let bands: [(CGFloat, CGFloat, CGFloat)] = [(0.22, 0.58, 0.18), (0.55, 0.70, 0.22), (0.10, 0.80, 0.16)]
    for band in bands {
        let rect = CGRect(x: size.width * band.0, y: size.height * band.1,
                          width: size.width * 0.55, height: size.height * band.2)
        ctx.fill(Path(ellipseIn: rect), with: .color(color))
    }
}

private func pine(_ ctx: inout GraphicsContext, _ origin: CGPoint, scale: CGFloat, color: Color) {
    var trunk = Path()
    trunk.move(to: origin)
    trunk.addLine(to: CGPoint(x: origin.x, y: origin.y - 78 * scale))
    ctx.stroke(trunk, with: .color(color), lineWidth: max(1.5, 2.2 * scale))
    for i in 0..<4 {
        let y = origin.y - (30 + CGFloat(i) * 16) * scale
        let half = (26 - CGFloat(i) * 5) * scale
        var tri = Path()
        tri.move(to: CGPoint(x: origin.x, y: y - 20 * scale))
        tri.addLine(to: CGPoint(x: origin.x - half, y: y))
        tri.addLine(to: CGPoint(x: origin.x + half, y: y))
        tri.closeSubpath()
        ctx.fill(tri, with: .color(color.opacity(0.92)))
    }
}

private func plum(_ ctx: inout GraphicsContext, _ origin: CGPoint, scale: CGFloat, color: Color) {
    var branch = Path()
    branch.move(to: CGPoint(x: origin.x + 70 * scale, y: origin.y + 20 * scale))
    branch.addQuadCurve(to: CGPoint(x: origin.x - 10 * scale, y: origin.y - 46 * scale),
                        control: CGPoint(x: origin.x + 20 * scale, y: origin.y + 10 * scale))
    ctx.stroke(branch, with: .color(color), style: StrokeStyle(lineWidth: max(1.2, 1.8 * scale), lineCap: .round))
    let blossoms: [CGPoint] = [CGPoint(x: 0, y: -46), CGPoint(x: 18, y: -28), CGPoint(x: 36, y: -8),
                               CGPoint(x: -8, y: -18), CGPoint(x: 48, y: 6)]
    for b in blossoms {
        let c = CGPoint(x: origin.x + b.x * scale, y: origin.y + b.y * scale)
        let r = 4.2 * scale
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                 with: .color(InkTheme.seal.opacity(0.9)))
    }
}

private func crane(_ ctx: inout GraphicsContext, _ origin: CGPoint, scale: CGFloat, dark: Bool) {
    let body = dark ? Color.white.opacity(0.85) : Color(red: 0.95, green: 0.95, blue: 0.93)
    let ink = dark ? Color.white.opacity(0.9) : Color(red: 0.12, green: 0.10, blue: 0.09)
    let rect = CGRect(x: origin.x, y: origin.y, width: 28 * scale, height: 10 * scale)
    ctx.fill(Path(ellipseIn: rect), with: .color(body))
    var neck = Path()
    neck.move(to: CGPoint(x: origin.x + 24 * scale, y: origin.y + 4 * scale))
    neck.addQuadCurve(to: CGPoint(x: origin.x + 40 * scale, y: origin.y - 16 * scale),
                      control: CGPoint(x: origin.x + 34 * scale, y: origin.y + 2 * scale))
    ctx.stroke(neck, with: .color(ink), style: StrokeStyle(lineWidth: max(1, 1.4 * scale), lineCap: .round))
    let head = CGRect(x: origin.x + 38 * scale, y: origin.y - 20 * scale, width: 5 * scale, height: 5 * scale)
    ctx.fill(Path(ellipseIn: head), with: .color(ink))
    ctx.fill(Path(ellipseIn: CGRect(x: origin.x + 41 * scale, y: origin.y - 24 * scale, width: 3 * scale, height: 4 * scale)),
             with: .color(InkTheme.seal))
    var wing = Path()
    wing.move(to: CGPoint(x: origin.x + 8 * scale, y: origin.y + 4 * scale))
    wing.addQuadCurve(to: CGPoint(x: origin.x - 16 * scale, y: origin.y - 8 * scale),
                      control: CGPoint(x: origin.x - 4 * scale, y: origin.y - 14 * scale))
    ctx.stroke(wing, with: .color(ink.opacity(0.8)), style: StrokeStyle(lineWidth: max(1, 1.3 * scale), lineCap: .round))
}
