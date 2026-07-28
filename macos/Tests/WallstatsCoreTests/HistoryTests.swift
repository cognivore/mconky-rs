import Testing
@testable import WallstatsCore

@Suite("Metric history")
struct HistoryTests {
    @Test("Sparkline history obeys its plan bound")
    func historyBound() throws {
        var state = try DashboardState(plan: testPlan(history: 3))

        for sequence in 1 ... 5 {
            try state.apply(UpdateMessage(
                sequence: UInt64(sequence),
                timestampMS: Int64(sequence * 1_000),
                values: [UpdateItem(metric: "cpu.total", value: .ratio(Double(sequence) / 10))]
            ))
        }

        #expect(state.histories["cpu.total"]?.map(\.value) == [0.3, 0.4, 0.5])
        #expect(state.history(for: "cpu.total", limit: 2).map(\.value) == [0.4, 0.5])
    }

    @Test("Explicit metric errors remain visible and do not erase history")
    func explicitErrorPersists() throws {
        var state = try DashboardState(plan: testPlan(history: 2))
        try state.apply(UpdateMessage(
            sequence: 1,
            timestampMS: 1_000,
            values: [UpdateItem(metric: "cpu.total", value: .ratio(0.4))]
        ))
        try state.apply(UpdateMessage(
            sequence: 2,
            timestampMS: 2_000,
            values: [UpdateItem(metric: "cpu.total", error: "sensor unavailable")]
        ))
        try state.apply(UpdateMessage(sequence: 3, timestampMS: 3_000, values: []))

        #expect(state.metrics["cpu.total"]?.error == "sensor unavailable")
        #expect(state.metrics["cpu.total"]?.value == .ratio(0.4))
        #expect(state.histories["cpu.total"]?.map(\.value) == [0.4])
    }

    @Test("Plot series contribute bounded histories")
    func plotHistoryBound() throws {
        let plan = DashboardPlan(
            title: "Plot",
            metrics: [MetricDefinition(id: "cpu.total", valueType: .ratio, staleAfterMS: 3_000)],
            window: WindowPlan(
                width: 420,
                anchor: .topRight,
                margin: 20,
                layer: .desktop,
                opacity: 0.94
            ),
            sections: [SectionPlan(title: "Plot", widgets: [
                WidgetPlan(
                    kind: .plot,
                    label: "CPU",
                    metric: "",
                    format: .number,
                    history: 3,
                    series: [PlotSeries(metric: "cpu.total", format: .percent)]
                ),
            ])]
        )
        var state = try DashboardState(plan: plan)
        for sequence in 1 ... 5 {
            try state.apply(UpdateMessage(
                sequence: UInt64(sequence),
                timestampMS: Int64(sequence * 1_000),
                values: [UpdateItem(metric: "cpu.total", value: .ratio(Double(sequence) / 10))]
            ))
        }
        #expect(state.history(for: "cpu.total").map(\.value) == [0.3, 0.4, 0.5])
    }

    private func testPlan(history: Int) -> DashboardPlan {
        DashboardPlan(
            title: "Test",
            metrics: [MetricDefinition(id: "cpu.total", valueType: .ratio, staleAfterMS: 3_000)],
            window: WindowPlan(
                width: 420,
                anchor: .topRight,
                margin: 20,
                layer: .desktop,
                opacity: 0.94
            ),
            sections: [
                SectionPlan(
                    title: "Performance",
                    widgets: [
                        WidgetPlan(
                            kind: .sparkline,
                            label: "CPU",
                            metric: "cpu.total",
                            format: .percent,
                            history: history
                        ),
                    ]
                ),
            ]
        )
    }
}
