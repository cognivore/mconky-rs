import SwiftUI
import WidgetKit
import WallstatsCore

@main
struct WallstatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetSnapshotStore.widgetKind,
            provider: WallstatsTimelineProvider()
        ) { entry in
            WallstatsWidgetView(entry: entry)
        }
        .configurationDisplayName("Wallstats")
        .description("A graphical system activity snapshot.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
