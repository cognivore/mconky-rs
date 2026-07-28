import Foundation
import SwiftUI
import WallstatsCore

struct CompactStatusTile: View {
    let status: CompactStatusSnapshot?
    let sampledAt: Date?
    let date: Date
    let size: CGFloat

    init(
        status: CompactStatusSnapshot?,
        sampledAt: Date?,
        date: Date,
        size: CGFloat = 58
    ) {
        self.status = status
        self.sampledAt = sampledAt
        self.date = date
        self.size = size
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(WidgetColors.field)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(WidgetColors.fieldBorder, lineWidth: 0.75)

            VStack(spacing: 6) {
                HStack(spacing: CGFloat(glyphLayout.spacing)) {
                    Text(status?.value.leading ?? "☁️")
                    Text(status?.value.trailing ?? "💾")
                }
                .font(.system(size: CGFloat(glyphLayout.fontSize)))

                HStack(spacing: 8) {
                    StatusLightMark(light: light)
                    Text(compactAge)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.76))
                        .frame(minWidth: 25, alignment: .leading)
                }
            }
            .padding(7)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status?.metricID ?? "Compact status")
        .accessibilityValue(accessibilityValue)
    }

    private var compactAge: String {
        CompactAgeFormatter.compact(
            ageSeconds: status?.value.ageSeconds,
            elapsedSeconds: sampledAt.map { date.timeIntervalSince($0) } ?? 0
        )
    }

    private var light: StatusLight {
        status?.value.light ?? .gray
    }

    private var glyphLayout: CompactStatusGlyphLayout {
        CompactStatusGlyphLayout.resolve(glyphScale: status?.value.glyphScale)
    }

    private var accessibilityValue: String {
        let age = compactAge == "--" ? "age unavailable" : "age \(compactAge)"
        return "\(light.accessibilityDescription), \(age)"
    }
}

private struct StatusLightMark: View {
    let light: StatusLight

    @ViewBuilder
    var body: some View {
        switch light {
        case .green:
            Circle()
                .fill(WidgetColors.upload)
                .frame(width: 8, height: 8)
        case .blue:
            Diamond()
                .fill(WidgetColors.download)
                .frame(width: 8, height: 8)
        case .amber:
            Triangle()
                .fill(WidgetColors.disk)
                .frame(width: 9, height: 8)
        case .red:
            XMark(color: WidgetColors.failure)
                .frame(width: 9, height: 9)
        case .gray:
            Circle()
                .stroke(WidgetColors.neutral, lineWidth: 1.4)
                .frame(width: 8, height: 8)
        }
    }
}

private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct XMark: View {
    let color: Color

    var body: some View {
        ZStack {
            Capsule()
                .fill(color)
                .frame(width: 10, height: 1.8)
                .rotationEffect(.degrees(45))
            Capsule()
                .fill(color)
                .frame(width: 10, height: 1.8)
                .rotationEffect(.degrees(-45))
        }
    }
}

private extension StatusLight {
    var accessibilityDescription: String {
        switch self {
        case .green:
            "Green circle"
        case .blue:
            "Blue diamond"
        case .amber:
            "Amber triangle"
        case .red:
            "Red X"
        case .gray:
            "Gray ring"
        }
    }
}
