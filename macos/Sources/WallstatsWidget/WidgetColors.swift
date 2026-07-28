import SwiftUI

enum WidgetColors {
    static let graphiteTop = Color(red: 0.16, green: 0.17, blue: 0.19)
    static let graphiteBottom = Color(red: 0.075, green: 0.082, blue: 0.095)
    static let graphiteGlint = Color(red: 0.32, green: 0.34, blue: 0.37)

    static let railTrack = Color.white.opacity(0.06)
    static let baseline = Color.white.opacity(0.14)
    static let grid = Color.white.opacity(0.055)
    static let missingMark = Color.white.opacity(0.16)
    static let field = Color.white.opacity(0.045)
    static let fieldBorder = Color.white.opacity(0.075)
    static let sectionOutline = Color.white.opacity(0.15)
    static let sectionLabel = Color.white.opacity(0.46)

    static let cpu = Color(red: 0.34, green: 0.76, blue: 0.82)
    static let memory = Color(red: 0.63, green: 0.53, blue: 0.80)
    static let disk = Color(red: 0.84, green: 0.63, blue: 0.34)
    static let download = Color(red: 0.35, green: 0.54, blue: 0.80)
    static let upload = Color(red: 0.39, green: 0.75, blue: 0.61)
    static let failure = Color(red: 0.88, green: 0.36, blue: 0.33)
    static let neutral = Color.white.opacity(0.34)
    static let widgetLabel = Color.white.opacity(0.56)
    static let widgetValue = Color.white.opacity(0.86)

    static func accent(_ name: String?) -> Color {
        switch name?.lowercased() {
        case "violet", "purple": memory
        case "amber", "orange": disk
        case "blue": download
        case "green", "mint": upload
        case "red": failure
        case "gray", "grey": neutral
        default: cpu
        }
    }
}

struct WidgetContainerBackground: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    WidgetColors.graphiteTop.opacity(0.72),
                    WidgetColors.graphiteBottom.opacity(0.82),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                colors: [
                    WidgetColors.graphiteGlint.opacity(0.09),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .center
            )
        }
    }
}
