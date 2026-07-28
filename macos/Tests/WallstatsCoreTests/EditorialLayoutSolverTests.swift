import Testing
@testable import WallstatsCore

@Suite("Editorial layout solver")
struct EditorialLayoutSolverTests {
    @Test("Stack geometry is deterministic, finite, nonoverlapping, and gap preserving")
    func stackGeometry() {
        let root = LayoutNode.stack(gap: 7, children: [value("a"), gauge("b")])
        let first = EditorialLayoutSolver.solve(root: root, width: 200)
        let second = EditorialLayoutSolver.solve(root: root, width: 200)

        #expect(first == second)
        #expect(first.overflow == false)
        #expect(first.placements.map(\.pathID) == ["0/0", "0/1"])
        assertFiniteAndNonoverlapping(first.placements)
        let frames = first.placements.map(\.allocationFrame)
        #expect(abs(frames[1].y - frames[0].maxY - 7) < 0.000_001)
    }

    @Test("Split uses weighted widths when tracks meet their minimum")
    func weightedSplit() {
        let root = LayoutNode.split(
            gap: 10,
            minimumTrackWidth: 50,
            tracks: [
                LayoutTrack(weight: 1, child: value("a")),
                LayoutTrack(weight: 2, child: value("b")),
            ]
        )
        let result = EditorialLayoutSolver.solve(root: root, width: 300)
        let frames = result.placements.map(\.allocationFrame)

        #expect(abs(frames[0].width - 113.333_333) < 0.001)
        #expect(abs(frames[1].width - 176.666_667) < 0.001)
        #expect(abs(frames[1].x - frames[0].maxX - 10) < 0.000_001)
        assertFiniteAndNonoverlapping(result.placements)
    }

    @Test("Split re-homes tracks into a source-ordered stack when too narrow")
    func splitRehomes() {
        let root = LayoutNode.split(
            gap: 6,
            minimumTrackWidth: 60,
            tracks: [
                LayoutTrack(weight: 1, child: value("a")),
                LayoutTrack(weight: 1, child: value("b")),
            ]
        )
        let result = EditorialLayoutSolver.solve(root: root, width: 100)
        let frames = result.placements.map(\.allocationFrame)

        #expect(frames.allSatisfy { $0.x == 0 && $0.width == 100 })
        #expect(abs(frames[1].y - frames[0].maxY - 6) < 0.000_001)
        #expect(result.placements.map(\.pathID) == ["0/0", "0/1"])
    }

    @Test("Flow derives columns and row heights deterministically")
    func flowColumns() {
        let root = LayoutNode.flow(
            horizontalGap: 10,
            verticalGap: 8,
            minimumItemWidth: 100,
            children: [value("a"), gauge("b"), value("c")]
        )
        let result = EditorialLayoutSolver.solve(root: root, width: 250)
        let frames = result.placements.map(\.allocationFrame)

        #expect(frames[0].y == frames[1].y)
        #expect(abs(frames[0].width - 120) < 0.000_001)
        #expect(abs(frames[1].x - frames[0].maxX - 10) < 0.000_001)
        #expect(abs(frames[2].y - max(frames[0].maxY, frames[1].maxY) - 8) < 0.000_001)
        assertFiniteAndNonoverlapping(result.placements)
    }

    @Test("Section content contains its child and compact status content is square")
    func sectionAndSquareContent() {
        let root = LayoutNode.section(
            title: "status",
            insets: LayoutInsets(top: 5, right: 7, bottom: 9, left: 11),
            child: .widget(WidgetPlan(
                kind: .compactStatus,
                label: "sync",
                metric: "sync",
                format: .compactStatus
            ))
        )
        let result = EditorialLayoutSolver.solve(root: root, width: 180, boundedHeight: 100)
        let section = result.placements[0]
        let widget = result.placements[1]

        #expect(section.role == .sectionChrome)
        #expect(section.contentFrame.contains(widget.allocationFrame))
        #expect(widget.contentFrame.width == widget.contentFrame.height)
        #expect(widget.allocationFrame.contains(widget.contentFrame))
    }

    @Test("Bounded layout grows, shrinks, and reports impossible overflow")
    func boundedFlexAndOverflow() {
        let root = LayoutNode.stack(gap: 6, children: [value("a"), value("b")])
        let natural = EditorialLayoutSolver.solve(root: root, width: 100)
        let grown = EditorialLayoutSolver.solve(root: root, width: 100, boundedHeight: 74)
        let shrunk = EditorialLayoutSolver.solve(root: root, width: 100, boundedHeight: 48)
        let overflow = EditorialLayoutSolver.solve(root: root, width: 100, boundedHeight: 40)

        #expect(natural.naturalHeight == 58)
        #expect(grown.placements[0].allocationFrame.height > natural.placements[0].allocationFrame.height)
        #expect(shrunk.overflow == false)
        #expect(shrunk.placements[0].allocationFrame.height < natural.placements[0].allocationFrame.height)
        #expect(overflow.overflow)
        #expect(overflow.resolvedHeight == overflow.minimumHeight)
        assertFiniteAndNonoverlapping(overflow.placements)
    }

    @Test("Metric values cannot affect geometry")
    func valuesDoNotAffectGeometry() {
        let root = LayoutNode.stack(gap: 4, children: [
            .widget(WidgetPlan(kind: .plot, label: "plot", history: 60, series: [
                PlotSeries(metric: "a", format: .number),
            ])),
            value("b"),
        ])
        let before = EditorialLayoutSolver.solve(root: root, width: 240, boundedHeight: 160)
        let after = EditorialLayoutSolver.solve(root: root, width: 240, boundedHeight: 160)
        #expect(before.placements == after.placements)
    }

    private func value(_ metric: String) -> LayoutNode {
        .widget(WidgetPlan(kind: .value, label: metric, metric: metric, format: .number))
    }

    private func gauge(_ metric: String) -> LayoutNode {
        .widget(WidgetPlan(kind: .gauge, label: metric, metric: metric, format: .percent))
    }

    private func assertFiniteAndNonoverlapping(_ placements: [EditorialPlacement]) {
        let widgetFrames = placements.compactMap { placement -> EditorialRect? in
            if case .widget = placement.role { return placement.allocationFrame }
            return nil
        }
        for frame in widgetFrames {
            #expect(frame.x.isFinite)
            #expect(frame.y.isFinite)
            #expect(frame.width.isFinite)
            #expect(frame.height.isFinite)
        }
        for left in widgetFrames.indices {
            for right in widgetFrames.indices where right > left {
                let a = widgetFrames[left]
                let b = widgetFrames[right]
                let overlaps = a.x < b.maxX && b.x < a.maxX && a.y < b.maxY && b.y < a.maxY
                #expect(!overlaps)
            }
        }
    }
}
