import Foundation

public enum MetricValueFormatter {
    public static func string(for value: TypedMetricValue, format: MetricFormat) -> String {
        switch format {
        case .percent:
            guard let number = value.numericValue else { return "n/a" }
            return "\(decimal(number * 100, maximumFractionDigits: 1))%"

        case .bytes:
            guard case let .bytes(number) = value else { return "n/a" }
            return byteString(Double(number), suffix: "")

        case .bytesPerSecond:
            guard case let .bytesPerSecond(number) = value else { return "n/a" }
            return byteString(number, suffix: "/s")

        case .count:
            guard case let .count(number) = value else { return "n/a" }
            return groupedInteger(number)

        case .number:
            guard let number = value.numericValue else { return "n/a" }
            return decimal(number, maximumFractionDigits: 2)

        case .duration:
            guard case let .durationSeconds(number) = value else { return "n/a" }
            return durationString(number)

        case .text:
            guard case let .text(text) = value else { return "n/a" }
            return text

        case .boolean:
            guard case let .boolean(boolean) = value else { return "n/a" }
            return boolean ? "Yes" : "No"

        case .table:
            guard case let .table(table) = value else { return "n/a" }
            return table.rows.count == 1 ? "1 row" : "\(table.rows.count) rows"

        case .compactStatus:
            return "n/a"

        case .celsius:
            guard case let .number(number) = value else { return "n/a" }
            return "\(decimal(number, maximumFractionDigits: 1))°C"

        case .watts:
            guard case let .number(number) = value else { return "n/a" }
            return "\(decimal(number, maximumFractionDigits: 1))W"

        case .megahertz:
            guard case let .number(number) = value else { return "n/a" }
            return "\(decimal(number, maximumFractionDigits: 0))MHz"
        }
    }

    private static func byteString(_ bytes: Double, suffix: String) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        var amount = bytes
        var unitIndex = 0
        while amount >= 1024, unitIndex < units.count - 1 {
            amount /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(decimal(amount, maximumFractionDigits: amount.rounded() == amount ? 0 : 1)) B\(suffix)"
        }
        let digits = amount < 10 ? 1 : 0
        return "\(decimal(amount, maximumFractionDigits: digits)) \(units[unitIndex])\(suffix)"
    }

    private static func durationString(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(decimal(seconds, maximumFractionDigits: seconds < 10 ? 1 : 0))s"
        }
        guard let wholeSeconds = Int64(exactly: seconds.rounded()) else {
            return String(
                format: "%.3gs",
                locale: Locale(identifier: "en_US_POSIX"),
                seconds
            ).lowercased()
        }

        if wholeSeconds < 3600 {
            return "\(wholeSeconds / 60)m \(twoDigits(wholeSeconds % 60))s"
        }
        if wholeSeconds < 86_400 {
            return "\(wholeSeconds / 3600)h \(twoDigits((wholeSeconds % 3600) / 60))m"
        }
        return "\(wholeSeconds / 86_400)d \(twoDigits((wholeSeconds % 86_400) / 3600))h"
    }

    private static func decimal(_ value: Double, maximumFractionDigits: Int) -> String {
        guard value.isFinite else { return "n/a" }
        var result = String(
            format: "%.*f",
            locale: Locale(identifier: "en_US_POSIX"),
            maximumFractionDigits,
            value
        )
        if maximumFractionDigits > 0, result.contains(".") {
            while result.last == "0" {
                result.removeLast()
            }
            if result.last == "." {
                result.removeLast()
            }
        }
        return result == "-0" ? "0" : result
    }

    private static func groupedInteger(_ value: UInt64) -> String {
        let digits = String(value)
        var result = ""

        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index).isMultiple(of: 3) {
                result.append(",")
            }
            result.append(character)
        }
        return result
    }

    private static func twoDigits(_ value: Int64) -> String {
        value < 10 ? "0\(value)" : String(value)
    }
}

public enum WidgetValueFormatter {
    public static func string(for value: TypedMetricValue?, format: MetricFormat) -> String {
        guard let value else { return "--" }
        switch (value, format) {
        case let (.ratio(number), .percent), let (.number(number), .percent):
            return "\(decimal(number * 100, digits: 1))%"
        case let (.bytes(number), .bytes):
            return compactBytes(Double(number))
        case let (.bytesPerSecond(number), .bytesPerSecond):
            return "\(compactBytes(number))/s"
        case let (.count(number), .count):
            return String(number)
        case let (.durationSeconds(number), .duration):
            if number < 60 {
                return "\(decimal(number, digits: 0))s"
            }
            return CompactAgeFormatter.compact(ageSeconds: number)
        case let (.text(text), .text):
            return text
        case let (.boolean(boolean), .boolean):
            return boolean ? "yes" : "no"
        case let (.number(number), .celsius):
            return "\(decimal(number, digits: 1))°C"
        case let (.number(number), .watts):
            return "\(decimal(number, digits: 1))W"
        case let (.number(number), .megahertz):
            return "\(decimal(number, digits: 0))MHz"
        case let (.table(table), .table):
            return "\(table.rows.count)r"
        case let (.ratio(number), .number),
             let (.bytesPerSecond(number), .number),
             let (.durationSeconds(number), .number),
             let (.number(number), .number):
            return decimal(number, digits: 2)
        case let (.bytes(number), .number), let (.count(number), .number):
            return String(number)
        default:
            return "--"
        }
    }

    private static func compactBytes(_ bytes: Double) -> String {
        guard bytes.isFinite, bytes >= 0 else { return "--" }
        let units = ["B", "K", "M", "G", "T", "P", "E"]
        var amount = bytes
        var unitIndex = 0
        while amount >= 1024, unitIndex < units.count - 1 {
            amount /= 1024
            unitIndex += 1
        }
        let digits = unitIndex > 0 && amount < 10 && amount.rounded() != amount ? 1 : 0
        return "\(decimal(amount, digits: digits))\(units[unitIndex])"
    }

    private static func decimal(_ value: Double, digits: Int) -> String {
        guard value.isFinite else { return "--" }
        var result = String(
            format: "%.*f",
            locale: Locale(identifier: "en_US_POSIX"),
            digits,
            value
        )
        if digits > 0 {
            while result.last == "0" {
                result.removeLast()
            }
            if result.last == "." {
                result.removeLast()
            }
        }
        return result
    }
}
