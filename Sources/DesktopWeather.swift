import AppKit
import CoreGraphics
import IOKit.ps
import QuartzCore

@MainActor
final class WeatherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DesktopWeather {
    private struct WindowBounds: Sendable {
        let id: UInt32
        let rect: CGRect
        let layer: Int
        let dock: Bool
        let stage: Bool
    }

    private final class DisplayWeather {
        let panel: WeatherPanel
        let view: WeatherMetalView
        var physics: WeatherPhysics
        var link: CADisplayLink?
        var pickup: WeatherPanel?
        var lastFrame = 0.0
        var ledges: [WeatherSurface] = []
        var masks: [CGRect] = []
        var geometryRevision = -1

        init(panel: WeatherPanel, view: WeatherMetalView, effect: String) {
            self.panel = panel
            self.view = view
            physics = WeatherPhysics(effect: effect)
        }
    }

    private var displays: [CGDirectDisplayID: DisplayWeather] = [:]
    private var geometry: [WindowBounds] = []
    private var timer: Timer?
    private var lastScan = 0.0
    private var geometryRevision = 0
    private var scanInProgress = false
    private var generation = 0
    private let windowQueue = DispatchQueue(label: "Driftwood.window-bounds", qos: .utility)
    private var linkedDisplays: [ObjectIdentifier: (screen: NSScreen, display: DisplayWeather)] = [:]
    private var lastPower = 0.0
    private var powerFactor = 1.0
    private var screens: [NSScreen] = []
    var density = 0.65
    var speed = 0.48
    var motion = true
    var onVideoPlayback: ((CGDirectDisplayID, Bool) -> Void)?
    private var videoStates: [CGDirectDisplayID: Bool] = [:]

    func configure(effect: String?, screens: [NSScreen], video: Bool) -> Bool {
        stop()
        self.screens = screens
        lastScan = 0
        lastPower = 0
        if let effect {
            for screen in screens {
                guard let view = WeatherMetalView(effect: effect) else {
                    stop()
                    return false
                }
                let panel = WeatherPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
                panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false
                panel.isExcludedFromWindowsMenu = true
                panel.contentView = view
                panel.setFrame(screen.frame, display: false)
                let display = DisplayWeather(panel: panel, view: view, effect: effect)
                let link = screen.displayLink(target: self, selector: #selector(drawFrame(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
                link.isPaused = true
                link.add(to: .main, forMode: .common)
                display.link = link
                if effect == "snow" { display.pickup = snowPickup(on: screen, view: view) }
                displays[screen.displayID] = display
                linkedDisplays[ObjectIdentifier(link)] = (screen, display)
            }
        }
        if effect != nil || video {
            let timer = Timer(timeInterval: 0.18, target: self, selector: #selector(tick),
                              userInfo: nil, repeats: true)
            timer.tolerance = 0.025
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            tick()
        }
        return true
    }

    func stop() {
        generation += 1
        geometry = []
        linkedDisplays.removeAll()
        timer?.invalidate()
        timer = nil
        for display in displays.values {
            display.link?.invalidate()
            display.pickup?.close()
            display.panel.close()
        }
        displays.removeAll()
        videoStates.removeAll()
    }

    func ploughSnow() {
        for display in displays.values {
            display.physics.clearSettledSnow()
            display.view.snowballs = Snowballs()
        }
    }

    func refreshPlayback() {
        videoStates.removeAll()
        tick()
    }

    @objc private func tick() {
        guard timer != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPower > 1 {
            let powerSnapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
            let source = IOPSGetProvidingPowerSourceType(powerSnapshot)?.takeUnretainedValue()
            let onBattery = (source as String?) == kIOPSBatteryPowerValue
            powerFactor = onBattery || ProcessInfo.processInfo.isLowPowerModeEnabled ? 0.5 : 1
            lastPower = now
        }
        scanWindows(now: now, minimumInterval: 0.52)

        for screen in screens {
            let frame = screen.quartzFrame
            let covered = geometry.contains {
                $0.layer == 0 && !$0.stage && abs($0.rect.minX - frame.minX) <= 8 && abs($0.rect.minY - frame.minY) <= 8
                    && abs($0.rect.width - frame.width) <= 8 && abs($0.rect.height - frame.height) <= 8
            }
            let visible = !covered && CGDisplayIsAsleep(screen.displayID) == 0
            guard let display = displays[screen.displayID] else {
                let playing = visible && motion
                if videoStates[screen.displayID] != playing {
                    videoStates[screen.displayID] = playing
                    onVideoPlayback?(screen.displayID, playing)
                }
                continue
            }
            guard visible && motion else {
                display.link?.isPaused = true
                display.lastFrame = 0
                if display.panel.isVisible { display.panel.orderOut(nil); display.pickup?.orderOut(nil) }
                continue
            }
            if !display.panel.isVisible {
                display.panel.orderFrontRegardless()
                display.pickup?.orderFrontRegardless()
            }
            let preferred: Float = powerFactor < 1 ? 24 : 30
            if display.link?.preferredFrameRateRange.preferred != preferred {
                display.link?.preferredFrameRateRange = CAFrameRateRange(minimum: preferred, maximum: preferred, preferred: preferred)
            }
            display.link?.isPaused = false
        }
    }

    @objc private func drawFrame(_ link: CADisplayLink) {
        guard motion, let (screen, display) = linkedDisplays[ObjectIdentifier(link)] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = display.lastFrame == 0 ? 1.0 / 60 : min(0.05, max(0.001, now - display.lastFrame))
        display.lastFrame = now
        scanWindows(now: now, minimumInterval: NSEvent.pressedMouseButtons != 0 ? 0.075 : 0.52)
        if display.geometryRevision != geometryRevision {
            display.geometryRevision = geometryRevision
            let frame = screen.quartzFrame
            var ledges = geometry.compactMap { window -> WeatherSurface? in
                let localFrame = window.rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
                guard window.rect.intersects(frame), localFrame.minY >= 18 else { return nil }
                // Stage Manager can publish both the thumbnail and an app-owned proxy.
                let nearEdge = localFrame.minX < 65 || localFrame.maxX > frame.width - 65
                let thumbnail = nearEdge && localFrame.width < min(235, frame.width * 0.23)
                    && localFrame.height < frame.height * 0.52
                guard !window.stage, !thumbnail else { return nil }
                if window.dock {
                    guard localFrame.minY > frame.height * 0.76 || localFrame.width < 130 else { return nil }
                }
                return WeatherSurface(id: window.id, rect: localFrame, isDock: window.dock)
            }
            if !ledges.contains(where: \.isDock), let dock = dockLedge(on: screen, frame: frame) {
                ledges.insert(dock, at: 0)
            }
            display.ledges = ledges
            display.masks = ledges.map { surface in
                let rect = surface.rect
                return CGRect(x: rect.minX, y: rect.minY + abs(surface.tilt), width: rect.width,
                              height: max(0, rect.height - abs(surface.tilt)))
            }
        }
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
        display.physics.step(dt: dt, size: screen.frame.size, surfaces: display.ledges, density: density * powerFactor, mouse: local, speed: speed)
        display.view.render(display.physics, occluders: display.masks, dt: dt, density: density)
    }

    private func scanWindows(now: Double, minimumInterval: Double) {
        guard !scanInProgress, now - lastScan >= minimumInterval else { return }
        lastScan = now
        scanInProgress = true
        let requestedGeneration = generation
        windowQueue.async { [weak self] in
            let result = Self.windowBounds()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanInProgress = false
                guard self.generation == requestedGeneration else { return }
                self.geometry = result
                self.geometryRevision += 1
            }
        }
    }

    private func snowPickup(on screen: NSScreen, view: WeatherMetalView) -> WeatherPanel {
        let frame = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: 16)
        let panel = WeatherPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        panel.isOpaque = false
        panel.backgroundColor = NSColor.white.withAlphaComponent(0.012)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let pickup = SnowPickupView(frame: CGRect(origin: .zero, size: frame.size))
        let local: (CGPoint) -> CGPoint = { CGPoint(x: $0.x - screen.frame.minX, y: screen.frame.maxY - $0.y) }
        pickup.onBegin = { [weak view] point in view?.snowballs.begin(at: local(point)) }
        pickup.onDrag = { [weak view] point in view?.snowballs.drag(to: local(point)) }
        pickup.onRelease = { [weak view] point in view?.snowballs.release(at: local(point), size: screen.frame.size) }
        panel.contentView = pickup
        return panel
    }

    // Recent macOS versions can publish the Dock as a display-sized transparent surface.
    // Its reserved bottom inset still locates the top edge of a visible bottom Dock.
    private func dockLedge(on screen: NSScreen, frame: CGRect) -> WeatherSurface? {
        let inset = screen.visibleFrame.minY - screen.frame.minY
        guard (18...125).contains(inset),
              let dock = geometry.first(where: { $0.dock && $0.rect.intersects(frame) }) else { return nil }
        let tile = UserDefaults(suiteName: "com.apple.dock")?.double(forKey: "tilesize") ?? 0
        let apps = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps")?.count ?? 16
        let width = min(frame.width * 0.9, max(230, CGFloat(apps + 4) * (tile > 0 ? tile + 4 : inset * 0.82)))
        let rect = CGRect(x: (frame.width - width) / 2, y: frame.height - inset + 3, width: width, height: inset)
        return WeatherSurface(id: dock.id, rect: rect, isDock: true)
    }

    nonisolated private static func windowBounds() -> [WindowBounds] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        return windows.compactMap { item in
            guard let layer = item[kCGWindowLayer as String] as? Int,
                  let id = item[kCGWindowNumber as String] as? UInt32,
                  let bounds = item[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"],
                  w >= 70, h >= 28, (item[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0.2
            else { return nil }
            let owner = item[kCGWindowOwnerName as String] as? String
            let systemDock = owner == "Dock"
            let stage = owner == "WindowManager"
                || (systemDock && w <= 300 && h >= 45 && h <= 350 && layer != dockLevel)
            let dock = systemDock && layer == dockLevel
            guard stage || dock || (layer == 0 && !systemDock) else { return nil }
            return WindowBounds(id: id, rect: CGRect(x: x, y: y, width: w, height: h), layer: layer,
                                dock: dock, stage: stage)
        }
    }
}
