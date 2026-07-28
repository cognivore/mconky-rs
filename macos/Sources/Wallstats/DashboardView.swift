import SwiftUI
import WallstatsCore

struct DashboardView: View {
    @ObservedObject var model: AppModel

    let onContentSizeChange: (CGSize) -> Void
    let onPresentationChange: (AppWindowPresentation) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            content(at: Int64(timeline.date.timeIntervalSince1970 * 1_000))
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color(red: 0.045, green: 0.052, blue: 0.061).opacity(0.96))
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.28)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 1)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ContentSizePreferenceKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(ContentSizePreferenceKey.self, perform: onContentSizeChange)
        .onChange(of: model.windowPresentation, initial: true) { _, presentation in
            onPresentationChange(presentation)
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func content(at timestampMS: Int64) -> some View {
        VStack(spacing: 0) {
            header

            if model.phase == .failed {
                AlertStrip(text: model.fatalMessage ?? model.statusDetail)
                    .padding(.top, 12)
            }

            if let plan = model.plan, let dashboard = model.dashboard {
                VStack(spacing: 0) {
                    ForEach(Array(plan.sections.enumerated()), id: \.offset) { sectionIndex, section in
                        if sectionIndex > 0 {
                            Divider().overlay(Color.white.opacity(0.08))
                                .padding(.vertical, 12)
                        }
                        DashboardSectionView(
                            section: section,
                            dashboard: dashboard,
                            timestampMS: timestampMS
                        )
                    }
                }
                .padding(.top, 14)
            } else {
                EmptyDashboardView(model: model)
                    .padding(.top, 18)
            }

            footer
                .padding(.top, 14)
        }
        .padding(16)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.plan?.title ?? "WALLSTATS")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(model.statusDetail)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.48))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle()
                    .fill(phaseColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: phaseColor.opacity(0.8), radius: 3)
                Text(model.phase.rawValue.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.68))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.configURL?.lastPathComponent ?? "NO CONFIG")
                .lineLimit(1)
            Spacer()
            if let sdkVersion = model.sdkVersion {
                Text("SDK \(sdkVersion)")
            }
        }
        .font(.system(size: 9, weight: .regular, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.3))
    }

    private var phaseColor: Color {
        switch model.phase {
        case .running:
            Color(red: 0.35, green: 0.88, blue: 0.64)
        case .failed:
            Color(red: 1, green: 0.36, blue: 0.31)
        case .starting, .waitingForPlan, .reloading, .resolving:
            Color(red: 1, green: 0.72, blue: 0.26)
        case .idle:
            Color.white.opacity(0.35)
        }
    }
}

private struct DashboardSectionView: View {
    let section: SectionPlan
    let dashboard: DashboardState
    let timestampMS: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.38))

            ForEach(Array(section.widgets.enumerated()), id: \.offset) { _, widget in
                MetricWidgetView(
                    widget: widget,
                    snapshot: dashboard.metrics[widget.metric],
                    history: dashboard.history(for: widget.metric, limit: widget.history),
                    stale: dashboard.isStale(metric: widget.metric, at: timestampMS)
                )
            }
        }
    }
}

private struct MetricWidgetView: View {
    let widget: WidgetPlan
    let snapshot: MetricSnapshot?
    let history: [HistorySample]
    let stale: Bool

    private var accent: Color { Color.wallstatsAccent(widget.accent) }

    var body: some View {
        Group {
            if let error = snapshot?.error {
                errorView(error)
            } else {
                switch widget.kind {
                case .value:
                    valueView
                case .sparkline:
                    sparklineView
                case .gauge:
                    gaugeView
                case .table:
                    tableView
                case .plot, .compactStatus:
                    valueView
                }
            }
        }
        .opacity(stale ? 0.58 : 1)
    }

    private func errorView(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                label
                Spacer()
                StateBadge(text: "ERROR", color: Color(red: 1, green: 0.36, blue: 0.31))
            }
            Text(error)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(red: 1, green: 0.5, blue: 0.46))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private var valueView: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            label
            Spacer(minLength: 10)
            statusBadge
            Text(formattedValue)
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(snapshot?.value == nil ? Color.white.opacity(0.3) : .white)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 3)
    }

    private var sparklineView: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label
                Spacer()
                statusBadge
                Text(formattedValue)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }
            SparklinePlot(
                samples: history,
                fixedRange: snapshot?.value?.kind == .ratio ? 0 ... 1 : nil,
                accent: accent
            )
            .frame(height: 38)
        }
        .padding(.vertical, 3)
    }

    private var gaugeView: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label
                Spacer()
                statusBadge
                Text(formattedValue)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }
            GaugeBar(value: snapshot?.value?.numericValue ?? 0, accent: accent)
                .frame(height: 7)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var tableView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                label
                Spacer()
                statusBadge
                Text(formattedValue)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.46))
            }
            if case let .table(table) = snapshot?.value {
                MetricTableView(table: table, accent: accent)
            } else {
                Text("Waiting for table data")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
        }
        .padding(.vertical, 3)
    }

    private var label: some View {
        Text(widget.label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.68))
            .lineLimit(1)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if stale {
            StateBadge(text: "STALE", color: Color(red: 1, green: 0.72, blue: 0.26))
        }
    }

    private var formattedValue: String {
        guard let value = snapshot?.value else { return "--" }
        return MetricValueFormatter.string(for: value, format: widget.format)
    }
}

private struct SparklinePlot: View {
    let samples: [HistorySample]
    let fixedRange: ClosedRange<Double>?
    let accent: Color

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty, size.width > 0, size.height > 0 else { return }

            let values = samples.map(\.value)
            let lower = fixedRange?.lowerBound ?? values.min() ?? 0
            let upper = fixedRange?.upperBound ?? values.max() ?? 1

            func normalized(_ value: Double) -> Double {
                guard lower != upper else { return 0.5 }
                let scale = max(abs(lower), abs(upper))
                guard scale.isFinite, scale > 0 else { return 0.5 }
                let scaledLower = lower / scale
                let scaledUpper = upper / scale
                let denominator = scaledUpper - scaledLower
                guard denominator.isFinite, denominator > 0 else { return 0.5 }
                let result = ((value / scale) - scaledLower) / denominator
                return result.isFinite ? min(max(result, 0), 1) : 0.5
            }

            func point(at index: Int) -> CGPoint {
                let x = samples.count == 1
                    ? size.width
                    : CGFloat(index) / CGFloat(samples.count - 1) * size.width
                let y = size.height - CGFloat(normalized(values[index])) * size.height
                return CGPoint(x: x, y: y)
            }

            var line = Path()
            line.move(to: point(at: 0))
            for index in samples.indices.dropFirst() {
                line.addLine(to: point(at: index))
            }

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [accent.opacity(0.28), accent.opacity(0.01)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(line, with: .color(accent), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .background {
            VStack {
                Divider().overlay(Color.white.opacity(0.045))
                Spacer()
                Divider().overlay(Color.white.opacity(0.045))
            }
        }
        .accessibilityLabel("\(samples.count) point history")
    }
}

private struct GaugeBar: View {
    let value: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                Capsule()
                    .fill(accent)
                    .frame(width: proxy.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .accessibilityValue("\(Int(min(max(value, 0), 1) * 100)) percent")
    }
}

private struct MetricTableView: View {
    let table: TableValue
    let accent: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                GridRow {
                    ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                        Text(column.uppercased())
                            .foregroundStyle(accent.opacity(0.85))
                    }
                }
                Divider().overlay(Color.white.opacity(0.07))
                ForEach(Array(table.rows.prefix(8).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .foregroundStyle(Color.white.opacity(0.72))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .font(.system(size: 9, weight: .regular, design: .monospaced))
        }
        .overlay(alignment: .bottomTrailing) {
            if table.rows.count > 8 {
                Text("+\(table.rows.count - 8) more")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
        }
    }
}

private struct EmptyDashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.phase == .failed ? "CONFIGURATION REQUIRED" : "COLLECTOR STARTING")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(model.phase == .failed ? Color.red.opacity(0.85) : Color.white.opacity(0.55))
            Text(model.statusDetail)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            if !model.diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(model.diagnostics.suffix(4))) { diagnostic in
                        Text(diagnostic.message)
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .foregroundStyle(diagnostic.level == .error ? Color.red.opacity(0.8) : Color.white.opacity(0.38))
                            .lineLimit(3)
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AlertStrip: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(Color(red: 1, green: 0.48, blue: 0.42))
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct StateBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.11), in: Capsule())
    }
}

private struct ContentSizePreferenceKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private extension Color {
    static func wallstatsAccent(_ name: String?) -> Color {
        switch name?.lowercased() {
        case "green", "mint":
            Color(red: 0.35, green: 0.88, blue: 0.64)
        case "amber", "orange":
            Color(red: 1, green: 0.68, blue: 0.25)
        case "red":
            Color(red: 1, green: 0.36, blue: 0.31)
        case "purple", "violet":
            Color(red: 0.72, green: 0.55, blue: 1)
        case "blue":
            Color(red: 0.34, green: 0.58, blue: 1)
        default:
            Color(red: 0.26, green: 0.82, blue: 0.92)
        }
    }
}
