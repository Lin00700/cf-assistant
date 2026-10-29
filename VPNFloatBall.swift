import SwiftUI

/// 首页悬浮球。仅 VPN 包显示。未连接是圆形开关；连接后变成实时网速球。
struct VPNFloatBall: View {
    var container: CGSize
    var openVPN: () -> Void

    @ObservedObject private var vpn = VPNManager.shared
    @ObservedObject private var store = ProxyStore.shared
    @ObservedObject private var traffic = VPNTraffic.shared

    @AppStorage("vpn.ball.trailing") private var trailing = true
    @AppStorage("vpn.ball.yFraction") private var yFraction = 0.68

    @State private var drag = CGSize.zero
    @State private var spin = 0.0

    var body: some View {
        ball
            .offset(x: origin.x + drag.width, y: origin.y + drag.height)
            .gesture(dragGesture)
            .onTapGesture { toggle() }
            .onLongPressGesture(minimumDuration: 0.45) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                openVPN()
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: trailing)
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: yFraction)
            .animation(.easeInOut(duration: 0.2), value: vpn.isConnected)
            .task { await vpn.load() }
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var ball: some View {
        if vpn.isConnected {
            speedBall
        } else {
            toggleBall
        }
    }

    private var toggleBall: some View {
        ZStack {
            Circle().fill(InkTheme.paper)
            Circle().stroke(InkTheme.ink.opacity(0.5), lineWidth: 1.4)
            if isBusy {
                Circle()
                    .trim(from: 0.08, to: 0.34)
                    .stroke(InkTheme.seal, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .rotationEffect(.degrees(spin))
                    .onAppear {
                        withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                            spin = 360
                        }
                    }
            } else {
                Image(systemName: "seal")
                    .font(.title3)
                    .foregroundColor(InkTheme.ink)
            }
        }
        .frame(width: 56, height: 56)
        .shadow(color: InkTheme.ink.opacity(0.16), radius: 6, y: 3)
        .contentShape(Circle())
    }

    private var speedBall: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("↑ \(VPNTraffic.formatRate(traffic.uploadRate))")
            Text("↓ \(VPNTraffic.formatRate(traffic.downloadRate))")
        }
        .font(.caption2.monospacedDigit().weight(.semibold))
        .foregroundColor(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(InkTheme.seal)
                .shadow(color: InkTheme.seal.opacity(0.6), radius: 10, y: 2)
        )
        .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.35), lineWidth: 1))
        .fixedSize()
        .contentShape(Capsule())
    }

    private var isBusy: Bool {
        vpn.status == .connecting || vpn.status == .reasserting || vpn.status == .disconnecting
    }

    private var ballSize: CGSize {
        vpn.isConnected ? CGSize(width: 124, height: 44) : CGSize(width: 56, height: 56)
    }

    /// Top-leading offset of the ball inside the tab view.
    private var origin: CGPoint {
        let margin: CGFloat = 12
        let minY: CGFloat = 72
        let maxY = max(minY, container.height - ballSize.height - 12)
        let y = min(max(minY, CGFloat(yFraction) * container.height - ballSize.height / 2), maxY)
        let x = trailing ? max(margin, container.width - ballSize.width - margin) : margin
        return CGPoint(x: x, y: y)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in drag = value.translation }
            .onEnded { value in
                let centerX = origin.x + ballSize.width / 2 + value.translation.width
                trailing = centerX > container.width / 2
                let minY: CGFloat = 72
                let maxY = max(minY, container.height - ballSize.height - 12)
                let y = min(max(minY, origin.y + value.translation.height), maxY)
                if container.height > 1 {
                    yFraction = Double((y + ballSize.height / 2) / container.height)
                }
                drag = .zero
            }
    }

    private func toggle() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let turnOn = !vpn.isActive
        Task { await vpn.set(on: turnOn, store: store) }
    }

    private var accessibilityText: String {
        if vpn.isConnected {
            return "网速 上传 \(VPNTraffic.formatRate(traffic.uploadRate)) 下载 \(VPNTraffic.formatRate(traffic.downloadRate))"
        }
        return vpn.isActive ? "断开 VPN" : "连接 VPN"
    }
}
