// Portalistic — draws the picture with Metal (MetalFX spatial upscaling to the window).

import AppKit
import CoreGraphics
import Metal
import MetalFX
import QuartzCore

/// Shows the VM's picture with Metal: the part that changed goes into a texture, MetalFX's
/// spatial scaler enlarges it to the window's pixel size (sharper than plain stretching: it
/// finds edges and sharpens them), and it's drawn in step with the display. Without MetalFX, or
/// when the window is smaller than the picture or over twice its size, plain smooth scaling.
final class Renderer {
    let layer = CAMetalLayer()
    var sharpScaling = true
    private(set) var mode = ""                   // what the last frame used, for Stream Info
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var input: MTLTexture?               // the VM's screen
    private var output: MTLTexture?              // MetalFX's result
    private var scaler: MTLFXSpatialScaler?
    private var scalerSize = (0, 0, 0, 0)        // input w, h, output w, h
    private var noScaler = false                 // this Mac's GPU can't
    private var failedSize = (0, 0, 0, 0)        // a scaler that couldn't be made for these sizes
    // Never wait on the main thread (it also handles the mouse): draw only when the GPU is done
    // with the texture and at most one picture waits for the display. Otherwise the change
    // keeps adding up, and onReady (main thread) asks for a redraw when there's room again.
    private var gpuBusy = false
    private var queued = 0                       // drawables not yet on screen
    private var queuedAt = 0.0
    private var wanted = false                   // a draw was skipped: redraw when there's room
    var onReady: (() -> Void)?

    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    // One triangle that covers the viewport; uv 0..1 over it, top-left = 0,0.
    vertex VOut v_main(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }
    fragment float4 f_main(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
        return float4(tex.sample(smp, in.uv).rgb, 1.0);
    }
    """

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(),
              let lib = try? d.makeLibrary(source: Renderer.shaders, options: nil),
              let vf = lib.makeFunction(name: "v_main"), let ff = lib.makeFunction(name: "f_main") else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vf
        pd.fragmentFunction = ff
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let ps = try? d.makeRenderPipelineState(descriptor: pd), let sm = d.makeSamplerState(descriptor: sd) else { return nil }
        device = d
        queue = q
        pipeline = ps
        sampler = sm
        noScaler = !MTLFXSpatialScalerDescriptor.supportsDevice(d)
        layer.device = d
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.displaySyncEnabled = true          // in step with the display: no tearing
        layer.maximumDrawableCount = 3
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.backgroundColor = NSColor.black.cgColor
    }

    /// Draws the picture at `picture` (drawable pixels, top-left origin; the rest is black).
    /// live: the window is being resized (no new MetalFX scaler for every in-between size).
    func draw(_ fb: Framebuffer, picture: CGRect, live: Bool = false) {
        let now = CACurrentMediaTime()
        if queued > 0 && now - queuedAt > 0.5 { queued = 0 }   // a present that never reported back
        guard !gpuBusy && queued < 2 else { wanted = true; return }
        wanted = false
        if input == nil || input?.width != fb.width || input?.height != fb.height {
            input = makeInput(fb.width, fb.height, usage: .shaderRead)
            scaler = nil
            fb.lock.lock()
            fb.dirty = CGRect(x: 0, y: 0, width: fb.width, height: fb.height)
            fb.lock.unlock()
        }
        // the picture's place, kept inside the drawable
        let ds = layer.drawableSize
        let ox = max(0, picture.minX), oy = max(0, picture.minY)
        let outW = Int(min(picture.width, ds.width - ox)), outH = Int(min(picture.height, ds.height - oy))
        guard outW > 0, outH > 0 else { return }

        // MetalFX for enlarging up to 2x; plain smooth scaling otherwise
        var useScaler = false
        let sizes = (fb.width, fb.height, outW, outH)
        if sharpScaling && !noScaler && !live && outW > fb.width && outH > fb.height
            && outW <= fb.width * 2 && outH <= fb.height * 2 && sizes != failedSize {
            if scaler == nil || scalerSize != sizes { makeScaler(fb, outW, outH) }
            useScaler = scaler != nil && output != nil
        }
        guard let tex = input else { return }

        // the changed part of the picture into the texture
        fb.lock.lock()
        let d = fb.dirty.intersection(CGRect(x: 0, y: 0, width: fb.width, height: fb.height))
        if !d.isNull && !d.isEmpty {
            let x = Int(d.minX), y = Int(d.minY), w = Int(d.width), h = Int(d.height)
            tex.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0,
                        withBytes: fb.data + y * fb.stride + x * 4, bytesPerRow: fb.stride)
        }
        fb.dirty = .null
        fb.lock.unlock()

        guard let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else {
            // no drawable this time (the texture has the change already): try again shortly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.onReady?() }
            return
        }
        var source = tex
        if useScaler, let sc = scaler, let out = output {
            sc.colorTexture = tex
            sc.inputContentWidth = fb.width
            sc.inputContentHeight = fb.height
            sc.outputTexture = out
            sc.encode(commandBuffer: cb)
            source = out
            mode = "MetalFX"
        } else {
            mode = outW == fb.width && outH == fb.height ? "1:1" : "smooth scaling"
        }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setViewport(MTLViewport(originX: Double(ox), originY: Double(oy),
                                    width: Double(outW), height: Double(outH), znear: 0, zfar: 1))
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        gpuBusy = true
        queued += 1
        queuedAt = now
        cb.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async { self?.gpuBusy = false; self?.readyAgain() }
        }
        drawable.addPresentedHandler { [weak self] _ in
            DispatchQueue.main.async {
                if let r = self, r.queued > 0 { r.queued -= 1 }
                self?.readyAgain()
            }
        }
        cb.present(drawable)
        cb.commit()
    }

    private func readyAgain() {
        if wanted && !gpuBusy && queued < 2 { onReady?() }
    }

    private func makeInput(_ w: Int, _ h: Int, usage: MTLTextureUsage) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = usage.union(.shaderRead)
        td.storageMode = .shared                 // filled by the CPU (Apple silicon: no copy)
        return device.makeTexture(descriptor: td)
    }

    private func makeScaler(_ fb: Framebuffer, _ ow: Int, _ oh: Int) {
        scaler = nil
        output = nil
        scalerSize = (fb.width, fb.height, ow, oh)
        let desc = MTLFXSpatialScalerDescriptor()
        desc.inputWidth = fb.width
        desc.inputHeight = fb.height
        desc.outputWidth = ow
        desc.outputHeight = oh
        desc.colorTextureFormat = .bgra8Unorm
        desc.outputTextureFormat = .bgra8Unorm
        desc.colorProcessingMode = .perceptual   // ordinary (gamma-encoded) colours
        guard let sc = desc.makeSpatialScaler(device: device) else { failedSize = scalerSize; return }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: ow, height: oh, mipmapped: false)
        td.usage = sc.outputTextureUsage.union(.shaderRead)
        td.storageMode = .private
        guard let out = device.makeTexture(descriptor: td) else { return }
        // the input texture must allow what the scaler does with it
        if let tex = input, !tex.usage.contains(sc.colorTextureUsage) {
            input = makeInput(fb.width, fb.height, usage: sc.colorTextureUsage)
            fb.lock.lock()
            fb.dirty = CGRect(x: 0, y: 0, width: fb.width, height: fb.height)
            fb.lock.unlock()
        }
        scaler = sc
        output = out
    }
}
