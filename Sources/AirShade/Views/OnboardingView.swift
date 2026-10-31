import SwiftUI
import AppKit

struct OnboardingView: View {
    @Bindable var model: AppModel
    private var appIcon: NSImage? {
        Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().interpolation(.high).frame(width: 76, height: 76)
                } else {
                    Image(systemName: "eye.slash.circle.fill").font(.system(size: 54)).foregroundStyle(.cyan)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Welcome to AirShade").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("Your attention. Your privacy.").font(.callout).foregroundStyle(.secondary)
                    Label(model.stateTitle, systemImage: model.isEnabled ? "shield.lefthalf.filled" : "pause.circle")
                        .font(.caption.weight(.medium)).foregroundStyle(model.isEnabled ? Color.green : Color.secondary)
                }
            }
            HStack(spacing: 10) {
                Text(model.completedSetupSteps == 3 ? "You're all set" : "A few steps to a quieter screen")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(model.completedSetupSteps) of 3 ready").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Capsule().fill(index < model.completedSetupSteps ? Color.green : Color.secondary.opacity(0.18)).frame(height: 4)
                }
            }.accessibilityLabel("\(model.completedSetupSteps) of 3 setup steps ready")
            VStack(spacing: 10) {
                SetupStepCard(number: "01", symbol: "airpods", title: "Connect your AirPods",
                              complete: model.motionAllowed, badge: model.motionAllowed ? "Permission granted" : (model.motionDenied ? "Access needed" : "Motion access")) {
                    if model.simulated != nil {
                        Text("Simulation mode · no real headphone connection").foregroundStyle(.orange)
                    } else if model.motionAllowed {
                        Label(model.hasFreshMotion ? "Connected · live head tracking" : "Authorized · waiting for your AirPods",
                              systemImage: model.hasFreshMotion ? "waveform" : "headphones")
                            .foregroundStyle(model.hasFreshMotion ? Color.green : Color.secondary)
                        if !model.hasFreshMotion {
                            Text("Wear your AirPods and connect them to this Mac. We'll pick up motion automatically.").foregroundStyle(.secondary)
                        }
                    } else {
                        Text(model.motionDenied ? "Motion access is turned off. Enable it in System Settings to use head tracking." : "Let AirShade follow your head direction. No microphone or camera needed.").foregroundStyle(.secondary)
                    }
                    if !model.motionAllowed || !model.hasFreshMotion {
                        HStack {
                            Button(model.motionDenied ? "Open Motion Settings" : (model.motionAllowed ? "Retry connection" : "Allow motion & connect")) {
                                if model.motionDenied { model.openMotionSettings() } else { model.connectMotion() }
                            }.buttonStyle(.bordered)
                            if model.motionStarted && !model.motionDenied && !model.hasFreshMotion {
                                Text("Waiting for motion…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    DisclosureGroup("Compatible headphones") {
                        Text("AirPods 3 and newer, AirPods Pro, and AirPods Max. AirPods 1 and 2 don't support head tracking.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                SetupStepCard(number: "02", symbol: "rectangle.on.rectangle", title: "Enable screen blur",
                              complete: model.screenAllowed, badge: model.screenAllowed ? "Permission granted" : "Screen Recording") {
                    Text(model.screenAllowed ? "Screen Recording is already enabled. Your blurred snapshots stay on this Mac, in memory only." : "Allow Screen Recording for the frosted-glass effect. Until then, AirShade uses a solid cover.")
                        .foregroundStyle(.secondary)
                    if !model.screenAllowed {
                        HStack {
                            Button("Allow Screen Recording", action: model.requestCapture).buttonStyle(.bordered)
                            Button("Check again", action: model.recheckCaptureAccess).buttonStyle(.borderless)
                        }
                        if !model.captureCheckMessage.isEmpty {
                            Text(model.captureCheckMessage).font(.caption).foregroundStyle(.orange)
                        }
                        DisclosureGroup("Already enabled in Settings?") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Permissions belong to a signed copy of the app. Reopen AirShade after granting access. An older development build may need its permission turned off and on once.")
                                Text("Running copy: \(Bundle.main.bundleURL.path)").textSelection(.enabled)
                                Button("Open Screen Recording Settings", action: model.openCaptureSettings)
                            }.font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        }.font(.caption)
                    }
                }
                SetupStepCard(number: "03", symbol: "viewfinder", title: "Find your focus",
                              complete: model.calibrated, badge: model.calibrated ? "Calibrated" : (model.engine.state == .recoveryRequired ? "Resume needed" : "Calibrate")) {
                    Text(model.calibrated ? "Your screen direction is set. Look away to cover your displays; look back to clear them." : "Choose your screen layout below, then look at your main screen and calibrate. Recalibrate after restarting or losing tracking.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(model.isEnabled ? "Recenter / Resume" : "Calibrate & enable") {
                            if model.isEnabled { model.recenter() } else { model.enable() }
                        }.buttonStyle(.borderedProminent).tint(.cyan)
                            .disabled(!model.hasFreshMotion || model.calibrationCountdown > 0)
                        if model.isEnabled { Button("Pause", action: model.pause).buttonStyle(.bordered) }
                    }
                }
            }
            Label("Private by design. Nothing is uploaded.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }
}

private struct SetupStepCard<Content: View>: View {
    let number: String
    let symbol: String
    let title: String
    let complete: Bool
    let badge: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill((complete ? Color.green : Color.cyan).opacity(0.12))
                Image(systemName: complete ? "checkmark" : symbol)
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(complete ? Color.green : Color.cyan)
            }.frame(width: 42, height: 42).accessibilityLabel(complete ? "Completed" : "Step \(number)")
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer(minLength: 4)
                    Text(badge).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(complete ? Color.green : Color.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background((complete ? Color.green : Color.secondary).opacity(0.10), in: Capsule())
                }
                content().font(.callout)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder((complete ? Color.green : Color.primary).opacity(complete ? 0.22 : 0.08), lineWidth: 1))
    }
}
