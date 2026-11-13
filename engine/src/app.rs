use crate::collector::{CollectedMetric, Collector, SingleMetricSource, Source};
use crate::disk_io::{
    DISK_IO_METRIC_SPECS, DiskIoCollector, DiskIoMetricIds, DiskIoMetrics, DiskIoSource,
};
use crate::error::{ConfigError, Error, Result};
use crate::macmon::{
    MACMON_METRIC_SPECS, MacmonCollector, MacmonMetricIds, MacmonMetrics, MacmonSource,
};
use crate::system::{
    SYSTEM_METRIC_SPECS, SystemCollector, SystemMetricIds, SystemMetrics, SystemSource,
};
use crate::widget::Section;
use crate::{
    MAX_PROTOCOL_RECORD_BYTES, Metric, MetricId, PROTOCOL_MAJOR, PROTOCOL_MINOR, SDK_VERSION,
    Surface, SurfaceKind, WireType,
};
use serde::Serialize;
use std::any::Any;
use std::collections::HashSet;
use std::env;
use std::ffi::OsString;
use std::io::{self, Write};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(4);

/// A collection interval and protocol staleness threshold.
#[derive(Clone, Copy, Debug)]
pub struct Schedule {
    interval: Duration,
    stale_after: Duration,
}

impl Schedule {
    /// Creates a schedule and defaults staleness to three collection intervals.
    pub fn every(interval: Duration) -> Self {
        Self {
            interval,
            stale_after: interval.checked_mul(3).unwrap_or(Duration::MAX),
        }
    }

    /// Sets the duration after which the native app should mark a value stale.
    pub fn stale_after(mut self, stale_after: Duration) -> Self {
        self.stale_after = stale_after;
        self
    }

    /// Returns the collection interval.
    pub fn interval(&self) -> Duration {
        self.interval
    }

    /// Returns the staleness threshold.
    pub fn stale_after_duration(&self) -> Duration {
        self.stale_after
    }

    fn validate(&self) -> std::result::Result<(), ConfigError> {
        validate_duration(self.interval, "collection interval")?;
        validate_duration(self.stale_after, "stale-after duration")
    }

    fn stale_after_ms(&self) -> std::result::Result<i64, ConfigError> {
        i64::try_from(self.stale_after.as_millis()).map_err(|_| {
            ConfigError::InvalidSchedule("stale-after duration exceeds i64 milliseconds".to_owned())
        })
    }

    fn interval_ms(&self) -> std::result::Result<i64, ConfigError> {
        i64::try_from(self.interval.as_millis()).map_err(|_| {
            ConfigError::InvalidSchedule("collection interval exceeds i64 milliseconds".to_owned())
        })
    }
}

fn validate_duration(duration: Duration, name: &str) -> std::result::Result<(), ConfigError> {
    if duration.is_zero() {
        return Err(ConfigError::InvalidSchedule(format!(
            "{name} must be greater than zero"
        )));
    }
    if duration.as_millis() == 0 {
        return Err(ConfigError::InvalidSchedule(format!(
            "{name} must be at least one millisecond"
        )));
    }
    if duration.as_millis() > i64::MAX as u128 {
        return Err(ConfigError::InvalidSchedule(format!(
            "{name} exceeds i64 milliseconds"
        )));
    }
    Ok(())
}

/// Window edge used to place the Wallstats panel.
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Anchor {
    /// Upper-left corner.
    TopLeft,
    /// Upper edge, centered horizontally.
    TopCenter,
    /// Upper-right corner.
    TopRight,
    /// Left edge, centered vertically.
    CenterLeft,
    /// Center of the screen.
    Center,
    /// Right edge, centered vertically.
    CenterRight,
    /// Lower-left corner.
    BottomLeft,
    /// Lower edge, centered horizontally.
    BottomCenter,
    /// Lower-right corner.
    BottomRight,
}

/// Native window layer.
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Layer {
    /// A desktop-level panel.
    Desktop,
    /// A panel above normal windows.
    Floating,
}

/// Native panel placement and appearance.
#[derive(Clone, Debug, Serialize)]
pub struct Window {
    width: u32,
    anchor: Anchor,
    margin: u32,
    layer: Layer,
    opacity: f64,
}

impl Window {
    /// Creates the default 420-point top-right desktop panel.
    pub fn desktop() -> Self {
        Self {
            width: 420,
            anchor: Anchor::TopRight,
            margin: 20,
            layer: Layer::Desktop,
            opacity: 0.94,
        }
    }

    /// Sets the panel width in points.
    pub fn width(mut self, width: u32) -> Self {
        self.width = width;
        self
    }

    /// Sets the screen anchor.
    pub fn anchor(mut self, anchor: Anchor) -> Self {
        self.anchor = anchor;
        self
    }

    /// Sets the screen-edge margin in points.
    pub fn margin(mut self, margin: u32) -> Self {
        self.margin = margin;
        self
    }

    /// Sets the native window layer.
    pub fn layer(mut self, layer: Layer) -> Self {
        self.layer = layer;
        self
    }

    /// Sets opacity from 0 through 1.
    pub fn opacity(mut self, opacity: f64) -> Self {
        self.opacity = opacity;
        self
    }

    fn validate(&self) -> std::result::Result<(), ConfigError> {
        if self.width == 0 {
            return Err(ConfigError::InvalidWindow(
                "width must be greater than zero".to_owned(),
            ));
        }
        if !self.opacity.is_finite() || !(0.0..=1.0).contains(&self.opacity) {
            return Err(ConfigError::InvalidWindow(
                "opacity must be finite and between 0 and 1".to_owned(),
            ));
        }
        Ok(())
    }
}

impl Default for Window {
    fn default() -> Self {
        Self::desktop()
    }
}

#[derive(Clone, Debug, Serialize)]
struct MetricDefinition {
    id: MetricId,
    value_type: &'static str,
    stale_after_ms: i64,
    sample_interval_ms: i64,
}

/// A complete Wallstats configuration and collector runtime.
pub struct App {
    title: String,
    metrics: Vec<MetricDefinition>,
    sources: Vec<Box<dyn Source>>,
    window: Window,
    sections: Vec<Section>,
    surfaces: Vec<Surface>,
}

impl App {
    /// Creates an empty app with the default desktop window.
    pub fn new(title: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            metrics: Vec::new(),
            sources: Vec::new(),
            window: Window::default(),
            sections: Vec::new(),
            surfaces: Vec::new(),
        }
    }

    /// Replaces the native window settings.
    pub fn set_window(&mut self, window: Window) -> &mut Self {
        self.window = window;
        self
    }

    /// Replaces the section layout.
    pub fn set_sections(&mut self, sections: Vec<Section>) -> &mut Self {
        self.sections = sections;
        self
    }

    /// Replaces the immutable editorial surface trees.
    pub fn set_surfaces(&mut self, surfaces: Vec<Surface>) -> &mut Self {
        self.surfaces = surfaces;
        self
    }

    /// Registers a user-defined typed collector and returns its typed handle.
    pub fn metric<T: WireType>(
        &mut self,
        id: impl Into<String>,
        schedule: Schedule,
        collector: impl Collector<T>,
    ) -> std::result::Result<Metric<T>, ConfigError> {
        schedule.validate()?;
        let id = MetricId::new(id)?;
        self.ensure_available(&id)?;
        let stale_after_ms = schedule.stale_after_ms()?;
        let handle = Metric::new(id.clone());
        self.metrics.push(MetricDefinition {
            id: id.clone(),
            value_type: T::VALUE_TYPE,
            stale_after_ms,
            sample_interval_ms: schedule.interval_ms()?,
        });
        self.sources.push(Box::new(SingleMetricSource::<T, _>::new(
            id,
            schedule.interval,
            collector,
        )));
        Ok(handle)
    }

    /// Registers the shared built-in system source and returns all its handles.
    pub fn system(
        &mut self,
        settings: SystemCollector,
    ) -> std::result::Result<SystemMetrics, ConfigError> {
        settings.schedule_value().validate()?;
        if settings.top_process_count() == 0 {
            return Err(ConfigError::InvalidSchedule(
                "top process row count must be greater than zero".to_owned(),
            ));
        }

        let ids = SystemMetricIds::parse()?;
        for id in ids.all() {
            self.ensure_available(id)?;
        }
        let stale_after_ms = settings.schedule_value().stale_after_ms()?;
        for (id, (_, value_type)) in ids.all().into_iter().zip(SYSTEM_METRIC_SPECS) {
            self.metrics.push(MetricDefinition {
                id: id.clone(),
                value_type,
                stale_after_ms,
                sample_interval_ms: settings.schedule_value().interval_ms()?,
            });
        }
        let handles = ids.handles();
        self.sources.push(Box::new(SystemSource::new(ids, settings)));
        Ok(handles)
    }

    /// Registers the shared `macmon` source and returns all typed handles.
    pub fn macmon(
        &mut self,
        settings: MacmonCollector,
    ) -> std::result::Result<MacmonMetrics, ConfigError> {
        settings.validate()?;
        settings.schedule_value().validate()?;
        let ids = MacmonMetricIds::parse()?;
        for id in ids.all() {
            self.ensure_available(id)?;
        }
        let stale_after_ms = settings.schedule_value().stale_after_ms()?;
        for (id, (_, value_type)) in ids.all().into_iter().zip(MACMON_METRIC_SPECS) {
            self.metrics.push(MetricDefinition {
                id: id.clone(),
                value_type,
                stale_after_ms,
                sample_interval_ms: settings.schedule_value().interval_ms()?,
            });
        }
        let handles = ids.handles();
        self.sources.push(Box::new(MacmonSource::new(ids, settings)));
        Ok(handles)
    }

    /// Registers the shared `ioreg` disk-rate source and returns typed handles.
    pub fn disk_io(
        &mut self,
        settings: DiskIoCollector,
    ) -> std::result::Result<DiskIoMetrics, ConfigError> {
        settings.validate()?;
        settings.schedule_value().validate()?;
        let ids = DiskIoMetricIds::parse()?;
        for id in ids.all() {
            self.ensure_available(id)?;
        }
        let stale_after_ms = settings.schedule_value().stale_after_ms()?;
        for (id, (_, value_type)) in ids.all().into_iter().zip(DISK_IO_METRIC_SPECS) {
            self.metrics.push(MetricDefinition {
                id: id.clone(),
                value_type,
                stale_after_ms,
                sample_interval_ms: settings.schedule_value().interval_ms()?,
            });
        }
        let handles = ids.handles();
        self.sources.push(Box::new(DiskIoSource::new(ids, settings)));
        Ok(handles)
    }

    /// Validates IDs, schedules, window settings, widgets, and layout references.
    ///
    /// [`App::run`] always calls this before writing anything to stdout.
    pub fn validate(&self) -> std::result::Result<(), ConfigError> {
        if self.title.trim().is_empty() {
            return Err(ConfigError::InvalidLayout(
                "app title cannot be empty".to_owned(),
            ));
        }
        if self.metrics.is_empty() {
            return Err(ConfigError::InvalidLayout(
                "at least one metric must be registered".to_owned(),
            ));
        }
        if self.sections.is_empty() && self.surfaces.is_empty() {
            return Err(ConfigError::InvalidLayout(
                "at least one legacy section or surface must be configured".to_owned(),
            ));
        }
        self.window.validate()?;

        let mut registered = HashSet::with_capacity(self.metrics.len());
        for metric in &self.metrics {
            if !registered.insert(&metric.id) {
                return Err(ConfigError::DuplicateMetric(metric.id.clone()));
            }
        }

        for section in &self.sections {
            section.validate()?;
            if section.title().trim().is_empty() {
                return Err(ConfigError::InvalidLayout(
                    "section titles cannot be empty".to_owned(),
                ));
            }
            if section.widgets().is_empty() {
                return Err(ConfigError::InvalidLayout(format!(
                    "section {:?} has no widgets",
                    section.title()
                )));
            }
            for widget in section.widgets() {
                widget.validate()?;
                for metric in widget.metrics() {
                    if !registered.contains(metric) {
                        return Err(ConfigError::UnknownMetricReference {
                            section: section.title().to_owned(),
                            metric: metric.clone(),
                        });
                    }
                }
            }
        }
        // Any number of desktop overlays may coexist — each becomes its own
        // panel — while every widget-family kind maps to a single native slot.
        let mut surface_kinds = HashSet::with_capacity(self.surfaces.len());
        for surface in &self.surfaces {
            if surface.kind() != SurfaceKind::Desktop && !surface_kinds.insert(surface.kind()) {
                return Err(ConfigError::InvalidLayout(format!(
                    "surface kind {:?} is duplicated",
                    surface.kind()
                )));
            }
            surface.validate(&registered)?;
        }
        Ok(())
    }

    /// Runs `--check`, `--once`, or continuous mode based on process arguments.
    ///
    /// Protocol records are the only bytes written to stdout. Callers should
    /// print a returned error to stderr.
    pub fn run(mut self) -> Result<()> {
        self.validate()?;
        let mode = Mode::from_args(env::args_os().skip(1))?;
        let stdout = io::stdout();
        let mut stdout = stdout.lock();
        self.run_mode(mode, &mut stdout)
    }

    fn ensure_available(&self, id: &MetricId) -> std::result::Result<(), ConfigError> {
        if self.metrics.iter().any(|metric| &metric.id == id) {
            Err(ConfigError::DuplicateMetric(id.clone()))
        } else {
            Ok(())
        }
    }

    fn run_mode(&mut self, mode: Mode, writer: &mut impl Write) -> Result<()> {
        self.write_prelude(writer)?;
        match mode {
            Mode::Check => Ok(()),
            Mode::Once => self.run_once(writer),
            Mode::Continuous => self.run_continuous(writer),
        }
    }

    fn write_prelude(&self, writer: &mut impl Write) -> Result<()> {
        write_record(
            writer,
            &Hello {
                record_type: "hello",
                protocol_major: PROTOCOL_MAJOR,
                protocol_minor: PROTOCOL_MINOR,
                sdk_version: SDK_VERSION,
            },
        )?;
        write_record(
            writer,
            &Plan {
                record_type: "plan",
                title: &self.title,
                metrics: &self.metrics,
                window: &self.window,
                sections: &self.sections,
                surfaces: &self.surfaces,
            },
        )
    }

    fn run_once(&mut self, writer: &mut impl Write) -> Result<()> {
        let values = self
            .sources
            .iter_mut()
            .flat_map(|source| source.collect())
            .collect();
        write_update(writer, 1, values)
    }

    fn run_continuous(&mut self, writer: &mut impl Write) -> Result<()> {
        let (sender, receiver) = mpsc::channel();
        let mut workers = Vec::with_capacity(self.sources.len());
        for mut source in std::mem::take(&mut self.sources) {
            let sender = sender.clone();
            let source_name = source.name().to_owned();
            let interval = source.interval();
            let thread_name = format!("wallstats-{source_name}");
            let worker_source_name = source_name.clone();
            match thread::Builder::new().name(thread_name).spawn(move || loop {
                let started = Instant::now();
                let collected = catch_unwind(AssertUnwindSafe(|| source.collect()));
                match collected {
                    Ok(values) => {
                        if sender.send(WorkerMessage::Update(values)).is_err() {
                            return;
                        }
                    }
                    Err(payload) => {
                        let message = format!(
                            "collector {worker_source_name:?} panicked: {}",
                            panic_payload(payload)
                        );
                        let _ = sender.send(WorkerMessage::Fatal(message));
                        return;
                    }
                }
                thread::sleep(interval.saturating_sub(started.elapsed()));
            }) {
                Ok(worker) => workers.push(worker),
                Err(error) => {
                    let message = format!("cannot start collector {source_name:?}: {error}");
                    write_record(writer, &Fatal::new(&message))?;
                    return Err(Error::Runtime(message));
                }
            }
        }
        drop(sender);

        let mut sequence = 0_u64;
        let mut next_heartbeat = Instant::now() + HEARTBEAT_INTERVAL;
        loop {
            let now = Instant::now();
            if now >= next_heartbeat {
                sequence = next_sequence(sequence)?;
                write_record(
                    writer,
                    &Heartbeat {
                        record_type: "heartbeat",
                        sequence,
                        timestamp_ms: timestamp_ms()?,
                    },
                )?;
                while next_heartbeat <= now {
                    next_heartbeat += HEARTBEAT_INTERVAL;
                }
                continue;
            }

            match receiver.recv_timeout(next_heartbeat.saturating_duration_since(now)) {
                Ok(WorkerMessage::Update(values)) => {
                    sequence = next_sequence(sequence)?;
                    write_update(writer, sequence, values)?;
                }
                Ok(WorkerMessage::Fatal(message)) => {
                    write_record(writer, &Fatal::new(&message))?;
                    return Err(Error::Runtime(message));
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    let message = "all collector workers stopped".to_owned();
                    write_record(writer, &Fatal::new(&message))?;
                    return Err(Error::Runtime(message));
                }
            }
        }
    }
}

fn next_sequence(sequence: u64) -> Result<u64> {
    sequence
        .checked_add(1)
        .ok_or_else(|| Error::Runtime("protocol sequence overflow".to_owned()))
}

fn panic_payload(payload: Box<dyn Any + Send>) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_owned()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "non-string panic payload".to_owned()
    }
}

fn timestamp_ms() -> Result<i64> {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| Error::Runtime(format!("system clock predates the Unix epoch: {error}")))?;
    i64::try_from(elapsed.as_millis())
        .map_err(|_| Error::Runtime("Unix timestamp exceeds i64 milliseconds".to_owned()))
}

fn write_update(writer: &mut impl Write, sequence: u64, values: Vec<CollectedMetric>) -> Result<()> {
    write_record(
        writer,
        &Update {
            record_type: "update",
            sequence,
            timestamp_ms: timestamp_ms()?,
            values,
        },
    )
}

fn write_record(writer: &mut impl Write, record: &impl Serialize) -> Result<()> {
    let mut record_buffer = ProtocolRecordBuffer::new();
    let serialization = serde_json::to_writer(&mut record_buffer, record);
    if record_buffer.exceeded_limit {
        return Err(Error::ProtocolRecordTooLarge {
            limit: MAX_PROTOCOL_RECORD_BYTES,
        });
    }
    serialization.map_err(Error::Serialization)?;
    writer
        .write_all(&record_buffer.bytes)
        .map_err(Error::Output)?;
    writer.write_all(b"\n").map_err(Error::Output)?;
    writer.flush().map_err(Error::Output)
}

struct ProtocolRecordBuffer {
    bytes: Vec<u8>,
    exceeded_limit: bool,
}

impl ProtocolRecordBuffer {
    fn new() -> Self {
        Self {
            bytes: Vec::new(),
            exceeded_limit: false,
        }
    }
}

impl Write for ProtocolRecordBuffer {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > MAX_PROTOCOL_RECORD_BYTES.saturating_sub(self.bytes.len()) {
            self.exceeded_limit = true;
            return Err(io::Error::other("protocol record exceeds size limit"));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Mode {
    Check,
    Once,
    Continuous,
}

impl Mode {
    fn from_args(arguments: impl IntoIterator<Item = OsString>) -> std::result::Result<Self, ConfigError> {
        let mut arguments: Vec<_> = arguments.into_iter().collect();
        if arguments.first().is_some_and(|argument| argument == "--") {
            arguments.remove(0);
        }
        match arguments.as_slice() {
            [] => Ok(Self::Continuous),
            [argument] if argument == "--check" => Ok(Self::Check),
            [argument] if argument == "--once" => Ok(Self::Once),
            _ => Err(ConfigError::UnknownArguments(
                arguments
                    .into_iter()
                    .map(|argument| argument.to_string_lossy().into_owned())
                    .collect(),
            )),
        }
    }
}

#[derive(Serialize)]
struct Hello<'a> {
    #[serde(rename = "type")]
    record_type: &'a str,
    protocol_major: u32,
    protocol_minor: u32,
    sdk_version: &'a str,
}

#[derive(Serialize)]
struct Plan<'a> {
    #[serde(rename = "type")]
    record_type: &'a str,
    title: &'a str,
    metrics: &'a [MetricDefinition],
    window: &'a Window,
    sections: &'a [Section],
    surfaces: &'a [Surface],
}

#[derive(Serialize)]
struct Update<'a> {
    #[serde(rename = "type")]
    record_type: &'a str,
    sequence: u64,
    timestamp_ms: i64,
    values: Vec<CollectedMetric>,
}

#[derive(Serialize)]
struct Heartbeat<'a> {
    #[serde(rename = "type")]
    record_type: &'a str,
    sequence: u64,
    timestamp_ms: i64,
}

#[derive(Serialize)]
struct Fatal<'a> {
    #[serde(rename = "type")]
    record_type: &'a str,
    message: &'a str,
}

impl<'a> Fatal<'a> {
    fn new(message: &'a str) -> Self {
        Self {
            record_type: "fatal",
            message,
        }
    }
}

enum WorkerMessage {
    Update(Vec<CollectedMetric>),
    Fatal(String),
}

#[cfg(test)]
mod tests {
    use super::{App, Mode, Schedule, write_record};
    use crate::{
        ConfigError, Count, Error, LayoutNode, MAX_PROTOCOL_RECORD_BYTES, Plot, PlotSeries, Ratio,
        Section, Stat, Surface, widgets,
    };
    use serde::Serialize;
    use serde_json::Value;
    use std::time::Duration;

    fn schedule() -> Schedule {
        Schedule::every(Duration::from_secs(1))
    }

    #[test]
    fn rejects_duplicate_metrics_when_registered() {
        let mut app = App::new("Test");
        app.metric::<Count>("jobs", schedule(), || Ok(1)).unwrap();
        let error = app
            .metric::<Count>("jobs", schedule(), || Ok(2))
            .unwrap_err();
        assert!(matches!(error, ConfigError::DuplicateMetric(_)));
    }

    #[test]
    fn validates_layout_references_against_this_app() {
        let mut first = App::new("First");
        let foreign = first
            .metric::<Count>("foreign", schedule(), || Ok(1))
            .unwrap();

        let mut second = App::new("Second");
        second
            .metric::<Count>("local", schedule(), || Ok(1))
            .unwrap();
        second.set_sections(vec![Section::new(
            "Invalid",
            widgets![Stat::new("Foreign", foreign)],
        )]);
        assert!(matches!(
            second.validate(),
            Err(ConfigError::UnknownMetricReference { .. })
        ));
    }

    #[test]
    fn validates_every_plot_series_reference() {
        let mut first = App::new("First");
        let foreign = first
            .metric::<Ratio>("foreign.ratio", schedule(), || Ok(0.5))
            .unwrap();

        let mut second = App::new("Second");
        let local = second
            .metric::<Ratio>("local.ratio", schedule(), || Ok(0.25))
            .unwrap();
        second.set_sections(vec![Section::new(
            "Plot",
            widgets![Plot::new(
                "Mixed",
                vec![
                    PlotSeries::new(local, "cyan"),
                    PlotSeries::new(foreign, "blue"),
                ],
            )],
        )]);
        assert!(matches!(
            second.validate(),
            Err(ConfigError::UnknownMetricReference { .. })
        ));
    }

    #[test]
    fn surface_only_apps_are_valid_and_duplicate_kinds_are_rejected() {
        let mut app = App::new("Surface");
        let cpu = app
            .metric::<Ratio>("cpu", schedule(), || Ok(0.5))
            .unwrap();
        let root = LayoutNode::widget(Stat::new("CPU", cpu).percent());
        app.set_surfaces(vec![Surface::widget_small(root.clone())]);
        assert!(app.validate().is_ok());
        app.set_surfaces(vec![
            Surface::widget_small(root.clone()),
            Surface::widget_small(root),
        ]);
        assert!(matches!(app.validate(), Err(ConfigError::InvalidLayout(_))));
    }

    #[test]
    fn multiple_desktop_surfaces_are_valid() {
        let mut app = App::new("Surfaces");
        let cpu = app
            .metric::<Ratio>("cpu", schedule(), || Ok(0.5))
            .unwrap();
        let root = LayoutNode::widget(Stat::new("CPU", cpu).percent());
        app.set_surfaces(vec![
            Surface::desktop(root.clone()),
            Surface::desktop(root.clone())
                .position(24.0, 24.0, crate::SurfaceOrigin::BottomRight)
                .width(320.0),
            Surface::widget_small(root),
        ]);
        assert!(app.validate().is_ok());
    }

    #[test]
    fn once_mode_writes_hello_plan_and_one_typed_update() {
        let mut app = App::new("Test");
        let jobs = app
            .metric::<Count>("jobs", schedule(), || Ok(7))
            .unwrap();
        app.set_sections(vec![Section::new(
            "Jobs",
            widgets![Stat::new("Jobs", jobs)],
        )]);
        app.validate().unwrap();

        let mut output = Vec::new();
        app.run_mode(Mode::Once, &mut output).unwrap();
        let records: Vec<Value> = String::from_utf8(output)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();

        assert_eq!(records.len(), 3);
        assert_eq!(records[0]["type"], "hello");
        assert_eq!(records[0]["protocol_major"], 1);
        assert_eq!(records[1]["type"], "plan");
        assert_eq!(
            records[1]["metrics"][0]["sample_interval_ms"],
            schedule().interval().as_millis() as u64
        );
        assert_eq!(records[2]["type"], "update");
        assert_eq!(records[2]["sequence"], 1);
        assert_eq!(
            records[2]["values"][0],
            serde_json::json!({"metric":"jobs","value":{"kind":"count","value":7}})
        );
    }

    #[test]
    fn protocol_record_at_limit_is_written() {
        #[derive(Serialize)]
        struct Payload<'a> {
            payload: &'a str,
        }

        let overhead = serde_json::to_vec(&Payload { payload: "" }).unwrap().len();
        let payload = "x".repeat(MAX_PROTOCOL_RECORD_BYTES - overhead);
        let mut output = Vec::new();
        write_record(&mut output, &Payload { payload: &payload }).unwrap();

        assert_eq!(output.len(), MAX_PROTOCOL_RECORD_BYTES + 1);
        assert_eq!(output.last(), Some(&b'\n'));
    }

    #[test]
    fn oversized_protocol_record_is_rejected_before_output() {
        #[derive(Serialize)]
        struct Payload<'a> {
            payload: &'a str,
        }

        let overhead = serde_json::to_vec(&Payload { payload: "" }).unwrap().len();
        let payload = "x".repeat(MAX_PROTOCOL_RECORD_BYTES - overhead + 1);
        let mut output = Vec::new();
        let error = write_record(&mut output, &Payload { payload: &payload }).unwrap_err();

        assert!(matches!(
            error,
            Error::ProtocolRecordTooLarge {
                limit: MAX_PROTOCOL_RECORD_BYTES
            }
        ));
        assert!(output.is_empty());
    }
}
