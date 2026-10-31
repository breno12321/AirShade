import SwiftUI

struct SetupView: View {
    @Bindable var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                OnboardingView(model: model)
                GroupBox("Your screens & comfort zone") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Screen layout", selection: Binding(get: { model.screenLayout }, set: model.changeLayout)) {
                            Text("One screen").tag("single")
                            Text("Second on left").tag("left")
                            Text("Second on right").tag("right")
                        }.pickerStyle(.segmented)
                        ScreenZoneDiagram(secondYaw: model.displaySecondYaw, threshold: model.threshold,
                                          transition: model.transition, headYaw: model.displayHeadYaw,
                                          pitch: model.engine.vertical, live: model.isEnabled && model.hasFreshMotion)
                        Toggle("Reverse left / right tracking", isOn: Binding(
                            get: { model.reverseHorizontalTracking }, set: { model.reverseHorizontalTracking = $0 }))
                        Text("The pointer should follow your head: turn right and it moves right. Two-screen calibration also detects this direction automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.screenLayout != "single" {
                            setting("Angle between screens", value: $model.screenSeparation, range: 5...90, suffix: "°")
                            Text("The space between your screens stays clear. The comfort margin starts beyond the outer screens; vertical tolerance stays unchanged.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("1. Capture main screen", action: { model.captureScreen(main: true) })
                                Button("2. Capture \(model.screenLayout) screen", action: { model.captureScreen(main: false) })
                                    .disabled(!model.hasMainReference)
                            }.disabled(!model.hasFreshMotion || model.calibrationCountdown > 0)
                            Text(model.calibrationCountdown > 0 ? "\(model.layoutMessage)  \(model.calibrationCountdown)…" : model.layoutMessage)
                                .font(.callout).foregroundStyle(model.calibrationCountdown > 0 ? Color.orange : Color.secondary)
                            Text("Each capture gives you 3 seconds to turn your head. Setup pauses protection. Recalibrate if you move your displays.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        setting("Comfort margin beyond screens", value: $model.threshold, range: 2...30, suffix: "°")
                        setting("Additional angle to full cover", value: $model.transition, range: 5...30, suffix: "°")
                        setting("Blur strength", value: $model.blurStrength, range: 20...80, suffix: "")
                        Text("Blur strength applies to the next cover. A 3° return margin and a brief dwell prevent flicker.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                        if !model.loginError.isEmpty { Text(model.loginError).font(.caption).foregroundStyle(.orange) }
                    }.padding(12)
                }
                if let simulated = model.simulated { SimulationView(source: simulated) }
                VStack(alignment: .leading, spacing: 6) {
                    Text("⌃⌥⌘P  Enable / Pause     ⌃⌥⌘C  Recenter / Resume").font(.callout.monospaced())
                    Text(model.shortcutStatus).font(.caption).foregroundStyle(.secondary)
                    Text("Tracking loss keeps your screen covered until you resume. AirShade measures head direction, not physical presence. It is a visual privacy aid, not a screen lock.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Local only. No camera, uploads, analytics, or saved screenshots.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28)
        }.frame(width: 580, height: 740)
        .onAppear { model.refreshSetupStatus() }
    }
    private func setting(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(name); Spacer(); Text("\(Int(value.wrappedValue))\(suffix)").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: 1)
        }
    }
}

private struct SimulationView: View {
    let source: SimulatedMotion
    @State private var yaw = 0.0
    @State private var pitch = 0.0
    @State private var connected = true
    var body: some View {
        GroupBox("Development simulation — not real AirPods") {
            VStack {
                Slider(value: $yaw, in: -90...90) { Text("Yaw") }.onChange(of: yaw) { _, value in source.yaw = value }
                Slider(value: $pitch, in: -90...90) { Text("Pitch") }.onChange(of: pitch) { _, value in source.pitch = value }
                Toggle("Send motion samples", isOn: $connected).onChange(of: connected) { _, value in source.connected = value }
            }.padding(10)
        }
    }
}

/// A live, vector-rendered configuration image. All boundaries use the same degree
/// values as the motion engine; this is not a static illustration.
private struct ScreenZoneDiagram: View {
    let secondYaw: Double
    let threshold: Double
    let transition: Double
    let headYaw: Double
    let pitch: Double
    let live: Bool
    private var low: Double { min(0, secondYaw) - threshold }
    private var high: Double { max(0, secondYaw) + threshold }
    var body: some View {
        VStack(spacing: 8) {
            Canvas { context, size in
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.60)
                let radius = min(size.width / 2 - 28, size.height * 0.52)
                func point(_ degrees: Double, _ distance: Double) -> CGPoint {
                    let radians = degrees * .pi / 180
                    return CGPoint(x: origin.x + sin(radians) * distance,
                                   y: origin.y - cos(radians) * distance)
                }
                func sector(_ from: Double, _ to: Double, _ color: Color) {
                    let a = max(-130, from), b = min(130, to)
                    guard a < b else { return }
                    var path = Path(); path.move(to: origin)
                    for degree in stride(from: a, through: b, by: 1) { path.addLine(to: point(degree, radius)) }
                    path.addLine(to: point(b, radius)); path.closeSubpath()
                    context.fill(path, with: .color(color))
                }
                sector(-130, 130, .secondary.opacity(0.10))
                sector(low - transition, low, .orange.opacity(0.35))
                sector(high, high + transition, .orange.opacity(0.35))
                sector(low, high, .green.opacity(0.28))
                for boundary in [low, high] {
                    var line = Path(); line.move(to: origin); line.addLine(to: point(boundary, radius))
                    context.stroke(line, with: .color(.green), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                for (angle, name) in [(0.0, "Main"), (secondYaw, "Second")] {
                    if name == "Second" && secondYaw == 0 { continue }
                    let center = point(angle, radius - 28)
                    let monitor = CGRect(x: center.x - 19, y: center.y - 12, width: 38, height: 24)
                    context.fill(Path(roundedRect: monitor, cornerRadius: 4), with: .color(.primary.opacity(0.85)))
                    context.fill(Path(roundedRect: monitor.insetBy(dx: 3, dy: 3), cornerRadius: 2), with: .color(.cyan.opacity(0.8)))
                    context.draw(Text(name).font(.caption2.bold()), at: CGPoint(x: center.x, y: center.y + 23))
                }
                let marker = point(live ? min(125, max(-125, headYaw)) : 0, radius - 62)
                var arrow = Path(); arrow.move(to: origin); arrow.addLine(to: marker)
                context.stroke(arrow, with: .color(live ? .cyan : .secondary), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: marker.x - 5, y: marker.y - 5, width: 10, height: 10)), with: .color(.cyan))
                context.fill(Path(ellipseIn: CGRect(x: origin.x - 9, y: origin.y - 9, width: 18, height: 18)), with: .color(.primary))
                context.draw(Text("YOU").font(.system(size: 9, weight: .bold)), at: CGPoint(x: origin.x, y: origin.y + 19))
            }.frame(height: 260)
            HStack(spacing: 16) {
                Label("Clear", systemImage: "circle.fill").foregroundStyle(.green)
                Label("Transition", systemImage: "circle.fill").foregroundStyle(.orange)
                Label("Full cover", systemImage: "circle.fill").foregroundStyle(.secondary)
            }.font(.caption)
            Text("Clear sweep: \(Int(low.rounded()))° to +\(Int(high.rounded()))° · Full cover beyond \(Int((low - transition).rounded()))° / +\(Int((high + transition).rounded()))°")
                .font(.caption2).foregroundStyle(.secondary)
            Text(live ? "Live head: \(Int(headYaw))° sideways · \(Int(pitch))° vertically" : "Top-down preview · Enable protection to see your live head direction")
                .font(.caption).foregroundStyle(live ? Color.cyan : Color.secondary)
        }
        .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Screen layout preview. Clear horizontal range from \(Int(low)) to \(Int(high)) degrees. Vertical comfort margin \(Int(threshold)) degrees. \(live ? "Live head yaw \(Int(headYaw)) degrees." : "Protection paused.")")
    }
}
