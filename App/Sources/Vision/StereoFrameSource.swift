#if os(visionOS)
import AzaharCore
import Metal
import QuartzCore
import RealityKit

/// Feeds the emulator's frames into RealityKit textures.
///
/// Vulkan (device): the core renders side-by-side full-width stereo into an offscreen texture
/// ring (az_offscreen_*). Each RealityKit update takes the newest frame and blits it into one
/// LowLevelTexture; both panels sample it, the top one per eye (StereoScreen.usda).
/// Software renderer (Simulator): the two screens arrive as CPU pixels (az_get_software_frame) and
/// are uploaded into one texture each; there is no right eye then.
@MainActor
final class StereoFrameSource {
    /// Handed to the core with az_set_surface. The Vulkan renderer needs a surface to set up,
    /// but with offscreen output nothing is ever presented to it, so it is never shown.
    let layer = CAMetalLayer()
    /// Pixel size of the stereo frame: two eye halves of `eyeSize` side by side.
    let eyeSize: (width: Int, height: Int)
    var frameSize: (width: Int, height: Int) { (eyeSize.width * 2, eyeSize.height) }

    /// Where a panel samples: its texture and the rect of its screen for each eye, in 0...1.
    struct Source {
        let texture: TextureResource
        let left: CGRect
        let right: CGRect
    }
    /// Called when the texture or the screen rects change (first frame, size change).
    var onSources: ((_ top: Source?, _ bottom: Source?) -> Void)?
    /// Bottom screen rect in surface pixels, for touch input.
    private(set) var bottomPixelRect: CGRect?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var stereoTexture: LowLevelTexture?
    private var stereoResource: TextureResource?
    private var generation: UInt64 = .max
    private var lastFrame: UInt64 = 0
    private var rects: (top: CGRect, bottom: CGRect)?

    private var softwareTextures: [LowLevelTexture?] = [nil, nil]
    private var softwareResources: [TextureResource?] = [nil, nil]
    private var softwareCounter: UInt64 = 0
    private var softwareBuffer: [UInt8] = []

    init(eyeWidth: Int, eyeHeight: Int) {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        eyeSize = (eyeWidth, eyeHeight)
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: eyeWidth * 2, height: eyeHeight)
    }

    /// Gives the surface to the core: double width, portrait layout (top screen over bottom).
    func attach() {
        let ptr = Unmanaged.passUnretained(layer).toOpaque()
        az_set_surface(ptr, Int32(frameSize.width), Int32(frameSize.height), true)
    }

    func detach() {
        if !az_is_running() { az_set_surface(nil, 0, 0, false) }
    }

    /// Once per RealityKit frame.
    func pump() {
        VisionHangWatchdog.shared.pumped(frame: lastFrame)
        updateRects()
        if az_is_software_renderer() {
            pumpSoftware()
        } else {
            pumpStereo()
        }
    }

    // MARK: Layout

    /// The core's screen rects (left-eye half, surface pixels). They only change with the layout.
    private func updateRects() {
        var t = AZScreenRect(), b = AZScreenRect()
        guard az_get_screen_rects(&t, &b) else { return }
        let top = CGRect(x: CGFloat(t.x), y: CGFloat(t.y), width: CGFloat(t.width), height: CGFloat(t.height))
        let bottom = CGRect(x: CGFloat(b.x), y: CGFloat(b.y), width: CGFloat(b.width), height: CGFloat(b.height))
        guard rects == nil || rects!.top != top || rects!.bottom != bottom else { return }
        rects = (top, bottom)
        bottomPixelRect = b.enabled ? bottom : nil
        publish()
    }

    private func publish() {
        if az_is_software_renderer() {
            let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
            onSources?(softwareResources[0].map { Source(texture: $0, left: whole, right: whole) },
                       softwareResources[1].map { Source(texture: $0, left: whole, right: whole) })
            return
        }
        guard let resource = stereoResource, let rects else { return }
        let w = CGFloat(frameSize.width), h = CGFloat(frameSize.height)
        func unit(_ r: CGRect, eye: Int) -> CGRect {
            CGRect(x: (r.minX + CGFloat(eye) * w / 2) / w, y: r.minY / h, width: r.width / w, height: r.height / h)
        }
        onSources?(Source(texture: resource, left: unit(rects.top, eye: 0), right: unit(rects.top, eye: 1)),
                   Source(texture: resource, left: unit(rects.bottom, eye: 0), right: unit(rects.bottom, eye: 0)))
    }

    // MARK: Vulkan offscreen frames

    private func pumpStereo() {
        var frame = AZOffscreenFrame()
        guard az_offscreen_acquire(&frame) else { return }
        let slot = frame.slot
        guard frame.frame != lastFrame, let ptr = frame.texture else {
            az_offscreen_release(slot)
            return
        }
        let source = Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as! MTLTexture
        if stereoTexture == nil || generation != frame.generation {
            generation = frame.generation
            do {
                // Mipmapped: the panel usually shows the frame smaller than its pixel size, and
                // sampling level 0 alone shimmers there.
                let levels = Int(log2(Double(max(source.width, source.height)))) + 1
                let texture = try LowLevelTexture(descriptor: .init(
                    textureType: .type2D, pixelFormat: source.pixelFormat,
                    width: source.width, height: source.height, depth: 1,
                    mipmapLevelCount: levels, textureUsage: [.shaderRead, .shaderWrite]))
                stereoTexture = texture
                stereoResource = try TextureResource(from: texture)
                VisionDiag.log("stereo: frame texture \(source.width)x\(source.height) format \(source.pixelFormat.rawValue)")
            } catch {
                NSLog("Holofold stereo: cannot create the frame texture: %@", "\(error)")
                az_offscreen_release(slot)
                return
            }
            publish()
        }
        guard let target = stereoTexture, let commands = queue.makeCommandBuffer() else {
            az_offscreen_release(slot)
            return
        }
        let destination = target.replace(using: commands)
        if let blit = commands.makeBlitCommandEncoder() {
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                      to: destination, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            if destination.mipmapLevelCount > 1 { blit.generateMipmaps(for: destination) }
            blit.endEncoding()
        }
        commands.addCompletedHandler { _ in az_offscreen_release(slot) }
        commands.commit()
        lastFrame = frame.frame
    }

    // MARK: Software renderer frames (Simulator)

    private func pumpSoftware() {
        var w: Int32 = 0, h: Int32 = 0
        let counter = az_get_software_frame(0, nil, 0, &w, &h)
        guard counter != 0, counter != softwareCounter else { return }
        softwareCounter = counter
        var changed = false
        for screen in 0..<2 {
            var sw: Int32 = 0, sh: Int32 = 0
            _ = az_get_software_frame(Int32(screen), nil, 0, &sw, &sh)
            guard sw > 0, sh > 0 else { continue }
            let size = Int(sw) * Int(sh) * 4
            if softwareBuffer.count < size { softwareBuffer = [UInt8](repeating: 0, count: size) }
            softwareBuffer.withUnsafeMutableBufferPointer { p in
                _ = az_get_software_frame(Int32(screen), p.baseAddress, Int32(size), &sw, &sh)
            }
            if softwareTextures[screen].map({ $0.descriptor.width != Int(sw) || $0.descriptor.height != Int(sh) }) ?? true {
                guard let texture = try? LowLevelTexture(descriptor: .init(
                    textureType: .type2D, pixelFormat: .rgba8Unorm, width: Int(sw), height: Int(sh),
                    depth: 1, mipmapLevelCount: 1, textureUsage: [.shaderRead, .shaderWrite])) else { continue }
                softwareTextures[screen] = texture
                softwareResources[screen] = try? TextureResource(from: texture)
                changed = true
            }
            guard let texture = softwareTextures[screen],
                  let staging = device.makeBuffer(bytes: softwareBuffer, length: size, options: .storageModeShared),
                  let commands = queue.makeCommandBuffer() else { continue }
            let destination = texture.replace(using: commands)
            if let blit = commands.makeBlitCommandEncoder() {
                blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: Int(sw) * 4,
                          sourceBytesPerImage: size, sourceSize: MTLSize(width: Int(sw), height: Int(sh), depth: 1),
                          to: destination, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
            }
            commands.commit()
        }
        if changed { publish() }
    }
}
#endif
