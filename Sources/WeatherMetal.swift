import AppKit
import MetalKit
import simd

private struct WeatherVertex {
    let point: SIMD2<Float>
    var uv: SIMD2<Float> = SIMD2(repeating: 3)
    let color: SIMD4<Float>
}

@MainActor
final class WeatherMetalView: MTKView, MTKViewDelegate {
    private let pipeline: MTLRenderPipelineState
    private let queue: MTLCommandQueue
    private var vertices: [WeatherVertex] = []
    private let effect: String
    private var masks: [SIMD4<Float>] = []
    private var reusableBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)
    var snowballs = Snowballs()
    private static let corners: [SIMD2<Float>] = [
        SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1),
        SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1)
    ]
    private var clipScale = SIMD2<Float>.zero
    private var cachedBanks: [WeatherVertex] = []
    private var bankRefresh: CGFloat = 0
    private var renderedBanks: [SnowBank] = []
    private var previousMasks: [CGRect] = []
    init?(effect: String) {
        guard let gpu = MTLCreateSystemDefaultDevice(), let queue = gpu.makeCommandQueue() else { return nil }
        let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float2 point; float2 uv; float4 color; };
        struct Output { float4 position [[position]]; float4 color; float2 clipPoint; float2 uv; };
        vertex Output weather_vertex(const device Vertex *vertices [[buffer(0)]], uint i [[vertex_id]]) {
            return { float4(vertices[i].point, 0, 1), vertices[i].color, vertices[i].point, vertices[i].uv };
        }
        fragment float4 weather_fragment(Output in [[stage_in]],
                constant float4 *rects [[buffer(0)]], constant uint &count [[buffer(1)]]) {
            for (uint i = 0; i < count; ++i) {
                float4 r = rects[i];
                if (all(in.clipPoint >= r.xy) && all(in.clipPoint <= r.zw)) discard_fragment();
            }
            float alpha = in.color.a;
            if (in.uv.y < 1.5) {
                bool soft = in.uv.x > 1.5;
                float radius = length(in.uv - float2(soft ? 4 : 0, 0));
                alpha *= soft ? 1 - smoothstep(0.10, 1.0, radius) : 1 - smoothstep(0.72, 1.0, radius);
            }
            return float4(in.color.rgb * alpha, alpha);
        }
        """
        guard let library = try? gpu.makeLibrary(source: shader, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "weather_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "weather_fragment")
        let target = descriptor.colorAttachments[0]!
        target.pixelFormat = .bgra8Unorm
        target.isBlendingEnabled = true
        target.sourceRGBBlendFactor = .one
        target.destinationRGBBlendFactor = .oneMinusSourceAlpha
        target.sourceAlphaBlendFactor = .one
        target.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? gpu.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        self.pipeline = pipeline
        self.queue = queue
        self.effect = effect
        super.init(frame: .zero, device: gpu)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        isPaused = true
        enableSetNeedsDisplay = false
        wantsLayer = true
        layer?.isOpaque = false
        framebufferOnly = true
        autoResizeDrawable = false
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("Use init(effect:)") }
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let size = CGSize(width: (bounds.width * 0.70).rounded(), height: (bounds.height * 0.70).rounded())
        if size.width > 0, size.height > 0, drawableSize != size { drawableSize = size }
    }

    func render(_ physics: WeatherPhysics, occluders: [CGRect], dt: CGFloat, density: CGFloat) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        clipScale = SIMD2(Float(2 / bounds.width), Float(-2 / bounds.height))
        vertices.removeAll(keepingCapacity: true)
        if previousMasks != occluders {
            previousMasks = occluders
            masks = occluders.prefix(120).map {
                let lower = clip(CGPoint(x: $0.minX, y: $0.maxY))
                let upper = clip(CGPoint(x: $0.maxX, y: $0.minY))
                return SIMD4(lower.x, lower.y, upper.x, upper.y)
            }
        }
        let frost = SIMD4<Float>(0.96, 0.98, 1, 0.89)
        bankRefresh -= dt
        if bankRefresh <= 0, renderedBanks != physics.banks {
            renderedBanks = physics.banks
            bankRefresh = 0.15
            for bank in physics.banks { drawBank(bank, color: frost) }
            swap(&cachedBanks, &vertices)
            vertices.removeAll(keepingCapacity: true)
        }
        vertices.append(contentsOf: cachedBanks)
        if effect == "snow" {
            snowballs.step(dt: dt, floor: bounds.height - 6,
                           dock: physics.banks.first(where: { $0.surface.isDock })?.surface.rect)
        }
        let colors: [String: SIMD4<Float>] = [
            "rain": SIMD4(0.78, 0.92, 1, 0.88), "petals": SIMD4(1, 0.57, 0.72, 0.9),
            "leaves": SIMD4(1, 0.59, 0.23, 0.89), "fireflies": SIMD4(0.85, 1, 0.36, 0.76),
            "stars": SIMD4(0.9, 0.76, 1, 0.95)
        ]
        let tint = colors[effect] ?? frost
        let snowScale = WeatherPhysics.snowRadiusScale(density: density)
        for particle in physics.particles {
            let p = particle.position
            var color = tint
            color.w *= Float(min(1, particle.life * (particle.spark ? 3 : 1)))
            if effect == "snow" {
                color.w *= Float(0.42 + min(0.44, particle.size * 0.24))
            }
            if particle.spark {
                disc(p, radius: particle.size, color: color)
            } else if effect == "rain" || effect == "stars" {
                let length: CGFloat = effect == "rain" ? 0.022 : 0.13
                let tail = CGPoint(x: p.x - particle.velocity.dx * length, y: p.y - particle.velocity.dy * length)
                let width = effect == "rain" ? 0.68 : 1.25
                let clear = SIMD4(color.x, color.y, color.z, 0)
                triangle(CGPoint(x: p.x - width, y: p.y), CGPoint(x: p.x + width, y: p.y), tail, color, color, clear)
            } else if effect == "fireflies" {
                let pulse = 0.62 + 0.38 * sin(particle.life * 2.3 + particle.size)
                color.w *= Float(pulse)
                disc(p, radius: particle.size * 4, color: SIMD4(color.x, color.y, color.z, color.w * 0.4), soft: true)
                disc(p, radius: particle.size, color: color)
            } else {
                disc(p, radius: particle.size * (effect == "snow" ? snowScale : 0.78), color: color)
            }
        }
        if physics.lightning > 0 {
            let flash = SIMD4<Float>(0.7, 0.82, 1, Float(physics.lightning))
            let right = CGPoint(x: bounds.width, y: 0)
            let left = CGPoint(x: 0, y: bounds.height)
            let corner = CGPoint(x: bounds.width, y: bounds.height)
            triangle(.zero, right, left, flash, flash, flash)
            triangle(right, left, corner, flash, flash, flash)
        }

        if let x = physics.ploughX { drawPlough(x: x, y: bounds.height - 4) }
        for ball in snowballs.placed { snowball(ball.center, radius: ball.radius) }
        for head in snowballs.heads { drawFace(head) }
        if let ball = snowballs.rolling { snowball(ball.center, radius: ball.radius) }
        draw()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { inFlight.signal(); return }
        let signal = inFlight
        command.addCompletedHandler { _ in signal.signal() }
        encoder.setRenderPipelineState(pipeline)
        var maskCount = UInt32(masks.count)
        var empty = SIMD4<Float>.zero
        if masks.isEmpty {
            encoder.setFragmentBytes(&empty, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        } else {
            masks.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress {
                    encoder.setFragmentBytes(base, length: buffer.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
                }
            }
        }
        encoder.setFragmentBytes(&maskCount, length: MemoryLayout<UInt32>.stride, index: 1)
        vertices.withUnsafeBufferPointer { buffer in
            guard let address = buffer.baseAddress, !buffer.isEmpty else { return }
            let length = buffer.count * MemoryLayout<WeatherVertex>.stride
            if (reusableBuffers[bufferIndex]?.length ?? 0) < length {
                reusableBuffers[bufferIndex] = device?.makeBuffer(length: max(64 * 1024, length * 2), options: .storageModeShared)
            }
            guard let geometry = reusableBuffers[bufferIndex] else { return }
            geometry.contents().copyMemory(from: address, byteCount: length)
            encoder.setVertexBuffer(geometry, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: buffer.count)
        }
        bufferIndex = (bufferIndex + 1) % reusableBuffers.count
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    private func drawBank(_ bank: SnowBank, color: SIMD4<Float>) {
        let isFloor = bank.surface.id == 0
        guard bank.profile.contains(where: { $0 > 0.16 }) else { return }
        let rect = bank.surface.rect
        let left = max(0, rect.minX)
        let right = min(bounds.width, rect.maxX)
        let count = max(3, Int((right - left) / 6))
        let shade = SIMD4<Float>(0.63, 0.77, 0.96, 0.98)
        let baseOffset: CGFloat = isFloor ? 0.9 : 1.5
        func height(at x: CGFloat) -> CGFloat {
            let depth = bank.depth(at: x)
            if isFloor {
                let nearby = (bank.depth(at: x - 16) + bank.depth(at: x + 16)) * 0.25 + depth * 0.5
                let mound = 0.24 + 0.76 * pow(0.5 + 0.5 * sin(x * 0.036 + 0.6 * sin(x * 0.009)), 1.5)
                return nearby * mound * 1.48
            }
            let wave = 0.72 + 0.15 * sin(x * 0.059) + 0.09 * sin(x * 0.113 + 2.1)
            return depth * wave * min(1, (x - left) / 11, (right - x) / 11)
        }
        var previous = CGPoint(x: left, y: bank.surface.top(at: left) + baseOffset - height(at: left))
        for i in 1...count {
            let x = left + (right - left) * CGFloat(i) / CGFloat(count)
            let base = bank.surface.top(at: x) + baseOffset
            let crest = CGPoint(x: x, y: base - height(at: x))
            let a = CGPoint(x: previous.x, y: bank.surface.top(at: previous.x) + baseOffset)
            let b = CGPoint(x: x, y: base)
            triangle(previous, crest, a, color, color, shade)
            triangle(crest, a, b, color, shade, shade)
            previous = crest
        }
    }

    private func drawPlough(x: CGFloat, y: CGFloat) {
        let amber = SIMD4<Float>(0.96, 0.65, 0.16, 1)
        let shadow = SIMD4<Float>(0.17, 0.22, 0.31, 1)
        let glass = SIMD4<Float>(0.53, 0.83, 0.92, 1)
        func rectangle(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: SIMD4<Float>) {
            let a = CGPoint(x: x, y: y)
            let b = CGPoint(x: x + w, y: y)
            let c = CGPoint(x: x, y: y + h)
            let d = CGPoint(x: x + w, y: y + h)
            triangle(a, b, c, color, color, color)
            triangle(b, c, d, color, color, color)
        }
        rectangle(x - 17, y - 11, 25, 7, amber)
        rectangle(x - 12, y - 19, 12, 9, amber)
        rectangle(x - 10, y - 17, 7, 5, glass)
        disc(CGPoint(x: x - 11, y: y - 3), radius: 4, color: shadow)
        disc(CGPoint(x: x + 2, y: y - 3), radius: 4, color: shadow)
        let blade = SIMD4<Float>(0.67, 0.78, 0.90, 1)
        triangle(CGPoint(x: x + 8, y: y - 9), CGPoint(x: x + 18, y: y + 2),
                 CGPoint(x: x + 7, y: y + 2), blade, blade, blade)
    }

    private func drawFace(_ ball: Snowball) {
        let p = ball.center
        let r = ball.radius
        let coal = SIMD4<Float>(0.07, 0.10, 0.14, 1)
        let carrot = SIMD4<Float>(1, 0.40, 0.10, 1)
        let scarf = SIMD4<Float>(0.85, 0.13, 0.25, 1)
        for x in [-0.26, 0.26] {
            disc(CGPoint(x: p.x + r * x, y: p.y - r * 0.16), radius: max(1, r * 0.08), color: coal)
        }
        triangle(p, CGPoint(x: p.x + r * 0.55, y: p.y + r * 0.13),
                 CGPoint(x: p.x, y: p.y + r * 0.23), carrot, carrot, carrot)
        let left = CGPoint(x: p.x - r * 0.53, y: p.y + r * 0.70)
        let right = CGPoint(x: p.x + r * 0.53, y: left.y)
        let a = CGPoint(x: left.x, y: left.y + r * 0.18)
        let b = CGPoint(x: right.x, y: a.y)
        triangle(left, right, a, scarf, scarf, scarf)
        triangle(right, a, b, scarf, scarf, scarf)
    }

    private func snowball(_ center: CGPoint, radius: CGFloat) {
        let frost = SIMD4<Float>(0.72, 0.85, 1, 1)
        let light = SIMD4<Float>(0.99, 0.99, 1, 0.95)
        disc(center, radius: radius, color: frost)
        let gleam = CGPoint(x: center.x - radius * 0.19, y: center.y - radius * 0.24)
        disc(gleam, radius: radius * 0.75, color: light, soft: true)
    }

    private func disc(_ center: CGPoint, radius: CGFloat, color: SIMD4<Float>, soft: Bool = false) {
        let c = clip(center)
        let scale = clipScale * Float(radius)
        let offset = SIMD2<Float>(soft ? 4 : 0, 0)
        for corner in Self.corners {
            vertices.append(WeatherVertex(point: c + corner * scale, uv: corner + offset, color: color))
        }
    }

    private func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ ca: SIMD4<Float>, _ cb: SIMD4<Float>, _ cc: SIMD4<Float>) {
        vertices.append(WeatherVertex(point: clip(a), color: ca))
        vertices.append(WeatherVertex(point: clip(b), color: cb))
        vertices.append(WeatherVertex(point: clip(c), color: cc))
    }

    private func clip(_ point: CGPoint) -> SIMD2<Float> {
        SIMD2(Float(point.x), Float(point.y)) * clipScale + SIMD2(-1, 1)
    }

}
