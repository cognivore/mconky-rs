import Foundation
import SwiftUI
import WidgetKit
import WallstatsCore

struct WallstatsWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: WallstatsEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot,
               let surface = snapshot.widgetSurfaces.first(where: { $0.kind == surfaceKind })
            {
                EditorialSurfaceView(
                    root: surface.root,
                    metrics: snapshot.metrics,
                    sampledAt: snapshot.sampledAt,
                    date: entry.date
                )
            } else {
                QuietEmptySurface()
            }
        }
        .opacity(entry.isStale ? 0.46 : 1)
        .accessibilityHint(entry.isStale ? "System activity snapshot is stale" : "Current system activity snapshot")
        .widgetURL(URL(string: "wallstats://config"))
        .containerBackground(for: .widget) {
            WidgetContainerBackground()
        }
    }

    private var surfaceKind: SurfaceKind {
        switch family {
        case .systemLarge: .widgetLarge
        case .systemMedium: .widgetMedium
        default: .widgetSmall
        }
    }
}

private struct QuietEmptySurface: View {
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
