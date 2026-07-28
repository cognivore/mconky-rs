use crate::metric::WireValue;
use crate::{MetricId, Number, WireType};
use serde::Serialize;
use std::error::Error;
use std::fmt;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::marker::PhantomData;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// A recoverable error collecting one metric.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CollectError {
    message: String,
}

impl CollectError {
    /// Creates a collection error that will be sent in the metric update.
    pub fn new(message: impl Into<String>) -> Self {
        let message = message.into();
        Self {
            message: if message.trim().is_empty() {
                "collector returned an empty error message".to_owned()
            } else {
                message
            },
        }
    }

    /// Returns the protocol-safe error message.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for CollectError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for CollectError {}

/// The result returned by metric collectors.
pub type CollectResult<T> = Result<T, CollectError>;

/// A user-defined typed metric collector.
///
/// Collection failures are values: return [`CollectError`] rather than
/// panicking. The runtime emits that error for this metric and keeps serving.
pub trait Collector<T: WireType>: Send + 'static {
    /// Collects the current metric value.
    fn collect(&mut self) -> CollectResult<T::Value>;
}

impl<T, F> Collector<T> for F
where
    T: WireType,
    F: FnMut() -> CollectResult<T::Value> + Send + 'static,
{
    fn collect(&mut self) -> CollectResult<T::Value> {
        self()
    }
}

pub(crate) trait Source: Send {
    fn name(&self) -> &str;
    fn interval(&self) -> Duration;
    fn collect(&mut self) -> Vec<CollectedMetric>;
}

pub(crate) struct SingleMetricSource<T, C>
where
    T: WireType,
    C: Collector<T>,
{
    id: MetricId,
    interval: Duration,
    collector: C,
    marker: PhantomData<fn() -> T>,
}

impl<T, C> SingleMetricSource<T, C>
where
    T: WireType,
    C: Collector<T>,
{
    pub(crate) fn new(id: MetricId, interval: Duration, collector: C) -> Self {
        Self {
            id,
            interval,
            collector,
            marker: PhantomData,
        }
    }
}

impl<T, C> Source for SingleMetricSource<T, C>
where
    T: WireType,
    C: Collector<T>,
{
    fn name(&self) -> &str {
        self.id.as_str()
    }

    fn interval(&self) -> Duration {
        self.interval
    }

    fn collect(&mut self) -> Vec<CollectedMetric> {
        let outcome = self.collector.collect().and_then(T::into_wire);
        vec![CollectedMetric::from_result(self.id.clone(), outcome)]
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct CollectedMetric {
    metric: MetricId,
    #[serde(flatten)]
    outcome: CollectionOutcome,
}

impl CollectedMetric {
    pub(crate) fn from_result(id: MetricId, result: CollectResult<WireValue>) -> Self {
        match result {
            Ok(value) => Self::value(id, value),
            Err(error) => Self::error(id, error),
        }
    }

    pub(crate) fn value(metric: MetricId, value: WireValue) -> Self {
        Self {
            metric,
            outcome: CollectionOutcome::Value { value },
        }
    }

    pub(crate) fn error(metric: MetricId, error: CollectError) -> Self {
        Self {
            metric,
            outcome: CollectionOutcome::Error {
                error: error.to_string(),
            },
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
enum CollectionOutcome {
    Value { value: WireValue },
    Error { error: String },
}

/// Builder for a bounded, line-oriented text log counter.
#[derive(Clone, Debug)]
pub struct LogCountBuilder {
    path: PathBuf,
    max_tail_bytes: usize,
    needles: Vec<String>,
}

impl LogCountBuilder {
    /// Creates a builder for `path` with a 256 KiB tail bound.
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            max_tail_bytes: 256 * 1024,
            needles: Vec::new(),
        }
    }

    /// Sets the maximum number of bytes read from the end of the file.
    pub fn max_tail_bytes(mut self, max_tail_bytes: usize) -> Self {
        self.max_tail_bytes = max_tail_bytes;
        self
    }

    /// Adds one case-sensitive substring to match.
    pub fn matching(mut self, substring: impl Into<String>) -> Self {
        self.needles.push(substring.into());
        self
    }

    /// Adds multiple case-sensitive substrings to match.
    pub fn matching_any<I, S>(mut self, substrings: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.needles.extend(substrings.into_iter().map(Into::into));
        self
    }

    /// Validates the settings and creates the collector.
    pub fn build(self) -> Result<LogCountCollector, LogCountConfigError> {
        if self.max_tail_bytes == 0 {
            return Err(LogCountConfigError::ZeroTailLimit);
        }
        if self.needles.is_empty() {
            return Err(LogCountConfigError::NoSubstrings);
        }
        if self.needles.iter().any(String::is_empty) {
            return Err(LogCountConfigError::EmptySubstring);
        }
        Ok(LogCountCollector {
            path: self.path,
            max_tail_bytes: self.max_tail_bytes,
            needles: self.needles,
        })
    }
}

/// A validated bounded text log counter.
///
/// A line contributes at most one count, even if it contains several matching
/// substrings. Missing, non-regular, unreadable, or non-UTF-8 files produce a
/// per-metric collection error.
#[derive(Clone, Debug)]
pub struct LogCountCollector {
    path: PathBuf,
    max_tail_bytes: usize,
    needles: Vec<String>,
}

impl LogCountCollector {
    /// Starts building a collector for `path`.
    pub fn builder(path: impl Into<PathBuf>) -> LogCountBuilder {
        LogCountBuilder::new(path)
    }

    fn count(&self) -> CollectResult<u64> {
        let bytes = read_file_tail(&self.path, self.max_tail_bytes).map_err(|error| {
            CollectError::new(format!("cannot read log {}: {error}", self.path.display()))
        })?;
        let text = std::str::from_utf8(&bytes).map_err(|error| {
            CollectError::new(format!(
                "log {} is not valid UTF-8: {error}",
                self.path.display()
            ))
        })?;
        let count = text
            .lines()
            .filter(|line| self.needles.iter().any(|needle| line.contains(needle)))
            .count();
        u64::try_from(count).map_err(|_| CollectError::new("matching line count exceeds u64"))
    }
}

impl Collector<crate::Count> for LogCountCollector {
    fn collect(&mut self) -> CollectResult<u64> {
        self.count()
    }
}

/// A log collector builder validation error.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LogCountConfigError {
    /// At least one byte must be available to the tail reader.
    ZeroTailLimit,
    /// At least one substring is required.
    NoSubstrings,
    /// Empty substrings would match every line and are rejected.
    EmptySubstring,
}

impl fmt::Display for LogCountConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ZeroTailLimit => formatter.write_str("log tail byte limit must be greater than zero"),
            Self::NoSubstrings => formatter.write_str("log collector needs at least one substring"),
            Self::EmptySubstring => formatter.write_str("log collector substrings cannot be empty"),
        }
    }
}

impl Error for LogCountConfigError {}

pub(crate) fn read_file_tail(path: &Path, max_tail_bytes: usize) -> io::Result<Vec<u8>> {
    let mut file = File::open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "path is not a regular file",
        ));
    }
    read_tail(&mut file, metadata.len(), max_tail_bytes)
}

fn read_tail(reader: &mut (impl Read + Seek), len: u64, max_tail_bytes: usize) -> io::Result<Vec<u8>> {
    let limit = u64::try_from(max_tail_bytes).unwrap_or(u64::MAX);
    let start = len.saturating_sub(limit);
    let starts_on_line_boundary = if start == 0 {
        true
    } else {
        reader.seek(SeekFrom::Start(start - 1))?;
        let mut previous = [0];
        reader.read_exact(&mut previous)?;
        previous[0] == b'\n'
    };
    reader.seek(SeekFrom::Start(start))?;

    let mut bytes = Vec::with_capacity(usize::try_from(len - start).unwrap_or(max_tail_bytes));
    reader.take(limit).read_to_end(&mut bytes)?;

    // A byte tail can begin in the middle of a line. Ignore that fragment so
    // it cannot be reported as a complete matching log entry.
    if !starts_on_line_boundary {
        if let Some(newline) = bytes.iter().position(|byte| *byte == b'\n') {
            bytes.drain(..=newline);
        } else {
            bytes.clear();
        }
    }
    Ok(bytes)
}

/// A bounded parser for a file containing one floating-point scalar.
#[derive(Clone, Debug)]
pub struct FileNumberCollector {
    path: PathBuf,
    max_bytes: usize,
}

impl FileNumberCollector {
    /// Creates a scalar file collector with a 64 KiB input limit.
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            max_bytes: 64 * 1024,
        }
    }

    /// Sets the maximum accepted file size.
    pub fn max_bytes(mut self, max_bytes: usize) -> Self {
        self.max_bytes = max_bytes;
        self
    }
}

impl Collector<Number> for FileNumberCollector {
    fn collect(&mut self) -> CollectResult<f64> {
        if self.max_bytes == 0 {
            return Err(CollectError::new("scalar file byte limit must be greater than zero"));
        }
        let file = File::open(&self.path).map_err(|error| {
            CollectError::new(format!("cannot open scalar file {}: {error}", self.path.display()))
        })?;
        let metadata = file.metadata().map_err(|error| {
            CollectError::new(format!("cannot inspect scalar file {}: {error}", self.path.display()))
        })?;
        if !metadata.is_file() {
            return Err(CollectError::new(format!(
                "scalar path {} is not a regular file",
                self.path.display()
            )));
        }
        if metadata.len() > u64::try_from(self.max_bytes).unwrap_or(u64::MAX) {
            return Err(CollectError::new(format!(
                "scalar file {} exceeds {} bytes",
                self.path.display(),
                self.max_bytes
            )));
        }

        let read_limit = u64::try_from(self.max_bytes)
            .unwrap_or(u64::MAX)
            .saturating_add(1);
        let mut bytes = Vec::new();
        file.take(read_limit).read_to_end(&mut bytes).map_err(|error| {
            CollectError::new(format!("cannot read scalar file {}: {error}", self.path.display()))
        })?;
        if bytes.len() > self.max_bytes {
            return Err(CollectError::new(format!(
                "scalar file {} exceeds {} bytes",
                self.path.display(),
                self.max_bytes
            )));
        }
        let text = std::str::from_utf8(&bytes).map_err(|error| {
            CollectError::new(format!(
                "scalar file {} is not valid UTF-8: {error}",
                self.path.display()
            ))
        })?;
        text.trim().parse::<f64>().map_err(|error| {
            CollectError::new(format!(
                "cannot parse scalar file {} as a number: {error}",
                self.path.display()
            ))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{Collector, LogCountCollector, read_tail};
    use crate::Count;
    use std::fs;
    use std::io::Cursor;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_FILE: AtomicU64 = AtomicU64::new(0);

    struct TestFile(PathBuf);

    impl TestFile {
        fn new(contents: &[u8]) -> Self {
            let serial = NEXT_FILE.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "wallstats-log-test-{}-{serial}",
                std::process::id()
            ));
            fs::write(&path, contents).unwrap();
            Self(path)
        }
    }

    impl Drop for TestFile {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.0);
        }
    }

    #[test]
    fn tail_reader_never_returns_more_than_the_limit() {
        let contents = b"old ERROR\nkeep WARN\nkeep ERROR\n";
        let mut cursor = Cursor::new(contents);
        let tail = read_tail(&mut cursor, contents.len() as u64, 22).unwrap();
        assert!(tail.len() <= 22);
        assert_eq!(std::str::from_utf8(&tail).unwrap(), "keep WARN\nkeep ERROR\n");
    }

    #[test]
    fn tail_reader_keeps_a_line_that_starts_at_the_byte_boundary() {
        let contents = b"old ERROR\nkeep WARN\nkeep ERROR\n";
        let mut cursor = Cursor::new(contents);
        let tail = read_tail(&mut cursor, contents.len() as u64, 21).unwrap();
        assert_eq!(std::str::from_utf8(&tail).unwrap(), "keep WARN\nkeep ERROR\n");
    }

    #[test]
    fn log_collector_counts_lines_matching_any_substring_once() {
        let file = TestFile::new(b"ok\nERROR first\nWARN second\nERROR WARN both\n");
        let mut collector = LogCountCollector::builder(&file.0)
            .max_tail_bytes(1024)
            .matching_any(["ERROR", "WARN"])
            .build()
            .unwrap();
        assert_eq!(Collector::<Count>::collect(&mut collector).unwrap(), 3);
    }

    #[test]
    fn missing_log_is_a_collection_error() {
        let mut collector = LogCountCollector::builder("/definitely/not/a/wallstats/log")
            .matching("ERROR")
            .build()
            .unwrap();
        assert!(Collector::<Count>::collect(&mut collector).is_err());
    }
}
