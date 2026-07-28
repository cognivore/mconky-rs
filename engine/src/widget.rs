use crate::error::ConfigError;
use crate::{
    Boolean, Bytes, BytesPerSecond, CompactStatus, Count, DurationSeconds, Metric, MetricId, Number,
    Ratio, Table, Text, WireType,
};
use serde::Serialize;
use std::collections::HashSet;
use std::marker::PhantomData;

/// A metric type that can be shown as a single formatted value.
///
/// This trait is sealed indirectly by [`WireType`].
pub trait ValueMetric: WireType {
    #[doc(hidden)]
    const DEFAULT_FORMAT: &'static str;
}

/// A numeric metric type that can be plotted over time.
///
/// `Text`, `Boolean`, and `Table` intentionally do not implement this trait.
pub trait ScalarMetric: ValueMetric {}

/// A metric type that can drive a gauge.
///
/// Protocol v1 gauges are bounded ratios, so only [`Ratio`] implements this
/// trait.
pub trait GaugeMetric: ValueMetric {}

macro_rules! value_metric {
    ($type:ty, $format:literal) => {
        impl ValueMetric for $type {
            const DEFAULT_FORMAT: &'static str = $format;
        }
    };
}

value_metric!(Ratio, "percent");
value_metric!(Bytes, "bytes");
value_metric!(BytesPerSecond, "bytes_per_second");
value_metric!(Count, "count");
value_metric!(Number, "number");
value_metric!(Text, "text");
value_metric!(Boolean, "boolean");
value_metric!(DurationSeconds, "duration");

impl ScalarMetric for Ratio {}
impl ScalarMetric for Bytes {}
impl ScalarMetric for BytesPerSecond {}
impl ScalarMetric for Count {}
impl ScalarMetric for Number {}
impl ScalarMetric for DurationSeconds {}

impl GaugeMetric for Ratio {}

/// Builder for a formatted single-value widget.
///
/// Formatting methods exist only on the matching metric type.
///
/// ```compile_fail
/// use wallstats::{Bytes, Metric, Stat};
/// fn invalid(metric: Metric<Bytes>) {
///     let _ = Stat::new("Memory", metric).percent();
/// }
/// ```
pub struct Stat<T: ValueMetric> {
    label: String,
    metric: MetricId,
    format: &'static str,
    marker: PhantomData<fn() -> T>,
}

impl<T: ValueMetric> Stat<T> {
    /// Creates a stat with the wire type's natural format.
    pub fn new(label: impl Into<String>, metric: impl Into<Metric<T>>) -> Self {
        Self {
            label: label.into(),
            metric: metric.into().id().clone(),
            format: T::DEFAULT_FORMAT,
            marker: PhantomData,
        }
    }
}

impl Stat<Ratio> {
    /// Uses percent formatting. Available only for [`Ratio`].
    pub fn percent(mut self) -> Self {
        self.format = "percent";
        self
    }
}

impl Stat<Bytes> {
    /// Uses byte formatting. Available only for [`Bytes`].
    pub fn bytes(mut self) -> Self {
        self.format = "bytes";
        self
    }
}

impl Stat<BytesPerSecond> {
    /// Uses bytes-per-second formatting. Available only for [`BytesPerSecond`].
    pub fn bytes_per_second(mut self) -> Self {
        self.format = "bytes_per_second";
        self
    }
}

impl Stat<Number> {
    /// Uses Celsius formatting. Available only for [`Number`].
    pub fn celsius(mut self) -> Self {
        self.format = "celsius";
        self
    }

    /// Uses watt formatting. Available only for [`Number`].
    pub fn watts(mut self) -> Self {
        self.format = "watts";
        self
    }

    /// Uses megahertz formatting. Available only for [`Number`].
    pub fn megahertz(mut self) -> Self {
        self.format = "megahertz";
        self
    }
}

/// Builder for a bounded gauge widget.
///
/// ```compile_fail
/// use wallstats::{Gauge, Metric, Number};
/// fn invalid(metric: Metric<Number>) {
///     let _ = Gauge::new("Load", metric);
/// }
/// ```
pub struct Gauge<T: GaugeMetric> {
    label: String,
    metric: MetricId,
    format: &'static str,
    accent: String,
    marker: PhantomData<fn() -> T>,
}

impl<T: GaugeMetric> Gauge<T> {
    /// Creates a gauge with type-appropriate formatting.
    pub fn new(label: impl Into<String>, metric: impl Into<Metric<T>>) -> Self {
        Self {
            label: label.into(),
            metric: metric.into().id().clone(),
            format: T::DEFAULT_FORMAT,
            accent: "cyan".to_owned(),
            marker: PhantomData,
        }
    }

    /// Sets the native app accent name.
    pub fn accent(mut self, accent: impl Into<String>) -> Self {
        self.accent = accent.into();
        self
    }
}

impl Gauge<Ratio> {
    /// Uses percent formatting. Available only for [`Ratio`].
    pub fn percent(mut self) -> Self {
        self.format = "percent";
        self
    }
}

/// Builder for a scalar history widget.
///
/// ```compile_fail
/// use wallstats::{Metric, Sparkline, Text};
/// fn invalid(metric: Metric<Text>) {
///     let _ = Sparkline::new("Status", metric);
/// }
/// ```
pub struct Sparkline<T: ScalarMetric> {
    label: String,
    metric: MetricId,
    format: &'static str,
    accent: String,
    history: u32,
    marker: PhantomData<fn() -> T>,
}

impl<T: ScalarMetric> Sparkline<T> {
    /// Creates a 60-sample sparkline with natural formatting.
    pub fn new(label: impl Into<String>, metric: impl Into<Metric<T>>) -> Self {
        Self {
            label: label.into(),
            metric: metric.into().id().clone(),
            format: T::DEFAULT_FORMAT,
            accent: "cyan".to_owned(),
            history: 60,
            marker: PhantomData,
        }
    }

    /// Sets the native app accent name.
    pub fn accent(mut self, accent: impl Into<String>) -> Self {
        self.accent = accent.into();
        self
    }

    /// Sets the number of samples retained by the native app.
    pub fn history(mut self, history: u32) -> Self {
        self.history = history;
        self
    }
}

impl Sparkline<Ratio> {
    /// Uses percent formatting. Available only for [`Ratio`].
    pub fn percent(mut self) -> Self {
        self.format = "percent";
        self
    }
}

impl Sparkline<Bytes> {
    /// Uses byte formatting. Available only for [`Bytes`].
    pub fn bytes(mut self) -> Self {
        self.format = "bytes";
        self
    }
}

impl Sparkline<BytesPerSecond> {
    /// Uses bytes-per-second formatting. Available only for [`BytesPerSecond`].
    pub fn bytes_per_second(mut self) -> Self {
        self.format = "bytes_per_second";
        self
    }
}

/// One typed scalar series in a [`Plot`].
///
/// ```compile_fail
/// use wallstats::{Metric, PlotSeries, Text};
/// fn invalid(metric: Metric<Text>) {
///     let _ = PlotSeries::new(metric, "cyan");
/// }
/// ```
///
/// ```compile_fail
/// use wallstats::{Metric, PlotSeries, Table};
/// fn invalid(metric: Metric<Table>) {
///     let _ = PlotSeries::new(metric, "cyan");
/// }
/// ```
#[derive(Clone, Debug, Serialize)]
pub struct PlotSeries {
    metric: MetricId,
    format: &'static str,
    accent: String,
}

impl PlotSeries {
    /// Creates a series whose format is derived from its scalar metric type.
    pub fn new<T: ScalarMetric>(
        metric: impl Into<Metric<T>>,
        accent: impl Into<String>,
    ) -> Self {
        Self {
            metric: metric.into().id().clone(),
            format: T::DEFAULT_FORMAT,
            accent: accent.into(),
        }
    }
}

/// Builder for a multi-series scalar history plot.
pub struct Plot {
    label: String,
    series: Vec<PlotSeries>,
    history: u32,
}

impl Plot {
    /// Creates a 60-sample plot.
    pub fn new(label: impl Into<String>, series: Vec<PlotSeries>) -> Self {
        Self {
            label: label.into(),
            series,
            history: 60,
        }
    }

    /// Sets the number of retained samples.
    pub fn history(mut self, history: u32) -> Self {
        self.history = history;
        self
    }
}

/// Builder for a [`CompactStatus`] widget.
///
/// ```compile_fail
/// use wallstats::{CompactStatusWidget, Metric, Text};
/// fn invalid(metric: Metric<Text>) {
///     let _ = CompactStatusWidget::new("Status", metric);
/// }
/// ```
pub struct CompactStatusWidget {
    label: String,
    metric: MetricId,
}

impl CompactStatusWidget {
    /// Creates a compact-status widget.
    pub fn new(
        label: impl Into<String>,
        metric: impl Into<Metric<CompactStatus>>,
    ) -> Self {
        Self {
            label: label.into(),
            metric: metric.into().id().clone(),
        }
    }
}

/// Builder for a table widget. Its constructor accepts only [`Metric<Table>`].
///
/// ```compile_fail
/// use wallstats::{Metric, Number, TableWidget};
/// fn invalid(metric: Metric<Number>) {
///     let _ = TableWidget::new("Processes", metric);
/// }
/// ```
pub struct TableWidget {
    label: String,
    metric: MetricId,
}

impl TableWidget {
    /// Creates a table widget.
    pub fn new(label: impl Into<String>, metric: impl Into<Metric<Table>>) -> Self {
        Self {
            label: label.into(),
            metric: metric.into().id().clone(),
        }
    }
}

/// A type-erased, serializable protocol widget.
#[derive(Clone, Debug, Serialize)]
#[serde(transparent)]
pub struct Widget(WidgetKind);

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum WidgetKind {
    Value {
        label: String,
        metric: MetricId,
        format: &'static str,
    },
    Gauge {
        label: String,
        metric: MetricId,
        format: &'static str,
        accent: String,
    },
    Sparkline {
        label: String,
        metric: MetricId,
        format: &'static str,
        accent: String,
        history: u32,
    },
    Plot {
        label: String,
        series: Vec<PlotSeries>,
        history: u32,
    },
    CompactStatus {
        label: String,
        metric: MetricId,
        format: &'static str,
    },
    Table {
        label: String,
        metric: MetricId,
        format: &'static str,
    },
}

impl<T: ValueMetric> From<Stat<T>> for Widget {
    fn from(stat: Stat<T>) -> Self {
        Self(WidgetKind::Value {
            label: stat.label,
            metric: stat.metric,
            format: stat.format,
        })
    }
}

impl<T: GaugeMetric> From<Gauge<T>> for Widget {
    fn from(gauge: Gauge<T>) -> Self {
        Self(WidgetKind::Gauge {
            label: gauge.label,
            metric: gauge.metric,
            format: gauge.format,
            accent: gauge.accent,
        })
    }
}

impl<T: ScalarMetric> From<Sparkline<T>> for Widget {
    fn from(sparkline: Sparkline<T>) -> Self {
        Self(WidgetKind::Sparkline {
            label: sparkline.label,
            metric: sparkline.metric,
            format: sparkline.format,
            accent: sparkline.accent,
            history: sparkline.history,
        })
    }
}

impl From<Plot> for Widget {
    fn from(plot: Plot) -> Self {
        Self(WidgetKind::Plot {
            label: plot.label,
            series: plot.series,
            history: plot.history,
        })
    }
}

impl From<CompactStatusWidget> for Widget {
    fn from(status: CompactStatusWidget) -> Self {
        Self(WidgetKind::CompactStatus {
            label: status.label,
            metric: status.metric,
            format: "compact_status",
        })
    }
}

impl From<TableWidget> for Widget {
    fn from(table: TableWidget) -> Self {
        Self(WidgetKind::Table {
            label: table.label,
            metric: table.metric,
            format: "table",
        })
    }
}

impl Widget {
    pub(crate) fn metrics(&self) -> Vec<&MetricId> {
        match &self.0 {
            WidgetKind::Value { metric, .. }
            | WidgetKind::Gauge { metric, .. }
            | WidgetKind::Sparkline { metric, .. }
            | WidgetKind::CompactStatus { metric, .. }
            | WidgetKind::Table { metric, .. } => vec![metric],
            WidgetKind::Plot { series, .. } => {
                series.iter().map(|series| &series.metric).collect()
            }
        }
    }

    pub(crate) fn validate(&self) -> Result<(), ConfigError> {
        let (label, accent) = match &self.0 {
            WidgetKind::Value { label, .. }
            | WidgetKind::Plot { label, .. }
            | WidgetKind::CompactStatus { label, .. }
            | WidgetKind::Table { label, .. } => (label, None),
            WidgetKind::Gauge { label, accent, .. }
            | WidgetKind::Sparkline { label, accent, .. } => (label, Some(accent)),
        };
        if label.trim().is_empty() {
            return Err(ConfigError::InvalidWidget {
                label: label.clone(),
                reason: "label cannot be empty".to_owned(),
            });
        }
        if accent.is_some_and(|accent| accent.trim().is_empty()) {
            return Err(ConfigError::InvalidWidget {
                label: label.clone(),
                reason: "accent cannot be empty".to_owned(),
            });
        }

        match &self.0 {
            WidgetKind::Sparkline { history: 0, .. } => Err(ConfigError::InvalidWidget {
                label: label.clone(),
                reason: "sparkline history must be greater than zero".to_owned(),
            }),
            WidgetKind::Plot {
                series, history, ..
            } => validate_plot(label, series, *history),
            _ => Ok(()),
        }
    }
}

fn validate_plot(
    label: &str,
    series: &[PlotSeries],
    history: u32,
) -> Result<(), ConfigError> {
    if history == 0 {
        return Err(ConfigError::InvalidWidget {
            label: label.to_owned(),
            reason: "plot history must be greater than zero".to_owned(),
        });
    }
    if series.is_empty() {
        return Err(ConfigError::InvalidWidget {
            label: label.to_owned(),
            reason: "plot must contain at least one series".to_owned(),
        });
    }
    let mut metrics = HashSet::with_capacity(series.len());
    for series in series {
        if !metrics.insert(&series.metric) {
            return Err(ConfigError::InvalidWidget {
                label: label.to_owned(),
                reason: format!("plot metric {:?} is duplicated", series.metric.as_str()),
            });
        }
        if !is_supported_accent(&series.accent) {
            return Err(ConfigError::InvalidWidget {
                label: label.to_owned(),
                reason: format!("unsupported plot accent {:?}", series.accent),
            });
        }
    }
    Ok(())
}

fn is_supported_accent(accent: &str) -> bool {
    matches!(
        accent.to_ascii_lowercase().as_str(),
        "cyan"
            | "green"
            | "mint"
            | "amber"
            | "orange"
            | "red"
            | "purple"
            | "violet"
            | "blue"
    )
}

#[cfg(test)]
mod tests {
    use super::{CompactStatusWidget, Plot, PlotSeries, Section, Sparkline, Stat, TableWidget, Widget};
    use crate::{CompactStatus, Count, DurationSeconds, Metric, MetricId, Number, Ratio, Table};
    use serde_json::json;

    #[test]
    fn widgets_emit_native_protocol_format_names() {
        let count = Metric::<Count>::new(MetricId::new("jobs").unwrap());
        let duration = Metric::<DurationSeconds>::new(MetricId::new("job.time").unwrap());
        let table = Metric::<Table>::new(MetricId::new("jobs.table").unwrap());

        assert_eq!(
            serde_json::to_value(Widget::from(Stat::new("Jobs", count))).unwrap(),
            json!({"kind":"value","label":"Jobs","metric":"jobs","format":"count"})
        );
        assert_eq!(
            serde_json::to_value(Widget::from(Sparkline::new("Time", duration))).unwrap(),
            json!({"kind":"sparkline","label":"Time","metric":"job.time","format":"duration","accent":"cyan","history":60})
        );
        assert_eq!(
            serde_json::to_value(Widget::from(TableWidget::new("Jobs", table))).unwrap(),
            json!({"kind":"table","label":"Jobs","metric":"jobs.table","format":"table"})
        );
    }

    #[test]
    fn number_formats_plot_and_compact_status_serialize_exactly() {
        let temperature = Metric::<Number>::new(MetricId::new("temp.cpu").unwrap());
        let power = Metric::<Number>::new(MetricId::new("power.cpu").unwrap());
        let frequency = Metric::<Number>::new(MetricId::new("cpu.p.mhz").unwrap());
        let cpu = Metric::<Ratio>::new(MetricId::new("cpu.total").unwrap());
        let status = Metric::<CompactStatus>::new(MetricId::new("backup").unwrap());

        assert_eq!(
            serde_json::to_value(Widget::from(Stat::new("CPU", temperature).celsius())).unwrap(),
            json!({"kind":"value","label":"CPU","metric":"temp.cpu","format":"celsius"})
        );
        assert_eq!(
            serde_json::to_value(Widget::from(Stat::new("CPU", power).watts())).unwrap(),
            json!({"kind":"value","label":"CPU","metric":"power.cpu","format":"watts"})
        );
        assert_eq!(
            serde_json::to_value(Widget::from(Stat::new("P", frequency).megahertz())).unwrap(),
            json!({"kind":"value","label":"P","metric":"cpu.p.mhz","format":"megahertz"})
        );
        assert_eq!(
            serde_json::to_value(Widget::from(
                Plot::new("Load", vec![PlotSeries::new(cpu, "cyan")]).history(90)
            ))
            .unwrap(),
            json!({"kind":"plot","label":"Load","series":[{"metric":"cpu.total","format":"percent","accent":"cyan"}],"history":90})
        );
        assert_eq!(
            serde_json::to_value(Widget::from(CompactStatusWidget::new("Backup", status))).unwrap(),
            json!({"kind":"compact_status","label":"Backup","metric":"backup","format":"compact_status"})
        );
    }

    #[test]
    fn section_weight_defaults_and_serializes() {
        let count = Metric::<Count>::new(MetricId::new("jobs").unwrap());
        let default = Section::new("Jobs", vec![Stat::new("Jobs", &count).into()]);
        assert_eq!(serde_json::to_value(default).unwrap()["weight"], 1);
        let section = Section::new("Jobs", vec![Stat::new("Jobs", count).into()]).weight(4);
        assert_eq!(
            serde_json::to_value(section).unwrap(),
            json!({"title":"Jobs","widgets":[{"kind":"value","label":"Jobs","metric":"jobs","format":"count"}],"weight":4})
        );
    }

    #[test]
    fn plot_and_section_validation_reject_invalid_settings() {
        let cpu = Metric::<Ratio>::new(MetricId::new("cpu.total").unwrap());
        let empty = Widget::from(Plot::new("Empty", Vec::new()));
        assert!(empty.validate().is_err());

        let duplicate = Widget::from(Plot::new(
            "Duplicate",
            vec![
                PlotSeries::new(&cpu, "cyan"),
                PlotSeries::new(&cpu, "blue"),
            ],
        ));
        assert!(duplicate.validate().is_err());

        let bad_accent = Widget::from(Plot::new(
            "Accent",
            vec![PlotSeries::new(&cpu, "")],
        ));
        assert!(bad_accent.validate().is_err());
        let unsupported_accent = Widget::from(Plot::new(
            "Accent",
            vec![PlotSeries::new(&cpu, "chartreuse")],
        ));
        assert!(unsupported_accent.validate().is_err());

        let no_history = Widget::from(
            Plot::new("History", vec![PlotSeries::new(&cpu, "cyan")]).history(0),
        );
        assert!(no_history.validate().is_err());

        let section = Section::new("Bad", vec![Stat::new("CPU", cpu).into()]).weight(0);
        assert!(section.validate().is_err());
        let count = Metric::<Count>::new(MetricId::new("jobs").unwrap());
        let maximum = Section::new("Max", vec![Stat::new("Jobs", &count).into()]).weight(16);
        assert!(maximum.validate().is_ok());
        let too_large = Section::new("Large", vec![Stat::new("Jobs", count).into()]).weight(17);
        assert!(too_large.validate().is_err());
    }
}

/// A titled group of widgets in the desktop layout.
#[derive(Clone, Debug, Serialize)]
pub struct Section {
    title: String,
    widgets: Vec<Widget>,
    weight: u8,
}

impl Section {
    /// Creates a section.
    pub fn new(title: impl Into<String>, widgets: Vec<Widget>) -> Self {
        Self {
            title: title.into(),
            widgets,
            weight: 1,
        }
    }

    /// Sets the relative layout weight. Validation accepts 1 through 16.
    pub fn weight(mut self, weight: u8) -> Self {
        self.weight = weight;
        self
    }

    /// Returns the section title.
    pub fn title(&self) -> &str {
        &self.title
    }

    /// Returns the section widgets.
    pub fn widgets(&self) -> &[Widget] {
        &self.widgets
    }

    pub(crate) fn validate(&self) -> Result<(), ConfigError> {
        if !(1..=16).contains(&self.weight) {
            return Err(ConfigError::InvalidLayout(format!(
                "section {:?} weight must be between 1 and 16",
                self.title
            )));
        }
        Ok(())
    }
}
