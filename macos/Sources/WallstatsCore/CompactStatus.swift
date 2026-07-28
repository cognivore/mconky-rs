import Foundation

public enum StatusLight: String, Codable, CaseIterable, Equatable, Sendable {
    case green
    case blue
    case amber
    case red
    case gray
}

public struct CompactStatusMetricValue: Codable, Equatable, Sendable {
    public static let maximumGlyphBytes = 32
    public static let maximumGlyphGraphemes = 2

    public let leading: String
    public let trailing: String
    public let light: StatusLight
    public let ageSeconds: Double?
    public let glyphScale: Double?

    public init(
        leading: String,
        trailing: String,
        light: StatusLight,
        ageSeconds: Double? = nil,
        glyphScale: Double? = nil
    ) {
        self.leading = leading
        self.trailing = trailing
        self.light = light
        self.ageSeconds = ageSeconds
        self.glyphScale = glyphScale
    }

    enum CodingKeys: String, CodingKey {
        case leading
        case trailing
        case light
        case ageSeconds = "age_seconds"
        case glyphScale = "glyph_scale"
    }

    public var isValid: Bool {
        guard Self.isValidGlyph(leading), Self.isValidGlyph(trailing) else { return false }
        if let ageSeconds, !ageSeconds.isFinite || ageSeconds < 0 {
            return false
        }
        if let glyphScale, !glyphScale.isFinite || !(0.4 ... 1.5).contains(glyphScale) {
            return false
        }
        return true
    }

    public static func isValidGlyph(_ glyph: String) -> Bool {
        guard !glyph.isEmpty,
              glyph.utf8.count <= maximumGlyphBytes,
              glyph.count <= maximumGlyphGraphemes
        else {
            return false
        }
        return !glyph.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                true
            case .format:
                scalar.value != 0x200D
            default:
                false
            }
        }
    }
}

public struct CompactStatusSnapshot: Codable, Equatable, Sendable {
    public let metricID: String
    public let value: CompactStatusMetricValue

    public init(metricID: String, value: CompactStatusMetricValue) {
        self.metricID = metricID
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case metricID = "i"
        case leading = "l"
        case trailing = "r"
        case light = "c"
        case ageSeconds = "a"
        case glyphScale = "g"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metricID = try container.decode(String.self, forKey: .metricID)
        value = CompactStatusMetricValue(
            leading: try container.decode(String.self, forKey: .leading),
            trailing: try container.decode(String.self, forKey: .trailing),
            light: try container.decode(StatusLight.self, forKey: .light),
            ageSeconds: try container.decodeIfPresent(Double.self, forKey: .ageSeconds),
            glyphScale: try container.decodeIfPresent(Double.self, forKey: .glyphScale)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metricID, forKey: .metricID)
        try container.encode(value.leading, forKey: .leading)
        try container.encode(value.trailing, forKey: .trailing)
        try container.encode(value.light, forKey: .light)
        try container.encodeIfPresent(value.ageSeconds, forKey: .ageSeconds)
        try container.encodeIfPresent(value.glyphScale, forKey: .glyphScale)
    }
}

public struct CompactStatusGlyphLayout: Equatable, Sendable {
    public static let baseFontSize = 13.0
    public static let baseSpacing = 8.0
    public static let minimumSpacing = 3.0

    public let fontSize: Double
    public let spacing: Double

    public static func resolve(glyphScale: Double?) -> CompactStatusGlyphLayout {
        let requestedScale = glyphScale ?? 1
        let scale = requestedScale.isFinite && (0.4 ... 1.5).contains(requestedScale)
            ? requestedScale
            : 1
        let spacingScale = min(scale, 1 / scale)
        return CompactStatusGlyphLayout(
            fontSize: baseFontSize * scale,
            spacing: max(minimumSpacing, baseSpacing * spacingScale)
        )
    }
}

public enum CompactAgeFormatter {
    public static func compact(
        ageSeconds: Double?,
        elapsedSeconds: TimeInterval = 0
    ) -> String {
        guard let ageSeconds,
              ageSeconds.isFinite,
              ageSeconds >= 0,
              elapsedSeconds.isFinite
        else {
            return "--"
        }

        let totalSeconds = ageSeconds + max(elapsedSeconds, 0)
        let cappedDays = 99.0 * 24 * 60 * 60
        if !totalSeconds.isFinite || totalSeconds >= cappedDays {
            return "99d+"
        }
        if totalSeconds >= 24 * 60 * 60 {
            return "\(Int(totalSeconds / (24 * 60 * 60)))d"
        }
        if totalSeconds >= 60 * 60 {
            return "\(Int(totalSeconds / (60 * 60)))h"
        }
        if totalSeconds >= 60 {
            return "\(Int(totalSeconds / 60))m"
        }
        return "<1m"
    }
}

public enum DiskFreeFormatter {
    public static func compact(_ bytes: UInt64?) -> String {
        guard let bytes else { return "--" }
        let units = ["B", "K", "M", "G", "T", "P", "E"]
        var amount = Double(bytes)
        var unitIndex = 0
        while amount >= 1024, unitIndex < units.count - 1 {
            amount /= 1024
            unitIndex += 1
        }

        let fractionDigits = unitIndex > 0 && amount < 10 && amount.rounded() != amount ? 1 : 0
        return String(
            format: "%.*f%@",
            locale: Locale(identifier: "en_US_POSIX"),
            fractionDigits,
            amount,
            units[unitIndex]
        )
    }
}
