import Foundation
import Testing
@testable import WallstatsCore

@Suite("Surface protocol")
struct SurfaceProtocolTests {
    @Test("Rust surface JSON decodes and round-trips exactly")
    func surfaceRoundTrip() throws {
        let data = Data(#"""
        [
          {"kind":"desktop","root":{"kind":"stack","gap":4.0,"children":[{"kind":"widget","widget":{"kind":"value","label":"CPU","metric":"cpu","format":"percent"}}]},"x":32.0,"y":32.0,"origin":"bottom_left","width":400.0,"content_inset":16.0,"background_opacity":0.0,"click_through":true},
          {"kind":"widget_medium","root":{"kind":"split","gap":6.0,"minimum_track_width":120.0,"tracks":[{"weight":2.0,"child":{"kind":"widget","widget":{"kind":"value","label":"CPU","metric":"cpu","format":"percent"}}},{"weight":1.0,"child":{"kind":"widget","widget":{"kind":"compact_status","label":"Backup","metric":"backup","format":"compact_status"}}}]}}
        ]
        """#.utf8)
        let surfaces = try JSONDecoder().decode([SurfacePlan].self, from: data)

        #expect(surfaces.map(\.kind) == [.desktop, .widgetMedium])
        #expect(try JSONDecoder().decode(
            [SurfacePlan].self,
            from: JSONEncoder().encode(surfaces)
        ) == surfaces)
    }

    @Test("Desktop surfaces without an origin retain legacy top-left placement")
    func legacyDesktopOrigin() throws {
        let data = Data(#"{"kind":"desktop","root":{"kind":"widget","widget":{"kind":"value","label":"CPU","metric":"cpu","format":"percent"}},"x":0,"y":0,"width":400,"background_opacity":0,"click_through":true}"#.utf8)
        let surface = try JSONDecoder().decode(SurfacePlan.self, from: data)

        #expect(surface.origin == .topLeft)
    }

    @Test("Old plans decode with no surfaces")
    func oldPlanDefaults() throws {
        let plan = DashboardPlan(
            title: "old",
            metrics: [],
            window: testWindow(),
            sections: []
        )
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(DashboardPlan.self, from: data)
        #expect(decoded.surfaces.isEmpty)
    }

    @Test("Surface validation rejects duplicates, geometry, dimensions, and references")
    func invalidSurfaceModels() {
        let metric = MetricDefinition(id: "cpu", valueType: .ratio, staleAfterMS: 1_000)
        let leaf = LayoutNode.widget(WidgetPlan(
            kind: .value,
            label: "CPU",
            metric: "cpu",
            format: .percent
        ))
        let invalidSurfaces: [[SurfacePlan]] = [
            [
                SurfacePlan(kind: .widgetSmall, root: leaf),
                SurfacePlan(kind: .widgetSmall, root: leaf),
            ],
            [SurfacePlan(kind: .desktop, root: leaf, x: 0, y: 0, origin: .bottomLeft, width: 0, contentInset: 16, backgroundOpacity: 0, clickThrough: true)],
            [SurfacePlan(kind: .widgetMedium, root: .stack(gap: -.infinity, children: [leaf]))],
            [SurfacePlan(kind: .widgetMedium, root: .stack(gap: 0, children: []))],
            [SurfacePlan(kind: .widgetMedium, root: .split(
                gap: 0,
                minimumTrackWidth: 10,
                tracks: [LayoutTrack(weight: 0, child: leaf)]
            ))],
            [SurfacePlan(kind: .widgetMedium, root: .widget(WidgetPlan(
                kind: .value,
                label: "Missing",
                metric: "missing",
                format: .number
            )))],
        ]

        for surfaces in invalidSurfaces {
            let plan = DashboardPlan(
                title: "invalid",
                metrics: [metric],
                window: testWindow(),
                sections: [],
                surfaces: surfaces
            )
            #expect(throws: ProtocolValidationError.self) {
                try ProtocolValidator.validate(plan)
            }
        }
    }

    @Test("Surface validation enforces depth and node limits")
    func depthAndNodeLimits() {
        let metric = MetricDefinition(id: "cpu", valueType: .ratio, staleAfterMS: 1_000)
        let leaf = LayoutNode.widget(WidgetPlan(
            kind: .value,
            label: "CPU",
            metric: "cpu",
            format: .percent
        ))

        var deep = leaf
        for _ in 0 ..< 32 {
            deep = .section(title: "deep", insets: .zero, child: deep)
        }
        let many = LayoutNode.stack(gap: 0, children: Array(repeating: leaf, count: 257))
        for root in [deep, many] {
            let plan = DashboardPlan(
                title: "limits",
                metrics: [metric],
                window: testWindow(),
                sections: [],
                surfaces: [SurfacePlan(kind: .widgetLarge, root: root)]
            )
            #expect(throws: ProtocolValidationError.self) {
                try ProtocolValidator.validate(plan)
            }
        }
    }

    private func testWindow() -> WindowPlan {
        WindowPlan(width: 420, anchor: .topRight, margin: 20, layer: .desktop, opacity: 0.94)
    }
}
