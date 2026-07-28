import Testing
@testable import WallstatsCore

@Suite("Metric value formatting")
struct FormattingTests {
    @Test("Every protocol value format has a stable native representation")
    func formatsAllValueKinds() {
        #expect(MetricValueFormatter.string(for: .ratio(0.425), format: .percent) == "42.5%")
        #expect(MetricValueFormatter.string(for: .bytes(1_536), format: .bytes) == "1.5 KiB")
        #expect(
            MetricValueFormatter.string(for: .bytesPerSecond(1_048_576), format: .bytesPerSecond)
                == "1 MiB/s"
        )
        #expect(MetricValueFormatter.string(for: .number(42.26), format: .celsius) == "42.3°C")
        #expect(MetricValueFormatter.string(for: .number(65.5), format: .watts) == "65.5W")
        #expect(MetricValueFormatter.string(for: .number(2_450), format: .megahertz) == "2450MHz")
        #expect(MetricValueFormatter.string(for: .count(1_234_567), format: .count) == "1,234,567")
        #expect(MetricValueFormatter.string(for: .number(3.14), format: .number) == "3.14")
        #expect(MetricValueFormatter.string(for: .durationSeconds(125), format: .duration) == "2m 05s")
        #expect(MetricValueFormatter.string(for: .text("healthy"), format: .text) == "healthy")
        #expect(MetricValueFormatter.string(for: .boolean(true), format: .boolean) == "Yes")
        #expect(
            MetricValueFormatter.string(
                for: .table(TableValue(columns: ["PID"], rows: [["42"], ["43"]])),
                format: .table
            ) == "2 rows"
        )
    }

    @Test("Duration formatting safely handles the Int64 conversion boundary")
    func durationBoundaries() {
        let roundedPastInt64 = Double(Int64.max)
        #expect(
            MetricValueFormatter.string(for: .durationSeconds(roundedPastInt64), format: .duration)
                == "9.22e+18s"
        )

        let representableBelowBoundary = roundedPastInt64.nextDown
        let belowBoundary = MetricValueFormatter.string(
            for: .durationSeconds(representableBelowBoundary),
            format: .duration
        )
        #expect(belowBoundary.hasSuffix("h"))
        #expect(belowBoundary.contains("d "))

        #expect(
            MetricValueFormatter.string(
                for: .durationSeconds(Double.greatestFiniteMagnitude),
                format: .duration
            ) == "1.8e+308s"
        )
    }

    @Test("Disk free bytes use deterministic compact IEC units")
    func diskFreeFormatting() {
        #expect(DiskFreeFormatter.compact(nil) == "--")
        #expect(DiskFreeFormatter.compact(0) == "0B")
        #expect(DiskFreeFormatter.compact(999) == "999B")
        #expect(DiskFreeFormatter.compact(1_024) == "1K")
        #expect(DiskFreeFormatter.compact(9 * 1_048_576 + 524_288) == "9.5M")
        #expect(DiskFreeFormatter.compact(312 * 1_073_741_824) == "312G")
        #expect(DiskFreeFormatter.compact(1_319_413_953_331) == "1.2T")
    }

    @Test("Compact status glyph layout applies scale and spacing bounds")
    func compactStatusGlyphLayout() {
        #expect(CompactStatusGlyphLayout.resolve(glyphScale: nil) == CompactStatusGlyphLayout(
            fontSize: 13,
            spacing: 8
        ))

        let small = CompactStatusGlyphLayout.resolve(glyphScale: 0.4)
        #expect(small.fontSize == 5.2)
        #expect(abs(small.spacing - 3.2) < 0.000_001)

        let large = CompactStatusGlyphLayout.resolve(glyphScale: 1.5)
        #expect(large.fontSize == 19.5)
        #expect(abs(large.spacing - (8 / 1.5)) < 0.000_001)

        #expect(CompactStatusGlyphLayout.resolve(glyphScale: .nan).fontSize == 13)
    }

    @Test("Widget values use compact configured formats")
    func widgetValueFormatting() {
        #expect(WidgetValueFormatter.string(for: .bytes(1_610_612_736), format: .bytes) == "1.5G")
        #expect(WidgetValueFormatter.string(for: .bytesPerSecond(1_048_576), format: .bytesPerSecond) == "1M/s")
        #expect(WidgetValueFormatter.string(for: .number(42.26), format: .celsius) == "42.3°C")
        #expect(WidgetValueFormatter.string(for: .number(65.5), format: .watts) == "65.5W")
        #expect(WidgetValueFormatter.string(for: .number(2_450), format: .megahertz) == "2450MHz")
    }
}
