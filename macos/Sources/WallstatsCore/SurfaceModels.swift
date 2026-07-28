import Foundation

public enum SurfaceKind: String, Codable, CaseIterable, Equatable, Sendable {
    case desktop
    case widgetLarge = "widget_large"
    case widgetMedium = "widget_medium"
    case widgetSmall = "widget_small"
}

public enum SurfaceOrigin: String, Codable, CaseIterable, Equatable, Sendable {
    case bottomLeft = "bottom_left"
    case topLeft = "top_left"
    case bottomRight = "bottom_right"
    case topRight = "top_right"
}

public struct LayoutInsets: Codable, Equatable, Sendable {
    public let top: Double
    public let right: Double
    public let bottom: Double
    public let left: Double

    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public static let zero = LayoutInsets(top: 0, right: 0, bottom: 0, left: 0)
}

public struct LayoutTrack: Codable, Equatable, Sendable {
    public let weight: Double
    public let child: LayoutNode

    public init(weight: Double, child: LayoutNode) {
        self.weight = weight
        self.child = child
    }
}

public indirect enum LayoutNode: Codable, Equatable, Sendable {
    case widget(WidgetPlan)
    case section(title: String, insets: LayoutInsets, child: LayoutNode)
    case stack(gap: Double, children: [LayoutNode])
    case split(gap: Double, minimumTrackWidth: Double, tracks: [LayoutTrack])
    case flow(
        horizontalGap: Double,
        verticalGap: Double,
        minimumItemWidth: Double,
        children: [LayoutNode]
    )

    private enum CodingKeys: String, CodingKey {
        case kind
        case widget
        case title
        case insets
        case child
        case gap
        case children
        case minimumTrackWidth = "minimum_track_width"
        case tracks
        case horizontalGap = "horizontal_gap"
        case verticalGap = "vertical_gap"
        case minimumItemWidth = "minimum_item_width"
    }

    private enum Kind: String, Codable {
        case widget
        case section
        case stack
        case split
        case flow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .widget:
            self = .widget(try container.decode(WidgetPlan.self, forKey: .widget))
        case .section:
            self = .section(
                title: try container.decode(String.self, forKey: .title),
                insets: try container.decode(LayoutInsets.self, forKey: .insets),
                child: try container.decode(LayoutNode.self, forKey: .child)
            )
        case .stack:
            self = .stack(
                gap: try container.decode(Double.self, forKey: .gap),
                children: try container.decode([LayoutNode].self, forKey: .children)
            )
        case .split:
            self = .split(
                gap: try container.decode(Double.self, forKey: .gap),
                minimumTrackWidth: try container.decode(Double.self, forKey: .minimumTrackWidth),
                tracks: try container.decode([LayoutTrack].self, forKey: .tracks)
            )
        case .flow:
            self = .flow(
                horizontalGap: try container.decode(Double.self, forKey: .horizontalGap),
                verticalGap: try container.decode(Double.self, forKey: .verticalGap),
                minimumItemWidth: try container.decode(Double.self, forKey: .minimumItemWidth),
                children: try container.decode([LayoutNode].self, forKey: .children)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .widget(widget):
            try container.encode(Kind.widget, forKey: .kind)
            try container.encode(widget, forKey: .widget)
        case let .section(title, insets, child):
            try container.encode(Kind.section, forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encode(insets, forKey: .insets)
            try container.encode(child, forKey: .child)
        case let .stack(gap, children):
            try container.encode(Kind.stack, forKey: .kind)
            try container.encode(gap, forKey: .gap)
            try container.encode(children, forKey: .children)
        case let .split(gap, minimumTrackWidth, tracks):
            try container.encode(Kind.split, forKey: .kind)
            try container.encode(gap, forKey: .gap)
            try container.encode(minimumTrackWidth, forKey: .minimumTrackWidth)
            try container.encode(tracks, forKey: .tracks)
        case let .flow(horizontalGap, verticalGap, minimumItemWidth, children):
            try container.encode(Kind.flow, forKey: .kind)
            try container.encode(horizontalGap, forKey: .horizontalGap)
            try container.encode(verticalGap, forKey: .verticalGap)
            try container.encode(minimumItemWidth, forKey: .minimumItemWidth)
            try container.encode(children, forKey: .children)
        }
    }
}

public struct SurfacePlan: Codable, Equatable, Sendable {
    public let kind: SurfaceKind
    public let root: LayoutNode
    public let x: Double?
    public let y: Double?
    public let origin: SurfaceOrigin?
    public let width: Double?
    public let backgroundOpacity: Double?
    public let clickThrough: Bool?

    public init(
        kind: SurfaceKind,
        root: LayoutNode,
        x: Double? = nil,
        y: Double? = nil,
        origin: SurfaceOrigin? = nil,
        width: Double? = nil,
        backgroundOpacity: Double? = nil,
        clickThrough: Bool? = nil
    ) {
        self.kind = kind
        self.root = root
        self.x = x
        self.y = y
        self.origin = origin
        self.width = width
        self.backgroundOpacity = backgroundOpacity
        self.clickThrough = clickThrough
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case root
        case x
        case y
        case origin
        case width
        case backgroundOpacity = "background_opacity"
        case clickThrough = "click_through"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(SurfaceKind.self, forKey: .kind)
        root = try container.decode(LayoutNode.self, forKey: .root)
        x = try container.decodeIfPresent(Double.self, forKey: .x)
        y = try container.decodeIfPresent(Double.self, forKey: .y)
        origin = try container.decodeIfPresent(SurfaceOrigin.self, forKey: .origin)
            ?? (kind == .desktop ? .topLeft : nil)
        width = try container.decodeIfPresent(Double.self, forKey: .width)
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity)
        clickThrough = try container.decodeIfPresent(Bool.self, forKey: .clickThrough)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(root, forKey: .root)
        try container.encodeIfPresent(x, forKey: .x)
        try container.encodeIfPresent(y, forKey: .y)
        try container.encodeIfPresent(origin, forKey: .origin)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(backgroundOpacity, forKey: .backgroundOpacity)
        try container.encodeIfPresent(clickThrough, forKey: .clickThrough)
    }
}

public extension LayoutNode {
    var referencedMetrics: [String] {
        switch self {
        case let .widget(widget):
            return widget.kind == .plot ? widget.series.map(\.metric) : [widget.metric]
        case let .section(_, _, child):
            return child.referencedMetrics
        case let .stack(_, children), let .flow(_, _, _, children):
            return children.flatMap(\.referencedMetrics)
        case let .split(_, _, tracks):
            return tracks.flatMap { $0.child.referencedMetrics }
        }
    }
}
