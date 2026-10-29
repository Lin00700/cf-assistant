import SwiftUI
import SceneKit

enum GlobeStyle: String, CaseIterable, Identifiable {
    case night, ink, day
    var id: String { rawValue }
    var title: String {
        switch self {
        case .night: return "星空"
        case .ink: return "水墨"
        case .day: return "卫星"
        }
    }
    var assetName: String {
        switch self {
        case .night: return "EarthNight"
        case .ink: return "EarthInk"
        case .day: return "EarthDay"
        }
    }
    var background: UIColor {
        switch self {
        case .night: return UIColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)
        case .ink: return UIColor(red: 0.95, green: 0.93, blue: 0.88, alpha: 1)
        case .day: return UIColor(red: 0.03, green: 0.08, blue: 0.16, alpha: 1)
        }
    }
    var localUIColor: UIColor {
        self == .ink ? UIColor(red: 0.12, green: 0.10, blue: 0.09, alpha: 1) : .white
    }
}

struct GlobeSCN: UIViewRepresentable {
    @ObservedObject var model: VPNDashModel
    var style: GlobeStyle
    var paused: Bool
    var locate: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        context.coordinator.configure(view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.sync(view, model: model, style: style, paused: paused, locate: locate)
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            coordinator.timer?.invalidate()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let scene = SCNScene()
        let earth = SCNNode()
        var camera: SCNNode?
        var timer: Timer?
        weak var model: VPNDashModel?
        var arcKey = ""
        var styleID = ""
        var locateToken = -1
        weak var view: SCNView?

        func configure(_ view: SCNView) {
            self.view = view
            view.scene = scene
            view.allowsCameraControl = true
            view.antialiasingMode = .multisampling2X
            view.rendersContinuously = true
            view.isPlaying = true
            let sphere = SCNSphere(radius: 1)
            sphere.segmentCount = 64
            earth.geometry = sphere
            scene.rootNode.addChildNode(earth)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .omni
            key.light?.intensity = 700
            key.position = SCNVector3(1.6, 1.2, 2.4)
            scene.rootNode.addChildNode(key)

            let amb = SCNNode()
            amb.light = SCNLight()
            amb.light?.type = .ambient
            amb.light?.intensity = 280
            amb.name = "ambient"
            scene.rootNode.addChildNode(amb)

            let cam = SCNNode()
            cam.camera = SCNCamera()
            cam.camera?.fieldOfView = 42
            cam.camera?.zNear = 0.01
            cam.camera?.zFar = 30
            cam.position = SCNVector3(0, 0.12, 2.75)
            scene.rootNode.addChildNode(cam)
            view.pointOfView = cam
            camera = cam

            timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.projectLabels() }
            }
        }

        func sync(_ view: SCNView, model: VPNDashModel, style: GlobeStyle, paused: Bool, locate: Int) {
            self.model = model
            if styleID != style.rawValue {
                styleID = style.rawValue
                earth.geometry?.firstMaterial = material(style)
                view.backgroundColor = style.background
                scene.background.contents = style.background
                if let amb = scene.rootNode.childNode(withName: "ambient", recursively: false) {
                    amb.light?.intensity = style == .night ? 180 : 520
                }
            }
            let key = model.arcs.map { "\($0.id):\($0.count)" }.joined(separator: "|")
                + "|" + (model.origin?.ip ?? "")
            if key != arcKey {
                arcKey = key
                rebuild(style: style, arcs: model.arcs, origin: model.origin)
            }
            if paused {
                earth.removeAction(forKey: "spin")
            } else if earth.action(forKey: "spin") == nil {
                let spin = SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: -.pi * 2, z: 0, duration: 90))
                earth.runAction(spin, forKey: "spin")
            }
            if locate != locateToken {
                locateToken = locate
                if locate > 0, let origin = model.origin, let lat = origin.lat, let lon = origin.lon {
                    earth.removeAction(forKey: "spin")
                    earth.eulerAngles = SCNVector3(Float(lat * .pi / 180), Float(-lon * .pi / 180), 0)
                }
            }
        }

        private func material(_ style: GlobeStyle) -> SCNMaterial {
            let mat = SCNMaterial()
            mat.diffuse.contents = UIImage(named: style.assetName) ?? style.background
            mat.specular.contents = UIColor(white: 0.25, alpha: 1)
            mat.shininess = 0.08
            mat.isDoubleSided = false
            return mat
        }

        private func rebuild(style: GlobeStyle, arcs: [GlobeArc], origin: GeoFix?) {
            earth.childNode(withName: "arcs", recursively: false)?.removeFromParentNode()
            let holder = SCNNode()
            holder.name = "arcs"
            if let origin, let lat = origin.lat, let lon = origin.lon {
                holder.addChildNode(dot(lat: lat, lon: lon, color: style.localUIColor, radius: 0.028))
                for arc in arcs {
                    let pts = arcPoints(from: (lat, lon), to: (arc.lat, arc.lon))
                    let color: UIColor = arc.proxied ? .systemBlue : .systemOrange
                    for index in 0..<max(0, pts.count - 1) {
                        holder.addChildNode(link(pts[index], pts[index + 1], color: color))
                    }
                    holder.addChildNode(dot(lat: arc.lat, lon: arc.lon, color: color, radius: 0.02))
                }
            }
            earth.addChildNode(holder)
        }

        private func projectLabels() {
            guard let view, let model, let origin = model.origin, origin.lat != nil else {
                if model?.labels.isEmpty == false { model?.labels = [] }
                return
            }
            var next: [ScreenLabel] = []
            if let lat = origin.lat, let lon = origin.lon, let point = project(lat: lat, lon: lon, view: view) {
                next.append(ScreenLabel(id: "local", text: "本机", x: point.x, y: point.y))
            }
            for arc in model.arcs {
                if let point = project(lat: arc.lat, lon: arc.lon, view: view) {
                    let title = arc.count > 1 ? "\(arc.city) \(arc.count)" : arc.city
                    next.append(ScreenLabel(id: arc.id, text: title, x: point.x, y: point.y))
                }
            }
            if next != model.labels { model.labels = next }
        }

        private func project(lat: Double, lon: Double, view: SCNView) -> CGPoint? {
            let local = spherePoint(lat: lat, lon: lon, radius: 1.02)
            let world = earth.convertPosition(local, to: nil)
            guard let cam = view.pointOfView else { return nil }
            let camPos = cam.worldPosition
            let dx = camPos.x - world.x
            let dy = camPos.y - world.y
            let dz = camPos.z - world.z
            let facing = world.x * dx + world.y * dy + world.z * dz
            if facing <= 0 { return nil }
            let projected = view.projectPoint(world)
            let size = view.bounds.size
            if projected.x < 0 || projected.y < 0 || projected.x > Float(size.width) || projected.y > Float(size.height) {
                return nil
            }
            return CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
        }
    }
}

private func spherePoint(lat: Double, lon: Double, radius: Float) -> SCNVector3 {
    let la = Float(lat * .pi / 180)
    let lo = Float(lon * .pi / 180)
    return SCNVector3(radius * cos(la) * sin(lo), radius * sin(la), radius * cos(la) * cos(lo))
}

private func arcPoints(from: (Double, Double), to: (Double, Double)) -> [SCNVector3] {
    let a = spherePoint(lat: from.0, lon: from.1, radius: 1)
    let b = spherePoint(lat: to.0, lon: to.1, radius: 1)
    let segments = 18
    var points: [SCNVector3] = []
    for index in 0...segments {
        let t = Float(index) / Float(segments)
        var x = a.x + (b.x - a.x) * t
        var y = a.y + (b.y - a.y) * t
        var z = a.z + (b.z - a.z) * t
        let mag = max(0.0001, (x * x + y * y + z * z).squareRoot())
        let lift = (1 + 0.16 * sin(t * .pi))
        x = x / mag * lift
        y = y / mag * lift
        z = z / mag * lift
        points.append(SCNVector3(x, y, z))
    }
    return points
}

private func link(_ a: SCNVector3, _ b: SCNVector3, color: UIColor) -> SCNNode {
    let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
    let len = (dx * dx + dy * dy + dz * dz).squareRoot()
    let cyl = SCNCylinder(radius: 0.006, height: CGFloat(len))
    cyl.radialSegmentCount = 4
    let mat = SCNMaterial()
    mat.diffuse.contents = color
    mat.emission.contents = color
    cyl.materials = [mat]
    let node = SCNNode(geometry: cyl)
    node.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
    node.look(at: b, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
    return node
}

private func dot(lat: Double, lon: Double, color: UIColor, radius: CGFloat) -> SCNNode {
    let sphere = SCNSphere(radius: radius)
    let mat = SCNMaterial()
    mat.diffuse.contents = color
    mat.emission.contents = color
    sphere.materials = [mat]
    let node = SCNNode(geometry: sphere)
    node.position = spherePoint(lat: lat, lon: lon, radius: 1.02)
    return node
}

struct FlatEarthMap: View {
    var style: GlobeStyle
    var origin: GeoFix?
    var arcs: [GlobeArc]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Image(style.assetName)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                Canvas { context, _ in
                    guard let origin, let lat = origin.lat, let lon = origin.lon else { return }
                    let start = mapPoint(lat, lon, size)
                    var dot = Path(ellipseIn: CGRect(x: start.x - 4, y: start.y - 4, width: 8, height: 8))
                    context.fill(dot, with: .color(style == .ink ? Color(red: 0.12, green: 0.1, blue: 0.09) : .white))
                    for arc in arcs {
                        let end = mapPoint(arc.lat, arc.lon, size)
                        var path = Path()
                        path.move(to: start)
                        let mid = CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - 28)
                        path.addQuadCurve(to: end, control: mid)
                        context.stroke(path, with: .color(arc.proxied ? .blue : .orange), lineWidth: 1.4)
                        let mark = Path(ellipseIn: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7))
                        context.fill(mark, with: .color(arc.proxied ? .blue : .orange))
                    }
                }
                .allowsHitTesting(false)
                if let origin, let lat = origin.lat, let lon = origin.lon {
                    mapLabel("本机", mapPoint(lat, lon, size))
                }
                ForEach(arcs) { arc in
                    mapLabel(arc.count > 1 ? "\(arc.city) \(arc.count)" : arc.city, mapPoint(arc.lat, arc.lon, size))
                }
            }
        }
        .aspectRatio(2, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func mapLabel(_ text: String, _ point: CGPoint) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
            .position(x: point.x, y: max(12, point.y - 12))
    }
}

private func mapPoint(_ lat: Double, _ lon: Double, _ size: CGSize) -> CGPoint {
    CGPoint(x: (lon + 180) / 360 * size.width, y: (90 - lat) / 180 * size.height)
}
