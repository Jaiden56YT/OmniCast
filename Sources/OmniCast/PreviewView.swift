import AppKit
import OmniEngine
import SwiftUI

/// Hosts a libobs display that draws one canvas.
struct PreviewView: NSViewRepresentable {
    let canvas: Canvas
    var enabled = true

    func makeNSView(context: Context) -> PreviewNSView {
        PreviewNSView(canvas: canvas == .vertical ? OMNI_CANVAS_VERTICAL : OMNI_CANVAS_HORIZONTAL)
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        view.setEnabled(enabled)
    }

    static func dismantleNSView(_ view: PreviewNSView, coordinator: ()) {
        view.detach()
    }
}

final class PreviewNSView: NSView {
    private let canvas: omni_canvas
    private var attached = false
    private var wanted = true
    private var occlusionObserver: NSObjectProtocol?

    init(canvas: omni_canvas) {
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var pixelSize: (UInt32, UInt32) {
        let size = convertToBacking(bounds).size
        return (UInt32(max(size.width, 1)), UInt32(max(size.height, 1)))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        guard let window else { return }
        // A minimised or fully covered window draws nothing on screen, so stop
        // rendering the preview and leave the GPU to the canvases and encoders.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyEnabled() }
        }
        guard !attached, Engine.shared.running else { return }
        let (w, h) = pixelSize
        omni_preview_attach(canvas, Unmanaged.passUnretained(self).toOpaque(), w, h)
        attached = true
        applyEnabled()
    }

    override func layout() {
        super.layout()
        guard attached else { return }
        let (w, h) = pixelSize
        omni_preview_resize(canvas, w, h)
    }

    func setEnabled(_ enabled: Bool) {
        wanted = enabled
        applyEnabled()
    }

    private func applyEnabled() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        if attached { omni_preview_set_enabled(canvas, wanted && visible) }
    }

    func detach() {
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        if attached { omni_preview_detach(canvas) }
        attached = false
    }
}
