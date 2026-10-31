import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreImage
import Observation

@MainActor @Observable final class ShieldPresentation {
    var coverage = 1.0
    var horizontal = 0.0
    var vertical = 0.0
    var message = ""
    var image: NSImage?
    var blurStrength = 36.0
    var canResume = false
    var resume: () -> Void = {}
    var pause: () -> Void = {}
}

private struct ShieldView: View {
    let model: ShieldPresentation
    private var start: UnitPoint {
        abs(model.horizontal) >= abs(model.vertical)
            ? (model.horizontal >= 0 ? .trailing : .leading)
            : (model.vertical >= 0 ? .top : .bottom)
    }
    private var end: UnitPoint {
        UnitPoint(x: 1 - start.x, y: 1 - start.y)
    }
    var body: some View {
        ZStack {
            if let image = model.image {
                Image(nsImage: image).resizable().scaledToFill()
                    .overlay(Color.black.opacity(0.25))
                    .mask(LinearGradient(colors: [
                        .white.opacity(min(1, model.coverage * 2)),
                        .white.opacity(max(0, model.coverage * 2 - 1))
                    ], startPoint: start, endPoint: end))
                    .animation(.easeOut(duration: 0.1), value: model.coverage)
            } else {
                Color.black // Never expose a display while a capture is pending or failed.
            }
            VStack {
                Spacer()
                VStack(spacing: 10) {
                    Label("AirShade", systemImage: "eye.slash.fill").font(.headline)
                    if !model.message.isEmpty {
                        Text(model.message).font(.callout).multilineTextAlignment(.center)
                            .frame(maxWidth: 440)
                    }
                    HStack {
                        Button("Look forward & resume", action: model.resume).disabled(!model.canResume)
                        Button("Pause protection", action: model.pause)
                    }
                    Text("⌃⌥⌘P Pause  ·  ⌃⌥⌘C Recenter").font(.caption).foregroundStyle(.secondary)
                }
                .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding(.bottom, 44)
            }
        }.clipped().preferredColorScheme(.dark)
    }
}

private final class ShieldPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class OverlayService {
    private struct Entry {
        let panel: NSPanel
        let model: ShieldPresentation
    }
    private var entries: [CGDirectDisplayID: Entry] = [:]
    private var generation = UUID()
    private var captureTask: Task<Void, Never>?
    private let context = CIContext(options: [.cacheIntermediates: false])
    var onCaptureStatus: ((String) -> Void)?

    func update(coverage: Double, horizontal: Double, vertical: Double, message: String,
                canResume: Bool, strength: Double, resume: @escaping () -> Void, pause: @escaping () -> Void) {
        guard coverage > 0 else { clear(); return }
        let ids = Set(NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value })
        for id in Array(entries.keys) where !ids.contains(id) {
            entries.removeValue(forKey: id)?.panel.close()
        }
        var added = false
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            if let entry = entries[id], entry.panel.frame != screen.frame {
                entry.panel.setFrame(screen.frame, display: true)
                entry.model.image = nil; added = true
            }
            if entries[id] == nil {
                let model = ShieldPresentation()
                let panel = ShieldPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                panel.isOpaque = false; panel.backgroundColor = .clear
                panel.title = "AirShade — Privacy Shield"
                panel.hasShadow = false; panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false
                panel.contentView = NSHostingView(rootView: ShieldView(model: model))
                entries[id] = Entry(panel: panel, model: model)
                panel.makeKeyAndOrderFront(nil)
                panel.orderFrontRegardless()
                added = true
            }
            guard let entry = entries[id] else { continue }
            entry.model.coverage = coverage
            entry.model.horizontal = horizontal; entry.model.vertical = vertical
            entry.model.message = message; entry.model.canResume = canResume
            entry.model.blurStrength = strength
            entry.model.resume = resume; entry.model.pause = pause
        }
        if added { captureMissing() }
    }

    private func captureMissing() {
        captureTask?.cancel()
        let token = UUID(); generation = token
        captureTask = Task { [weak self] in
            guard let self else { return }
            guard CGPreflightScreenCaptureAccess() else {
                onCaptureStatus?("Screen Recording unavailable — using opaque protection.")
                return
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                for display in content.displays {
                    guard !Task.isCancelled, generation == token else { return }
                    guard let entry = entries[display.displayID], entry.model.image == nil else { continue }
                    let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                    let config = SCStreamConfiguration()
                    let scale = min(1.0, 1600.0 / Double(max(display.width, display.height)))
                    config.width = max(1, Int(Double(display.width) * scale))
                    config.height = max(1, Int(Double(display.height) * scale))
                    config.showsCursor = false
                    let captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard !Task.isCancelled, generation == token else { return }
                    let source = CIImage(cgImage: captured)
                    let blurred = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: entry.model.blurStrength]).cropped(to: source.extent)
                    if let result = context.createCGImage(blurred, from: source.extent) {
                        entry.model.image = NSImage(cgImage: result, size: NSSize(width: display.width, height: display.height))
                    }
                }
                if generation == token { onCaptureStatus?("Screen capture ready. Snapshots stay in memory.") }
            } catch {
                if generation == token { onCaptureStatus?("Capture failed — opaque protection remains active. \(error.localizedDescription)") }
            }
        }
    }
    func clear() {
        guard !entries.isEmpty || captureTask != nil else { return }
        generation = UUID(); captureTask?.cancel(); captureTask = nil
        for entry in entries.values { entry.model.image = nil; entry.panel.close() }
        entries.removeAll(); context.clearCaches()
    }
}
