import SwiftUI

public struct EditorialSurfaceView: View {
    public let root: LayoutNode
    public let metrics: [WidgetRenderMetric]
    public let sampledAt: Date
    public let date: Date

    public init(
        root: LayoutNode,
        metrics: [WidgetRenderMetric],
        sampledAt: Date,
        date: Date
    ) {
        self.root = root
        self.metrics = metrics
        self.sampledAt = sampledAt
        self.date = date
    }

    public var body: some View {
        GeometryReader { proxy in
            let result = EditorialLayoutSolver.solve(
                root: root,
                width: proxy.size.width,
                boundedHeight: proxy.size.height
            )
            if result.overflow {
                SurfaceEmptyMark()
            } else {
                let index = SurfaceContentIndex(root: root)
                let states = Dictionary(uniqueKeysWithValues: metrics.map { ($0.metricID, $0) })
                ZStack(alignment: .topLeading) {
                    ForEach(result.placements, id: \.pathID) { placement in
                        switch placement.role {
                        case .sectionChrome:
                            if let title = index.sections[placement.pathID] {
                                SurfaceSectionChrome(title: title)
                                    .frame(
                                        width: placement.allocationFrame.width,
                                        height: placement.allocationFrame.height
                                    )
                                    .position(
                                        x: placement.allocationFrame.x + placement.allocationFrame.width / 2,
                                        y: placement.allocationFrame.y + placement.allocationFrame.height / 2
                                    )
                            }
                        case .widget:
                            if let widget = index.widgets[placement.pathID] {
                                SurfaceWidgetLeaf(
                                    widget: widget,
                                    states: states,
                                    sampledAt: sampledAt,
                                    date: date
                                )
                                .frame(
                                    width: placement.contentFrame.width,
                                    height: placement.contentFrame.height
                                )
                                .position(
                                    x: placement.contentFrame.x + placement.contentFrame.width / 2,
                                    y: placement.contentFrame.y + placement.contentFrame.height / 2
                                )
                            }
                        }
                    }
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct SurfaceContentIndex {
    var widgets: [String: WidgetPlan] = [:]
    var sections: [String: String] = [:]

    init(root: LayoutNode) {
        visit(root, path: "0")
    }

    private mutating func visit(_ node: LayoutNode, path: String) {
        switch node {
        case let .widget(widget):
            widgets[path] = widget
        case let .section(title, _, child):
            sections[path] = title
            visit(child, path: "\(path)/0")
        case let .stack(_, children), let .flow(_, _, _, children):
            for index in children.indices {
                visit(children[index], path: "\(path)/\(index)")
            }
        case let .split(_, _, tracks):
            for index in tracks.indices {
                visit(tracks[index].child, path: "\(path)/\(index)")
            }
        }
    }
}

private struct SurfaceSectionChrome: View {
    let title: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            SurfaceSectionOutline(gapWidth: gapWidth)
                .stroke(SurfacePalette.outline, lineWidth: 0.75)
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(SurfacePalette.secondary)
                .lineLimit(1)
                .offset(x: 16)
        }
    }

    private var gapWidth: CGFloat {
        min(max(CGFloat(title.count) * 7 + 16, 40), 220)
    }
}

private struct SurfaceSectionOutline: Shape {
    let gapWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + 5
        let radius = min(9, max((rect.maxY - top) / 2, 0))
        let gapStart = min(rect.minX + 12, rect.maxX)
        let gapEnd = min(gapStart + gapWidth, rect.maxX - radius)
        var path = Path()
        path.move(to: CGPoint(x: gapEnd, y: top))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: top + radius),
            control: CGPoint(x: rect.maxX, y: top)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: top + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: top),
            control: CGPoint(x: rect.minX, y: top)
        )
        path.addLine(to: CGPoint(x: gapStart, y: top))
        return path
    }
}

private struct SurfaceWidgetLeaf: View {
    let widget: WidgetPlan
    let states: [String: WidgetRenderMetric]
    let sampledAt: Date
    let date: Date

    @ViewBuilder
    var body: some View {
        switch widget.kind {
        case .value:
            valueRow
        case .gauge:
            VStack(spacing: 5) {
                valueRow
                SurfaceGauge(
                    value: state?.error == nil ? state?.value?.numericValue : nil,
                    color: SurfacePalette.accent(widget.accent)
                )
            }
        case .sparkline:
            VStack(spacing: 4) {
                valueRow
                SurfacePlot(series: [series(metric: widget.metric, accent: widget.accent)])
            }
        case .plot:
            let plotSeries = widget.series.map { series(metric: $0.metric, accent: $0.accent) }
            VStack(alignment: .leading, spacing: 4) {
                if !widget.label.isEmpty {
                    Text(widget.label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.35)
                        .foregroundStyle(SurfacePalette.secondary)
                        .lineLimit(1)
                }
                SurfacePlotLegend(series: plotSeries)
                SurfacePlot(series: plotSeries)
            }
        case .compactStatus:
            SurfaceCompactStatus(
                label: widget.label,
                metricID: widget.metric,
                value: compactStatus,
                sampledAt: sampledAt,
                date: date
            )
        case .table:
            SurfaceTable(label: widget.label, state: state)
        }
    }

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(widget.label)
                .foregroundStyle(SurfacePalette.secondary)
                .tracking(0.35)
                .layoutPriority(1)
            Spacer(minLength: 3)
            Text(formattedValue)
                .foregroundStyle(SurfacePalette.primary)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .lineLimit(1)
    }

    private var state: WidgetRenderMetric? {
        states[widget.metric]
    }

    private var formattedValue: String {
        guard state?.error == nil else { return "--" }
        return WidgetValueFormatter.string(for: state?.value, format: widget.format)
    }

    private var compactStatus: CompactStatusMetricValue? {
        guard state?.error == nil, case let .compactStatus(value) = state?.value else { return nil }
        return value
    }

    private func series(metric: String, accent: String?) -> SurfacePlotSeries {
        guard let state = states[metric], state.error == nil else {
            return SurfacePlotSeries(
                label: SurfaceMetricLabel.compact(metric),
                samples: [],
                valueType: .number,
                color: SurfacePalette.accent(accent)
            )
        }
        return SurfacePlotSeries(
            label: SurfaceMetricLabel.compact(metric),
            samples: state.history.isEmpty
                ? state.value?.numericValue.map { [$0] } ?? []
                : state.history,
            valueType: state.valueType,
            color: SurfacePalette.accent(accent)
        )
    }
}

private struct SurfaceGauge: View {
    let value: Double?
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(SurfacePalette.track)
                if let value {
                    Capsule()
                        .fill(color.opacity(0.82))
                        .frame(width: max(2, proxy.size.width * min(max(value, 0), 1)))
                }
            }
        }
        .frame(height: 3)
    }
}

private struct SurfacePlotSeries {
    let label: String
    let samples: [Double]
    let valueType: MetricValueType
    let color: Color
}

private struct SurfacePlotLegend: View {
    let series: [SurfacePlotSeries]

    var body: some View {
        if series.count > 1 {
            HStack(spacing: 8) {
                ForEach(series.indices, id: \.self) { index in
                    HStack(spacing: 3) {
                        Capsule()
                            .fill(series[index].color)
                            .frame(width: 7, height: 2)
                        Text(series[index].label)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.25)
            .foregroundStyle(SurfacePalette.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
    }
}

private enum SurfaceMetricLabel {
    private static let genericSuffixes = Set(["ratio", "total", "value"])

    static func compact(_ metric: String) -> String {
        let components = metric.split(separator: ".").map(String.init)
        let component = components.reversed().first { !genericSuffixes.contains($0.lowercased()) }
            ?? components.last
            ?? metric
        return String(component.prefix(5)).uppercased()
    }
}

private struct SurfacePlot: View {
    let series: [SurfacePlotSeries]

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 3, y: 3, width: max(size.width - 6, 0), height: max(size.height - 6, 0))
            guard rect.width > 0, rect.height > 0 else { return }
            for fraction in [0.25, 0.5, 0.75] as [CGFloat] {
                var grid = Path()
                let y = rect.minY + rect.height * fraction
                grid.move(to: CGPoint(x: rect.minX, y: y))
                grid.addLine(to: CGPoint(x: rect.maxX, y: y))
                context.stroke(grid, with: .color(SurfacePalette.grid), lineWidth: 0.5)
            }
            for (index, item) in series.enumerated() where !item.samples.isEmpty {
                draw(item, index: index, rect: rect, context: &context)
            }
        }
    }

    private func draw(
        _ item: SurfacePlotSeries,
        index: Int,
        rect: CGRect,
        context: inout GraphicsContext
    ) {
        let normalizer = SurfaceNormalizer(samples: item.samples, type: item.valueType)
        func point(_ sample: Int) -> CGPoint {
            let x = item.samples.count == 1
                ? rect.maxX
                : rect.minX + CGFloat(sample) / CGFloat(item.samples.count - 1) * rect.width
            return CGPoint(
                x: x,
                y: rect.maxY - CGFloat(normalizer.normalize(item.samples[sample])) * rect.height
            )
        }
        var path = Path()
        path.move(to: point(0))
        for sample in item.samples.indices.dropFirst() {
            path.addLine(to: point(sample))
        }
        let dash: [CGFloat] = index % 3 == 1 ? [4, 2] : (index % 3 == 2 ? [1, 2] : [])
        context.stroke(
            path,
            with: .color(item.color.opacity(0.82)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: dash)
        )
        let endpoint = point(item.samples.count - 1)
        context.fill(
            Path(ellipseIn: CGRect(x: endpoint.x - 2, y: endpoint.y - 2, width: 4, height: 4)),
            with: .color(item.color)
        )
    }
}

private struct SurfaceNormalizer {
    let samples: [Double]
    let type: MetricValueType

    func normalize(_ value: Double) -> Double {
        if type == .ratio { return min(max(value, 0), 1) }
        let lower = samples.min() ?? 0
        let upper = samples.max() ?? 1
        if lower >= 0 {
            let denominator = log1p(max(upper, 1))
            return denominator > 0 ? min(max(log1p(max(value, 0)) / denominator, 0), 1) : 0.5
        }
        return upper > lower ? min(max((value - lower) / (upper - lower), 0), 1) : 0.5
    }
}

private struct SurfaceCompactStatus: View {
    let label: String
    let metricID: String
    let value: CompactStatusMetricValue?
    let sampledAt: Date
    let date: Date

    var body: some View {
        VStack(spacing: 5) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.35)
                    .foregroundStyle(SurfacePalette.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: CGFloat(layout.spacing)) {
                Text(value?.leading ?? "☁️")
                Text(value?.trailing ?? "💾")
            }
            .font(.system(size: CGFloat(layout.fontSize)))
            HStack(spacing: 7) {
                SurfaceStatusMark(light: value?.light ?? .gray)
                Text(CompactAgeFormatter.compact(
                    ageSeconds: value?.ageSeconds,
                    elapsedSeconds: date.timeIntervalSince(sampledAt)
                ))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(SurfacePalette.primary)
            }
        }
        .accessibilityLabel(metricID)
    }

    private var layout: CompactStatusGlyphLayout {
        CompactStatusGlyphLayout.resolve(glyphScale: value?.glyphScale)
    }
}

private struct SurfaceStatusMark: View {
    let light: StatusLight

    @ViewBuilder
    var body: some View {
        switch light {
        case .green: Circle().fill(SurfacePalette.green).frame(width: 8, height: 8)
        case .blue: SurfaceDiamond().fill(SurfacePalette.blue).frame(width: 8, height: 8)
        case .amber: SurfaceTriangle().fill(SurfacePalette.amber).frame(width: 9, height: 8)
        case .red:
            ZStack {
                Capsule().fill(SurfacePalette.red).frame(width: 10, height: 1.8).rotationEffect(.degrees(45))
                Capsule().fill(SurfacePalette.red).frame(width: 10, height: 1.8).rotationEffect(.degrees(-45))
            }
            .frame(width: 9, height: 9)
        case .gray: Circle().stroke(SurfacePalette.secondary, lineWidth: 1.4).frame(width: 8, height: 8)
        }
    }
}

private struct SurfaceDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
    }
}

private struct SurfaceTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

private struct SurfaceTable: View {
    let label: String
    let state: WidgetRenderMetric?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .foregroundStyle(SurfacePalette.secondary)
            if state?.error == nil, case let .table(table) = state?.value {
                HStack(spacing: 7) {
                    ForEach(table.columns.indices, id: \.self) { column in
                        Text(table.columns[column])
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .foregroundStyle(SurfacePalette.secondary)
                ForEach(table.rows.prefix(5).indices, id: \.self) { row in
                    HStack(spacing: 7) {
                        ForEach(table.rows[row].indices, id: \.self) { column in
                            Text(table.rows[row][column])
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .tracking(0.25)
        .foregroundStyle(SurfacePalette.primary)
        .lineLimit(1)
    }
}

private struct SurfaceEmptyMark: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: size.width / 2 - 6, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width / 2 + 6, y: size.height / 2))
            context.stroke(path, with: .color(SurfacePalette.secondary), lineWidth: 1)
        }
    }
}

private enum SurfacePalette {
    static let primary = Color.white.opacity(0.86)
    static let secondary = Color.white.opacity(0.68)
    static let outline = Color.white.opacity(0.16)
    static let track = Color.white.opacity(0.07)
    static let grid = Color.white.opacity(0.055)
    static let cyan = Color(red: 0.34, green: 0.76, blue: 0.82)
    static let blue = Color(red: 0.35, green: 0.54, blue: 0.80)
    static let green = Color(red: 0.39, green: 0.75, blue: 0.61)
    static let amber = Color(red: 0.84, green: 0.63, blue: 0.34)
    static let violet = Color(red: 0.63, green: 0.53, blue: 0.80)
    static let red = Color(red: 0.88, green: 0.36, blue: 0.33)

    static func accent(_ name: String?) -> Color {
        switch name?.lowercased() {
        case "blue": blue
        case "green", "mint": green
        case "amber", "orange": amber
        case "violet", "purple": violet
        case "red": red
        default: cyan
        }
    }
}
