import XCTest
import AppKit
import WebKit
import MetalKit
@testable import Rise

final class ClothTransitionTests: XCTestCase {
    func testDemoClothResistanceSpringRippleClockAndExactEndpoints() {
        let released = 120.0/280.0
        XCTAssertEqual(ClothMotion.pull(distance: 120), released)
        XCTAssertEqual(ClothMotion.pull(distance: 160), 0.5)
        XCTAssertLessThan(ClothMotion.pull(distance: 10000), 1)
        var motion = ClothMotion()
        motion.release(distance: 120, at: 100, cancelled: false)
        XCTAssertEqual(motion.pull(at: 100), released)
        XCTAssertTrue(motion.ripples)
        XCTAssertEqual(motion.elapsed(at: 100), 0, "Ripple starts on release, not after settling")
        XCTAssertEqual(motion.strength, 0.4+released*0.6, accuracy: 0.0001)
        XCTAssertEqual(motion.originFraction, released*0.05, accuracy: 0.0001)
        let samples = (0...132).map { motion.pull(at: 100+Double($0)/240) }
        XCTAssertLessThan(samples.min()!, 0)
        XCTAssertGreaterThan(samples.min()!, -released*0.01)
        XCTAssertEqual(motion.pull(at: 100.55), 0)
        XCTAssertEqual(motion.pull(at: 100.17, reduceMotion: true), 0)
        motion.release(distance: 90, at: 200, cancelled: true)
        XCTAssertFalse(motion.ripples)
        XCTAssertEqual(motion.pull(at: 201), 0)
        motion.release(distance: 10, at: 300, cancelled: false)
        XCTAssertEqual(motion.pull(at: 300), 10.0/170.0, "A new release cannot inherit an old spring")
    }
    func testCompressionHasStraightFullHeightEdgesAndMirrorsForForward() {
        let size = CGSize(width: 840, height: 516)
        let back = ClothMotion.outline(size: size, pull: 1, forward: false)
        let forward = ClothMotion.outline(size: size, pull: 1, forward: true)
        XCTAssertFalse(back.contains(CGPoint(x: 41, y: 258)))
        XCTAssertTrue(back.contains(CGPoint(x: 43, y: 258)))
        XCTAssertTrue(back.contains(CGPoint(x: 839, y: 258)))
        XCTAssertFalse(forward.contains(CGPoint(x: 799, y: 258)))
        XCTAssertTrue(forward.contains(CGPoint(x: 797, y: 258)))
        XCTAssertTrue(forward.contains(CGPoint(x: 1, y: 258)))
        for y in [30.0,129,258,387,486] {
            XCTAssertFalse(back.contains(CGPoint(x:41,y:y)), "Every part of the left edge moves by the same amount")
            XCTAssertTrue(back.contains(CGPoint(x:43,y:y)))
            XCTAssertFalse(forward.contains(CGPoint(x:799,y:y)))
            XCTAssertTrue(forward.contains(CGPoint(x:797,y:y)))
        }
        for x in [60.0, 400, 820] {
            XCTAssertTrue(back.contains(CGPoint(x: x, y: 1)))
            XCTAssertTrue(back.contains(CGPoint(x: x, y: 515)))
        }
        let flat = ClothMotion.outline(size: size, pull: 0, forward: false)
        XCTAssertTrue(flat.contains(CGPoint(x: 1, y: 258)))
    }
    @MainActor func testOuterFrameFillClipAndShadowFollowBothBendingEdgesAndRestore() throws {
        _ = NSApplication.shared
        let size = CGSize(width:840,height:516), sheet = CGRect(origin:.zero,size:size)
        let shadow = PageSurface(color:.white,radius:7), clip = PageSurface(color:.white,radius:7)
        shadow.frame = sheet; clip.frame = sheet
        for forward in [false,true] {
            let path = try XCTUnwrap(ClothMotion.frameOutline(size:size,sheet:sheet,pull:0.6,forward:forward))
            shadow.setClothOutline(path); clip.setClothOutline(path,clipContents:true)
            let gap = CGPoint(x:forward ? 839 : 1,y:258)
            XCTAssertFalse(try XCTUnwrap(shadow.layer?.shadowPath).contains(gap), "The shadow must leave the stationary edge")
            XCTAssertFalse(try XCTUnwrap((clip.layer?.mask as? CAShapeLayer)?.path).contains(gap))
            XCTAssertEqual(shadow.layer?.backgroundColor, NSColor.clear.cgColor)
            shadow.fill = .black; clip.fill = .black
            shadow.refreshOutline(); clip.refreshOutline()
            XCTAssertEqual(shadow.layer?.backgroundColor, NSColor.clear.cgColor, "Navigation/theme updates must not bring back the old rectangular backing")
            XCTAssertFalse(try XCTUnwrap(shadow.layer?.shadowPath).contains(gap))
            shadow.setClothOutline(nil); clip.setClothOutline(nil)
            XCTAssertTrue(try XCTUnwrap(shadow.layer?.shadowPath).contains(gap))
            XCTAssertNil(clip.layer?.mask)
            XCTAssertEqual(shadow.layer?.backgroundColor, NSColor.black.cgColor)
        }
        let body = CGRect(x:0,y:40,width:840,height:476)
        let dev = try XCTUnwrap(ClothMotion.frameOutline(size:size,sheet:body,pull:0.6,forward:false))
        XCTAssertFalse(dev.contains(CGPoint(x:1,y:20)), "Developer header follows the full-height compression")
        XCTAssertFalse(dev.contains(CGPoint(x:1,y:body.midY)))
        XCTAssertNil(ClothMotion.frameOutline(size:size,sheet:CGRect(x:423,y:0,width:417,height:516),pull:0.6,forward:false), "An interior split edge cannot deform the opposite pane's frame")
    }
    @MainActor private func image(width: Int = 840, height: Int = 516, gradient: Bool, blue: Bool = false, verticalGradient: Bool = false) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width*height*4)
        for y in 0..<height { for x in 0..<width {
            let i = (y*width+x)*4
            bytes[i] = blue ? 0 : (gradient ? UInt8(x*255/(width-1)) : 230)
            bytes[i+1] = verticalGradient ? UInt8(y*255/(height-1)) : 0; bytes[i+2] = blue ? 230 : 0
        } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
    @MainActor private func render(_ renderer: ClothRenderer, _ uniforms: ClothUniforms) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 840, height: 516, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        XCTAssertTrue(renderer.encode(pass, uniforms: uniforms, into: command))
        command.commit(); command.waitUntilCompleted(); XCTAssertNil(command.error)
        var data = [UInt8](repeating: 0, count: 840*516*4)
        data.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 840*4, from: MTLRegionMake2D(0,0,840,516), mipmapLevel: 0) }
        return data
    }
    @MainActor func testRealMetalWarpRippleImmediateRevealAndMirroredDestination() throws {
        let renderer = try XCTUnwrap(ClothRenderer(), "Cloth Metal shader must compile on the supported Mac")
        try renderer.setOutgoing(image(gradient: true))
        var u = ClothUniforms()
        let flat = try render(renderer,u)
        u.pull = 1
        let bent = try render(renderer,u)
        let middle = (258*840+84)*4+2
        XCTAssertGreaterThan(flat[middle], bent[middle], "Content bends with the outline rather than only clipping its edge")
        XCTAssertEqual(flat[(258*840+839)*4+2], bent[(258*840+839)*4+2], accuracy: 1, "Far edge stays pinned")
        for y in [40,129,387,475] {
            XCTAssertEqual(bent[(y*840+84)*4+2], bent[middle], accuracy:1, "Horizontal compression is equal at every height")
        }
        XCTAssertGreaterThan(Int(flat[(40*840+84)*4+2])-Int(bent[(40*840+84)*4+2]),
                             Int(flat[(40*840+700)*4+2])-Int(bent[(40*840+700)*4+2]), "Displacement tapers toward the fixed edge")
        try renderer.setOutgoing(image(gradient:false,verticalGradient:true))
        u.pull = 0; let verticalFlat = try render(renderer,u)
        u.pull = 1; let verticalCompressed = try render(renderer,u)
        for y in [40,129,258,387,475] {
            XCTAssertEqual(verticalFlat[(y*840+84)*4+1],verticalCompressed[(y*840+84)*4+1], "Compression must not shear content vertically")
        }
        try renderer.setOutgoing(image(gradient: false))
        try renderer.setIncoming(image(gradient: false, blue: true))
        u.pull = 0.6; u.elapsed = 0; u.strength = 0.76; u.originFraction = 0.03; u.reveal = 1
        let release = try render(renderer,u)
        let origin = (258*840+25)*4
        XCTAssertGreaterThan(release[origin], 0, "Destination starts showing at the released edge immediately")
        u.elapsed = 0.12
        let reveal = try render(renderer,u)
        for y in [20,129,387,495] {
            for x in [120,360,800] {
                for channel in [0,2] {
                    XCTAssertEqual(reveal[(y*840+x)*4+channel], reveal[(258*840+x)*4+channel], accuracy: 1, "Ripple and reveal advance equally across the entire page height")
                }
            }
        }
        XCTAssertGreaterThan(reveal[(258*840+120)*4], 200)
        XCTAssertGreaterThan(reveal[(258*840+800)*4+2], 200)
        u.forward = 1
        let mirrored = try render(renderer,u)
        XCTAssertGreaterThan(mirrored[(258*840+720)*4], 200)
        XCTAssertGreaterThan(mirrored[(258*840+40)*4+2], 200)
        u.elapsed = Float(ClothMotion.rippleDuration); u.pull = 0
        let done = try render(renderer,u)
        XCTAssertEqual(done[(258*840+20)*4], 230, accuracy: 1)
        XCTAssertEqual(done[(258*840+820)*4+2], 0)
        u.reveal = 0
        let cancelled = try render(renderer,u)
        XCTAssertEqual(cancelled[(258*840+20)*4+2], 230, accuracy: 1, "Cancelled swipes never reveal the destination")
        renderer.clear(); XCTAssertNil(renderer.outgoing); XCTAssertNil(renderer.incoming)
    }
}
