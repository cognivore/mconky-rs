import SwiftUI
import WallstatsCore

struct DesktopSurfaceView: View {
    @ObservedObject var model: AppModel
    let surface: SurfacePlan

    var body: some View {
        if let dashboard = model.dashboard {
            let metrics = WidgetSnapshot.renderMetrics(dashboard: dashboard, root: surface.root)
            EditorialSurfaceView(
                root: surface.root,
                metrics: metrics,
                sampledAt: sampledAt(metrics: metrics, fallback: Date()),
                date: Date()
            )
        }
    }

    private func sampledAt(metrics: [WidgetRenderMetric], fallback: Date) -> Date {
        guard let timestamp = metrics.compactMap(\.timestampMS).max() else { return fallback }
        return Date(timeIntervalSince1970: Double(timestamp) / 1_000)
    }
}
