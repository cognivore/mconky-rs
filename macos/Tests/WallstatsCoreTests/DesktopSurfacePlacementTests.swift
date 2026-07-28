import AppKit
import Testing
@testable import Wallstats

@Suite("Desktop surface placement")
struct DesktopSurfacePlacementTests {
    @Test("Zero coordinates place the surface at the visible bottom-left")
    func bottomLeftOrigin() {
        let frame = DesktopSurfacePlacement.frame(
            width: 480,
            height: 200,
            x: 0,
            y: 0,
            screenFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: NSRect(x: 0, y: 24, width: 1_440, height: 852)
        )

        #expect(frame.origin == NSPoint(x: 0, y: 24))
    }

    @Test("Positive coordinates move right and up from bottom-left")
    func positiveOffsets() {
        let frame = DesktopSurfacePlacement.frame(
            width: 480,
            height: 200,
            x: 270,
            y: 40,
            screenFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 876)
        )

        #expect(frame.origin == NSPoint(x: 270, y: 40))
    }
}
