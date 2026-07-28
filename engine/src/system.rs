use crate::app::Schedule;
use crate::collector::{CollectError, CollectedMetric, Source};
use crate::{
    Bytes, BytesPerSecond, Metric, MetricId, Ratio, Table, TableValue, WireType,
};
use std::path::Path;
use std::time::{Duration, Instant};
use sysinfo::{
    CpuRefreshKind, Disks, MemoryRefreshKind, Networks, ProcessRefreshKind, ProcessesToUpdate,
    System,
};

/// Settings for the shared built-in system collector.
///
/// One refresh produces every metric in [`SystemMetrics`], avoiding a full
/// system refresh per metric.
#[derive(Clone, Copy, Debug)]
pub struct SystemCollector {
    schedule: Schedule,
    top_processes: usize,
}

impl SystemCollector {
    /// Creates a collector scheduled every second and retaining eight processes.
    pub fn new() -> Self {
        Self {
            schedule: Schedule::every(Duration::from_secs(1)),
            top_processes: 8,
        }
    }

    /// Sets the shared source schedule.
    pub fn schedule(mut self, schedule: Schedule) -> Self {
        self.schedule = schedule;
        self
    }

    /// Sets the maximum number of rows in the top-process table.
    pub fn top_processes(mut self, count: usize) -> Self {
        self.top_processes = count;
        self
    }

    pub(crate) fn schedule_value(&self) -> Schedule {
        self.schedule
    }

    pub(crate) fn top_process_count(&self) -> usize {
        self.top_processes
    }
}

impl Default for SystemCollector {
    fn default() -> Self {
        Self::new()
    }
}

/// Typed handles emitted by the shared built-in system collector.
#[derive(Clone, Debug)]
pub struct SystemMetrics {
    /// Aggregate CPU utilization, from 0 to 1.
    pub cpu_total: Metric<Ratio>,
    /// Currently used physical memory in bytes.
    pub memory_used: Metric<Bytes>,
    /// Total physical memory in bytes.
    pub memory_total: Metric<Bytes>,
    /// Used physical memory divided by total physical memory.
    pub memory_ratio: Metric<Ratio>,
    /// Used bytes on the filesystem mounted at `/`.
    pub root_disk_used: Metric<Bytes>,
    /// Total bytes on the filesystem mounted at `/`.
    pub root_disk_total: Metric<Bytes>,
    /// Available bytes on the filesystem mounted at `/`.
    pub root_disk_available: Metric<Bytes>,
    /// Root filesystem used bytes divided by total bytes.
    pub root_disk_ratio: Metric<Ratio>,
    /// Aggregate received bytes per second across network interfaces.
    pub network_down: Metric<BytesPerSecond>,
    /// Aggregate transmitted bytes per second across network interfaces.
    pub network_up: Metric<BytesPerSecond>,
    /// Top processes sorted by current CPU utilization.
    pub top_processes: Metric<Table>,
}

pub(crate) const SYSTEM_METRIC_SPECS: [(&str, &str); 11] = [
    ("cpu.total", Ratio::VALUE_TYPE),
    ("memory.used", Bytes::VALUE_TYPE),
    ("memory.total", Bytes::VALUE_TYPE),
    ("memory.ratio", Ratio::VALUE_TYPE),
    ("disk.root.used", Bytes::VALUE_TYPE),
    ("disk.root.total", Bytes::VALUE_TYPE),
    ("disk.root.available", Bytes::VALUE_TYPE),
    ("disk.root.ratio", Ratio::VALUE_TYPE),
    ("network.down", BytesPerSecond::VALUE_TYPE),
    ("network.up", BytesPerSecond::VALUE_TYPE),
    ("processes.top", Table::VALUE_TYPE),
];

#[derive(Clone)]
pub(crate) struct SystemMetricIds {
    cpu_total: MetricId,
    memory_used: MetricId,
    memory_total: MetricId,
    memory_ratio: MetricId,
    root_disk_used: MetricId,
    root_disk_total: MetricId,
    root_disk_available: MetricId,
    root_disk_ratio: MetricId,
    network_down: MetricId,
    network_up: MetricId,
    top_processes: MetricId,
}

impl SystemMetricIds {
    pub(crate) fn parse() -> Result<Self, crate::MetricIdError> {
        Ok(Self {
            cpu_total: MetricId::new(SYSTEM_METRIC_SPECS[0].0)?,
            memory_used: MetricId::new(SYSTEM_METRIC_SPECS[1].0)?,
            memory_total: MetricId::new(SYSTEM_METRIC_SPECS[2].0)?,
            memory_ratio: MetricId::new(SYSTEM_METRIC_SPECS[3].0)?,
            root_disk_used: MetricId::new(SYSTEM_METRIC_SPECS[4].0)?,
            root_disk_total: MetricId::new(SYSTEM_METRIC_SPECS[5].0)?,
            root_disk_available: MetricId::new(SYSTEM_METRIC_SPECS[6].0)?,
            root_disk_ratio: MetricId::new(SYSTEM_METRIC_SPECS[7].0)?,
            network_down: MetricId::new(SYSTEM_METRIC_SPECS[8].0)?,
            network_up: MetricId::new(SYSTEM_METRIC_SPECS[9].0)?,
            top_processes: MetricId::new(SYSTEM_METRIC_SPECS[10].0)?,
        })
    }

    pub(crate) fn all(&self) -> [&MetricId; 11] {
        [
            &self.cpu_total,
            &self.memory_used,
            &self.memory_total,
            &self.memory_ratio,
            &self.root_disk_used,
            &self.root_disk_total,
            &self.root_disk_available,
            &self.root_disk_ratio,
            &self.network_down,
            &self.network_up,
            &self.top_processes,
        ]
    }

    pub(crate) fn handles(&self) -> SystemMetrics {
        SystemMetrics {
            cpu_total: Metric::new(self.cpu_total.clone()),
            memory_used: Metric::new(self.memory_used.clone()),
            memory_total: Metric::new(self.memory_total.clone()),
            memory_ratio: Metric::new(self.memory_ratio.clone()),
            root_disk_used: Metric::new(self.root_disk_used.clone()),
            root_disk_total: Metric::new(self.root_disk_total.clone()),
            root_disk_available: Metric::new(self.root_disk_available.clone()),
            root_disk_ratio: Metric::new(self.root_disk_ratio.clone()),
            network_down: Metric::new(self.network_down.clone()),
            network_up: Metric::new(self.network_up.clone()),
            top_processes: Metric::new(self.top_processes.clone()),
        }
    }
}

pub(crate) struct SystemSource {
    ids: SystemMetricIds,
    interval: Duration,
    top_processes: usize,
    state: Option<SystemState>,
}

impl SystemSource {
    pub(crate) fn new(ids: SystemMetricIds, settings: SystemCollector) -> Self {
        Self {
            ids,
            interval: settings.schedule.interval(),
            top_processes: settings.top_processes,
            state: None,
        }
    }
}

impl Source for SystemSource {
    fn name(&self) -> &str {
        "system"
    }

    fn interval(&self) -> Duration {
        self.interval
    }

    fn collect(&mut self) -> Vec<CollectedMetric> {
        let state = self.state.get_or_insert_with(SystemState::new);
        state.refresh();

        let cpu_ratio = f64::from(state.system.global_cpu_usage()) / 100.0;
        let memory_used = state.system.used_memory();
        let memory_total = state.system.total_memory();
        let memory_ratio = ratio(memory_used, memory_total, "total memory is zero");
        let network_rates = if state.networks.is_empty() {
            Err(CollectError::new("no network interfaces were discovered"))
        } else {
            Ok(state.network_rate.sample(
                aggregate_network_totals(&state.networks),
                Instant::now(),
            ))
        };

        let mut values = vec![
            encoded::<Ratio>(self.ids.cpu_total.clone(), cpu_ratio),
            encoded::<Bytes>(self.ids.memory_used.clone(), memory_used),
            encoded::<Bytes>(self.ids.memory_total.clone(), memory_total),
            result::<Ratio>(self.ids.memory_ratio.clone(), memory_ratio),
        ];

        match state
            .disks
            .list()
            .iter()
            .find(|disk| disk.mount_point() == Path::new("/"))
        {
            Some(disk) => {
                let total = disk.total_space();
                let available = disk.available_space();
                let used = total.saturating_sub(available);
                values.push(encoded::<Bytes>(self.ids.root_disk_used.clone(), used));
                values.push(encoded::<Bytes>(self.ids.root_disk_total.clone(), total));
                values.push(encoded::<Bytes>(
                    self.ids.root_disk_available.clone(),
                    available,
                ));
                values.push(result::<Ratio>(
                    self.ids.root_disk_ratio.clone(),
                    ratio(used, total, "root disk total is zero"),
                ));
            }
            None => {
                for id in [
                    &self.ids.root_disk_used,
                    &self.ids.root_disk_total,
                    &self.ids.root_disk_available,
                    &self.ids.root_disk_ratio,
                ] {
                    values.push(CollectedMetric::error(
                        id.clone(),
                        CollectError::new("no filesystem is mounted at /"),
                    ));
                }
            }
        }

        match network_rates {
            Ok((network_down, network_up)) => {
                values.push(encoded::<BytesPerSecond>(
                    self.ids.network_down.clone(),
                    network_down,
                ));
                values.push(encoded::<BytesPerSecond>(
                    self.ids.network_up.clone(),
                    network_up,
                ));
            }
            Err(error) => {
                values.push(CollectedMetric::error(
                    self.ids.network_down.clone(),
                    error.clone(),
                ));
                values.push(CollectedMetric::error(self.ids.network_up.clone(), error));
            }
        }
        values.push(result::<Table>(
            self.ids.top_processes.clone(),
            top_process_table(&state.system, self.top_processes),
        ));
        values
    }
}

struct SystemState {
    system: System,
    disks: Disks,
    networks: Networks,
    network_rate: RateTracker,
    initialized: bool,
}

impl SystemState {
    fn new() -> Self {
        Self {
            system: System::new(),
            disks: Disks::new_with_refreshed_list(),
            networks: Networks::new_with_refreshed_list(),
            network_rate: RateTracker::default(),
            initialized: false,
        }
    }

    fn refresh(&mut self) {
        if self.initialized {
            self.system.refresh_cpu_usage();
        } else {
            self.system
                .refresh_cpu_list(CpuRefreshKind::nothing().with_cpu_usage());
        }
        self.system
            .refresh_memory_specifics(MemoryRefreshKind::nothing().with_ram());
        self.system.refresh_processes_specifics(
            ProcessesToUpdate::All,
            true,
            ProcessRefreshKind::nothing()
                .with_cpu()
                .with_memory()
                .without_tasks(),
        );
        self.disks.refresh(true);
        self.networks.refresh(true);
        self.initialized = true;
    }
}

fn ratio(numerator: u64, denominator: u64, zero_message: &str) -> Result<f64, CollectError> {
    if denominator == 0 {
        Err(CollectError::new(zero_message))
    } else {
        Ok(numerator as f64 / denominator as f64)
    }
}

fn encoded<T: WireType>(id: MetricId, value: T::Value) -> CollectedMetric {
    CollectedMetric::from_result(id, T::into_wire(value))
}

fn result<T: WireType>(id: MetricId, value: Result<T::Value, CollectError>) -> CollectedMetric {
    CollectedMetric::from_result(id, value.and_then(T::into_wire))
}

fn top_process_table(system: &System, limit: usize) -> Result<TableValue, CollectError> {
    let mut processes: Vec<_> = system.processes().iter().collect();
    processes.sort_by(|(_, left), (_, right)| right.cpu_usage().total_cmp(&left.cpu_usage()));
    let rows = processes.into_iter().take(limit).map(|(pid, process)| {
        [
            pid.to_string(),
            format!("{:.1}%", process.cpu_usage()),
            format_bytes(process.memory()),
            process.name().to_string_lossy().into_owned(),
        ]
    });
    TableValue::new(["PID", "CPU", "MEM", "COMMAND"], rows)
        .map_err(|error| CollectError::new(error.to_string()))
}

fn format_bytes(bytes: u64) -> String {
    const MIB: f64 = 1024.0 * 1024.0;
    format!("{:.1} MiB", bytes as f64 / MIB)
}

fn aggregate_network_totals(networks: &Networks) -> (u64, u64) {
    networks.iter().fold((0, 0), |(received, transmitted), (_, data)| {
        (
            received.saturating_add(data.total_received()),
            transmitted.saturating_add(data.total_transmitted()),
        )
    })
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

#[cfg(test)]
mod tests {
    use super::{RateTracker, SystemMetricIds, SYSTEM_METRIC_SPECS};
    use std::time::{Duration, Instant};

    #[test]
    fn rates_use_monotonic_deltas_and_start_at_zero() {
        let start = Instant::now();
        let mut tracker = RateTracker::default();
        assert_eq!(tracker.sample((1_000, 2_000), start), (0.0, 0.0));
        assert_eq!(
            tracker.sample((2_000, 2_500), start + Duration::from_secs(2)),
            (500.0, 250.0)
        );
    }

    #[test]
    fn counter_resets_do_not_create_negative_rates() {
        let start = Instant::now();
        let mut tracker = RateTracker::default();
        tracker.sample((1_000, 2_000), start);
        assert_eq!(
            tracker.sample((10, 20), start + Duration::from_secs(1)),
            (0.0, 0.0)
        );
    }

    #[test]
    fn system_metrics_include_root_available_bytes() {
        let ids = SystemMetricIds::parse().unwrap();
        let handles = ids.handles();
        assert_eq!(SYSTEM_METRIC_SPECS.len(), 11);
        assert_eq!(
            handles.root_disk_available.id().as_str(),
            "disk.root.available"
        );
    }
}
