import CoreGraphics
import Foundation

@main
struct WeatherPhysicsTests {
    static func main() {
        let screen = CGSize(width: 1000, height: 700)
        let window = WeatherSurface(id: 42, rect: CGRect(x: 100, y: 200, width: 500, height: 350))
        let moved = WeatherSurface(id: 42, rect: window.rect.offsetBy(dx: 40, dy: 0))
        let pointer = CGPoint(x: -100, y: -100)

        var snow = WeatherPhysics(effect: "snow")
        snow.step(dt: 0.001, size: screen, surfaces: [window], density: 1, mouse: pointer)
        snow.particles = [particle(x: 270, y: 199, dy: 65)]
        snow.step(dt: 0.03, size: screen, surfaces: [window], density: 1, mouse: pointer)
        precondition(snow.particles.first?.surface == window.id, "Snow must settle on the top of the window")
        for offset in [-65.0, 65.0] {
            let shifted = WeatherSurface(id: window.id, rect: window.rect.offsetBy(dx: offset, dy: 0))
            var falling = snow
            for _ in 0..<24 { falling.step(dt: 0.03, size: screen, surfaces: [shifted], density: 1, mouse: pointer) }
            guard let loose = falling.particles.first else { fatalError("The displaced flake disappeared") }
            precondition(loose.releasedFrom == window.id && loose.surface == nil)
            precondition(abs(loose.position.x - 270) < 4 && loose.position.y > 225,
                         "Snow must fall from its original position whichever direction the window moves")
        }

        var landing = snow
        for _ in 0..<200 { landing.step(dt: 0.03, size: screen, surfaces: [moved], density: 0.05, mouse: pointer) }
        precondition((landing.banks.last?.depth(at: 270) ?? 0) > 0,
                     "Released snow must survive the trip down and land near its starting x position")

        let lower = WeatherSurface(id: 43, rect: CGRect(x: 150, y: 315, width: 290, height: 200))
        let away = WeatherSurface(id: window.id, rect: window.rect.offsetBy(dx: 400, dy: 0))
        for surfaces in [[lower], [away, lower]] {
            var cascade = snow
            for _ in 0..<100 { cascade.step(dt: 0.03, size: screen, surfaces: surfaces, density: 0.05, mouse: pointer) }
            precondition((cascade.banks.first { $0.surface.id == lower.id }?.depth(at: 270) ?? 0) > 0,
                         "Snow released from a moved or closed window must land on a lower window")
        }

        for (effect, y, ledges, expected) in [
            ("rain", 195.0, [window], 4), ("rain", 690.0, [], 4), ("stars", 195.0, [window], 10)
        ] {
            var weather = WeatherPhysics(effect: effect)
            weather.step(dt: 0.001, size: screen, surfaces: ledges, density: 1, mouse: pointer)
            weather.particles = [particle(x: 270, y: y, dy: 800)]
            weather.step(dt: 0.03, size: screen, surfaces: ledges, density: 1, mouse: pointer)
            precondition(weather.particles.filter(\.spark).count == expected, "\(effect) should splash or spark at impact")
        }
        var banks = WeatherPhysics(effect: "snow")
        let ceiling = WeatherSurface(id: 77, rect: CGRect(x: 0, y: 0, width: 1000, height: 25))
        banks.step(dt: 0.001, size: screen, surfaces: [ceiling, window], density: 0.5, mouse: pointer)
        banks.particles = [270.0, 560.0].flatMap { x in
            Array(repeating: particle(x: x, y: 199, dy: 80), count: 4)
        }
        banks.step(dt: 0.033, size: screen, surfaces: [window], density: 0.5, mouse: pointer)
        precondition((banks.banks.first?.depth(at: 270) ?? 0) > 0)
        let narrower = WeatherSurface(id: window.id, rect: CGRect(x: 100, y: 200, width: 300, height: 350))
        banks.step(dt: 0.033, size: screen, surfaces: [narrower], density: 0.5, mouse: pointer)
        precondition((banks.banks.first?.depth(at: 270) ?? 0) > 0)
        let bankDebris = banks.particles.filter { $0.releasedFrom == window.id }
        precondition(!bankDebris.isEmpty && bankDebris.allSatisfy { $0.position.x > 400 && $0.velocity.dy > 0 },
                     "Only snow whose support was removed should drop")
        var accumulation = WeatherPhysics(effect: "snow")
        accumulation.step(dt: 0.001, size: screen, surfaces: [], density: 0.5, mouse: pointer)
        accumulation.particles = []
        for _ in 0..<60 { accumulation.step(dt: 0.033, size: screen, surfaces: [], density: 0.5, mouse: pointer) }
        precondition(accumulation.banks.last?.depth(at: 250) == 0, "Time alone must not fill the floor")
        accumulation.particles = Array(repeating: particle(x: 250, y: screen.height - 2, dy: 80), count: 6)
        accumulation.step(dt: 0.033, size: screen, surfaces: [], density: 0.5, mouse: pointer)
        precondition((accumulation.banks.last?.depth(at: 250) ?? 0) > 4)
        precondition(accumulation.banks.last?.depth(at: 550) == 0, "A flake must build snow only near its impact")
        accumulation.clearSettledSnow()
        precondition(accumulation.banks.last?.depth(at: 250) == 0 && accumulation.ploughX != nil)
        precondition(WeatherPhysics.snowRadiusScale(density: 1.5) > 2 * WeatherPhysics.snowRadiusScale(density: 0.55))
        var foreground = WeatherPhysics(effect: "rain")
        foreground.step(dt: 0.001, size: screen, surfaces: [window], density: 1, mouse: pointer)
        var drop = particle(x: 270, y: 195, dy: 800)
        drop.foreground = true
        foreground.particles = [drop]
        foreground.step(dt: 0.03, size: screen, surfaces: [window], density: 1, mouse: pointer)
        precondition(foreground.particles.first?.position.y ?? 0 > window.rect.minY)
        precondition(!foreground.particles.contains(where: \.spark))
        var closing = WeatherPhysics(effect: "snow")
        for _ in 0..<90 { closing.step(dt: 0.033, size: screen, surfaces: [window], density: 0.5, mouse: pointer) }
        closing.particles = Array(repeating: particle(x: 270, y: 199, dy: 80), count: 5)
        closing.step(dt: 0.033, size: screen, surfaces: [window], density: 0.5, mouse: pointer)
        let thumbnail = WeatherSurface(id: window.id, rect: CGRect(x: 15, y: 175, width: 85, height: 95))
        closing.step(dt: 0.033, size: screen, surfaces: [thumbnail], density: 0.5, mouse: pointer)
        let released = closing.particles.filter { $0.releasedFrom == window.id }
        precondition(!released.isEmpty)
        precondition(released.allSatisfy { $0.position.x >= window.rect.minX - 1 && abs($0.velocity.dx) < 15 },
                     "Minimized snow must start at the old window and drop down")

        var stack = Snowballs()
        let floor = screen.height - 6
        for point in [CGPoint(x: 420, y: 535), CGPoint(x: 421, y: 470), CGPoint(x: 419, y: 390)] {
            stack.begin(at: CGPoint(x: 420, y: floor))
            stack.drag(to: point)
            stack.release(at: point, size: screen)
            for _ in 0..<80 { stack.step(dt: 0.016, floor: floor) }
        }
        precondition(stack.placed.count == 3 && stack.placed.allSatisfy { !$0.falling })
        precondition(stack.placed[2].center.y < stack.placed[1].center.y && stack.placed[1].center.y < stack.placed[0].center.y,
                     "Each snowball should land above the one below it")
        precondition(stack.heads.count == 1, "Three stacked balls should make one snowman")
        var dockBall = Snowballs()
        let dock = CGRect(x: 300, y: 610, width: 400, height: 80)
        dockBall.begin(at: CGPoint(x: 180, y: floor))
        dockBall.release(at: CGPoint(x: 450, y: 500), size: screen)
        for _ in 0..<80 { dockBall.step(dt: 0.016, floor: floor, dock: dock) }
        guard let placedOnDock = dockBall.placed.first else { fatalError("Expected a rolled ball") }
        precondition(!placedOnDock.falling && placedOnDock.center.y + placedOnDock.radius == dock.minY,
                     "A ball dropped above the Dock should land on its top edge")
        var slow = WeatherPhysics(effect: "snow")
        slow.step(dt: 0.001, size: screen, surfaces: [], density: 0.5, mouse: pointer)
        slow.particles = [particle(x: 270, y: 80, dy: 48)]
        var fast = slow
        slow.step(dt: 0.04, size: screen, surfaces: [], density: 0.5, mouse: pointer, speed: 0.2)
        fast.step(dt: 0.04, size: screen, surfaces: [], density: 0.5, mouse: pointer)
        precondition(slow.particles[0].position.y < fast.particles[0].position.y,
                     "Fall speed should change distance traveled at the same density")
        print("Passed: stacking, minimize drops, foreground rain, snowbanks, ceiling exclusion, snow settling, window movement, rain splashes, and meteor impacts")
    }

    private static func particle(x: CGFloat, y: CGFloat, dy: CGFloat) -> WeatherParticle {
        WeatherParticle(position: CGPoint(x: x, y: y), velocity: CGVector(dx: 0, dy: dy),
                        size: 2, life: 3)
    }
}
