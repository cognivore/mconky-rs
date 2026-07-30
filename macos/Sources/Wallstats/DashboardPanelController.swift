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
               let configuredY = surface.y,
               let origin = surface.origin,
               let configuredContentInset = surface.contentInset
        else {
            hide()
            return
        }

        let visible = screen.visibleFrame
        let screenFrame = screen.frame
        let width = min(max(CGFloat(configuredWidth), 1), visible.width)
        let contentInset = CGFloat(configuredContentInset)
        let contentWidth = max(width - contentInset * 2, 0)
        let layout = EditorialLayoutSolver.solve(root: surface.root, width: contentWidth)
        let height = min(
            max(CGFloat(layout.resolvedHeight) + contentInset * 2, 1),
            visible.height
        )
        let frame = DesktopSurfacePlacement.frame(
            width: width,
            height: height,
            x: CGFloat(configuredX),
            y: CGFloat(configuredY),
            origin: origin,
            screenFrame: screenFrame,
            visibleFrame: visible
        )

        panel.ignoresMouseEvents = surface.clickThrough ?? true
        panel.backgroundColor = NSColor.black.withAlphaComponent(
            CGFloat(surface.backgroundOpacity ?? 0)
        )
        panel.setFrame(frame, display: true)

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

enum DesktopSurfacePlacement {
    static func frame(
        width: CGFloat,
        height: CGFloat,
        x: CGFloat,
        y: CGFloat,
        origin: SurfaceOrigin,
        screenFrame: NSRect,
        visibleFrame: NSRect
    ) -> NSRect {
        let desiredX: CGFloat
        let desiredY: CGFloat
        switch origin {
        case .bottomLeft:
            desiredX = screenFrame.minX + x
            desiredY = screenFrame.minY + y
        case .topLeft:
            desiredX = screenFrame.minX + x
            desiredY = screenFrame.maxY - y - height
        case .bottomRight:
            desiredX = screenFrame.maxX - x - width
            desiredY = screenFrame.minY + y
        case .topRight:
            desiredX = screenFrame.maxX - x - width
            desiredY = screenFrame.maxY - y - height
        }
        let origin = NSPoint(
            x: min(max(desiredX, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(desiredY, visibleFrame.minY), visibleFrame.maxY - height)
        )
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }
}
