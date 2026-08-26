#!/usr/bin/env rust-script
//! ```cargo
//! [dependencies]
//! wallstats = { path = "/Users/sweater/Github/wallstats/engine" }
//! ```

// The invisible companion recompiles this file automatically after each save.

use std::error::Error;
use std::env;
use std::io;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use wallstats::{
    App, Bytes, CollectError, CompactStatus, CompactStatusValue, CompactStatusWidget, Count,
    DiskIoCollector, DurationSeconds, Gauge, Insets, LayoutNode, LayoutTrack, MacmonCollector,
    Number, Plot, PlotSeries, Ratio, Schedule, Stat, StatusLight, Surface, SurfaceOrigin,
    SystemCollector, TableWidget, Text, TextFileSet, Widget, Window,
};

fn configure() -> Result<App, Box<dyn Error>> {
    let home = env::var_os("HOME").map(PathBuf::from).ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, "HOME is not set")
    })?;
    let desktop_enabled = true;
    let wyrm_watch_enabled = true;
    let widget_large_enabled = true;
    let widget_medium_enabled = true;
    let widget_small_enabled = true;
    let desktop_background_opacity = 0.12;
    let sampling = if desktop_enabled {
        Duration::from_secs(5)
    } else {
        Duration::from_secs(30)
    };
    let mut app = App::new("SEPTNESIS");
    app.set_window(Window::desktop().width(420).margin(20).opacity(0.94));

    let system = app.system(
        SystemCollector::new()
            .schedule(Schedule::every(sampling))
            .top_processes(8),
    )?;
    let mac = app.macmon(MacmonCollector::new().schedule(Schedule::every(sampling)))?;
    let disk_io = app.disk_io(DiskIoCollector::new().schedule(Schedule::every(sampling)))?;
    let backup_logs = TextFileSet::new(home.join(".local/log")).matching(|name| {
        name.strip_prefix("backup-home-")
            .and_then(|suffix| suffix.strip_suffix(".log"))
            .and_then(|suffix| suffix.as_bytes().first())
            .is_some_and(u8::is_ascii_digit)
    });
    let backup = app.metric::<CompactStatus>(
        "backup",
        Schedule::every(Duration::from_secs(30)),
        move || {
            let logs = backup_logs.read()?;
            let latest = logs
                .first()
                .ok_or_else(|| CollectError::new("no backup logs"))?;
            let saved = logs
                .iter()
                .find(|log| log.contains_all(["snapshot ", " saved"]))
                .ok_or_else(|| CollectError::new("no saved backup snapshot"))?;
            let light = if latest.contains("FATAL:") {
                StatusLight::Red
            } else if latest.contains("Warning: at least one source file could not be read") {
                StatusLight::Amber
            } else if latest.contains_all(["snapshot ", " saved"]) {
                StatusLight::Green
            } else if latest.age()? <= Duration::from_secs(5 * 60) {
                StatusLight::Blue
            } else {
                StatusLight::Red
            };
            Ok(CompactStatusValue::new("☁️", "💾", light)
                .age(saved.age()?)
                .glyph_scale(0.55))
        },
    )?;

    // ── wyrm · the vacationvm deploy box (sweater.vac.fere.me) ───────────
    // One SSH probe per cycle gathers everything; every wyrm metric reads the
    // shared snapshot, so the server sees a single short connection every
    // five minutes. Numbers go dark ("--") whenever the latest probe failed —
    // only the status light and the risk line keep reporting, in red.
    let wyrm_probe = Arc::new(WyrmProbe::new());
    let wyrm_schedule = Schedule::every(WYRM_CADENCE);
    let probe = Arc::clone(&wyrm_probe);
    let wyrm_status = app.metric::<CompactStatus>("wyrm.status", wyrm_schedule, move || {
        let reading = probe.reading();
        let Some((age, snapshot)) = reading.snapshot else {
            let message = reading
                .error
                .unwrap_or_else(|| "no sample yet".to_owned());
            return Err(CollectError::new(format!("wyrm unreachable: {message}")));
        };
        let light = if reading.error.is_some() {
            StatusLight::Red
        } else {
            snapshot.risk().0
        };
        Ok(CompactStatusValue::new("🐉", "☁️", light)
            .age(age)
            .glyph_scale(0.7))
    })?;
    let probe = Arc::clone(&wyrm_probe);
    let wyrm_risk = app.metric::<Text>("wyrm.risk", wyrm_schedule, move || {
        let reading = probe.reading();
        if reading.error.is_some() {
            return Ok("unreachable".to_owned());
        }
        match reading.snapshot {
            Some((_, snapshot)) => Ok(snapshot.risk().1),
            None => Ok("no contact yet".to_owned()),
        }
    })?;
    let probe = Arc::clone(&wyrm_probe);
    let wyrm_load1 = app.metric::<Number>("wyrm.load1", wyrm_schedule, move || {
        Ok(probe.snapshot()?.load1)
    })?;
    let probe = Arc::clone(&wyrm_probe);
    let wyrm_load5 = app.metric::<Number>("wyrm.load5", wyrm_schedule, move || {
        Ok(probe.snapshot()?.load5)
    })?;
    let probe = Arc::clone(&wyrm_probe);
    let wyrm_failed = app.metric::<Count>("wyrm.units.failed", wyrm_schedule, move || {
        Ok(probe.snapshot()?.failed_units.len() as u64)
    })?;
    let probe = Arc::clone(&wyrm_probe);
    let wyrm_mem_ratio = app.metric::<Ratio>("wyrm.mem.ratio", wyrm_schedule, move || {
        Ok(probe.snapshot()?.mem_used_ratio())
    })?;
    let probe = Arc::clone(&wyrm_probe);
    let wyrm_mem_avail = app.metric::<Bytes>("wyrm.mem.avail", wyrm_schedule, move || {
        Ok(probe.snapshot()?.mem_avail)
    })?;
    let probe = Arc::clone(&wyrm_probe);
    let wyrm_swap_used = app.metric::<Bytes>("wyrm.swap.used", wyrm_schedule, move || {
        Ok(probe.snapshot()?.swap_used())
    })?;
    let probe = Arc::clone(&wyrm_probe);
    let wyrm_disk_ratio = app.metric::<Ratio>("wyrm.disk.ratio", wyrm_schedule, move || {
        Ok(probe.snapshot()?.disk_used_ratio())
    })?;
    let probe = Arc::clone(&wyrm_probe);
    let wyrm_disk_avail = app.metric::<Bytes>("wyrm.disk.avail", wyrm_schedule, move || {
        Ok(probe.snapshot()?.disk_avail)
    })?;
    let probe = Arc::clone(&wyrm_probe);
    let wyrm_uptime = app.metric::<DurationSeconds>("wyrm.uptime", wyrm_schedule, move || {
        Ok(probe.snapshot()?.uptime_seconds)
    })?;

    let cpu = Widget::from(Stat::new("CPU load", &mac.cpu_total).percent());
    let gpu = Widget::from(Stat::new("GPU load", &mac.gpu_ratio).percent());
    let gpu_frequency = Widget::from(Stat::new("GPU MHz", &mac.gpu_frequency).megahertz());
    let cpu_temp = Widget::from(Stat::new("CPU °C", &mac.cpu_temperature).celsius());
    let gpu_temp = Widget::from(Stat::new("GPU °C", &mac.gpu_temperature).celsius());
    let p_ratio = Widget::from(Stat::new("P-core load", &mac.p_cpu_ratio).percent());
    let p_frequency = Widget::from(Stat::new("P MHz", &mac.p_cpu_frequency).megahertz());
    let e_ratio = Widget::from(Stat::new("E-core load", &mac.e_cpu_ratio).percent());
    let e_frequency = Widget::from(Stat::new("E MHz", &mac.e_cpu_frequency).megahertz());
    let cpu_power = Widget::from(Stat::new("CPU W", &mac.cpu_power).watts());
    let gpu_power = Widget::from(Stat::new("GPU W", &mac.gpu_power).watts());
    let ram_used = Widget::from(Stat::new("RAM used", &mac.ram_used).bytes());
    let ram_total = Widget::from(Stat::new("RAM total", &mac.ram_total).bytes());
    let ram_ratio = Widget::from(
        Gauge::new("RAM utilization", &mac.ram_ratio)
            .percent()
            .accent("purple"),
    );
    let swap_used = Widget::from(Stat::new("Swap used", &mac.swap_used).bytes());
    let swap_total = Widget::from(Stat::new("Swap total", &mac.swap_total).bytes());
    let swap_ratio = Widget::from(
        Gauge::new("Swap utilization", &mac.swap_ratio)
            .percent()
            .accent("blue"),
    );
    let disk_free = Widget::from(Stat::new("SSD free", &system.root_disk_available).bytes());
    let disk_used = Widget::from(
        Gauge::new("SSD utilization", &system.root_disk_ratio)
            .percent()
            .accent("orange"),
    );
    let disk_read = Widget::from(Stat::new("SSD read", &disk_io.read).bytes_per_second());
    let disk_write = Widget::from(Stat::new("SSD write", &disk_io.write).bytes_per_second());
    let network_down = Widget::from(Stat::new("Download", &system.network_down).bytes_per_second());
    let network_up = Widget::from(Stat::new("Upload", &system.network_up).bytes_per_second());
    let processes = Widget::from(TableWidget::new("processes", &system.top_processes));
    let backup = Widget::from(CompactStatusWidget::new("backup", &backup));
    let processor_activity = Widget::from(
        Plot::new(
            "CPU / GPU LOAD (0-100%)",
            vec![
                PlotSeries::new(&mac.cpu_total, "cyan"),
                PlotSeries::new(&mac.gpu_ratio, "blue"),
            ],
        )
        .history(90),
    );
    let disk_activity = Widget::from(
        Plot::new(
            "SSD I/O RATE",
            vec![
                PlotSeries::new(&disk_io.read, "amber"),
                PlotSeries::new(&disk_io.write, "purple"),
            ],
        )
        .history(90),
    );

    // Accents rhyme with the local surface: purple = RAM, orange = disk,
    // cyan/blue = load series. Risk state lives only in the status light.
    let wyrm_status_row = Widget::from(CompactStatusWidget::new("wyrm · vac.fere.me", &wyrm_status));
    let wyrm_risk_row = Widget::from(Stat::new("risk", &wyrm_risk));
    let wyrm_load_stat = Widget::from(Stat::new("load 1m", &wyrm_load1));
    let wyrm_failed_stat = Widget::from(Stat::new("failed units", &wyrm_failed));
    let wyrm_mem_stat = Widget::from(Stat::new("RAM free", &wyrm_mem_avail).bytes());
    let wyrm_disk_stat = Widget::from(Stat::new("disk free", &wyrm_disk_avail).bytes());
    let wyrm_swap_stat = Widget::from(Stat::new("swap used", &wyrm_swap_used).bytes());
    let wyrm_uptime_stat = Widget::from(Stat::new("uptime", &wyrm_uptime));
    let wyrm_mem_gauge = Widget::from(
        Gauge::new("RAM pressure", &wyrm_mem_ratio)
            .percent()
            .accent("purple"),
    );
    let wyrm_disk_gauge = Widget::from(
        Gauge::new("disk pressure", &wyrm_disk_ratio)
            .percent()
            .accent("orange"),
    );
    // 96 samples ≈ 8h when full, but history restarts empty on each reload
    // and the plot stretches what it has — the label must not promise a span.
    let wyrm_load_plot = Widget::from(
        Plot::new(
            "LOAD · 5-MIN STEPS",
            vec![
                PlotSeries::new(&wyrm_load1, "cyan"),
                PlotSeries::new(&wyrm_load5, "blue"),
            ],
        )
        .history(96),
    );

    let mut surfaces = Vec::new();
    if desktop_enabled {
        surfaces.push(
            Surface::desktop(LayoutNode::stack(
                16.0,
                vec![
                    LayoutNode::section(
                        "PERF",
                        Insets::all(16.0),
                        LayoutNode::stack(
                            12.0,
                            vec![
                                LayoutNode::flow(
                                    16.0,
                                    12.0,
                                    120.0,
                                    vec![
                                        LayoutNode::widget(cpu.clone()),
                                        LayoutNode::widget(gpu.clone()),
                                        LayoutNode::widget(gpu_frequency.clone()),
                                        LayoutNode::widget(cpu_temp.clone()),
                                        LayoutNode::widget(gpu_temp.clone()),
                                        LayoutNode::widget(p_ratio.clone()),
                                        LayoutNode::widget(p_frequency.clone()),
                                        LayoutNode::widget(e_ratio.clone()),
                                        LayoutNode::widget(e_frequency.clone()),
                                        LayoutNode::widget(cpu_power.clone()),
                                        LayoutNode::widget(gpu_power.clone()),
                                    ],
                                ),
                                LayoutNode::widget(processor_activity.clone()),
                            ],
                        ),
                    ),
                    LayoutNode::section(
                        "MEM",
                        Insets::all(16.0),
                        LayoutNode::stack(
                            12.0,
                            vec![
                                LayoutNode::flow(
                                    16.0,
                                    12.0,
                                    120.0,
                                    vec![
                                        LayoutNode::widget(ram_used.clone()),
                                        LayoutNode::widget(ram_total.clone()),
                                        LayoutNode::widget(swap_used.clone()),
                                        LayoutNode::widget(swap_total.clone()),
                                    ],
                                ),
                                LayoutNode::flow(
                                    16.0,
                                    12.0,
                                    240.0,
                                    vec![
                                        LayoutNode::widget(ram_ratio.clone()),
                                        LayoutNode::widget(swap_ratio.clone()),
                                    ],
                                ),
                            ],
                        ),
                    ),
                    LayoutNode::section(
                        "DISK",
                        Insets::all(16.0),
                        LayoutNode::stack(
                            12.0,
                            vec![
                                LayoutNode::flow(
                                    16.0,
                                    12.0,
                                    130.0,
                                    vec![
                                        LayoutNode::widget(disk_free.clone()),
                                        LayoutNode::widget(disk_read.clone()),
                                        LayoutNode::widget(disk_write.clone()),
                                        LayoutNode::widget(backup.clone()),
                                    ],
                                ),
                                LayoutNode::widget(disk_used.clone()),
                                LayoutNode::widget(disk_activity.clone()),
                            ],
                        ),
                    ),
                    LayoutNode::section(
                        "NET",
                        Insets::all(16.0),
                        LayoutNode::flow(
                            16.0,
                            12.0,
                            240.0,
                            vec![
                                LayoutNode::widget(network_down.clone()),
                                LayoutNode::widget(network_up.clone()),
                            ],
                        ),
                    ),
                    LayoutNode::section(
                        "PROC",
                        Insets::all(16.0),
                        LayoutNode::widget(processes.clone()),
                    ),
                ],
            ))
            .position(32.0, 32.0, SurfaceOrigin::BottomLeft)
            .width(640.0)
            .content_inset(16.0)
            .background_opacity(desktop_background_opacity)
            .click_through(true),
        );
    }
    if wyrm_watch_enabled {
        surfaces.push(
            Surface::desktop(LayoutNode::section(
                "WYRM",
                Insets::all(14.0),
                LayoutNode::stack(
                    10.0,
                    vec![
                        LayoutNode::widget(wyrm_status_row),
                        LayoutNode::widget(wyrm_risk_row),
                        LayoutNode::flow(
                            14.0,
                            8.0,
                            128.0,
                            vec![
                                LayoutNode::widget(wyrm_load_stat),
                                LayoutNode::widget(wyrm_failed_stat),
                                LayoutNode::widget(wyrm_mem_stat),
                                LayoutNode::widget(wyrm_disk_stat),
                                LayoutNode::widget(wyrm_swap_stat),
                                LayoutNode::widget(wyrm_uptime_stat),
                            ],
                        ),
                        LayoutNode::widget(wyrm_mem_gauge),
                        LayoutNode::widget(wyrm_disk_gauge),
                        LayoutNode::widget(wyrm_load_plot),
                    ],
                ),
            ))
            .position(32.0, 32.0, SurfaceOrigin::BottomRight)
            .width(340.0)
            .content_inset(14.0)
            .background_opacity(desktop_background_opacity)
            .click_through(true),
        );
    }
    if widget_large_enabled {
        surfaces.push(Surface::widget_large(LayoutNode::stack(
            8.0,
            vec![
                LayoutNode::section(
                    "perf",
                    Insets::all(6.0),
                    LayoutNode::stack(
                        6.0,
                        vec![
                            LayoutNode::flow(
                                5.0,
                                5.0,
                                100.0,
                                vec![
                                    LayoutNode::widget(cpu.clone()),
                                    LayoutNode::widget(gpu.clone()),
                                    LayoutNode::widget(gpu_frequency.clone()),
                                    LayoutNode::widget(cpu_temp.clone()),
                                    LayoutNode::widget(gpu_temp.clone()),
                                    LayoutNode::widget(cpu_power.clone()),
                                    LayoutNode::widget(gpu_power.clone()),
                                ],
                            ),
                            LayoutNode::widget(processor_activity.clone()),
                        ],
                    ),
                ),
                LayoutNode::section(
                    "disk + net",
                    Insets::all(6.0),
                    LayoutNode::stack(
                        8.0,
                        vec![
                            LayoutNode::flow(
                                8.0,
                                8.0,
                                108.0,
                                vec![
                                    LayoutNode::widget(disk_free.clone()),
                                    LayoutNode::widget(disk_read.clone()),
                                    LayoutNode::widget(disk_write.clone()),
                                    LayoutNode::widget(network_down.clone()),
                                    LayoutNode::widget(network_up.clone()),
                                ],
                            ),
                            LayoutNode::widget(disk_used.clone()),
                            LayoutNode::widget(backup.clone()),
                        ],
                    ),
                ),
            ],
        )));
    }
    if widget_medium_enabled {
        surfaces.push(Surface::widget_medium(LayoutNode::split(
            8.0,
            140.0,
            vec![
                LayoutTrack::new(
                    2.0,
                    LayoutNode::flow(
                        5.0,
                        5.0,
                        86.0,
                        vec![
                            LayoutNode::widget(cpu.clone()),
                            LayoutNode::widget(gpu.clone()),
                            LayoutNode::widget(cpu_temp.clone()),
                            LayoutNode::widget(gpu_temp.clone()),
                        ],
                    ),
                ),
                LayoutTrack::new(
                    1.0,
                    LayoutNode::flow(
                        5.0,
                        5.0,
                        96.0,
                        vec![
                            LayoutNode::widget(disk_free.clone()),
                            LayoutNode::widget(network_down.clone()),
                            LayoutNode::widget(backup.clone()),
                        ],
                    ),
                ),
            ],
        )));
    }
    if widget_small_enabled {
        surfaces.push(Surface::widget_small(LayoutNode::flow(
            4.0,
            4.0,
            76.0,
            vec![
                LayoutNode::widget(cpu),
                LayoutNode::widget(gpu),
                LayoutNode::widget(cpu_temp),
                LayoutNode::widget(backup),
            ],
        )));
    }
    app.set_surfaces(surfaces);
    Ok(app)
}

fn main() {
    if let Err(error) = configure().and_then(|app| app.run().map_err(Into::into)) {
        eprintln!("wallstats: {error}");
        std::process::exit(1);
    }
}

// ── wyrm probe machinery ─────────────────────────────────────────────────

const WYRM_TARGET: &str = "root@35.175.171.155";
const WYRM_CADENCE: Duration = Duration::from_secs(5 * 60);

// Everything in one round-trip, one `key value` pair per line. The trailing
// `end` marker distinguishes a complete transcript from a dropped connection.
const WYRM_PROBE_SCRIPT: &str = concat!(
    "read l1 l5 l15 rest < /proc/loadavg; echo \"load1 $l1\"; echo \"load5 $l5\"; ",
    "read up idle < /proc/uptime; echo \"uptime $up\"; ",
    "echo \"cores $(nproc)\"; ",
    "awk '/^MemTotal:/{print \"mem_total\",$2*1024} ",
    "/^MemAvailable:/{print \"mem_avail\",$2*1024} ",
    "/^SwapTotal:/{print \"swap_total\",$2*1024} ",
    "/^SwapFree:/{print \"swap_free\",$2*1024}' /proc/meminfo; ",
    "df -B1 --output=size,avail / | awk 'NR==2{print \"disk_total\",$1; print \"disk_avail\",$2}'; ",
    "systemctl list-units --state=failed --plain --no-legend --no-pager | awk '{print \"failed_unit\",$1}'; ",
    "echo end"
);

#[derive(Clone)]
struct WyrmSnapshot {
    load1: f64,
    load5: f64,
    uptime_seconds: f64,
    cores: f64,
    mem_total: u64,
    mem_avail: u64,
    swap_total: u64,
    swap_free: u64,
    disk_total: u64,
    disk_avail: u64,
    failed_units: Vec<String>,
}

impl WyrmSnapshot {
    fn mem_used_ratio(&self) -> f64 {
        let total = self.mem_total.max(1) as f64;
        ((total - self.mem_avail as f64) / total).clamp(0.0, 1.0)
    }

    fn swap_used(&self) -> u64 {
        self.swap_total.saturating_sub(self.swap_free)
    }

    fn disk_used_ratio(&self) -> f64 {
        let total = self.disk_total.max(1) as f64;
        ((total - self.disk_avail as f64) / total).clamp(0.0, 1.0)
    }

    // The single headline the panel shows: the worst active condition wins.
    // Thresholds are sized for the actual box (t3.medium: 2 vCPUs, 4 GB RAM).
    fn risk(&self) -> (StatusLight, String) {
        let cores = self.cores.max(1.0);
        if let [first, rest @ ..] = self.failed_units.as_slice() {
            let name: String = first.trim_end_matches(".service").chars().take(22).collect();
            let headline = if rest.is_empty() {
                format!("{name} failed")
            } else {
                format!("{name} +{} failed", rest.len())
            };
            return (StatusLight::Red, headline);
        }
        let disk = self.disk_used_ratio();
        let mem_left = self.mem_avail as f64 / self.mem_total.max(1) as f64;
        let swap = self.swap_used();
        if disk > 0.92 {
            return (StatusLight::Red, format!("disk {:.0}% full", disk * 100.0));
        }
        if mem_left < 0.07 {
            return (StatusLight::Red, format!("ram low: {} left", human_bytes(self.mem_avail)));
        }
        if swap > self.mem_total / 2 {
            return (StatusLight::Red, format!("swap {} hot", human_bytes(swap)));
        }
        if self.load5 > cores * 2.0 {
            return (StatusLight::Red, format!("load {:.1} on {:.0}c", self.load5, cores));
        }
        if disk > 0.82 {
            return (StatusLight::Amber, format!("disk {:.0}% full", disk * 100.0));
        }
        if mem_left < 0.15 {
            return (StatusLight::Amber, format!("ram {} left", human_bytes(self.mem_avail)));
        }
        if swap > self.mem_total / 4 {
            return (StatusLight::Amber, format!("swap {} in use", human_bytes(swap)));
        }
        if self.load5 > cores {
            return (StatusLight::Amber, format!("load {:.1} on {:.0}c", self.load5, cores));
        }
        (StatusLight::Green, "steady".to_owned())
    }
}

struct WyrmReading {
    // Age and content of the last good sample, if any probe ever succeeded.
    snapshot: Option<(Duration, WyrmSnapshot)>,
    // Present while the most recent probe failed.
    error: Option<String>,
}

#[derive(Default)]
struct WyrmProbeState {
    attempted_at: Option<Instant>,
    fetched: Option<(Instant, WyrmSnapshot)>,
    error: Option<String>,
}

struct WyrmProbe {
    state: Mutex<WyrmProbeState>,
}

impl WyrmProbe {
    fn new() -> Self {
        Self {
            state: Mutex::new(WyrmProbeState::default()),
        }
    }

    // The first wyrm collector to arrive each cycle runs the SSH probe while
    // holding the lock; its siblings block those few seconds and then read the
    // fresh snapshot. The guard sits below the cadence so one connection
    // serves the whole cycle.
    fn reading(&self) -> WyrmReading {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let due = state.attempted_at.map_or(true, |at| {
            at.elapsed() >= WYRM_CADENCE - Duration::from_secs(30)
        });
        if due {
            state.attempted_at = Some(Instant::now());
            match fetch_wyrm() {
                Ok(snapshot) => {
                    state.fetched = Some((Instant::now(), snapshot));
                    state.error = None;
                }
                Err(message) => {
                    eprintln!("wyrm probe: {message}");
                    state.error = Some(message);
                }
            }
        }
        WyrmReading {
            snapshot: state
                .fetched
                .as_ref()
                .map(|(at, snapshot)| (at.elapsed(), snapshot.clone())),
            error: state.error.clone(),
        }
    }

    // Typed metrics show a value only while the latest probe succeeded;
    // otherwise they surface the failure and the panel renders "--".
    fn snapshot(&self) -> Result<WyrmSnapshot, CollectError> {
        let reading = self.reading();
        if let Some(message) = reading.error {
            return Err(CollectError::new(format!("wyrm unreachable: {message}")));
        }
        reading
            .snapshot
            .map(|(_, snapshot)| snapshot)
            .ok_or_else(|| CollectError::new("no wyrm sample yet"))
    }
}

fn fetch_wyrm() -> Result<WyrmSnapshot, String> {
    let output = Command::new("/usr/bin/ssh")
        .args([
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "-T",
            WYRM_TARGET,
            WYRM_PROBE_SCRIPT,
        ])
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("cannot run ssh: {error}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let detail = stderr
            .lines()
            .rev()
            .map(str::trim)
            .find(|line| !line.is_empty())
            .unwrap_or("no diagnostics")
            .to_owned();
        return Err(format!("ssh {}: {detail}", output.status));
    }
    parse_wyrm(&String::from_utf8_lossy(&output.stdout))
}

fn parse_wyrm(transcript: &str) -> Result<WyrmSnapshot, String> {
    let mut load1 = None;
    let mut load5 = None;
    let mut uptime_seconds = None;
    let mut cores = None;
    let mut mem_total = None;
    let mut mem_avail = None;
    let mut swap_total = None;
    let mut swap_free = None;
    let mut disk_total = None;
    let mut disk_avail = None;
    let mut failed_units = Vec::new();
    let mut complete = false;

    for line in transcript.lines() {
        let mut parts = line.split_whitespace();
        let Some(key) = parts.next() else { continue };
        let value = parts.next();
        match key {
            "load1" => load1 = value.and_then(|v| v.parse::<f64>().ok()),
            "load5" => load5 = value.and_then(|v| v.parse::<f64>().ok()),
            "uptime" => uptime_seconds = value.and_then(|v| v.parse::<f64>().ok()),
            "cores" => cores = value.and_then(|v| v.parse::<f64>().ok()),
            "mem_total" => mem_total = value.and_then(|v| v.parse::<u64>().ok()),
            "mem_avail" => mem_avail = value.and_then(|v| v.parse::<u64>().ok()),
            "swap_total" => swap_total = value.and_then(|v| v.parse::<u64>().ok()),
            "swap_free" => swap_free = value.and_then(|v| v.parse::<u64>().ok()),
            "disk_total" => disk_total = value.and_then(|v| v.parse::<u64>().ok()),
            "disk_avail" => disk_avail = value.and_then(|v| v.parse::<u64>().ok()),
            "failed_unit" => failed_units.extend(value.map(str::to_owned)),
            "end" => complete = true,
            _ => {}
        }
    }

    if !complete {
        return Err("probe transcript was truncated".to_owned());
    }
    let field = |value: Option<f64>, name: &str| {
        value.ok_or_else(|| format!("probe transcript is missing {name}"))
    };
    let bytes = |value: Option<u64>, name: &str| {
        value.ok_or_else(|| format!("probe transcript is missing {name}"))
    };
    Ok(WyrmSnapshot {
        load1: field(load1, "load1")?,
        load5: field(load5, "load5")?,
        uptime_seconds: field(uptime_seconds, "uptime")?,
        cores: field(cores, "cores")?,
        mem_total: bytes(mem_total, "mem_total")?,
        mem_avail: bytes(mem_avail, "mem_avail")?,
        swap_total: bytes(swap_total, "swap_total")?,
        swap_free: bytes(swap_free, "swap_free")?,
        disk_total: bytes(disk_total, "disk_total")?,
        disk_avail: bytes(disk_avail, "disk_avail")?,
        failed_units,
    })
}

fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 7] = ["B", "K", "M", "G", "T", "P", "E"];
    let mut amount = bytes as f64;
    let mut unit = 0;
    while amount >= 1024.0 && unit < UNITS.len() - 1 {
        amount /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes}B")
    } else if amount < 10.0 {
        format!("{amount:.1}{}", UNITS[unit])
    } else {
        format!("{amount:.0}{}", UNITS[unit])
    }
}
