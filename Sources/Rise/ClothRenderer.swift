import AppKit
import MetalKit

struct ClothUniforms {
    var size = SIMD2<Float>(840, 516)
    var pull: Float = 0
    var elapsed: Float = -1
    var strength: Float = 0
    var originFraction: Float = 0
    var forward: Float = 0
    var reveal: Float = 0
}

/// AppKit/Metal equivalent of the demo's distortionEffect, colorEffect and
/// layerEffect. The compositor samples both warped pages at the ripple offset.
@MainActor final class ClothRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private(set) var outgoing: MTLTexture?
    private(set) var incoming: MTLTexture?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let url = Bundle.module.url(forResource: "PageCloth", withExtension: "metal", subdirectory: "Shaders") else { return nil }
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "clothVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "clothFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            self.device = device; self.queue = queue
        } catch { NSLog("Rise cloth renderer: %@", error.localizedDescription); return nil }
    }
    func setOutgoing(_ image: CGImage) throws {
        outgoing = try texture(image)
    }
    func setIncoming(_ image: CGImage?) throws {
        incoming = try image.map { try texture($0) }
    }
    private func texture(_ image: CGImage) throws -> MTLTexture {
        // MTKTextureLoader's CGImage path can return a non-sRGB texture despite
        // its SRGB option. Explicit color conversion/upload prevents a visible
        // gamma or text-weight jump when the snapshot replaces the live page.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
            width: image.width, height: image.height, mipmapped: false)
        descriptor.usage = .shaderRead; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw NSError(domain: "Rise.Cloth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn’t allocate the page texture."])
        }
        var pixels = [UInt8](repeating: 0, count: image.width*image.height*4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width*4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw NSError(domain: "Rise.Cloth", code: 2)
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            texture.replace(region: MTLRegionMake2D(0,0,image.width,image.height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: image.width*4)
        }
        return texture
    }
    func clear() { outgoing = nil; incoming = nil }
    @discardableResult func encode(_ descriptor: MTLRenderPassDescriptor, uniforms: ClothUniforms,
                                   into command: MTLCommandBuffer) -> Bool {
        guard let outgoing, let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ClothUniforms>.stride, index: 0)
        encoder.setFragmentTexture(outgoing, index: 0)
        encoder.setFragmentTexture(incoming ?? outgoing, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding(); return true
    }
}

final class ClothBackdrop: Surface {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class ClothMetalView: MTKView {
    var corner: CGFloat = 7
    var continuous = false
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private let outline = CAShapeLayer()
    init(renderer: ClothRenderer) {
        super.init(frame: .zero, device: renderer.device)
        wantsLayer = true
        colorPixelFormat = .bgra8Unorm_srgb
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        isPaused = true; enableSetNeedsDisplay = false; framebufferOnly = true
        layer?.isOpaque = false; layer?.mask = outline
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        outline.fillColor = NSColor.white.cgColor
        setAccessibilityElement(false)
    }
    required init(coder: NSCoder) { fatalError() }
    func setOutline(pull: Double, forward: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outline.frame = bounds
        outline.path = ClothMotion.outline(size: bounds.size, pull: pull, forward: forward, corner: corner, continuous: continuous)
        CATransaction.commit()
    }
}
