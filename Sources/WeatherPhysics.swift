import CoreGraphics
import Foundation

struct WeatherSurface: Equatable {
    let id: UInt32
    let rect: CGRect
    var isDock = false
    var tilt: CGFloat = 0

    func top(at x: CGFloat) -> CGFloat {
        rect.minY + max(0, -tilt) + tilt * (x - rect.minX) / max(1, rect.width)
    }
}

struct WeatherParticle {
    var position: CGPoint
    var velocity: CGVector
    var size: CGFloat
    var life: CGFloat
    var surface: UInt32?
    var spark = false
    var releasedFrom: UInt32?
    var foreground = false
}

struct SnowBank: Equatable {
    let surface: WeatherSurface
    var profile: [CGFloat] = []

    func depth(at x: CGFloat) -> CGFloat {
        guard profile.count > 1, x >= surface.rect.minX, x <= surface.rect.maxX else { return 0 }
        let progress = min(1, max(0, (x - surface.rect.minX) / surface.rect.width))
        let offset = progress * CGFloat(profile.count - 1)
        let index = Int(offset)
        let t = offset - CGFloat(index)
        let fraction = t * t * (3 - 2 * t)
        return profile[index] * (1 - fraction) + profile[min(index + 1, profile.count - 1)] * fraction
    }
}

struct WeatherPhysics {
    let effect: String
    var particles: [WeatherParticle] = []
    private(set) var banks: [SnowBank] = []
    private var seeded = false
    private(set) var ploughX: CGFloat?
    private var cachedSurfaces: [WeatherSurface] = []
    private var cachedSize: CGSize = .zero
    private var ledges: [WeatherSurface] = []
    private var frames: [UInt32: CGRect] = [:]
    private var spawnBudget: CGFloat = 0
    private(set) var lightning: CGFloat = 0
    private var flashCountdown: CGFloat = 12
    private var pointer = CGPoint(x: -1000, y: -1000)
    private var stillTime: CGFloat = 0

    init(effect: String) { self.effect = effect }

    static func snowRadiusScale(density: CGFloat) -> CGFloat {
        1 + 1.15 * min(1, max(0, (density - 0.55) / 0.95))
    }


    mutating func step(dt: CGFloat, size: CGSize, surfaces: [WeatherSurface], density: CGFloat, mouse: CGPoint, speed: CGFloat = 1) {
        guard size.width > 0, size.height > 0 else { return }
        let rain = effect == "rain"
        let meteor = effect == "stars"
        let firefly = effect == "fireflies"
        let floor = WeatherSurface(id: 0, rect: CGRect(x: 0, y: size.height - 1, width: size.width, height: 2))
        let ground = [floor]

        let geometryChanged = cachedSize != size || cachedSurfaces != surfaces
        let previous = frames
        if geometryChanged {
            cachedSize = size
            cachedSurfaces = surfaces
            ledges = surfaces.filter { $0.rect.minY >= 18 } + ground
            frames.removeAll(keepingCapacity: true)
            for ledge in ledges { frames[ledge.id] = ledge.rect }
        }
        let pointerSpeed = hypot(mouse.x - pointer.x, mouse.y - pointer.y) / dt
        stillTime = pointerSpeed < 22 ? stillTime + dt : 0
        pointer = mouse

        if rain {
            flashCountdown -= dt
            lightning = max(0, lightning - dt * 1.5)
            if flashCountdown <= 0 {
                lightning = 0.16
                flashCountdown = .random(in: 11...24)
            }
        }

        let snow = effect == "snow"
        let rate: CGFloat = rain ? 105 : meteor ? 3.5 : firefly ? 10 : snow ? 6 : 33
        let motionStep = dt * speed
        let boost = snow ? 1 + max(0, density - 0.70) * 0.4 : 1
        let scale = max(0.5, min(2, size.width / 1200)) * density * boost
        let cap = max(3, min(snow ? 225 : 650, Int((snow ? 145 : 410) * scale)))
        if !seeded {
            for _ in 0..<Int((rain ? 88 : meteor ? 6 : 67) * scale) {
                particles.append(makeParticle(size: size, initial: true))
            }
            seeded = true
        }
        spawnBudget += motionStep * rate * scale
        while spawnBudget >= 1 {
            spawnBudget -= 1
            guard particles.count < cap else { continue }
            particles.append(makeParticle(size: size, initial: false))
        }

        if snow {
            if let x = ploughX {
                ploughX = x < size.width + 30 ? x + dt * 145 : nil
            }
            if geometryChanged { updateBanks(ledges: ledges, cap: cap, size: size) }
        }

        var next: [WeatherParticle] = []
        next.reserveCapacity(particles.count)
        for var particle in particles {
            particle.life -= motionStep
            if particle.life <= 0 { continue }

            if let id = particle.surface {
                if snow, let old = previous[id], let new = frames[id],
                   Self.resizeKeepsLedge(from: old, to: new),
                   (new.minX...new.maxX).contains(particle.position.x) {
                    particle.position.y += new.minY - old.minY
                    next.append(particle)
                    continue
                }
                if let old = previous[id], let new = frames[id], !Self.relocated(from: old, to: new) {
                    let dx = new.minX - old.minX
                    let dy = new.minY - old.minY
                    let swept = effect == "leaves" && pointerSpeed > 70
                        && hypot(mouse.x - particle.position.x, mouse.y - particle.position.y) < 85
                    if !swept && hypot(dx, dy) < 1.2 && abs(old.width - new.width) + abs(old.height - new.height) < 1.5 && new.minX <= particle.position.x && particle.position.x <= new.maxX {
                        next.append(particle)
                        continue
                    }
                    particle.velocity = CGVector(dx: swept ? .random(in: -180...180) : max(-410, min(410, dx * 13)),
                                                 dy: swept ? -120 : max(-135, min(160, dy * 6)))
                } else {
                    particle.velocity = CGVector(dx: .random(in: -12...12), dy: .random(in: 30...85))
                    particle.foreground = true
                }
                if snow {
                    particle.velocity = Self.snowDropVelocity()
                    particle.life = 24
                    particle.foreground = false
                }
                particle.releasedFrom = id
                particle.surface = nil
            }

            let old = particle.position
            if firefly && stillTime > 0.45 && CGRect(origin: .zero, size: size).contains(mouse) {
                let dx = mouse.x - old.x
                let dy = mouse.y - old.y
                let distance = max(28, hypot(dx, dy))
                particle.velocity.dx = particle.velocity.dx * 0.985 + dx / distance * dt * 55
                particle.velocity.dy = particle.velocity.dy * 0.985 + dy / distance * dt * 55
            } else if particle.spark {
                particle.velocity.dy += 680 * dt
            } else if !rain && !meteor && !firefly {
                let terminal: CGFloat = snow && particle.releasedFrom == nil ? 64 : 170
                particle.velocity.dy = min(terminal, particle.velocity.dy + (snow ? (particle.releasedFrom == nil ? 5 : 85) : 28) * motionStep)
                if snow && particle.releasedFrom == nil {
                    particle.velocity.dx += sin(particle.life * 0.75 + particle.size * 12) * motionStep * 5
                }
                particle.velocity.dx *= max(0, 1 - motionStep * 0.12)
            }
            particle.position.x += particle.velocity.dx * motionStep
            particle.position.y += particle.velocity.dy * motionStep

            if !particle.spark && !firefly, let hit = collision(from: old, to: particle.position, ledges: particle.foreground ? ground : ledges, skipping: particle.releasedFrom) {
                particle.position = hit.point
                if rain || meteor {
                    for _ in 0..<(rain ? 4 : 10) where next.count < cap {
                        next.append(WeatherParticle(position: hit.point,
                                                    velocity: CGVector(dx: .random(in: -160...160), dy: .random(in: -235 ... -80)),
                                                    size: .random(in: 1.1...2.6), life: .random(in: 0.23...0.49), spark: true))
                    }
                    continue
                }
                if snow {
                    deposit(on: hit.id, at: hit.point.x, size: particle.size, speed: speed)
                    if hit.id == 0 { continue }
                }
                particle.position.y -= CGFloat.random(in: 0.6...6.5)
                particle.surface = hit.id
                particle.releasedFrom = nil
                particle.life = effect == "snow" ? 2.8 : 13
            }

            if particle.position.y < size.height + 20 && particle.position.x > -28 && particle.position.x < size.width + 28 {
                next.append(particle)
            }
        }
        if next.count > cap { next.removeFirst(next.count - cap) }
        particles = next
    }

    mutating func clearSettledSnow() {
        guard effect == "snow" else { return }
        for index in banks.indices { banks[index].profile.removeAll() }
        particles.removeAll { $0.surface != nil || $0.releasedFrom != nil }
        ploughX = -30
    }

    private mutating func deposit(on id: UInt32, at x: CGFloat, size: CGFloat, speed: CGFloat) {
        guard let bank = banks.firstIndex(where: { $0.surface.id == id }) else { return }
        let rect = banks[bank].surface.rect
        let count = max(2, Int(ceil(rect.width / 14)) + 1)
        if banks[bank].profile.isEmpty { banks[bank].profile = Array(repeating: 0, count: count) }
        let position = (x - rect.minX) / rect.width * CGFloat(count - 1)
        let center = min(count - 1, max(0, Int(position.rounded())))
        for index in max(0, center - 2)...min(count - 1, center + 2) {
            let weight = max(0, 1 - abs(CGFloat(index) - position) / 2.5)
            banks[bank].profile[index] = min(id == 0 ? 12 : 7,
                                            banks[bank].profile[index] + weight * size * 0.45 * min(1, speed))
        }
    }

    private func makeParticle(size: CGSize, initial: Bool) -> WeatherParticle {
        let rain = effect == "rain"
        let meteor = effect == "stars"
        let firefly = effect == "fireflies"
        let y: CGFloat = initial || firefly ? .random(in: 26...max(26, size.height)) : 20
        let dx: CGFloat = rain ? -96 : meteor ? -460 : .random(in: -14...22)
        let dy: CGFloat = rain ? .random(in: 300...570) : meteor ? 360 : firefly ? .random(in: -14...14) : .random(in: 23...53)
        return WeatherParticle(position: CGPoint(x: .random(in: 0...size.width), y: y),
                               velocity: CGVector(dx: dx, dy: dy), size: effect == "snow" ? .random(in: 0.95...1.80) : .random(in: 1.2...3.1),
                               life: firefly ? 9 : effect == "snow" ? 49 : 30, foreground: (effect == "snow" || rain) && Int.random(in: 0..<5) < 2)
    }

    private mutating func updateBanks(ledges: [WeatherSurface], cap: Int, size: CGSize) {
        let previousBanks = Dictionary(uniqueKeysWithValues: banks.map { ($0.surface.id, $0) })
        var next: [SnowBank] = []
        for (index, ledge) in ledges.enumerated() {
            let id = ledge.id
            let rect = ledge.rect
            let visibleMin = max(0, rect.minX)
            let visibleMax = min(size.width, rect.maxX)
            guard visibleMax - visibleMin >= 16, rect.minY < size.height else { continue }
            let center = CGPoint(x: (visibleMin + visibleMax) / 2, y: rect.minY)
            let shadowed = ledges.prefix(index).contains {
                $0.rect.contains(center) && $0.rect.minX <= visibleMin && $0.rect.maxX >= visibleMax
            }
            guard !shadowed || id == 0 else { continue }

            let old = previousBanks[id]
            let oldRect = old?.surface.rect ?? rect
            var bank = SnowBank(surface: ledge)
            if let old, !old.profile.isEmpty {
                if oldRect == rect {
                    bank.profile = old.profile
                } else {
                    let keep = id == 0 || Self.resizeKeepsLedge(from: oldRect, to: rect)
                    release(old, supportedBy: keep ? rect : nil, cap: cap, width: size.width)
                    if keep {
                        let count = max(2, Int(ceil(rect.width / 14)) + 1)
                        bank.profile = (0..<count).map { old.depth(at: rect.minX + rect.width * CGFloat($0) / CGFloat(count - 1)) }
                    }
                }
            }
            next.append(bank)
        }
        let present = Set(ledges.map(\.id))
        for bank in banks where bank.surface.id != 0 && !present.contains(bank.surface.id) {
            release(bank, supportedBy: nil, cap: cap, width: size.width)
        }
        banks = next
    }

    private static func resizeKeepsLedge(from old: CGRect, to new: CGRect) -> Bool {
        let resized = abs(old.width - new.width) + abs(old.height - new.height) > 0.5
        return resized && old.minX < new.maxX && new.minX < old.maxX
    }

    private static func relocated(from old: CGRect, to new: CGRect) -> Bool {
        new.width < old.width * 0.62 || new.height < old.height * 0.62
            || abs(new.midX - old.midX) > 140 || abs(new.midY - old.midY) > 140
    }

    private static func snowDropVelocity() -> CGVector {
        CGVector(dx: .random(in: -5...5), dy: .random(in: 28...43))
    }

    private mutating func release(_ bank: SnowBank, supportedBy: CGRect?, cap: Int, width: CGFloat) {
        let rect = bank.surface.rect
        let left = max(0, rect.minX)
        let right = min(width, rect.maxX)
        let count = min(38, Int(max(0, right - left) / 11))
        for i in 0..<count where particles.count < cap {
            let x = left + (right - left) * (CGFloat(i) + 0.5) / CGFloat(count)
            if let supportedBy, (supportedBy.minX...supportedBy.maxX).contains(x) { continue }
            let depth = bank.depth(at: x)
            guard depth > 0.2 else { continue }
            particles.append(WeatherParticle(position: CGPoint(x: x, y: bank.surface.top(at: x) - depth * 0.45),
                                             velocity: Self.snowDropVelocity(), size: .random(in: 0.9...2.2), life: 24,
                                             releasedFrom: bank.surface.id))
        }
    }

    private func collision(from start: CGPoint, to end: CGPoint, ledges: [WeatherSurface], skipping: UInt32?) -> (id: UInt32, point: CGPoint)? {
        let dy = end.y - start.y
        guard dy > 0 else { return nil }
        var nearest: (UInt32, CGPoint)?
        for (index, ledge) in ledges.enumerated() {
            guard ledge.id != skipping else { continue }
            let before = start.y - ledge.top(at: start.x)
            let after = end.y - ledge.top(at: end.x)
            guard before <= 0, after >= 0, after > before else { continue }
            let time = -before / (after - before)
            let x = start.x + (end.x - start.x) * time
            let point = CGPoint(x: x, y: start.y + dy * time)
            guard point.y < (nearest?.1.y ?? .infinity) else { continue }
            guard x >= ledge.rect.minX, x <= ledge.rect.maxX else { continue }
            guard !ledges.prefix(index).contains(where: { $0.rect.contains(point) }) else { continue }
            nearest = (ledge.id, point)
        }
        return nearest
    }
}
