//! Typed configuration and collection runtime for Wallstats.
//!
//! A configuration registers typed metrics, lays them out with typed widget
//! builders, and finally calls [`App::run`]. The runtime writes protocol v1
//! JSON Lines to stdout. It never invokes a shell.

#![forbid(unsafe_code)]
#![warn(missing_docs)]

mod app;
mod command;
mod collector;
mod disk_io;
mod error;
mod id;
mod layout;
mod macmon;
mod metric;
mod system;
mod text_file;
mod widget;

pub use app::{Anchor, App, Layer, Schedule, Window};
pub use collector::{
    CollectError, CollectResult, Collector, FileNumberCollector, LogCountBuilder,
    LogCountCollector, LogCountConfigError,
};
pub use disk_io::{DiskIoCollector, DiskIoMetrics};
pub use error::{ConfigError, Error, Result};
pub use id::{MetricId, MetricIdError};
pub use layout::{Insets, LayoutNode, LayoutTrack, Surface, SurfaceKind};
pub use macmon::{MacmonCollector, MacmonMetrics};
pub use metric::{
    Boolean, Bytes, BytesPerSecond, CompactStatus, CompactStatusValue, CompactStatusValueError,
    Count, DurationSeconds, Metric, Number, Ratio, StatusLight, Table, TableValue, TableValueError,
    Text, WireType,
};
#[doc(hidden)]
pub use metric::WireValue;
pub use system::{SystemCollector, SystemMetrics};
pub use text_file::{MAX_TEXT_FILE_TAIL_BYTES, TextFile, TextFileSet};
pub use widget::{
    CompactStatusWidget, Gauge, GaugeMetric, Plot, PlotSeries, ScalarMetric, Section, Sparkline,
    Stat, TableWidget, ValueMetric, Widget,
};

/// The protocol major version emitted by this crate.
pub const PROTOCOL_MAJOR: u32 = 1;

/// The protocol minor version emitted by this crate.
pub const PROTOCOL_MINOR: u32 = 0;

/// The SDK version reported in the protocol `hello` record.
pub const SDK_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Maximum JSON bytes in one protocol record, excluding its newline.
pub const MAX_PROTOCOL_RECORD_BYTES: usize = 1024 * 1024;

/// Builds a `Vec<Widget>` while converting typed widget builders.
///
/// ```
/// # use wallstats::{Metric, Ratio, Sparkline, widgets};
/// # fn example(cpu: Metric<Ratio>) {
/// let row = widgets![Sparkline::new("CPU", cpu).percent()];
/// # let _ = row;
/// # }
/// ```
#[macro_export]
macro_rules! widgets {
    ($($widget:expr),* $(,)?) => {
        ::std::vec![$(::core::convert::Into::<$crate::Widget>::into($widget)),*]
    };
}

/// Builds a `Vec<Section>` from readable `title => widgets` entries.
///
/// ```
/// # use wallstats::{Metric, Ratio, Sparkline, sections, widgets};
/// # fn example(cpu: Metric<Ratio>) {
/// let layout = sections![
///     "Performance" => widgets![Sparkline::new("CPU", cpu).percent()],
/// ];
/// # let _ = layout;
/// # }
/// ```
#[macro_export]
macro_rules! sections {
    ($($title:expr => $widgets:expr),* $(,)?) => {
        ::std::vec![$($crate::Section::new($title, $widgets)),*]
    };
    ($($section:expr),* $(,)?) => {
        ::std::vec![$($section),*]
    };
}

/// Builds a `Vec<Surface>` for [`App::set_surfaces`].
#[macro_export]
macro_rules! surfaces {
    ($($surface:expr),* $(,)?) => {
        ::std::vec![$($surface),*]
    };
}
