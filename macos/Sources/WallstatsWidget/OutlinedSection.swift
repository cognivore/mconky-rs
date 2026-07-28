import SwiftUI

struct OutlinedSection<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SectionOutline(gapWidth: labelGapWidth)
                .stroke(WidgetColors.sectionOutline, lineWidth: 0.75)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 9)
                .padding(.top, 17)
                .padding(.bottom, 9)

            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(WidgetColors.sectionLabel)
                .lineLimit(1)
                .offset(x: 16, y: 0)
        }
    }

    private var labelGapWidth: CGFloat {
        min(max(CGFloat(label.count) * 5.5 + 14, 34), 140)
    }
}

private struct SectionOutline: Shape {
    let gapWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + 5
        let bottom = rect.maxY
        let radius = min(9, max((bottom - top) / 2, 0))
        let gapStart = min(rect.minX + 12, rect.maxX)
        let gapEnd = min(gapStart + gapWidth, rect.maxX - radius)

        var path = Path()
        path.move(to: CGPoint(x: gapEnd, y: top))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: top + radius),
            control: CGPoint(x: rect.maxX, y: top)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: bottom),
            control: CGPoint(x: rect.maxX, y: bottom)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: bottom - radius),
            control: CGPoint(x: rect.minX, y: bottom)
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
