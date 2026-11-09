import AppKit
import SwiftUI

struct Scene: Identifiable {
    let id: String
    let name: String
    let caption: String
    let symbol: String
    let glow: UInt32

    static let catalog = [
        Scene(id: "snow", name: "Snow Lantern Inn", caption: "Warm windows on a snowy mountainside", symbol: "snowflake", glow: 0xF5EBD7),
        Scene(id: "rain", name: "The Rainy Bookshop", caption: "Amber windows and rain-slick cobbles", symbol: "cloud.rain", glow: 0xD0E3C8),
        Scene(id: "petals", name: "Blossom Creek", caption: "A spring morning by the footbridge", symbol: "leaf", glow: 0xFFE4C6),
        Scene(id: "leaves", name: "Cider Mill", caption: "Maple leaves and a turning waterwheel", symbol: "leaf.fill", glow: 0xFFE2A1),
        Scene(id: "fireflies", name: "Lantern Marsh", caption: "Fireflies along a little marsh boardwalk", symbol: "lightbulb", glow: 0xE9EF9F),
        Scene(id: "stars", name: "Campfire Lake", caption: "A little camp beneath the Milky Way", symbol: "sparkles", glow: 0xF2DCFF)
    ]
}

func ink(_ hex: UInt32) -> Color {
    Color(red: Double(hex >> 16) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
}

struct SceneArtwork: View {
    let scene: Scene

    private static let images: [String: NSImage] = Dictionary(uniqueKeysWithValues: Scene.catalog.compactMap { scene in
        guard let url = Bundle.main.url(forResource: scene.id, withExtension: "jpg", subdirectory: "Artwork"),
              let image = NSImage(contentsOf: url) else { return nil }
        return (scene.id, image)
    })

    var body: some View {
        GeometryReader { frame in
            if let image = Self.images[scene.id] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: frame.size.width, height: frame.size.height)
                    .clipped()
            } else {
                LinearGradient(colors: [ink(0x142137), ink(scene.glow)], startPoint: .bottom, endPoint: .top)
            }
        }
        .accessibilityHidden(true)
    }
}

struct Weather: View {
    let scene: Scene
    let running: Bool
    let strength: Double
    let speed: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !running)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate * speed
                let snowScale = scene.id == "snow" ? WeatherPhysics.snowRadiusScale(density: strength) : 1
                let count = scene.id == "rain" ? 80 : scene.id == "stars" ? 13 : 45
                for index in 0..<Int(Double(count) * strength) {
                    let seed = Double(index)
                    let phase = seed * 0.618
                    let drift = sin(time * 0.55 + seed) * 0.035
                    let speed = scene.id == "rain" ? 0.53 : 0.048
                    let y = wrap(phase + time * speed * (0.6 + wrap(seed * 0.43)))
                    let x = wrap(seed * 0.754 + drift + y * (scene.id == "rain" ? -0.14 : 0.15))
                    let point = CGPoint(x: x * size.width, y: y * size.height)
                    let unit = max(0.65, size.height / 590)
                    let tint = ink(scene.glow)
                    switch scene.id {
                    case "rain", "stars":
                        let meteor = scene.id == "stars"
                        if meteor && y > 0.31 { continue }
                        let start = CGPoint(x: point.x + unit * (meteor ? 26 : 4), y: point.y - unit * (meteor ? 13 : 20))
                        var trail = Path()
                        trail.move(to: start)
                        trail.addLine(to: point)
                        context.stroke(trail, with: .linearGradient(Gradient(colors: [.clear, tint.opacity(0.72)]),
                                                                     startPoint: start, endPoint: point), lineWidth: unit)
                    case "petals", "leaves":
                        var particle = context
                        particle.translateBy(x: point.x, y: point.y)
                        particle.rotate(by: .radians(time * 0.8 + seed))
                        particle.fill(Path(ellipseIn: CGRect(x: -4 * unit, y: -2 * unit, width: 8 * unit, height: 4 * unit)),
                                      with: .color(ink(scene.id == "leaves" ? 0xFFC179 : 0xFFD1E3).opacity(0.68)))
                    default:
                        let firefly = scene.id == "fireflies"
                        let radius = unit * (0.65 + wrap(seed * 0.317) * 1.4) * snowScale
                        let alpha = firefly ? (sin(time * 1.6 + seed) + 1) * 0.4 : 0.76
                        if firefly {
                            let glow = radius * 4
                            context.fill(Path(ellipseIn: CGRect(x: point.x - glow, y: point.y - glow, width: glow * 2, height: glow * 2)),
                                         with: .radialGradient(Gradient(colors: [tint.opacity(alpha), .clear]), center: point, startRadius: 0, endRadius: glow))
                        }
                        context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                                     with: .color(tint.opacity(alpha)))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func wrap(_ value: Double) -> Double { value - floor(value) }
}
