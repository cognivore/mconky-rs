use crate::app::Schedule;
use crate::collector::{CollectError, CollectedMetric, Source};
use crate::{Bytes, ConfigError, Metric, MetricId, Number, Ratio, WireType};
use serde_json::Value;
use std::io::{self, BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, ChildStdout, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const MAX_LINE_BYTES: usize = 256 * 1024;
const WORKER_INTERVAL: Duration = Duration::from_millis(1);
const INITIAL_RESTART_BACKOFF: Duration = Duration::from_secs(1);
const MAX_RESTART_BACKOFF: Duration = Duration::from_secs(30);

/// Settings for long-lived `macmon pipe` collection.
///
/// The child is killed and waited in `Drop` during graceful configuration
/// reload. The native host should still terminate the entire configuration
/// process group because forced termination can bypass Rust destructors.
#[derive(Clone, Debug)]
pub struct MacmonCollector {
    executable: PathBuf,
    schedule: Schedule,
}

impl MacmonCollector {
    /// Creates a collector using `macmon` from `PATH`, scheduled every two seconds.
    pub fn new() -> Self {
        Self {
            executable: PathBuf::from("macmon"),
            schedule: Schedule::every(Duration::from_secs(2)),
        }
    }

    /// Sets the executable path or command name.
    pub fn executable(mut self, executable: impl Into<PathBuf>) -> Self {
        self.executable = executable.into();
        self
    }

    /// Sets the shared source schedule.
    pub fn schedule(mut self, schedule: Schedule) -> Self {
        self.schedule = schedule;
        self
    }

    pub(crate) fn validate(&self) -> Result<(), ConfigError> {
        if self.executable.as_os_str().is_empty() {
            return Err(ConfigError::InvalidCollector {
                collector: "macmon",
                reason: "executable cannot be empty".to_owned(),
            });
        }
        Ok(())
    }

    pub(crate) fn schedule_value(&self) -> Schedule {
        self.schedule
    }
}

impl Default for MacmonCollector {
    fn default() -> Self {
        Self::new()
    }
}

/// Typed handles emitted by [`MacmonCollector`].
#[derive(Clone, Debug)]
pub struct MacmonMetrics {
    /// Total CPU utilization ratio.
    pub cpu_total: Metric<Ratio>,
    /// Performance-cluster utilization ratio.
    pub p_cpu_ratio: Metric<Ratio>,
    /// Performance-cluster frequency in MHz.
    pub p_cpu_frequency: Metric<Number>,
    /// Efficiency-cluster utilization ratio.
    pub e_cpu_ratio: Metric<Ratio>,
    /// Efficiency-cluster frequency in MHz.
    pub e_cpu_frequency: Metric<Number>,
    /// GPU utilization ratio.
    pub gpu_ratio: Metric<Ratio>,
    /// GPU frequency in MHz.
    pub gpu_frequency: Metric<Number>,
    /// Average CPU temperature in Celsius.
    pub cpu_temperature: Metric<Number>,
    /// Average GPU temperature in Celsius.
    pub gpu_temperature: Metric<Number>,
    /// CPU power in watts.
    pub cpu_power: Metric<Number>,
    /// GPU power in watts.
    pub gpu_power: Metric<Number>,
    /// Used RAM bytes.
    pub ram_used: Metric<Bytes>,
    /// Total RAM bytes.
    pub ram_total: Metric<Bytes>,
    /// Used RAM ratio.
    pub ram_ratio: Metric<Ratio>,
    /// Used swap bytes.
    pub swap_used: Metric<Bytes>,
    /// Total swap bytes.
    pub swap_total: Metric<Bytes>,
    /// Used swap ratio.
    pub swap_ratio: Metric<Ratio>,
}

pub(crate) const MACMON_METRIC_SPECS: [(&str, &str); 17] = [
    ("macmon.cpu.total", Ratio::VALUE_TYPE),
    ("macmon.cpu.p.ratio", Ratio::VALUE_TYPE),
    ("macmon.cpu.p.frequency", Number::VALUE_TYPE),
    ("macmon.cpu.e.ratio", Ratio::VALUE_TYPE),
    ("macmon.cpu.e.frequency", Number::VALUE_TYPE),
    ("macmon.gpu.ratio", Ratio::VALUE_TYPE),
    ("macmon.gpu.frequency", Number::VALUE_TYPE),
    ("macmon.temperature.cpu", Number::VALUE_TYPE),
    ("macmon.temperature.gpu", Number::VALUE_TYPE),
    ("macmon.power.cpu", Number::VALUE_TYPE),
    ("macmon.power.gpu", Number::VALUE_TYPE),
    ("macmon.ram.used", Bytes::VALUE_TYPE),
    ("macmon.ram.total", Bytes::VALUE_TYPE),
    ("macmon.ram.ratio", Ratio::VALUE_TYPE),
    ("macmon.swap.used", Bytes::VALUE_TYPE),
    ("macmon.swap.total", Bytes::VALUE_TYPE),
    ("macmon.swap.ratio", Ratio::VALUE_TYPE),
];

#[derive(Clone)]
pub(crate) struct MacmonMetricIds {
    ids: [MetricId; 17],
}

impl MacmonMetricIds {
    pub(crate) fn parse() -> Result<Self, crate::MetricIdError> {
        Ok(Self {
            ids: [
                MetricId::new(MACMON_METRIC_SPECS[0].0)?,
                MetricId::new(MACMON_METRIC_SPECS[1].0)?,
                MetricId::new(MACMON_METRIC_SPECS[2].0)?,
                MetricId::new(MACMON_METRIC_SPECS[3].0)?,
                MetricId::new(MACMON_METRIC_SPECS[4].0)?,
                MetricId::new(MACMON_METRIC_SPECS[5].0)?,
                MetricId::new(MACMON_METRIC_SPECS[6].0)?,
                MetricId::new(MACMON_METRIC_SPECS[7].0)?,
                MetricId::new(MACMON_METRIC_SPECS[8].0)?,
                MetricId::new(MACMON_METRIC_SPECS[9].0)?,
                MetricId::new(MACMON_METRIC_SPECS[10].0)?,
                MetricId::new(MACMON_METRIC_SPECS[11].0)?,
                MetricId::new(MACMON_METRIC_SPECS[12].0)?,
                MetricId::new(MACMON_METRIC_SPECS[13].0)?,
                MetricId::new(MACMON_METRIC_SPECS[14].0)?,
                MetricId::new(MACMON_METRIC_SPECS[15].0)?,
                MetricId::new(MACMON_METRIC_SPECS[16].0)?,
            ],
        })
    }

    pub(crate) fn all(&self) -> [&MetricId; 17] {
        std::array::from_fn(|index| &self.ids[index])
    }

    pub(crate) fn handles(&self) -> MacmonMetrics {
        MacmonMetrics {
            cpu_total: Metric::new(self.ids[0].clone()),
            p_cpu_ratio: Metric::new(self.ids[1].clone()),
            p_cpu_frequency: Metric::new(self.ids[2].clone()),
            e_cpu_ratio: Metric::new(self.ids[3].clone()),
            e_cpu_frequency: Metric::new(self.ids[4].clone()),
            gpu_ratio: Metric::new(self.ids[5].clone()),
            gpu_frequency: Metric::new(self.ids[6].clone()),
            cpu_temperature: Metric::new(self.ids[7].clone()),
            gpu_temperature: Metric::new(self.ids[8].clone()),
            cpu_power: Metric::new(self.ids[9].clone()),
            gpu_power: Metric::new(self.ids[10].clone()),
            ram_used: Metric::new(self.ids[11].clone()),
            ram_total: Metric::new(self.ids[12].clone()),
            ram_ratio: Metric::new(self.ids[13].clone()),
            swap_used: Metric::new(self.ids[14].clone()),
            swap_total: Metric::new(self.ids[15].clone()),
            swap_ratio: Metric::new(self.ids[16].clone()),
        }
    }
}

pub(crate) struct MacmonSource {
    ids: MacmonMetricIds,
    settings: MacmonCollector,
    process: Option<MacmonProcess>,
    backoff: RestartBackoff,
}

impl MacmonSource {
    pub(crate) fn new(ids: MacmonMetricIds, settings: MacmonCollector) -> Self {
        Self {
            ids,
            settings,
            process: None,
            backoff: RestartBackoff::default(),
        }
    }

    fn parse_json(&self, bytes: &[u8]) -> Result<ParsedMacmonSample, CollectError> {
        let root: Value = serde_json::from_slice(bytes)
            .map_err(|error| CollectError::new(format!("cannot parse macmon JSON: {error}")))?;

        let cpu_total = ratio_field(number(&root, &["cpu_usage_pct"]), "cpu_usage_pct");
        let p_frequency = bounded_number(
            array_number(&root, "pcpu_usage", 0),
            "pcpu_usage frequency",
            0.0,
            100_000.0,
        );
        let p_ratio = ratio_field(array_number(&root, "pcpu_usage", 1), "pcpu_usage ratio");
        let e_frequency = bounded_number(
            array_number(&root, "ecpu_usage", 0),
            "ecpu_usage frequency",
            0.0,
            100_000.0,
        );
        let e_ratio = ratio_field(array_number(&root, "ecpu_usage", 1), "ecpu_usage ratio");
        let gpu_frequency = bounded_number(
            array_number(&root, "gpu_usage", 0),
            "gpu_usage frequency",
            0.0,
            100_000.0,
        );
        let gpu_ratio = ratio_field(array_number(&root, "gpu_usage", 1), "gpu_usage ratio");
        let cpu_temperature = bounded_number(
            number(&root, &["temp", "cpu_temp_avg"]),
            "CPU temperature",
            -100.0,
            200.0,
        );
        let gpu_temperature = bounded_number(
            number(&root, &["temp", "gpu_temp_avg"]),
            "GPU temperature",
            -100.0,
            200.0,
        );
        let cpu_power = bounded_number(
            number(&root, &["cpu_power"]),
            "CPU power",
            0.0,
            100_000.0,
        );
        let gpu_power = bounded_number(
            number(&root, &["gpu_power"]),
            "GPU power",
            0.0,
            100_000.0,
        );
        let ram_used = unsigned(&root, &["memory", "ram_usage"]);
        let ram_total = unsigned(&root, &["memory", "ram_total"]);
        let ram_ratio = memory_ratio(ram_used.clone(), ram_total.clone(), "RAM");
        let swap_used = unsigned(&root, &["memory", "swap_usage"]);
        let swap_total = unsigned(&root, &["memory", "swap_total"]);
        let swap_ratio = memory_ratio(swap_used.clone(), swap_total.clone(), "swap");
        let should_restart = cpu_total.is_err()
            || p_ratio.is_err()
            || p_frequency.is_err()
            || e_ratio.is_err()
            || e_frequency.is_err()
            || gpu_ratio.is_err()
            || gpu_frequency.is_err()
            || cpu_temperature.is_err()
            || gpu_temperature.is_err()
            || cpu_power.is_err()
            || gpu_power.is_err()
            || ram_used.is_err()
            || ram_total.is_err()
            || ram_ratio.is_err()
            || swap_used.is_err()
            || swap_total.is_err()
            || swap_ratio.is_err();

        Ok(ParsedMacmonSample {
            values: vec![
                encoded::<Ratio>(self.ids.ids[0].clone(), cpu_total),
                encoded::<Ratio>(self.ids.ids[1].clone(), p_ratio),
                encoded::<Number>(self.ids.ids[2].clone(), p_frequency),
                encoded::<Ratio>(self.ids.ids[3].clone(), e_ratio),
                encoded::<Number>(self.ids.ids[4].clone(), e_frequency),
                encoded::<Ratio>(self.ids.ids[5].clone(), gpu_ratio),
                encoded::<Number>(self.ids.ids[6].clone(), gpu_frequency),
                encoded::<Number>(self.ids.ids[7].clone(), cpu_temperature),
                encoded::<Number>(self.ids.ids[8].clone(), gpu_temperature),
                encoded::<Number>(self.ids.ids[9].clone(), cpu_power),
                encoded::<Number>(self.ids.ids[10].clone(), gpu_power),
                encoded::<Bytes>(self.ids.ids[11].clone(), ram_used),
                encoded::<Bytes>(self.ids.ids[12].clone(), ram_total),
                encoded::<Ratio>(self.ids.ids[13].clone(), ram_ratio),
                encoded::<Bytes>(self.ids.ids[14].clone(), swap_used),
                encoded::<Bytes>(self.ids.ids[15].clone(), swap_total),
                encoded::<Ratio>(self.ids.ids[16].clone(), swap_ratio),
            ],
            should_restart,
        })
    }

    #[cfg(test)]
    fn collect_json(&self, bytes: &[u8]) -> Vec<CollectedMetric> {
        self.parse_json(bytes)
            .map(|sample| sample.values)
            .unwrap_or_else(|error| all_errors(&self.ids, error))
    }

    fn restart_with_error(&mut self, error: CollectError) -> Vec<CollectedMetric> {
        self.process.take();
        let delay = self.backoff.record_failure(Instant::now());
        all_errors(
            &self.ids,
            CollectError::new(format!("{error}; macmon restart in {} ms", delay.as_millis())),
        )
    }
}

impl Source for MacmonSource {
    fn name(&self) -> &str {
        "macmon"
    }

    fn interval(&self) -> Duration {
        // read_line blocks for the macmon cadence; avoid sleeping that cadence again.
        WORKER_INTERVAL
    }

    fn collect(&mut self) -> Vec<CollectedMetric> {
        self.backoff.wait_until_ready();
        if self.process.is_none() {
            match MacmonProcess::spawn(&self.settings) {
                Ok(process) => self.process = Some(process),
                Err(error) => return self.restart_with_error(error),
            }
        }

        let read_result = match self.process.as_mut() {
            Some(process) => process.read_line(),
            None => {
                return self.restart_with_error(CollectError::new(
                    "macmon process was not initialized",
                ));
            }
        };
        let line = match read_result {
            Ok(LineRead::Line(line)) => line,
            Ok(LineRead::Eof) => {
                let error = self
                    .process
                    .as_mut()
                    .map_or_else(|| CollectError::new("macmon process disappeared"), MacmonProcess::eof_error);
                return self.restart_with_error(error);
            }
            Ok(LineRead::TooLong) => {
                return self.restart_with_error(CollectError::new(format!(
                    "macmon JSON line exceeds {MAX_LINE_BYTES} bytes"
                )));
            }
            Err(error) => {
                return self.restart_with_error(CollectError::new(format!(
                    "cannot read macmon output: {error}"
                )));
            }
        };
        match self.parse_json(&line) {
            Ok(sample) => {
                if sample.should_restart {
                    self.process.take();
                    self.backoff.record_failure(Instant::now());
                } else {
                    self.backoff.reset();
                }
                sample.values
            }
            Err(error) => self.restart_with_error(error),
        }
    }
}

struct ParsedMacmonSample {
    values: Vec<CollectedMetric>,
    should_restart: bool,
}

struct MacmonProcess {
    child: Child,
    stdout: BufReader<ChildStdout>,
}

impl MacmonProcess {
    fn spawn(settings: &MacmonCollector) -> Result<Self, CollectError> {
        let interval_ms = settings.schedule.interval().as_millis().to_string();
        let mut child = Command::new(&settings.executable)
            .args([
                "pipe",
                "-s",
                "0",
                "--soc-info",
                "-i",
                interval_ms.as_str(),
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| {
                CollectError::new(format!(
                    "cannot start macmon {}: {error}",
                    settings.executable.display()
                ))
            })?;
        let stdout = match child.stdout.take() {
            Some(stdout) => stdout,
            None => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(CollectError::new("macmon stdout pipe is unavailable"));
            }
        };
        Ok(Self {
            child,
            stdout: BufReader::new(stdout),
        })
    }

    fn read_line(&mut self) -> io::Result<LineRead> {
        read_bounded_line(&mut self.stdout, MAX_LINE_BYTES)
    }

    fn eof_error(&mut self) -> CollectError {
        match self.child.try_wait() {
            Ok(Some(status)) if status.success() => {
                CollectError::new("macmon exited and closed stdout")
            }
            Ok(Some(status)) => CollectError::new(format!("macmon exited with {status}")),
            Ok(None) => CollectError::new("macmon closed stdout while still running"),
            Err(error) => CollectError::new(format!("cannot inspect macmon exit status: {error}")),
        }
    }
}

impl Drop for MacmonProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[derive(Debug, Eq, PartialEq)]
enum LineRead {
    Line(Vec<u8>),
    Eof,
    TooLong,
}

fn read_bounded_line(reader: &mut impl BufRead, limit: usize) -> io::Result<LineRead> {
    let mut line = Vec::new();
    let mut exceeded = false;
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return Ok(if exceeded {
                LineRead::TooLong
            } else if line.is_empty() {
                LineRead::Eof
            } else {
                LineRead::Line(line)
            });
        }
        let newline = available.iter().position(|byte| *byte == b'\n');
        let consumed = newline.map_or(available.len(), |index| index + 1);
        let content = newline.map_or(available, |index| &available[..index]);
        let remaining = limit.saturating_sub(line.len());
        let retained = remaining.min(content.len());
        line.extend_from_slice(&content[..retained]);
        exceeded |= retained < content.len();
        reader.consume(consumed);
        if newline.is_some() {
            return Ok(if exceeded {
                LineRead::TooLong
            } else {
                LineRead::Line(line)
            });
        }
    }
}

#[derive(Default)]
struct RestartBackoff {
    failures: u32,
    retry_at: Option<Instant>,
}

impl RestartBackoff {
    fn record_failure(&mut self, now: Instant) -> Duration {
        let multiplier = 1_u32 << self.failures.min(5);
        let delay = INITIAL_RESTART_BACKOFF
            .checked_mul(multiplier)
            .unwrap_or(MAX_RESTART_BACKOFF)
            .min(MAX_RESTART_BACKOFF);
        self.failures = self.failures.saturating_add(1);
        self.retry_at = Some(now + delay);
        delay
    }

    fn wait_until_ready(&self) {
        if let Some(retry_at) = self.retry_at {
            thread::sleep(retry_at.saturating_duration_since(Instant::now()));
        }
    }

    fn reset(&mut self) {
        self.failures = 0;
        self.retry_at = None;
    }
}

fn number(root: &Value, path: &[&str]) -> Result<f64, CollectError> {
    let name = path.join(".");
    let mut value = root;
    for component in path {
        value = value
            .get(*component)
            .ok_or_else(|| CollectError::new(format!("macmon field {name} is missing")))?;
    }
    value
        .as_f64()
        .ok_or_else(|| CollectError::new(format!("macmon field {name} is not a number")))
}

fn unsigned(root: &Value, path: &[&str]) -> Result<u64, CollectError> {
    let name = path.join(".");
    let mut value = root;
    for component in path {
        value = value
            .get(*component)
            .ok_or_else(|| CollectError::new(format!("macmon field {name} is missing")))?;
    }
    value.as_u64().ok_or_else(|| {
        CollectError::new(format!(
            "macmon field {name} is not a nonnegative integer"
        ))
    })
}

fn array_number(root: &Value, field: &str, index: usize) -> Result<f64, CollectError> {
    root.get(field)
        .and_then(Value::as_array)
        .and_then(|values| values.get(index))
        .and_then(Value::as_f64)
        .ok_or_else(|| {
            CollectError::new(format!(
                "macmon field {field}[{index}] is missing or not a number"
            ))
        })
}

fn ratio_field(value: Result<f64, CollectError>, name: &str) -> Result<f64, CollectError> {
    bounded_number(value, name, 0.0, 1.0)
}

fn bounded_number(
    value: Result<f64, CollectError>,
    name: &str,
    minimum: f64,
    maximum: f64,
) -> Result<f64, CollectError> {
    let value = value?;
    if !value.is_finite() || !(minimum..=maximum).contains(&value) {
        return Err(CollectError::new(format!(
            "macmon {name} must be finite and between {minimum} and {maximum}"
        )));
    }
    Ok(value)
}

fn memory_ratio(
    used: Result<u64, CollectError>,
    total: Result<u64, CollectError>,
    name: &str,
) -> Result<f64, CollectError> {
    let used = used?;
    let total = total?;
    if total == 0 {
        return if used == 0 {
            Ok(0.0)
        } else {
            Err(CollectError::new(format!(
                "macmon {name} usage is nonzero while total is zero"
            )))
        };
    }
    ratio_field(Ok(used as f64 / total as f64), &format!("{name} ratio"))
}

fn encoded<T: WireType>(id: MetricId, value: Result<T::Value, CollectError>) -> CollectedMetric {
    CollectedMetric::from_result(id, value.and_then(T::into_wire))
}

fn all_errors(ids: &MacmonMetricIds, error: CollectError) -> Vec<CollectedMetric> {
    ids.all()
        .into_iter()
        .map(|id| CollectedMetric::error(id.clone(), error.clone()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{
        INITIAL_RESTART_BACKOFF, LineRead, MacmonCollector, MacmonMetricIds, MacmonSource,
        RestartBackoff, bounded_number, read_bounded_line,
    };
    use crate::ConfigError;
    use serde_json::{Value, json};
    use std::io::Cursor;
    use std::path::PathBuf;
    use std::time::Instant;

    const FIXTURE: &str = r#"{
        "cpu_power":2.1,"cpu_usage_pct":0.25,"ecpu_usage":[1686,0.2],
        "gpu_power":0.3,"gpu_usage":[338,0.1],
        "memory":{"ram_total":1000,"ram_usage":400,"swap_total":200,"swap_usage":50},
        "pcpu_usage":[2628,0.3],
        "temp":{"cpu_temp_avg":45.5,"gpu_temp_avg":43.25}
    }"#;

    fn values(bytes: &[u8]) -> Vec<Value> {
        let source = MacmonSource::new(
            MacmonMetricIds::parse().unwrap(),
            MacmonCollector::new(),
        );
        source
            .collect_json(bytes)
            .into_iter()
            .map(|item| serde_json::to_value(item).unwrap())
            .collect()
    }

    #[test]
    fn parses_fixture_into_all_typed_metrics() {
        let values = values(FIXTURE.as_bytes());
        assert_eq!(values.len(), 17);
        assert_eq!(
            values[0],
            json!({"metric":"macmon.cpu.total","value":{"kind":"ratio","value":0.25}})
        );
        assert_eq!(values[2]["value"]["value"], 2628.0);
        assert_eq!(values[7]["value"]["value"], 45.5);
        assert_eq!(values[13]["value"]["value"], 0.4);
        assert_eq!(values[16]["value"]["value"], 0.25);
    }

    #[test]
    fn missing_and_out_of_range_fields_are_per_metric_errors() {
        let mut fixture: Value = serde_json::from_str(FIXTURE).unwrap();
        fixture.as_object_mut().unwrap().remove("gpu_power");
        fixture["cpu_usage_pct"] = json!(2.0);
        let values = values(&serde_json::to_vec(&fixture).unwrap());
        assert!(values[0]["error"].as_str().unwrap().contains("between 0"));
        assert!(values[10]["error"].as_str().unwrap().contains("missing"));
        assert!(values[1].get("value").is_some());
    }

    #[test]
    fn malformed_json_errors_every_metric() {
        let values = values(b"not json");
        assert_eq!(values.len(), 17);
        assert!(values.iter().all(|value| value.get("error").is_some()));
    }

    #[test]
    fn field_validation_errors_request_a_lazy_restart() {
        let mut fixture: Value = serde_json::from_str(FIXTURE).unwrap();
        fixture.as_object_mut().unwrap().remove("gpu_power");
        let source = MacmonSource::new(
            MacmonMetricIds::parse().unwrap(),
            MacmonCollector::new(),
        );
        let sample = source
            .parse_json(&serde_json::to_vec(&fixture).unwrap())
            .unwrap();
        assert!(sample.should_restart);
    }

    #[test]
    fn rejects_nonfinite_and_invalid_executable_settings() {
        assert!(bounded_number(Ok(f64::NAN), "test", 0.0, 1.0).is_err());
        assert!(matches!(
            MacmonCollector::new()
                .executable(PathBuf::new())
                .validate(),
            Err(ConfigError::InvalidCollector { .. })
        ));
    }

    #[test]
    fn exposes_fixed_typed_handles() {
        let handles = MacmonMetricIds::parse().unwrap().handles();
        assert_eq!(handles.cpu_total.id().as_str(), "macmon.cpu.total");
        assert_eq!(
            handles.p_cpu_frequency.id().as_str(),
            "macmon.cpu.p.frequency"
        );
        assert_eq!(handles.swap_ratio.id().as_str(), "macmon.swap.ratio");
    }

    #[test]
    fn long_lived_reader_returns_successive_bounded_lines() {
        let mut input = Cursor::new(b"{\"one\":1}\n{\"two\":2}\n".to_vec());
        assert_eq!(
            read_bounded_line(&mut input, 256).unwrap(),
            LineRead::Line(b"{\"one\":1}".to_vec())
        );
        assert_eq!(
            read_bounded_line(&mut input, 256).unwrap(),
            LineRead::Line(b"{\"two\":2}".to_vec())
        );
        assert_eq!(read_bounded_line(&mut input, 256).unwrap(), LineRead::Eof);
    }

    #[test]
    fn oversized_line_is_drained_before_the_next_line() {
        let mut input = Cursor::new(b"123456789\nok\n".to_vec());
        assert_eq!(read_bounded_line(&mut input, 4).unwrap(), LineRead::TooLong);
        assert_eq!(
            read_bounded_line(&mut input, 4).unwrap(),
            LineRead::Line(b"ok".to_vec())
        );
    }

    #[test]
    fn restart_backoff_grows_and_resets_deterministically() {
        let start = Instant::now();
        let mut backoff = RestartBackoff::default();
        assert_eq!(backoff.record_failure(start), INITIAL_RESTART_BACKOFF);
        assert_eq!(
            backoff.record_failure(start + INITIAL_RESTART_BACKOFF),
            INITIAL_RESTART_BACKOFF * 2
        );
        backoff.reset();
        assert_eq!(backoff.record_failure(start), INITIAL_RESTART_BACKOFF);
    }
}
