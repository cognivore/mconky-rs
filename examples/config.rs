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
use std::time::Duration;
use wallstats::{
    App, CollectError, CompactStatus, CompactStatusValue, CompactStatusWidget, DiskIoCollector,
    Gauge, MacmonCollector, Plot, PlotSeries, Schedule, Section, Stat, StatusLight,
    SystemCollector, TextFileSet, Window, sections, widgets,
};

fn configure() -> Result<App, Box<dyn Error>> {
    let home = env::var_os("HOME").map(PathBuf::from).ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, "HOME is not set")
    })?;
    let mut app = App::new("SEPTNESIS");
    app.set_window(Window::desktop().width(420).margin(20).opacity(0.94));

    let system = app.system(
        SystemCollector::new()
            .schedule(
                Schedule::every(Duration::from_secs(1))
                    .stale_after(Duration::from_secs(3)),
            )
            .top_processes(8),
    )?;
    let mac = app.macmon(MacmonCollector::new())?;
    let disk_io = app.disk_io(DiskIoCollector::new())?;
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

    app.set_sections(sections![
        Section::new(
            "perf",
            widgets![
                Stat::new("CPU", &mac.cpu_total).percent(),
                Stat::new("GPU", &mac.gpu_ratio).percent(),
                Stat::new("CPU °C", &mac.cpu_temperature).celsius(),
                Stat::new("GPU °C", &mac.gpu_temperature).celsius(),
                Stat::new("P", &mac.p_cpu_ratio).percent(),
                Stat::new("P MHz", &mac.p_cpu_frequency).megahertz(),
                Stat::new("E", &mac.e_cpu_ratio).percent(),
                Stat::new("E MHz", &mac.e_cpu_frequency).megahertz(),
                Stat::new("CPU W", &mac.cpu_power).watts(),
                Stat::new("GPU W", &mac.gpu_power).watts(),
                Plot::new(
                    "activity",
                    vec![
                        PlotSeries::new(&mac.cpu_total, "cyan"),
                        PlotSeries::new(&mac.gpu_ratio, "blue"),
                        PlotSeries::new(&disk_io.read, "amber"),
                        PlotSeries::new(&disk_io.write, "purple"),
                    ],
                )
                .history(90),
            ],
        )
        .weight(6),
        Section::new(
            "disk",
            widgets![
                Stat::new("free", &system.root_disk_available).bytes(),
                Gauge::new("used", &system.root_disk_ratio)
                    .percent()
                    .accent("orange"),
                CompactStatusWidget::new("backup", &backup),
            ],
        )
        .weight(2),
        Section::new(
            "net",
            widgets![
                Stat::new("down", &system.network_down).bytes_per_second(),
                Stat::new("up", &system.network_up).bytes_per_second(),
            ],
        )
        .weight(1),
    ]);
    Ok(app)
}

fn main() {
    if let Err(error) = configure().and_then(|app| app.run().map_err(Into::into)) {
        eprintln!("wallstats: {error}");
        std::process::exit(1);
    }
}
