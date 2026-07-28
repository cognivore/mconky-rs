import SwiftUI
import WallstatsCore

struct GenericSectionView: View {
    let section: WidgetRenderSection
    let snapshot: WidgetSnapshot
    let date: Date
    let metrics: [String: WidgetRenderMetric]

    var body: some View {
        OutlinedSection(section.title) {
            VStack(spacing: 6) {
                ForEach(section.widgets.indices, id: \.self) { index in
                    GenericWidgetView(
                        widget: section.widgets[index],
                        snapshot: snapshot,
                        date: date,
                        metrics: metrics
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

private struct GenericWidgetView: View {
    let widget: WidgetRenderWidget
    let snapshot: WidgetSnapshot
    let date: Date
    let metrics: [String: WidgetRenderMetric]

    @ViewBuilder
    var body: some View {
        switch widget.kind {
        case .value:
            valueRow
        case .gauge:
            gauge
        case .sparkline:
            sparkline
        case .plot:
            plot
        case .compactStatus:
            compactStatus
        case .table:
            table
        }
    }

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(widget.label)
                .foregroundStyle(WidgetColors.widgetLabel)
            Spacer(minLength: 4)
            Text(formattedValue)
                .foregroundStyle(WidgetColors.widgetValue)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var gauge: some View {
        VStack(spacing: 6) {
            valueRow
            GaugeRail(
                value: metricState?.error == nil ? metricState?.value?.numericValue : nil,
                color: WidgetColors.accent(widget.accent)
            )
        }
    }

    private var sparkline: some View {
        VStack(spacing: 5) {
            valueRow
            MetricPlot(series: [plotSeries(
                metricID: widget.metric,
                accent: widget.accent
            )])
        }
    }

    private var plot: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !widget.label.isEmpty {
                Text(widget.label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(WidgetColors.widgetLabel)
                    .lineLimit(1)
            }
            MetricPlot(series: widget.series.map {
                plotSeries(metricID: $0.metric, accent: $0.accent)
            })
        }
    }

    private var compactStatus: some View {
        HStack(spacing: 6) {
            if !widget.label.isEmpty {
                Text(widget.label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(WidgetColors.widgetLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            CompactStatusTile(
                status: compactStatusSnapshot,
                sampledAt: snapshot.sampledAt,
                date: date,
                size: 52
            )
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(widget.label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(WidgetColors.widgetLabel)
                .lineLimit(1)
            if case let .table(table) = metricState?.value, metricState?.error == nil {
                HStack(spacing: 7) {
                    ForEach(table.columns.indices, id: \.self) { index in
                        Text(table.columns[index])
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .foregroundStyle(WidgetColors.sectionLabel)
                ForEach(table.rows.prefix(4).indices, id: \.self) { rowIndex in
                    HStack(spacing: 7) {
                        ForEach(table.rows[rowIndex].indices, id: \.self) { columnIndex in
                            Text(table.rows[rowIndex][columnIndex])
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .foregroundStyle(WidgetColors.widgetValue)
            }
        }
        .font(.system(size: 8, design: .monospaced))
        .lineLimit(1)
    }

    private var metricState: WidgetRenderMetric? {
        guard let metric = widget.metric else { return nil }
        return metrics[metric]
    }

    private var formattedValue: String {
        guard metricState?.error == nil, let format = widget.format else { return "--" }
        return WidgetValueFormatter.string(for: metricState?.value, format: format)
    }

    private var compactStatusSnapshot: CompactStatusSnapshot? {
        guard let metric = widget.metric,
              let state = metrics[metric], state.error == nil,
              case let .compactStatus(value) = state.value
        else {
            return nil
        }
        return CompactStatusSnapshot(metricID: metric, value: value)
    }

    private func plotSeries(metricID: String?, accent: String?) -> MetricPlotSeries {
        guard let metricID, let state = metrics[metricID], state.error == nil else {
            return MetricPlotSeries(
                samples: [],
                valueType: .number,
                color: WidgetColors.accent(accent)
            )
        }
        let samples = state.history.isEmpty
            ? state.value?.numericValue.map { [$0] } ?? []
            : state.history
        return MetricPlotSeries(
            samples: samples,
            valueType: state.valueType,
            color: WidgetColors.accent(accent)
        )
    }
}

private struct GaugeRail: View {
    let value: Double?
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetColors.railTrack)
                if let value {
                    Capsule()
                        .fill(color.opacity(0.82))
                        .frame(width: max(2, proxy.size.width * min(max(value, 0), 1)))
                }
            }
        }
        .frame(height: 3)
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded())) percent" } ?? "Unavailable")
    }
}
