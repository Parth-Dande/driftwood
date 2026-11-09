import AppKit

struct Snowball {
    var center: CGPoint
    var radius: CGFloat
    var falling = false
    var speed: CGFloat = 0
}

struct Snowballs {
    private(set) var placed: [Snowball] = []
    private(set) var rolling: Snowball?
    private var distance: CGFloat = 0
    private var last = CGPoint.zero

    var heads: [Snowball] {
        guard placed.count >= 3 else { return [] }
        func isOn(_ top: Snowball, _ lower: Snowball) -> Bool {
            let gap = (top.radius + lower.radius) * 0.87
            return !top.falling && !lower.falling && abs(top.center.x - lower.center.x) < 1
                && abs(lower.center.y - top.center.y - gap) < 1
        }
        return placed.filter { top in
            placed.contains { body in isOn(top, body) && placed.contains { isOn(body, $0) } }
                && !placed.contains { isOn($0, top) }
        }
    }

    mutating func begin(at point: CGPoint) {
        last = point
        distance = 0
        rolling = Snowball(center: point, radius: 5)
    }

    mutating func drag(to point: CGPoint) {
        guard rolling != nil else { return }
        distance += hypot(point.x - last.x, point.y - last.y)
        last = point
        rolling?.center = point
        rolling?.radius = min(29, 5 + distance * 0.075)
    }

    mutating func release(at point: CGPoint, size: CGSize) {
        drag(to: point)
        defer { rolling = nil }
        guard var ball = rolling, distance > 22 else { return }
        ball.center.x = min(max(ball.radius, point.x), size.width - ball.radius)
        ball.center.y = max(ball.radius, point.y)
        ball.falling = true
        if placed.count >= 36 { return }
        placed.append(ball)
    }

    mutating func step(dt: CGFloat, floor: CGFloat, dock: CGRect? = nil) {
        for i in placed.indices where placed[i].falling {
            var ball = placed[i]
            let before = ball.center.y
            ball.speed += 720 * dt
            ball.center.y += ball.speed * dt
            var landing = floor - ball.radius
            if let dock, (dock.minX...dock.maxX).contains(ball.center.x),
               before <= dock.minY - ball.radius + 3 {
                landing = dock.minY - ball.radius
            }
            var centerX = ball.center.x
            for other in placed where !other.falling {
                let reach = min(ball.radius, other.radius) * 0.85
                let surface = other.center.y - (ball.radius + other.radius) * 0.87
                if abs(ball.center.x - other.center.x) <= reach && before <= surface + 6 && surface < landing {
                    landing = surface
                    centerX = other.center.x
                }
            }
            if ball.center.y >= landing {
                ball.center = CGPoint(x: centerX, y: landing)
                ball.falling = false
            }
            placed[i] = ball
        }
    }
}

// The pickup strip sits below normal windows, so clicks on apps stay with the app.
@MainActor
final class SnowPickupView: NSView {
    var onBegin: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onRelease: ((CGPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onBegin?(NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { onDrag?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { onRelease?(NSEvent.mouseLocation) }
}
