import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class Desktop {
    var active: Scene?
    var video: URL?
    var motion = true { didSet { weather.motion = motion; weather.refreshPlayback() } }
    var intensity = UserDefaults.standard.object(forKey: "weatherDensity") as? Double ?? 0.55 {
        didSet {
            weather.density = intensity
            UserDefaults.standard.set(intensity, forKey: "weatherDensity")
        }
    }
    var speed = UserDefaults.standard.object(forKey: "weatherSpeed") as? Double ?? 0.42 {
        didSet {
            weather.speed = speed
            UserDefaults.standard.set(speed, forKey: "weatherSpeed")
        }
    }
    private let weather = DesktopWeather()
    var error: String?
    var importing = false
    private var windows: [CGDirectDisplayID: WallpaperWindow] = [:]
    private var observation: NSObjectProtocol?

    init() {
        weather.density = intensity
        weather.speed = speed
        weather.onVideoPlayback = { [weak self] id, playing in
            guard let controller = self?.windows[id]?.videoController else { return }
            if playing { controller.play() }
            else { controller.pause() }
        }
        observation = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
    }

    func apply(_ scene: Scene) {
        active = scene
        video = nil
        rebuild()
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a local MP4 or MOV to loop silently."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        Task {
            defer { importing = false }
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let playable = try await asset.load(.isPlayable)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard playable, !tracks.isEmpty, duration.seconds.isFinite, duration.seconds > 0 else {
                    error = "Choose a playable MP4 or MOV containing a video track."
                    return
                }
                active = nil
                video = url
                rebuild()
            } catch {
                self.error = "Couldn’t open \(url.lastPathComponent). \(error.localizedDescription)"
            }
        }
    }

    func ploughSnow() { weather.ploughSnow() }

    func clear() {
        active = nil
        video = nil
        rebuild()
    }

    private func removeWindow(_ id: CGDirectDisplayID) {
        guard let window = windows.removeValue(forKey: id) else { return }
        window.videoController.teardown()
        window.close()
    }

    private func rebuild() {
        for id in Array(windows.keys) { removeWindow(id) }
        sync()
    }

    private func sync() {
        guard active != nil || video != nil else {
            weather.stop()
            return
        }
        let screens = NSScreen.screens
        let ids = Set(screens.map(\.displayID))
        for id in Array(windows.keys) where !ids.contains(id) { removeWindow(id) }
        for screen in screens {
            if let window = windows[screen.displayID] {
                window.match(screen: screen)
                continue
            }
            let window = WallpaperWindow(screen: screen)
            if let active {
                window.contentView = NSHostingView(rootView: SceneArtwork(scene: active))
            } else if let video {
                window.videoController.load(url: video, muted: true, fill: true)
            }
            windows[screen.displayID] = window
            window.orderFrontRegardless()
        }
        if !weather.configure(effect: active?.id, screens: screens, video: video != nil) {
            error = "Driftwood couldn’t start Metal. The still wallpaper is active."
        }
    }
}

struct LiveScene: View {
    let scene: Scene
    let desktop: Desktop

    @Environment(\.controlActiveState) private var windowActivity

    var body: some View {
        SceneArtwork(scene: scene)
            .overlay {
                if desktop.motion, windowActivity == .key, desktop.active == nil, desktop.video == nil {
                    Weather(scene: scene, running: true, strength: desktop.intensity, speed: desktop.speed)
                }
            }
    }
}

struct Gallery: View {
    @Bindable var desktop: Desktop
    @State private var selection = Scene.catalog[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DRIFTWOOD").font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(3).foregroundStyle(.mint)
                    Text("Weather for your desktop").font(.system(size: 27, weight: .medium, design: .serif))
                }
                Spacer()
                Button("Import Video…") { desktop.chooseVideo() }
                    .disabled(desktop.importing)
            }

            LiveScene(scene: selection, desktop: desktop)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.black.opacity(0.83), .clear], startPoint: .bottom, endPoint: .top)
                        .frame(height: 140)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selection.name).font(.system(size: 34, weight: .medium, design: .serif))
                        Text(selection.caption).font(.callout).foregroundStyle(.white.opacity(0.85))
                    }
                    .shadow(color: .black.opacity(0.8), radius: 8)
                    .padding(23)
                }
                .frame(height: 280)
                .clipShape(.rect(cornerRadius: 12))

            HStack(spacing: 8) {
                ForEach(Scene.catalog) { scene in
                    Button {
                        selection = scene
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            SceneArtwork(scene: scene)
                                .overlay(alignment: .topLeading) {
                                    Image(systemName: scene.symbol)
                                        .font(.caption).padding(6)
                                        .background(.black.opacity(0.42), in: Circle()).padding(5)
                                }
                                .frame(height: 48).clipShape(.rect(cornerRadius: 6))
                            Text(scene.name).font(.caption).lineLimit(1)
                        }
                        .padding(5)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(0.05), in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(selection.id == scene.id ? Color.mint : Color.clear, lineWidth: 1.5)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(scene.name)
                    .accessibilityAddTraits(selection.id == scene.id ? .isSelected : [])
                }
            }
            HStack(spacing: 14) {
                Toggle("Motion", isOn: $desktop.motion)
                Slider(value: $desktop.intensity, in: 0.05...1.5) { Text("Weather density") }
                    .frame(width: 142)
                    .disabled(!desktop.motion)
                Slider(value: $desktop.speed, in: 0.12...1.1) { Text("Fall speed") }
                    .frame(width: 135)
                    .disabled(!desktop.motion)
                Spacer()
                Button("Clear") { desktop.clear() }
                    .disabled(desktop.active == nil && desktop.video == nil || desktop.importing)
                Button("Apply to All Displays") { desktop.apply(selection) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(desktop.importing)
            }
            Text(status)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .accessibilityIdentifier("desktop-status")
        }
        .padding(23)
        .frame(width: 730)
        .background(Color(red: 0.07, green: 0.09, blue: 0.12))
        .preferredColorScheme(.dark)
        .alert("Driftwood", isPresented: Binding(
            get: { desktop.error != nil }, set: { if !$0 { desktop.error = nil } }
        )) {
            Button("OK") { desktop.error = nil }
        } message: {
            Text(desktop.error ?? "")
        }
    }

    private var status: String {
        if desktop.importing { return "Checking video…" }
        if desktop.active?.id == "snow" { return "Drag snow up from the bottom edge. Drop one ball above another to stack them." }
        if let active = desktop.active { return "On your desktop · \(active.name)" }
        if let video = desktop.video { return "On your desktop · \(video.lastPathComponent)" }
        return "Preview a scene, then apply it to your desktop."
    }
}

@main
struct DriftwoodApp: App {
    @State private var desktop = Desktop()

    var body: some SwiftUI.Scene {
        Window("Driftwood", id: "gallery") {
            Gallery(desktop: desktop)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Driftwood", systemImage: "cloud.moon") {
            StatusMenu(desktop: desktop)
        }
        .menuBarExtraStyle(.window)
    }
}

struct StatusMenu: View {
    @Bindable var desktop: Desktop
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Weather density").font(.headline)
                Spacer()
                Text(desktop.intensity, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $desktop.intensity, in: 0.05...1.5) { Text("Weather density") }
            HStack {
                Text("Fall speed").font(.headline)
                Spacer()
                Text(desktop.speed, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $desktop.speed, in: 0.12...1.1) { Text("Fall speed") }
            Divider()
            Button("Open Gallery") {
                openWindow(id: "gallery")
                NSApp.activate(ignoringOtherApps: true)
            }
            Menu("Apply Scene") {
                ForEach(Scene.catalog) { scene in
                    Button(scene.name) { desktop.apply(scene) }
                }
            }
            .disabled(desktop.importing)
            Button(desktop.motion ? "Pause Motion" : "Resume Motion") {
                desktop.motion.toggle()
            }
            Button {
                desktop.ploughSnow()
            } label: {
                Label("Plough Snow", systemImage: "truck.box")
            }
            .disabled(desktop.active?.id != "snow")
            Button("Clear Wallpaper") { desktop.clear() }
                .disabled(desktop.active == nil && desktop.video == nil)
            Divider()
            Button("Quit Driftwood") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 250)
    }
}
