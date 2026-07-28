use crate::{MetricId, MetricIdError};
use std::error::Error as StdError;
use std::fmt;
use std::io;

/// A configuration validation error.
#[derive(Debug)]
#[non_exhaustive]
pub enum ConfigError {
    /// A metric ID does not follow the protocol grammar.
    InvalidMetricId(MetricIdError),
    /// Two registered metrics have the same ID.
    DuplicateMetric(MetricId),
    /// A widget refers to a metric that is not registered in this app.
    UnknownMetricReference {
        /// Section containing the widget.
        section: String,
        /// Missing metric ID.
        metric: MetricId,
    },
    /// A source schedule is invalid.
    InvalidSchedule(String),
    /// A widget setting is invalid.
    InvalidWidget {
        /// Widget label.
        label: String,
        /// Validation failure.
        reason: String,
    },
    /// A window setting is invalid.
    InvalidWindow(String),
    /// The app title or section layout is invalid.
    InvalidLayout(String),
    /// A built-in collector setting is invalid.
    InvalidCollector {
        /// Collector name.
        collector: &'static str,
        /// Validation failure.
        reason: String,
    },
    /// The process received unsupported command-line arguments.
    UnknownArguments(Vec<String>),
}

impl fmt::Display for ConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidMetricId(error) => error.fmt(formatter),
            Self::DuplicateMetric(id) => write!(formatter, "duplicate metric ID {id:?}"),
            Self::UnknownMetricReference { section, metric } => write!(
                formatter,
                "section {section:?} refers to unregistered metric {metric:?}"
            ),
            Self::InvalidSchedule(reason) => write!(formatter, "invalid metric schedule: {reason}"),
            Self::InvalidWidget { label, reason } => {
                write!(formatter, "invalid widget {label:?}: {reason}")
            }
            Self::InvalidWindow(reason) => write!(formatter, "invalid window: {reason}"),
            Self::InvalidLayout(reason) => write!(formatter, "invalid layout: {reason}"),
            Self::InvalidCollector { collector, reason } => {
                write!(formatter, "invalid {collector} collector: {reason}")
            }
            Self::UnknownArguments(arguments) => {
                write!(formatter, "unsupported arguments: {}", arguments.join(" "))
            }
        }
    }
}

impl StdError for ConfigError {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        match self {
            Self::InvalidMetricId(error) => Some(error),
            _ => None,
        }
    }
}

impl From<MetricIdError> for ConfigError {
    fn from(error: MetricIdError) -> Self {
        Self::InvalidMetricId(error)
    }
}

/// A Wallstats configuration or runtime error.
#[derive(Debug)]
#[non_exhaustive]
pub enum Error {
    /// Configuration validation failed.
    Config(ConfigError),
    /// A protocol record could not be serialized.
    Serialization(serde_json::Error),
    /// A protocol record could not be written to stdout.
    Output(io::Error),
    /// A serialized JSON record exceeds the protocol line limit.
    ProtocolRecordTooLarge {
        /// Maximum permitted JSON bytes, excluding the trailing newline.
        limit: usize,
    },
    /// The collector runtime stopped unexpectedly.
    Runtime(String),
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Config(error) => error.fmt(formatter),
            Self::Serialization(error) => write!(formatter, "cannot serialize protocol record: {error}"),
            Self::Output(error) => write!(formatter, "cannot write protocol output: {error}"),
            Self::ProtocolRecordTooLarge { limit } => {
                write!(formatter, "protocol record exceeds the {limit}-byte limit")
            }
            Self::Runtime(message) => formatter.write_str(message),
        }
    }
}

impl StdError for Error {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        match self {
            Self::Config(error) => Some(error),
            Self::Serialization(error) => Some(error),
            Self::Output(error) => Some(error),
            Self::ProtocolRecordTooLarge { .. } => None,
            Self::Runtime(_) => None,
        }
    }
}

impl From<ConfigError> for Error {
    fn from(error: ConfigError) -> Self {
        Self::Config(error)
    }
}

/// The result type returned by Wallstats runtime operations.
pub type Result<T> = std::result::Result<T, Error>;
