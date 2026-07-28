import Foundation
import SwiftUI
import WidgetKit
import WallstatsCore

struct WallstatsWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: WallstatsEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, !snapshot.renderPlan.sections.isEmpty {
                rendered(snapshot)
            } else {
                EmptyRenderState()
                    .padding(18)
            }
        }
        .opacity(entry.isStale ? 0.46 : 1)
        .accessibilityHint(entry.isStale ? "System activity snapshot is stale" : "Current system activity snapshot")
        .widgetURL(URL(string: "wallstats://config"))
        .containerBackground(for: .widget) {
            WidgetContainerBackground()
        }
    }

    @ViewBuilder
    private func rendered(_ snapshot: WidgetSnapshot) -> some View {
        let metrics = Dictionary(uniqueKeysWithValues: snapshot.metrics.map { ($0.metricID, $0) })
        switch family {
        case .systemLarge:
            LargePlanLayout(snapshot: snapshot, date: entry.date, metrics: metrics)
                .padding(20)
        case .systemMedium:
            MediumPlanLayout(snapshot: snapshot, date: entry.date, metrics: metrics)
                .padding(16)
        default:
            SmallPlanLayout(snapshot: snapshot, date: entry.date, metrics: metrics)
                .padding(16)
        }
    }
}

private struct LargePlanLayout: View {
    let snapshot: WidgetSnapshot
    let date: Date
    let metrics: [String: WidgetRenderMetric]

    var body: some View {
        GeometryReader { proxy in
            let sections = snapshot.renderPlan.sections
            let spacing: CGFloat = 8
            let totalSpacing = spacing * CGFloat(max(sections.count - 1, 0))
            let availableHeight = max(proxy.size.height - totalSpacing, 0)
            let totalWeight = max(sections.reduce(0) { $0 + $1.weight }, 1)

            VStack(spacing: spacing) {
                ForEach(sections.indices, id: \.self) { index in
                    GenericSectionView(
                        section: sections[index],
                        snapshot: snapshot,
                        date: date,
                        metrics: metrics
                    )
                    .frame(height: availableHeight * CGFloat(sections[index].weight) / CGFloat(totalWeight))
                }
            }
        }
    }
}

private struct MediumPlanLayout: View {
    let snapshot: WidgetSnapshot
    let date: Date
    let metrics: [String: WidgetRenderMetric]

    var body: some View {
        GeometryReader { proxy in
            let sections = snapshot.renderPlan.sections
            if sections.count == 1 {
                GenericSectionView(
                    section: sections[0],
                    snapshot: snapshot,
                    date: date,
                    metrics: metrics
                )
            } else {
                let rows = max((sections.count + 1) / 2, 1)
                let spacing: CGFloat = 8
                let rowHeight = max(
                    (proxy.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows),
                    0
                )
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: spacing), GridItem(.flexible())],
                    spacing: spacing
                ) {
                    ForEach(sections.indices, id: \.self) { index in
                        GenericSectionView(
                            section: sections[index],
                            snapshot: snapshot,
                            date: date,
                            metrics: metrics
                        )
                        .frame(height: rowHeight)
                    }
                }
            }
        }
    }
}

private struct SmallPlanLayout: View {
    let snapshot: WidgetSnapshot
    let date: Date
    let metrics: [String: WidgetRenderMetric]

    var body: some View {
        if let section = selectedSection {
            GenericSectionView(
                section: section,
                snapshot: snapshot,
                date: date,
                metrics: metrics
            )
        } else {
            EmptyRenderState()
        }
    }

    private var selectedSection: WidgetRenderSection? {
        snapshot.renderPlan.sections.reduce(nil) { current, section in
            guard let current else { return section }
            return section.weight > current.weight ? section : current
        }
    }
}

private struct EmptyRenderState: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: size.width / 2 - 6, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width / 2 + 6, y: size.height / 2))
            context.stroke(
                path,
                with: .color(WidgetColors.missingMark),
                style: StrokeStyle(lineWidth: 1, lineCap: .round)
            )
        }
        .accessibilityLabel("Widget data unavailable")
    }
}
