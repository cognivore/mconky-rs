import AppKit
import SwiftUI
import WallstatsCore

@MainActor
final class DashboardPanelController: NSObject {
    let panel: NSPanel

    private let model: AppModel
    private var surface: SurfacePlan
    private var hostingView: NSHostingView<DesktopSurfaceView>?

    init(model: AppModel, surface: SurfacePlan) {
        self.model = model
        self.surface = surface
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        applySurface()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func update(surface: SurfacePlan) {
        self.surface = surface
        applySurface()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    @objc private func screenParametersDidChange() {
        applySurface()
    }

    private func applySurface() {
        guard surface.kind == .desktop,
              let screen = NSScreen.main ?? NSScreen.screens.first,
              let configuredWidth = surface.width,
              let configuredX = surface.x,
              let configuredY = surface.y
        else {
            hide()
            return
        }

        let visible = screen.visibleFrame
        let screenFrame = screen.frame
        let width = min(max(CGFloat(configuredWidth), 1), visible.width)
        let layout = EditorialLayoutSolver.solve(root: surface.root, width: width)
        let height = min(max(CGFloat(layout.resolvedHeight), 1), visible.height)
        let desiredX = screenFrame.minX + CGFloat(configuredX)
        let desiredY = screenFrame.maxY - CGFloat(configuredY) - height
        let origin = NSPoint(
            x: min(max(desiredX, visible.minX), visible.maxX - width),
            y: min(max(desiredY, visible.minY), visible.maxY - height)
        )

        panel.ignoresMouseEvents = surface.clickThrough ?? true
        panel.backgroundColor = NSColor.black.withAlphaComponent(
            CGFloat(surface.backgroundOpacity ?? 0)
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)

        let rootView = DesktopSurfaceView(model: model, surface: surface)
        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hostingView
            self.hostingView = hostingView
        }
        show()
    }
}
