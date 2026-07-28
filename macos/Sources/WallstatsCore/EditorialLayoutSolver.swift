import Foundation

public struct EditorialRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(_ other: EditorialRect, tolerance: Double = 0.000_001) -> Bool {
        other.x >= x - tolerance
            && other.y >= y - tolerance
            && other.maxX <= maxX + tolerance
            && other.maxY <= maxY + tolerance
    }
}

public enum EditorialPlacementRole: Equatable, Sendable {
    case sectionChrome
    case widget(WidgetKind)
}

public struct EditorialPlacement: Equatable, Sendable {
    public let pathID: String
    public let role: EditorialPlacementRole
    public let allocationFrame: EditorialRect
    public let contentFrame: EditorialRect

    public init(
        pathID: String,
        role: EditorialPlacementRole,
        allocationFrame: EditorialRect,
        contentFrame: EditorialRect
    ) {
        self.pathID = pathID
        self.role = role
        self.allocationFrame = allocationFrame
        self.contentFrame = contentFrame
    }
}

public struct EditorialLayoutResult: Equatable, Sendable {
    public let placements: [EditorialPlacement]
    public let naturalHeight: Double
    public let minimumHeight: Double
    public let resolvedHeight: Double
    public let overflow: Bool
}

public enum EditorialLayoutSolver {
    private static let sectionChromeHeight = 14.0

    public static func solve(
        root: LayoutNode,
        width: Double,
        boundedHeight: Double? = nil
    ) -> EditorialLayoutResult {
        let boundedHeightIsValid = boundedHeight.map { $0.isFinite && $0 >= 0 } ?? true
        guard width.isFinite, width >= 0, boundedHeightIsValid
        else {
            return EditorialLayoutResult(
                placements: [],
                naturalHeight: 0,
                minimumHeight: 0,
                resolvedHeight: 0,
                overflow: true
            )
        }

        let bounds = measure(root, width: width)
        let requestedHeight = boundedHeight ?? bounds.preferred
        let overflow = requestedHeight < bounds.minimum
        let resolvedHeight = overflow ? bounds.minimum : requestedHeight
        var placements: [EditorialPlacement] = []
        pack(
            root,
            path: "0",
            frame: EditorialRect(x: 0, y: 0, width: width, height: resolvedHeight),
            placements: &placements
        )
        return EditorialLayoutResult(
            placements: placements,
            naturalHeight: bounds.preferred,
            minimumHeight: bounds.minimum,
            resolvedHeight: resolvedHeight,
            overflow: overflow
        )
    }

    private struct FlexBounds {
        let minimum: Double
        let preferred: Double
        let maximum: Double
        let grow: Double
        let shrink: Double
    }

    private static func measure(_ node: LayoutNode, width: Double) -> FlexBounds {
        switch node {
        case let .widget(widget):
            return widgetBounds(widget.kind)
        case let .section(_, insets, child):
            let childWidth = max(width - insets.left - insets.right, 0)
            let childBounds = measure(child, width: childWidth)
            let extra = insets.top + insets.bottom + sectionChromeHeight
            return FlexBounds(
                minimum: childBounds.minimum + extra,
                preferred: childBounds.preferred + extra,
                maximum: childBounds.maximum + extra,
                grow: childBounds.grow,
                shrink: childBounds.shrink
            )
        case let .stack(gap, children):
            return stackedBounds(children, gap: gap, width: width)
        case let .split(gap, minimumTrackWidth, tracks):
            let trackWidths = splitWidths(
                width: width,
                gap: gap,
                minimumTrackWidth: minimumTrackWidth,
                tracks: tracks
            )
            guard let trackWidths else {
                return stackedBounds(tracks.map(\.child), gap: gap, width: width)
            }
            let bounds = zip(tracks, trackWidths).map { measure($0.0.child, width: $0.1) }
            return FlexBounds(
                minimum: bounds.map(\.minimum).max() ?? 0,
                preferred: bounds.map(\.preferred).max() ?? 0,
                maximum: bounds.map(\.maximum).max() ?? 0,
                grow: bounds.map(\.grow).max() ?? 0,
                shrink: bounds.map(\.shrink).max() ?? 0
            )
        case let .flow(horizontalGap, verticalGap, minimumItemWidth, children):
            let columns = flowColumns(
                width: width,
                gap: horizontalGap,
                minimumItemWidth: minimumItemWidth,
                itemCount: children.count
            )
            let itemWidth = max(
                (width - horizontalGap * Double(max(columns - 1, 0))) / Double(columns),
                0
            )
            let rows = stride(from: 0, to: children.count, by: columns).map { start in
                Array(children[start ..< min(start + columns, children.count)])
            }
            let rowBounds = rows.map { row -> FlexBounds in
                let bounds = row.map { measure($0, width: itemWidth) }
                return FlexBounds(
                    minimum: bounds.map(\.minimum).max() ?? 0,
                    preferred: bounds.map(\.preferred).max() ?? 0,
                    maximum: bounds.map(\.maximum).max() ?? 0,
                    grow: bounds.map(\.grow).max() ?? 0,
                    shrink: bounds.map(\.shrink).max() ?? 0
                )
            }
            return aggregate(rowBounds, gap: verticalGap)
        }
    }

    private static func widgetBounds(_ kind: WidgetKind) -> FlexBounds {
        switch kind {
        case .value:
            FlexBounds(minimum: 20, preferred: 26, maximum: 36, grow: 0.5, shrink: 1)
        case .gauge:
            FlexBounds(minimum: 28, preferred: 36, maximum: 48, grow: 1, shrink: 1)
        case .sparkline:
            FlexBounds(minimum: 44, preferred: 60, maximum: 98, grow: 2, shrink: 1)
        case .plot:
            FlexBounds(minimum: 70, preferred: 104, maximum: 194, grow: 3, shrink: 1)
        case .table:
            FlexBounds(minimum: 64, preferred: 112, maximum: 250, grow: 2, shrink: 1)
        case .compactStatus:
            FlexBounds(minimum: 54, preferred: 62, maximum: 68, grow: 0, shrink: 0)
        }
    }

    private static func stackedBounds(
        _ children: [LayoutNode],
        gap: Double,
        width: Double
    ) -> FlexBounds {
        aggregate(children.map { measure($0, width: width) }, gap: gap)
    }

    private static func aggregate(_ bounds: [FlexBounds], gap: Double) -> FlexBounds {
        let gaps = gap * Double(max(bounds.count - 1, 0))
        return FlexBounds(
            minimum: bounds.reduce(gaps) { $0 + $1.minimum },
            preferred: bounds.reduce(gaps) { $0 + $1.preferred },
            maximum: bounds.reduce(gaps) { $0 + $1.maximum },
            grow: bounds.reduce(0) { $0 + $1.grow },
            shrink: bounds.reduce(0) { $0 + $1.shrink }
        )
    }

    private static func pack(
        _ node: LayoutNode,
        path: String,
        frame: EditorialRect,
        placements: inout [EditorialPlacement]
    ) {
        switch node {
        case let .widget(widget):
            let bounds = widgetBounds(widget.kind)
            let contentHeight = min(frame.height, bounds.maximum)
            let contentFrame: EditorialRect
            if widget.kind == .compactStatus {
                let side = min(frame.width, contentHeight)
                contentFrame = EditorialRect(
                    x: frame.x + (frame.width - side) / 2,
                    y: frame.y + (frame.height - side) / 2,
                    width: side,
                    height: side
                )
            } else {
                contentFrame = EditorialRect(
                    x: frame.x,
                    y: frame.y + (frame.height - contentHeight) / 2,
                    width: frame.width,
                    height: contentHeight
                )
            }
            placements.append(EditorialPlacement(
                pathID: path,
                role: .widget(widget.kind),
                allocationFrame: frame,
                contentFrame: contentFrame
            ))
        case let .section(_, insets, child):
            let contentFrame = EditorialRect(
                x: frame.x + insets.left,
                y: frame.y + sectionChromeHeight + insets.top,
                width: max(frame.width - insets.left - insets.right, 0),
                height: max(
                    frame.height - sectionChromeHeight - insets.top - insets.bottom,
                    0
                )
            )
            placements.append(EditorialPlacement(
                pathID: path,
                role: .sectionChrome,
                allocationFrame: frame,
                contentFrame: contentFrame
            ))
            pack(child, path: "\(path)/0", frame: contentFrame, placements: &placements)
        case let .stack(gap, children):
            packStack(children, gap: gap, path: path, frame: frame, placements: &placements)
        case let .split(gap, minimumTrackWidth, tracks):
            guard let widths = splitWidths(
                width: frame.width,
                gap: gap,
                minimumTrackWidth: minimumTrackWidth,
                tracks: tracks
            ) else {
                packStack(
                    tracks.map(\.child),
                    gap: gap,
                    path: path,
                    frame: frame,
                    placements: &placements
                )
                return
            }
            var x = frame.x
            for index in tracks.indices {
                let childBounds = measure(tracks[index].child, width: widths[index])
                let height = min(max(frame.height, childBounds.minimum), childBounds.maximum)
                pack(
                    tracks[index].child,
                    path: "\(path)/\(index)",
                    frame: EditorialRect(x: x, y: frame.y, width: widths[index], height: height),
                    placements: &placements
                )
                x += widths[index] + gap
            }
        case let .flow(horizontalGap, verticalGap, minimumItemWidth, children):
            let columns = flowColumns(
                width: frame.width,
                gap: horizontalGap,
                minimumItemWidth: minimumItemWidth,
                itemCount: children.count
            )
            let itemWidth = max(
                (frame.width - horizontalGap * Double(max(columns - 1, 0))) / Double(columns),
                0
            )
            let rowStarts = Array(stride(from: 0, to: children.count, by: columns))
            let rowBounds = rowStarts.map { start -> FlexBounds in
                let row = children[start ..< min(start + columns, children.count)]
                let bounds = row.map { measure($0, width: itemWidth) }
                return FlexBounds(
                    minimum: bounds.map(\.minimum).max() ?? 0,
                    preferred: bounds.map(\.preferred).max() ?? 0,
                    maximum: bounds.map(\.maximum).max() ?? 0,
                    grow: bounds.map(\.grow).max() ?? 0,
                    shrink: bounds.map(\.shrink).max() ?? 0
                )
            }
            let heights = flex(bounds: rowBounds, available: frame.height, gap: verticalGap)
            var y = frame.y
            for (rowIndex, start) in rowStarts.enumerated() {
                for column in 0 ..< columns {
                    let childIndex = start + column
                    guard childIndex < children.count else { break }
                    let x = frame.x + Double(column) * (itemWidth + horizontalGap)
                    pack(
                        children[childIndex],
                        path: "\(path)/\(childIndex)",
                        frame: EditorialRect(
                            x: x,
                            y: y,
                            width: itemWidth,
                            height: heights[rowIndex]
                        ),
                        placements: &placements
                    )
                }
                y += heights[rowIndex] + verticalGap
            }
        }
    }

    private static func packStack(
        _ children: [LayoutNode],
        gap: Double,
        path: String,
        frame: EditorialRect,
        placements: inout [EditorialPlacement]
    ) {
        let bounds = children.map { measure($0, width: frame.width) }
        let heights = flex(bounds: bounds, available: frame.height, gap: gap)
        var y = frame.y
        for index in children.indices {
            pack(
                children[index],
                path: "\(path)/\(index)",
                frame: EditorialRect(x: frame.x, y: y, width: frame.width, height: heights[index]),
                placements: &placements
            )
            y += heights[index] + gap
        }
    }

    private static func flex(
        bounds: [FlexBounds],
        available: Double,
        gap: Double
    ) -> [Double] {
        guard !bounds.isEmpty else { return [] }
        let contentAvailable = max(available - gap * Double(max(bounds.count - 1, 0)), 0)
        let minimumTotal = bounds.reduce(0) { $0 + $1.minimum }
        if contentAvailable <= minimumTotal {
            return bounds.map(\.minimum)
        }

        var values = bounds.map(\.preferred)
        let preferredTotal = values.reduce(0, +)
        if contentAvailable > preferredTotal {
            distribute(
                amount: contentAvailable - preferredTotal,
                values: &values,
                bounds: bounds,
                grow: true
            )
        } else if contentAvailable < preferredTotal {
            distribute(
                amount: preferredTotal - contentAvailable,
                values: &values,
                bounds: bounds,
                grow: false
            )
        }
        return values
    }

    private static func distribute(
        amount: Double,
        values: inout [Double],
        bounds: [FlexBounds],
        grow: Bool
    ) {
        var remaining = amount
        var active = Array(values.indices)
        while remaining > 0.000_001, !active.isEmpty {
            let totalWeight = active.reduce(0.0) { partial, index in
                partial + (grow ? bounds[index].grow : bounds[index].shrink)
            }
            guard totalWeight > 0 else { break }
            var consumed = 0.0
            for index in active {
                let weight = grow ? bounds[index].grow : bounds[index].shrink
                let share = remaining * weight / totalWeight
                let capacity = grow
                    ? bounds[index].maximum - values[index]
                    : values[index] - bounds[index].minimum
                let delta = min(max(capacity, 0), share)
                values[index] += grow ? delta : -delta
                consumed += delta
            }
            active = active.filter { index in
                grow
                    ? values[index] < bounds[index].maximum - 0.000_001
                    : values[index] > bounds[index].minimum + 0.000_001
            }
            guard consumed > 0 else { break }
            remaining -= consumed
        }
    }

    private static func splitWidths(
        width: Double,
        gap: Double,
        minimumTrackWidth: Double,
        tracks: [LayoutTrack]
    ) -> [Double]? {
        guard !tracks.isEmpty else { return nil }
        let gutterTotal = gap * Double(max(tracks.count - 1, 0))
        let available = width - gutterTotal
        guard available >= minimumTrackWidth * Double(tracks.count) else { return nil }
        let extra = available - minimumTrackWidth * Double(tracks.count)
        let totalWeight = tracks.reduce(0) { $0 + $1.weight }
        return tracks.map { minimumTrackWidth + extra * $0.weight / totalWeight }
    }

    private static func flowColumns(
        width: Double,
        gap: Double,
        minimumItemWidth: Double,
        itemCount: Int
    ) -> Int {
        guard itemCount > 0 else { return 1 }
        let denominator = minimumItemWidth + gap
        guard denominator > 0 else { return itemCount }
        let derived = Int(floor((width + gap) / denominator))
        return min(max(derived, 1), itemCount)
    }
}
