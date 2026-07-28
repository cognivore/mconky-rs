import AppKit
import SwiftUI
import WallstatsCore

@MainActor
final class DashboardPanelController: NSObject {
    let panel: NSPanel

    private var hostingView: NSHostingView<DashboardView>?
    private var presentation: AppWindowPresentation
    private var targetScreen: NSScreen?

    init(model: AppModel) {
        presentation = model.windowPresentation
        targetScreen = NSScreen.main ?? NSScreen.screens.first
        let initialSize = Self.clampedSize(
            NSSize(width: presentation.width, height: 180),
            to: targetScreen?.visibleFrame
        )
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
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

        let rootView = DashboardView(
            model: model,
            onContentSizeChange: { [weak self] size in
                self?.updateContentSize(size)
            },
            onPresentationChange: { [weak self] presentation in
                self?.apply(presentation)
            }
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        self.hostingView = hostingView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        apply(presentation)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func apply(_ presentation: AppWindowPresentation) {
        self.presentation = presentation
        panel.ignoresMouseEvents = presentation.clickThrough
        panel.alphaValue = CGFloat(presentation.opacity)

        switch presentation.layer {
        case .desktop:
            let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow)) + 1
            panel.level = NSWindow.Level(rawValue: desktopLevel)
            panel.isFloatingPanel = false
        case .floating:
            panel.level = .floating
            panel.isFloatingPanel = true
        }

        resizePanel(requestedHeight: panel.frame.height)
        positionPanel()
    }

    private func updateContentSize(_ size: CGSize) {
        guard size.height.isFinite, size.height > 1 else { return }
        resizePanel(requestedHeight: ceil(size.height))
        positionPanel()
    }

    @objc private func screenParametersDidChange() {
        if let currentScreen = panel.screen, NSScreen.screens.contains(currentScreen) {
            targetScreen = currentScreen
        } else {
            targetScreen = NSScreen.main ?? NSScreen.screens.first
        }
        resizePanel(requestedHeight: panel.frame.height)
        positionPanel()
    }

    private func resizePanel(requestedHeight: CGFloat) {
        let size = Self.clampedSize(
            NSSize(width: presentation.width, height: requestedHeight),
            to: (targetScreen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        )
        if abs(panel.frame.width - size.width) > 0.5
            || abs(panel.frame.height - size.height) > 0.5
        {
            panel.setContentSize(size)
        }
    }

    private func positionPanel() {
        guard let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let size = panel.frame.size
        let margin = CGFloat(presentation.margin)

        let left = visibleFrame.minX + margin
        let centerX = visibleFrame.midX - size.width / 2
        let right = visibleFrame.maxX - margin - size.width
        let bottom = visibleFrame.minY + margin
        let centerY = visibleFrame.midY - size.height / 2
        let top = visibleFrame.maxY - margin - size.height

        let desiredOrigin: NSPoint
        switch presentation.anchor {
        case .topLeft:
            desiredOrigin = NSPoint(x: left, y: top)
        case .topCenter:
            desiredOrigin = NSPoint(x: centerX, y: top)
        case .topRight:
            desiredOrigin = NSPoint(x: right, y: top)
        case .centerLeft:
            desiredOrigin = NSPoint(x: left, y: centerY)
        case .center:
            desiredOrigin = NSPoint(x: centerX, y: centerY)
        case .centerRight:
            desiredOrigin = NSPoint(x: right, y: centerY)
        case .bottomLeft:
            desiredOrigin = NSPoint(x: left, y: bottom)
        case .bottomCenter:
            desiredOrigin = NSPoint(x: centerX, y: bottom)
        case .bottomRight:
            desiredOrigin = NSPoint(x: right, y: bottom)
        }
        let origin = NSPoint(
            x: min(max(desiredOrigin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(desiredOrigin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
        panel.setFrameOrigin(origin)
    }

    private static func clampedSize(_ size: NSSize, to visibleFrame: NSRect?) -> NSSize {
        guard let visibleFrame else {
            return NSSize(width: max(size.width, 1), height: max(size.height, 1))
        }
        return NSSize(
            width: min(max(size.width, 1), max(visibleFrame.width, 1)),
            height: min(max(size.height, 1), max(visibleFrame.height, 1))
        )
    }
}
