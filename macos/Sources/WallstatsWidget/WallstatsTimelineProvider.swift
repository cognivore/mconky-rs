import Foundation
import WidgetKit
import WallstatsCore

struct WallstatsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?

    var isStale: Bool {
        guard let snapshot else { return false }
        return date.timeIntervalSince(snapshot.sampledAt) > 45 * 60
    }
}

struct WallstatsTimelineProvider: TimelineProvider {
    private static let graphicalSample: WidgetSnapshot = {
        do {
            let root = LayoutNode.stack(gap: 8, children: [
                .section(
                    title: "performance",
                    insets: LayoutInsets(top: 6, right: 8, bottom: 6, left: 8),
                    child: .flow(
                        horizontalGap: 6,
                        verticalGap: 6,
                        minimumItemWidth: 72,
                        children: [
                            .widget(WidgetPlan(
                                kind: .gauge,
                                label: "cpu",
                                metric: "sample.ratio",
                                format: .percent,
                                accent: "cyan"
                            )),
                            .widget(WidgetPlan(
                                kind: .gauge,
                                label: "memory",
                                metric: "sample.memory",
                                format: .percent,
                                accent: "violet"
                            )),
                        ]
                    )
                ),
                .section(
                    title: "signals",
                    insets: LayoutInsets(top: 6, right: 8, bottom: 6, left: 8),
                    child: .widget(WidgetPlan(
                        kind: .plot,
                        label: "activity",
                        history: 20,
                        series: [
                            PlotSeries(metric: "sample.ratio", format: .percent, accent: "cyan"),
                            PlotSeries(metric: "sample.rate", format: .bytesPerSecond, accent: "blue"),
                        ]
                    ))
                ),
            ])
            return try WidgetSnapshot(
                sampledAt: Date(timeIntervalSince1970: 1_700_000_000),
                renderPlan: WidgetRenderPlan(sections: [
                    WidgetRenderSection(title: "performance", widgets: [
                        WidgetRenderWidget(
                            kind: .gauge,
                            label: "cpu",
                            metric: "sample.ratio",
                            format: .percent,
                            accent: "cyan"
                        ),
                        WidgetRenderWidget(
                            kind: .gauge,
                            label: "memory",
                            metric: "sample.memory",
                            format: .percent,
                            accent: "violet"
                        ),
                    ]),
                    WidgetRenderSection(title: "signals", weight: 2, widgets: [
                        WidgetRenderWidget(
                            kind: .plot,
                            label: "activity",
                            history: 20,
                            series: [
                                WidgetRenderSeries(metric: "sample.ratio", format: .percent, accent: "cyan"),
                                WidgetRenderSeries(metric: "sample.rate", format: .bytesPerSecond, accent: "blue"),
                            ]
                        ),
                    ]),
                    WidgetRenderSection(title: "storage", widgets: [
                        WidgetRenderWidget(
                            kind: .value,
                            label: "free",
                            metric: "sample.bytes",
                            format: .bytes
                        ),
                        WidgetRenderWidget(
                            kind: .compactStatus,
                            label: "sync",
                            metric: "sample.status",
                            format: .compactStatus
                        ),
                    ]),
                ]),
                metrics: [
                    WidgetRenderMetric(
                        metricID: "sample.ratio",
                        valueType: .ratio,
                        value: .ratio(0.58),
                        error: nil,
                        timestampMS: 1_700_000_000_000,
                        history: [0.28, 0.34, 0.42, 0.55, 0.49, 0.61, 0.52, 0.67, 0.58]
                    ),
                    WidgetRenderMetric(
                        metricID: "sample.memory",
                        valueType: .ratio,
                        value: .ratio(0.72),
                        error: nil,
                        timestampMS: 1_700_000_000_000,
                        history: []
                    ),
                    WidgetRenderMetric(
                        metricID: "sample.rate",
                        valueType: .bytesPerSecond,
                        value: .bytesPerSecond(5_600_000),
                        error: nil,
                        timestampMS: 1_700_000_000_000,
                        history: [1_200_000, 3_800_000, 6_200_000, 3_100_000, 8_400_000, 5_600_000]
                    ),
                    WidgetRenderMetric(
                        metricID: "sample.bytes",
                        valueType: .bytes,
                        value: .bytes(312 * 1_073_741_824),
                        error: nil,
                        timestampMS: 1_700_000_000_000,
                        history: []
                    ),
                    WidgetRenderMetric(
                        metricID: "sample.status",
                        valueType: .compactStatus,
                        value: .compactStatus(CompactStatusMetricValue(
                            leading: "☁️",
                            trailing: "💾",
                            light: .amber,
                            ageSeconds: 18 * 60
                        )),
                        error: nil,
                        timestampMS: 1_700_000_000_000,
                        history: []
                    ),
                ],
                widgetSurfaces: [
                    SurfacePlan(kind: .widgetLarge, root: root),
                    SurfacePlan(kind: .widgetMedium, root: root),
                    SurfacePlan(kind: .widgetSmall, root: root),
                ]
            )
        } catch {
            preconditionFailure("Invalid deterministic widget sample: \(error)")
        }
    }()

    func placeholder(in context: Context) -> WallstatsEntry {
        WallstatsEntry(date: Self.graphicalSample.sampledAt, snapshot: Self.graphicalSample)
    }

    func getSnapshot(in context: Context, completion: @escaping (WallstatsEntry) -> Void) {
        if context.isPreview {
            completion(WallstatsEntry(date: Self.graphicalSample.sampledAt, snapshot: Self.graphicalSample))
            return
        }
        completion(WallstatsEntry(date: Date(), snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WallstatsEntry>) -> Void) {
        let now = Date()
        let snapshot = loadSnapshot()
        let refreshMinutes = snapshot == nil ? 15 : 30
        let refresh = Calendar.current.date(byAdding: .minute, value: refreshMinutes, to: now)
            ?? now.addingTimeInterval(TimeInterval(refreshMinutes * 60))
        var entries = [WallstatsEntry(date: now, snapshot: snapshot)]
        if let snapshot {
            let staleTransition = snapshot.sampledAt.addingTimeInterval(45 * 60 + 1)
            if staleTransition > now, staleTransition < refresh {
                entries.append(WallstatsEntry(date: staleTransition, snapshot: snapshot))
            }
        }
        completion(Timeline(
            entries: entries,
            policy: .after(refresh)
        ))
    }

    private func loadSnapshot() -> WidgetSnapshot? {
        guard let store = try? WidgetSnapshotStore() else { return nil }
        return try? store.read()
    }
}
