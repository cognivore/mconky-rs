use crate::app::Schedule;
use crate::collector::{CollectError, CollectedMetric, Source};
use crate::command::run_bounded;
use crate::{BytesPerSecond, ConfigError, Metric, MetricId, WireType};
use std::path::PathBuf;
use std::time::{Duration, Instant};

const MAX_COMMAND_BYTES: usize = 1024 * 1024;

/// Settings for cumulative disk I/O collection through `ioreg`.
#[derive(Clone, Debug)]
pub struct DiskIoCollector {
    executable: PathBuf,
    schedule: Schedule,
}

impl DiskIoCollector {
    /// Creates a collector using `/usr/sbin/ioreg`, scheduled every two seconds.
    pub fn new() -> Self {
        Self {
            executable: PathBuf::from("/usr/sbin/ioreg"),
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
                collector: "disk I/O",
                reason: "executable cannot be empty".to_owned(),
            });
        }
        Ok(())
    }

    pub(crate) fn schedule_value(&self) -> Schedule {
        self.schedule
    }
}

impl Default for DiskIoCollector {
    fn default() -> Self {
        Self::new()
    }
}

/// Typed handles emitted by [`DiskIoCollector`].
#[derive(Clone, Debug)]
pub struct DiskIoMetrics {
    /// Aggregate disk read bytes per second.
    pub read: Metric<BytesPerSecond>,
    /// Aggregate disk write bytes per second.
    pub write: Metric<BytesPerSecond>,
}

pub(crate) const DISK_IO_METRIC_SPECS: [(&str, &str); 2] = [
    ("disk.io.read", BytesPerSecond::VALUE_TYPE),
    ("disk.io.write", BytesPerSecond::VALUE_TYPE),
];

#[derive(Clone)]
pub(crate) struct DiskIoMetricIds {
    read: MetricId,
    write: MetricId,
}

impl DiskIoMetricIds {
    pub(crate) fn parse() -> Result<Self, crate::MetricIdError> {
        Ok(Self {
            read: MetricId::new(DISK_IO_METRIC_SPECS[0].0)?,
            write: MetricId::new(DISK_IO_METRIC_SPECS[1].0)?,
        })
    }

    pub(crate) fn all(&self) -> [&MetricId; 2] {
        [&self.read, &self.write]
    }

    pub(crate) fn handles(&self) -> DiskIoMetrics {
        DiskIoMetrics {
            read: Metric::new(self.read.clone()),
            write: Metric::new(self.write.clone()),
        }
    }
}

pub(crate) struct DiskIoSource {
    ids: DiskIoMetricIds,
    settings: DiskIoCollector,
    rates: RateTracker,
}

impl DiskIoSource {
    pub(crate) fn new(ids: DiskIoMetricIds, settings: DiskIoCollector) -> Self {
        Self {
            ids,
            settings,
            rates: RateTracker::default(),
        }
    }
}

impl Source for DiskIoSource {
    fn name(&self) -> &str {
        "disk-io"
    }

    fn interval(&self) -> Duration {
        self.settings.schedule.interval()
    }

    fn collect(&mut self) -> Vec<CollectedMetric> {
        let totals = run_bounded(
            &self.settings.executable,
            &["-r", "-c", "IOBlockStorageDriver", "-d", "1", "-l"],
            MAX_COMMAND_BYTES,
        )
        .and_then(|output| parse_counters(&output));
        match totals {
            Ok(totals) => {
                let (read, write) = self.rates.sample(totals, Instant::now());
                vec![
                    encoded(self.ids.read.clone(), Ok(read)),
                    encoded(self.ids.write.clone(), Ok(write)),
                ]
            }
            Err(error) => vec![
                CollectedMetric::error(self.ids.read.clone(), error.clone()),
                CollectedMetric::error(self.ids.write.clone(), error),
            ],
        }
    }
}

fn parse_counters(output: &[u8]) -> Result<(u64, u64), CollectError> {
    let output = std::str::from_utf8(output)
        .map_err(|error| CollectError::new(format!("ioreg output is not UTF-8: {error}")))?;
    Ok((
        sum_counter(output, "Bytes (Read)")?,
        sum_counter(output, "Bytes (Write)")?,
    ))
}

fn sum_counter(output: &str, key: &str) -> Result<u64, CollectError> {
    let marker = format!("\"{key}\"");
    let mut remaining = output;
    let mut total = 0_u64;
    let mut count = 0_usize;
    while let Some(index) = remaining.find(&marker) {
        let after_marker = &remaining[index + marker.len()..];
        let after_equals = after_marker
            .trim_start()
            .strip_prefix('=')
            .ok_or_else(|| CollectError::new(format!("ioreg counter {key:?} has no value")))?
            .trim_start();
        let digit_count = after_equals
            .bytes()
            .take_while(u8::is_ascii_digit)
            .count();
        if digit_count == 0 {
            return Err(CollectError::new(format!(
                "ioreg counter {key:?} is not an integer"
            )));
        }
        let value = after_equals[..digit_count].parse::<u64>().map_err(|error| {
            CollectError::new(format!("cannot parse ioreg counter {key:?}: {error}"))
        })?;
        total = total.checked_add(value).ok_or_else(|| {
            CollectError::new(format!("aggregate ioreg counter {key:?} overflows u64"))
        })?;
        count += 1;
        remaining = &after_equals[digit_count..];
    }
    if count == 0 {
        return Err(CollectError::new(format!(
            "ioreg output contains no {key:?} counters"
        )));
    }
    Ok(total)
}

#[derive(Default)]
struct RateTracker {
    previous: Option<((u64, u64), Instant)>,
}

impl RateTracker {
    fn sample(&mut self, totals: (u64, u64), now: Instant) -> (f64, f64) {
        let rates = match self.previous {
            Some((previous, then)) => {
                let seconds = now.saturating_duration_since(then).as_secs_f64();
                if seconds > 0.0 {
                    (
                        totals.0.saturating_sub(previous.0) as f64 / seconds,
                        totals.1.saturating_sub(previous.1) as f64 / seconds,
                    )
                } else {
                    (0.0, 0.0)
                }
            }
            None => (0.0, 0.0),
        };
        self.previous = Some((totals, now));
        rates
    }
}

fn encoded(
    id: MetricId,
    value: Result<f64, CollectError>,
) -> CollectedMetric {
    CollectedMetric::from_result(id, value.and_then(BytesPerSecond::into_wire))
}

#[cfg(test)]
mod tests {
    use super::{DiskIoCollector, DiskIoMetricIds, RateTracker, parse_counters};
    use crate::ConfigError;
    use std::path::PathBuf;
    use std::time::{Duration, Instant};

    const FIXTURE: &str = r#"
      "Statistics" = {"Bytes (Read)"=100,"Bytes (Write)"=40}
      "Statistics" = {"Bytes (Read)"=25,"Bytes (Write)"=10}
    "#;

    #[test]
    fn parses_and_sums_ioreg_counters() {
        assert_eq!(parse_counters(FIXTURE.as_bytes()).unwrap(), (125, 50));
        assert!(parse_counters(b"no counters").is_err());
        assert!(parse_counters(b"\"Bytes (Read)\"=oops").is_err());
    }

    #[test]
    fn rates_start_at_zero_and_handle_counter_regression() {
        let start = Instant::now();
        let mut rates = RateTracker::default();
        assert_eq!(rates.sample((100, 200), start), (0.0, 0.0));
        assert_eq!(
            rates.sample((300, 300), start + Duration::from_secs(2)),
            (100.0, 50.0)
        );
        assert_eq!(
            rates.sample((10, 20), start + Duration::from_secs(3)),
            (0.0, 0.0)
        );
    }

    #[test]
    fn rejects_empty_executable() {
        assert!(matches!(
            DiskIoCollector::new()
                .executable(PathBuf::new())
                .validate(),
            Err(ConfigError::InvalidCollector { .. })
        ));
    }

    #[test]
    fn exposes_fixed_typed_handles() {
        let handles = DiskIoMetricIds::parse().unwrap().handles();
        assert_eq!(handles.read.id().as_str(), "disk.io.read");
        assert_eq!(handles.write.id().as_str(), "disk.io.write");
    }
}
