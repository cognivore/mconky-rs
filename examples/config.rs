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
    Gauge, Insets, LayoutNode, LayoutTrack, MacmonCollector, Plot, PlotSeries, Schedule, Stat,
    StatusLight, Surface, SurfaceOrigin, SystemCollector, TableWidget, TextFileSet, Widget, Window,
};

fn configure() -> Result<App, Box<dyn Error>> {
    let home = env::var_os("HOME").map(PathBuf::from).ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, "HOME is not set")
    })?;
    let desktop_enabled = true;
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

    let cpu = Widget::from(Stat::new("CPU", &mac.cpu_total).percent());
    let gpu = Widget::from(Stat::new("GPU", &mac.gpu_ratio).percent());
    let gpu_frequency = Widget::from(Stat::new("GPU MHz", &mac.gpu_frequency).megahertz());
    let cpu_temp = Widget::from(Stat::new("CPU °C", &mac.cpu_temperature).celsius());
    let gpu_temp = Widget::from(Stat::new("GPU °C", &mac.gpu_temperature).celsius());
    let p_ratio = Widget::from(Stat::new("P", &mac.p_cpu_ratio).percent());
    let p_frequency = Widget::from(Stat::new("P MHz", &mac.p_cpu_frequency).megahertz());
    let e_ratio = Widget::from(Stat::new("E", &mac.e_cpu_ratio).percent());
    let e_frequency = Widget::from(Stat::new("E MHz", &mac.e_cpu_frequency).megahertz());
    let cpu_power = Widget::from(Stat::new("CPU W", &mac.cpu_power).watts());
    let gpu_power = Widget::from(Stat::new("GPU W", &mac.gpu_power).watts());
    let ram_used = Widget::from(Stat::new("RAM", &mac.ram_used).bytes());
    let ram_total = Widget::from(Stat::new("RAM total", &mac.ram_total).bytes());
    let ram_ratio = Widget::from(
        Gauge::new("RAM used", &mac.ram_ratio)
            .percent()
            .accent("purple"),
    );
    let swap_used = Widget::from(Stat::new("swap", &mac.swap_used).bytes());
    let swap_total = Widget::from(Stat::new("swap total", &mac.swap_total).bytes());
    let swap_ratio = Widget::from(
        Gauge::new("swap used", &mac.swap_ratio)
            .percent()
            .accent("blue"),
    );
    let disk_free = Widget::from(Stat::new("free", &system.root_disk_available).bytes());
    let disk_used = Widget::from(
        Gauge::new("used", &system.root_disk_ratio)
            .percent()
            .accent("orange"),
    );
    let disk_read = Widget::from(Stat::new("read", &disk_io.read).bytes_per_second());
    let disk_write = Widget::from(Stat::new("write", &disk_io.write).bytes_per_second());
    let network_down = Widget::from(Stat::new("down", &system.network_down).bytes_per_second());
    let network_up = Widget::from(Stat::new("up", &system.network_up).bytes_per_second());
    let processes = Widget::from(TableWidget::new("processes", &system.top_processes));
    let backup = Widget::from(CompactStatusWidget::new("backup", &backup));
    let activity = Widget::from(
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
    );

    let mut surfaces = Vec::new();
    if desktop_enabled {
        surfaces.push(
            Surface::desktop(LayoutNode::stack(
                10.0,
                vec![
                    LayoutNode::section(
                        "PERF",
                        Insets::symmetric(6.0, 8.0),
                        LayoutNode::stack(
                            8.0,
                            vec![
                                LayoutNode::flow(
                                    6.0,
                                    6.0,
                                    100.0,
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
                                LayoutNode::widget(activity.clone()),
                            ],
                        ),
                    ),
                    LayoutNode::section(
                        "MEM",
                        Insets::symmetric(6.0, 8.0),
                        LayoutNode::flow(
                            6.0,
                            6.0,
                            104.0,
                            vec![
                                LayoutNode::widget(ram_used.clone()),
                                LayoutNode::widget(ram_total.clone()),
                                LayoutNode::widget(ram_ratio.clone()),
                                LayoutNode::widget(swap_used.clone()),
                                LayoutNode::widget(swap_total.clone()),
                                LayoutNode::widget(swap_ratio.clone()),
                            ],
                        ),
                    ),
                    LayoutNode::section(
                        "DISK",
                        Insets::symmetric(6.0, 8.0),
                        LayoutNode::flow(
                            6.0,
                            6.0,
                            100.0,
                            vec![
                                LayoutNode::widget(disk_free.clone()),
                                LayoutNode::widget(disk_used.clone()),
                                LayoutNode::widget(disk_read.clone()),
                                LayoutNode::widget(disk_write.clone()),
                                LayoutNode::widget(backup.clone()),
                            ],
                        ),
                    ),
                    LayoutNode::section(
                        "NET",
                        Insets::symmetric(6.0, 8.0),
                        LayoutNode::flow(
                            6.0,
                            6.0,
                            160.0,
                            vec![
                                LayoutNode::widget(network_down.clone()),
                                LayoutNode::widget(network_up.clone()),
                            ],
                        ),
                    ),
                    LayoutNode::section(
                        "PROC",
                        Insets::symmetric(6.0, 8.0),
                        LayoutNode::widget(processes.clone()),
                    ),
                ],
            ))
            .position(32.0, 32.0, SurfaceOrigin::BottomLeft)
            .width(480.0)
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
                            LayoutNode::widget(activity.clone()),
                        ],
                    ),
                ),
                LayoutNode::section(
                    "disk + net",
                    Insets::all(6.0),
                    LayoutNode::flow(
                        5.0,
                        5.0,
                        108.0,
                        vec![
                            LayoutNode::widget(disk_free.clone()),
                            LayoutNode::widget(disk_used.clone()),
                            LayoutNode::widget(disk_read.clone()),
                            LayoutNode::widget(disk_write.clone()),
                            LayoutNode::widget(network_down.clone()),
                            LayoutNode::widget(network_up.clone()),
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
