import MetalKit
import SwiftUI
import UIKit

/// MetalKit view that displays the live camera preview.
///
/// Subscribes to CameraManager's previewSink and renders the RGBA preview texture via
/// a passthrough blit. Keeps a CADisplayLink for vsync-aligned draws.
public final class PreviewView: MTKView, MTKViewDelegate {

    private let renderer = MetalLogRenderer.shared
    private var displayLink: CADisplayLink?
    private var currentTexture: MTLTexture?

    public init() {
        super.init(frame: .zero, device: MetalLogRenderer.shared.device)
        configure()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        self.device = renderer.device
        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        self.preferredFramesPerSecond = 60
        self.framebufferOnly = true
        self.isOpaque = true
        self.backgroundColor = .black
        self.contentMode = .scaleAspectFit
        self.isPaused = false  // Auto-draw at preferredFramesPerSecond

        // Subscribe to preview sink
        CameraManager.shared.previewSink = { [weak self] texture in
            self?.currentTexture = texture
        }

        startDisplayLink()
    }

    private func startDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func displayLinkFired() {
        // MTKView's setNeedsDisplay is private — but it auto-draws at
        // preferredFramesPerSecond when isPaused = false. We set isPaused = false
        // at init, so the display link here is just a safety tick to keep the view
        // alive even when no new frames have arrived.
        // No-op: MTKView handles its own drawing cadence.
    }

    // MARK: MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // No-op — we don't preallocate based on view size; we draw the source texture
        // scaled to fit.
    }

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let texture = currentTexture,
              let cmd = renderer.commandQueue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return }

        // Just blit the preview texture into the drawable.
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: min(texture.width, drawable.texture.width),
                                       height: min(texture.height, drawable.texture.height),
                                       depth: 1),
                  to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

// MARK: - SwiftUI bridge

public struct PreviewViewRepresentable: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> PreviewView {
        return PreviewView()
    }

    public func updateUIView(_ uiView: PreviewView, context: Context) {
        // No-op — the view is self-contained.
    }
}
