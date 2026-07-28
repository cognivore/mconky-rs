import AppKit
import Testing
@testable import Wallstats
@testable import WallstatsCore

@Suite("Desktop surface placement")
struct DesktopSurfacePlacementTests {
    @Test("Each origin applies offsets inward from its screen corner", arguments: [
        (SurfaceOrigin.bottomLeft, NSPoint(x: 32, y: 32)),
        (SurfaceOrigin.topLeft, NSPoint(x: 32, y: 668)),
        (SurfaceOrigin.bottomRight, NSPoint(x: 928, y: 32)),
        (SurfaceOrigin.topRight, NSPoint(x: 928, y: 668)),
    ])
    func cornerOrigins(origin: SurfaceOrigin, expected: NSPoint) {
        let frame = DesktopSurfacePlacement.frame(
            width: 480,
            height: 200,
            x: 32,
            y: 32,
            origin: origin,
            screenFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 876)
        )

        #expect(frame.origin == expected)
    }

    @Test("Placement remains inside the visible frame")
    func visibleFrameClamping() {
        let frame = DesktopSurfacePlacement.frame(
            width: 480,
            height: 200,
            x: 0,
            y: 0,
            origin: .bottomLeft,
            screenFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: NSRect(x: 80, y: 24, width: 1_360, height: 852)
        )

        #expect(frame.origin == NSPoint(x: 80, y: 24))
    }
}
