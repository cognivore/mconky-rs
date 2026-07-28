import Foundation
import SwiftUI
import WallstatsCore

struct MetricPlotSeries {
    let samples: [Double]
    let valueType: MetricValueType
    let color: Color
}

struct MetricPlot: View {
    let series: [MetricPlotSeries]

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 3, y: 3, width: max(size.width - 6, 0), height: max(size.height - 6, 0))
            guard plot.width > 0, plot.height > 0 else { return }
            drawGrid(in: plot, context: &context)

            for (index, item) in series.enumerated() where !item.samples.isEmpty {
                draw(item, index: index, in: plot, context: &context)
            }
            if series.allSatisfy({ $0.samples.isEmpty }) {
                drawMissingMark(in: plot, context: &context)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Metric history plot")
        .accessibilityValue("\(series.count) configured series")
    }

    private func drawGrid(in plot: CGRect, context: inout GraphicsContext) {
        for fraction in [0.25, 0.5, 0.75] as [CGFloat] {
            var path = Path()
            let y = plot.minY + plot.height * fraction
            path.move(to: CGPoint(x: plot.minX, y: y))
            path.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(path, with: .color(WidgetColors.grid), lineWidth: 0.5)
        }
    }

    private func draw(
        _ item: MetricPlotSeries,
        index: Int,
        in plot: CGRect,
        context: inout GraphicsContext
    ) {
        let normalizer = PlotNormalizer(samples: item.samples, valueType: item.valueType)

        func point(_ sampleIndex: Int) -> CGPoint {
            let x = item.samples.count == 1
                ? plot.maxX
                : plot.minX + CGFloat(sampleIndex) / CGFloat(item.samples.count - 1) * plot.width
            let y = plot.maxY - CGFloat(normalizer.normalize(item.samples[sampleIndex])) * plot.height
            return CGPoint(x: x, y: y)
        }

        var path = Path()
        path.move(to: point(0))
        for sampleIndex in item.samples.indices.dropFirst() {
            path.addLine(to: point(sampleIndex))
        }
        let dash: [CGFloat]
        switch index % 3 {
        case 1: dash = [4, 2]
        case 2: dash = [1, 2]
        default: dash = []
        }
        context.stroke(
            path,
            with: .color(item.color.opacity(0.82)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: dash)
        )

        let endpoint = point(item.samples.count - 1)
        context.fill(
            Path(ellipseIn: CGRect(x: endpoint.x - 2, y: endpoint.y - 2, width: 4, height: 4)),
            with: .color(item.color.opacity(0.95))
        )
    }

    private func drawMissingMark(in plot: CGRect, context: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(x: plot.midX - 5, y: plot.midY))
        path.addLine(to: CGPoint(x: plot.midX + 5, y: plot.midY))
        context.stroke(
            path,
            with: .color(WidgetColors.missingMark),
            style: StrokeStyle(lineWidth: 1, lineCap: .round)
        )
    }
}

private struct PlotNormalizer {
    let samples: [Double]
    let valueType: MetricValueType

    func normalize(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        if valueType == .ratio {
            return min(max(value, 0), 1)
        }

        let lower = samples.min() ?? 0
        let upper = samples.max() ?? 1
        if lower >= 0 {
            let denominator = log1p(max(upper, 1))
            guard denominator > 0, denominator.isFinite else { return 0.5 }
            return min(max(log1p(max(value, 0)) / denominator, 0), 1)
        }
        guard upper > lower else { return 0.5 }
        return min(max((value - lower) / (upper - lower), 0), 1)
    }
}
