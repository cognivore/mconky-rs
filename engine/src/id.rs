use serde::Serialize;
use std::error::Error;
use std::fmt;

/// A validated protocol metric identifier.
///
/// IDs match `[a-z][a-z0-9_.-]{0,127}`.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct MetricId(String);

impl MetricId {
    /// Parses and validates a metric identifier.
    pub fn new(value: impl Into<String>) -> Result<Self, MetricIdError> {
        let value = value.into();
        validate(&value)?;
        Ok(Self(value))
    }

    /// Returns the identifier as a string slice.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl AsRef<str> for MetricId {
    fn as_ref(&self) -> &str {
        self.as_str()
    }
}

impl fmt::Display for MetricId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl TryFrom<&str> for MetricId {
    type Error = MetricIdError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl TryFrom<String> for MetricId {
    type Error = MetricIdError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

/// Explains why a metric identifier is invalid.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MetricIdError {
    value: String,
    reason: &'static str,
}

impl MetricIdError {
    /// Returns the rejected identifier.
    pub fn value(&self) -> &str {
        &self.value
    }

    /// Returns a concise validation failure reason.
    pub fn reason(&self) -> &'static str {
        self.reason
    }
}

impl fmt::Display for MetricIdError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "invalid metric ID {:?}: {} (expected [a-z][a-z0-9_.-]{{0,127}})",
            self.value, self.reason
        )
    }
}

impl Error for MetricIdError {}

fn validate(value: &str) -> Result<(), MetricIdError> {
    let fail = |reason| {
        Err(MetricIdError {
            value: value.to_owned(),
            reason,
        })
    };

    if value.is_empty() {
        return fail("the ID is empty");
    }
    if value.len() > 128 {
        return fail("the ID is longer than 128 bytes");
    }

    let mut bytes = value.bytes();
    if !matches!(bytes.next(), Some(b'a'..=b'z')) {
        return fail("the first character is not a lowercase ASCII letter");
    }
    if !bytes.all(|byte| {
        matches!(
            byte,
            b'a'..=b'z' | b'0'..=b'9' | b'_' | b'.' | b'-'
        )
    }) {
        return fail("the ID contains a disallowed character");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::MetricId;

    #[test]
    fn accepts_protocol_metric_ids() {
        for id in ["a", "cpu.total", "disk-root_2", &format!("a{}", "z".repeat(127))] {
            assert!(MetricId::new(id).is_ok(), "{id}");
        }
    }

    #[test]
    fn rejects_invalid_metric_ids() {
        for id in [
            "",
            "CPU.total",
            "1cpu",
            ".cpu",
            "cpu total",
            "cpu/total",
            "café",
            &format!("a{}", "z".repeat(128)),
        ] {
            assert!(MetricId::new(id).is_err(), "{id}");
        }
    }
}
