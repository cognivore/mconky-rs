use crate::{CollectError, CollectResult, MetricId};
use serde::Serialize;
use std::error::Error;
use std::fmt;
use std::marker::PhantomData;
use std::time::Duration;
use unicode_segmentation::UnicodeSegmentation;

mod private {
    pub trait Sealed {}
}

/// A protocol wire type that can back a [`Metric`].
///
/// This trait is sealed because protocol v1 has a fixed set of value kinds.
pub trait WireType: private::Sealed + Send + Sync + 'static {
    /// The value returned by a [`crate::Collector`] for this wire type.
    type Value: Send + 'static;

    /// The protocol `value_type` name.
    const VALUE_TYPE: &'static str;

    #[doc(hidden)]
    fn into_wire(value: Self::Value) -> CollectResult<WireValue>;
}

macro_rules! marker {
    ($name:ident, $value:ty, $wire_name:literal) => {
        #[doc = concat!("The `", $wire_name, "` metric wire type.")]
        #[derive(Clone, Copy, Debug)]
        pub struct $name;

        impl private::Sealed for $name {}

        impl WireType for $name {
            type Value = $value;
            const VALUE_TYPE: &'static str = $wire_name;

            fn into_wire(value: Self::Value) -> CollectResult<WireValue> {
                Ok(WireValue::$name { value })
            }
        }
    };
}

/// The `ratio` metric wire type. Values must be finite and between 0 and 1.
#[derive(Clone, Copy, Debug)]
pub struct Ratio;

impl private::Sealed for Ratio {}

impl WireType for Ratio {
    type Value = f64;
    const VALUE_TYPE: &'static str = "ratio";

    fn into_wire(value: Self::Value) -> CollectResult<WireValue> {
        if !value.is_finite() || !(0.0..=1.0).contains(&value) {
            return Err(CollectError::new(
                "ratio value must be finite and between 0 and 1",
            ));
        }
        Ok(WireValue::Ratio { value })
    }
}

marker!(Bytes, u64, "bytes");

/// The `bytes_per_second` metric wire type. Values must be finite and nonnegative.
#[derive(Clone, Copy, Debug)]
pub struct BytesPerSecond;

impl private::Sealed for BytesPerSecond {}

impl WireType for BytesPerSecond {
    type Value = f64;
    const VALUE_TYPE: &'static str = "bytes_per_second";

    fn into_wire(value: Self::Value) -> CollectResult<WireValue> {
        finite_nonnegative(value, "bytes/sec")?;
        Ok(WireValue::BytesPerSecond { value })
    }
}

/// The `count` metric wire type. Values must fit the protocol's nonnegative i64 range.
#[derive(Clone, Copy, Debug)]
pub struct Count;

impl private::Sealed for Count {}

impl WireType for Count {
    type Value = u64;
    const VALUE_TYPE: &'static str = "count";

    fn into_wire(value: Self::Value) -> CollectResult<WireValue> {
        if value > i64::MAX as u64 {
            return Err(CollectError::new("count value exceeds i64::MAX"));
        }
        Ok(WireValue::Count { value })
    }
}

/// The `number` metric wire type. Values must be finite.
#[derive(Clone, Copy, Debug)]
pub struct Number;

impl private::Sealed for Number {}

impl WireType for Number {
    type Value = f64;
    const VALUE_TYPE: &'static str = "number";

    fn into_wire(value: Self::Value) -> CollectResult<WireValue> {
        if !value.is_finite() {
            return Err(CollectError::new("number value must be finite"));
        }
        Ok(WireValue::Number { value })
    }
}

marker!(Text, String, "text");
marker!(Boolean, bool, "boolean");

/// The `duration_seconds` metric wire type. Values must be finite and nonnegative.
#[derive(Clone, Copy, Debug)]
pub struct DurationSeconds;

impl private::Sealed for DurationSeconds {}

impl WireType for DurationSeconds {
    type Value = f64;
    const VALUE_TYPE: &'static str = "duration_seconds";

    fn into_wire(value: Self::Value) -> CollectResult<WireValue> {
        finite_nonnegative(value, "duration")?;
        Ok(WireValue::DurationSeconds { value })
    }
}

/// A protocol light color for [`CompactStatusValue`].
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StatusLight {
    /// Healthy or successful.
    Green,
    /// Active or in progress.
    Blue,
    /// Attention recommended.
    Amber,
    /// Failed or unhealthy.
    Red,
    /// Unknown or unavailable.
    Gray,
}

/// A compact status containing two glyphs, a light, and an optional age.
#[derive(Clone, Debug, PartialEq)]
pub struct CompactStatusValue {
    leading: String,
    trailing: String,
    light: StatusLight,
    age_seconds: Option<f64>,
    glyph_scale: Option<f64>,
}

impl CompactStatusValue {
    /// Creates a compact status without an age.
    ///
    /// Values are validated by [`Self::validate`] and again before protocol
    /// serialization.
    pub fn new(
        leading: impl Into<String>,
        trailing: impl Into<String>,
        light: StatusLight,
    ) -> Self {
        Self {
            leading: leading.into(),
            trailing: trailing.into(),
            light,
            age_seconds: None,
            glyph_scale: None,
        }
    }

    /// Sets the age from a nonnegative [`Duration`].
    pub fn age(mut self, age: Duration) -> Self {
        self.age_seconds = Some(age.as_secs_f64());
        self
    }

    /// Sets an age in seconds, validated before serialization.
    pub fn age_seconds(mut self, age_seconds: f64) -> Self {
        self.age_seconds = Some(age_seconds);
        self
    }

    /// Sets the glyph scale, validated to the inclusive range 0.4 through 1.5.
    pub fn glyph_scale(mut self, glyph_scale: f64) -> Self {
        self.glyph_scale = Some(glyph_scale);
        self
    }

    /// Returns the leading glyph string.
    pub fn leading(&self) -> &str {
        &self.leading
    }

    /// Returns the trailing glyph string.
    pub fn trailing(&self) -> &str {
        &self.trailing
    }

    /// Returns the status light.
    pub fn light(&self) -> StatusLight {
        self.light
    }

    /// Returns the optional age in seconds.
    pub fn age_seconds_value(&self) -> Option<f64> {
        self.age_seconds
    }

    /// Returns the optional glyph scale. Omission uses the native default of 1.0.
    pub fn glyph_scale_value(&self) -> Option<f64> {
        self.glyph_scale
    }

    /// Validates glyph and age constraints.
    pub fn validate(&self) -> Result<(), CompactStatusValueError> {
        validate_status_glyph("leading", &self.leading)?;
        validate_status_glyph("trailing", &self.trailing)?;
        if self
            .age_seconds
            .is_some_and(|age_seconds| !age_seconds.is_finite() || age_seconds < 0.0)
        {
            return Err(CompactStatusValueError::new(
                "age_seconds must be finite and nonnegative",
            ));
        }
        if self
            .glyph_scale
            .is_some_and(|glyph_scale| !glyph_scale.is_finite() || !(0.4..=1.5).contains(&glyph_scale))
        {
            return Err(CompactStatusValueError::new(
                "glyph_scale must be finite and between 0.4 and 1.5",
            ));
        }
        Ok(())
    }
}

fn validate_status_glyph(
    field: &str,
    glyph: &str,
) -> Result<(), CompactStatusValueError> {
    if glyph.trim().is_empty() {
        return Err(CompactStatusValueError::new(format!(
            "{field} glyph cannot be empty"
        )));
    }
    if glyph.len() > 32 {
        return Err(CompactStatusValueError::new(format!(
            "{field} glyph cannot exceed 32 UTF-8 bytes"
        )));
    }
    if glyph.chars().any(char::is_control) {
        return Err(CompactStatusValueError::new(format!(
            "{field} glyph cannot contain control characters"
        )));
    }
    if UnicodeSegmentation::graphemes(glyph, true).count() > 2 {
        return Err(CompactStatusValueError::new(format!(
            "{field} glyph cannot exceed 2 grapheme clusters"
        )));
    }
    Ok(())
}

/// A compact-status value validation error.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompactStatusValueError {
    message: String,
}

impl CompactStatusValueError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }

    /// Returns the validation failure message.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for CompactStatusValueError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for CompactStatusValueError {}

/// The `compact_status` metric wire type.
#[derive(Clone, Copy, Debug)]
pub struct CompactStatus;

impl private::Sealed for CompactStatus {}

impl WireType for CompactStatus {
    type Value = CompactStatusValue;
    const VALUE_TYPE: &'static str = "compact_status";

    fn into_wire(value: Self::Value) -> CollectResult<WireValue> {
        value
            .validate()
            .map_err(|error| CollectError::new(error.to_string()))?;
        Ok(WireValue::CompactStatus {
            leading: value.leading,
            trailing: value.trailing,
            light: value.light,
            age_seconds: value.age_seconds,
            glyph_scale: value.glyph_scale,
        })
    }
}

/// The `table` metric wire type. Collectors return [`TableValue`].
#[derive(Clone, Copy, Debug)]
pub struct Table;

impl private::Sealed for Table {}

impl WireType for Table {
    type Value = TableValue;
    const VALUE_TYPE: &'static str = "table";

    fn into_wire(value: Self::Value) -> CollectResult<WireValue> {
        value.validate().map_err(|error| CollectError::new(error.to_string()))?;
        Ok(WireValue::Table {
            columns: value.columns,
            rows: value.rows,
        })
    }
}

fn finite_nonnegative(value: f64, name: &str) -> CollectResult<()> {
    if !value.is_finite() || value < 0.0 {
        return Err(CollectError::new(format!(
            "{name} value must be finite and nonnegative"
        )));
    }
    Ok(())
}

/// A typed handle to a registered metric.
///
/// The phantom type is used by widget builders and does not affect protocol
/// serialization.
#[derive(Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct Metric<T: WireType> {
    id: MetricId,
    marker: PhantomData<fn() -> T>,
}

impl<T: WireType> Metric<T> {
    pub(crate) fn new(id: MetricId) -> Self {
        Self {
            id,
            marker: PhantomData,
        }
    }

    /// Returns this metric's validated ID.
    pub fn id(&self) -> &MetricId {
        &self.id
    }
}

impl<T: WireType> Clone for Metric<T> {
    fn clone(&self) -> Self {
        Self::new(self.id.clone())
    }
}

impl<T: WireType> From<&Metric<T>> for Metric<T> {
    fn from(metric: &Metric<T>) -> Self {
        metric.clone()
    }
}

/// A validated table value.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TableValue {
    columns: Vec<String>,
    rows: Vec<Vec<String>>,
}

impl TableValue {
    /// Creates a table and verifies that every row has one cell per column.
    pub fn new(
        columns: impl IntoIterator<Item = impl Into<String>>,
        rows: impl IntoIterator<Item = impl IntoIterator<Item = impl Into<String>>>,
    ) -> Result<Self, TableValueError> {
        let value = Self {
            columns: columns.into_iter().map(Into::into).collect(),
            rows: rows
                .into_iter()
                .map(|row| row.into_iter().map(Into::into).collect())
                .collect(),
        };
        value.validate()?;
        Ok(value)
    }

    /// Returns the column labels.
    pub fn columns(&self) -> &[String] {
        &self.columns
    }

    /// Returns the table rows.
    pub fn rows(&self) -> &[Vec<String>] {
        &self.rows
    }

    fn validate(&self) -> Result<(), TableValueError> {
        let width = self.columns.len();
        if width == 0 {
            return Err(TableValueError::NoColumns);
        }
        if let Some((index, row)) = self
            .rows
            .iter()
            .enumerate()
            .find(|(_, row)| row.len() != width)
        {
            return Err(TableValueError::WrongRowWidth {
                row: index,
                expected: width,
                actual: row.len(),
            });
        }
        Ok(())
    }
}

/// A table shape validation error.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TableValueError {
    /// A table must have at least one column.
    NoColumns,
    /// A row has a different number of cells than the header.
    WrongRowWidth {
        /// Zero-based row index.
        row: usize,
        /// Number of columns.
        expected: usize,
        /// Number of cells in this row.
        actual: usize,
    },
}

impl fmt::Display for TableValueError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoColumns => formatter.write_str("table must have at least one column"),
            Self::WrongRowWidth {
                row,
                expected,
                actual,
            } => write!(
                formatter,
                "table row {row} has {actual} cells; expected {expected}"
            ),
        }
    }
}

impl Error for TableValueError {}

#[doc(hidden)]
#[derive(Clone, Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum WireValue {
    /// Internal ratio representation.
    Ratio { value: f64 },
    /// Internal byte representation.
    Bytes { value: u64 },
    /// Internal byte-rate representation.
    BytesPerSecond { value: f64 },
    /// Internal count representation.
    Count { value: u64 },
    /// Internal duration representation.
    DurationSeconds { value: f64 },
    /// Internal number representation.
    Number { value: f64 },
    /// Internal text representation.
    Text { value: String },
    /// Internal boolean representation.
    Boolean { value: bool },
    /// Internal compact-status representation.
    CompactStatus {
        leading: String,
        trailing: String,
        light: StatusLight,
        #[serde(skip_serializing_if = "Option::is_none")]
        age_seconds: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        glyph_scale: Option<f64>,
    },
    /// Internal table representation.
    Table {
        columns: Vec<String>,
        rows: Vec<Vec<String>>,
    },
}

#[cfg(test)]
mod tests {
    use super::{
        Boolean, Bytes, BytesPerSecond, CompactStatus, CompactStatusValue, Count, DurationSeconds,
        Number, Ratio, StatusLight, Table, TableValue, Text, WireType,
    };
    use serde_json::{json, to_value};
    use std::time::Duration;

    #[test]
    fn typed_values_serialize_to_protocol_shapes() {
        let cases = [
            (to_value(Ratio::into_wire(0.42).unwrap()).unwrap(), json!({"kind":"ratio","value":0.42})),
            (to_value(Bytes::into_wire(123).unwrap()).unwrap(), json!({"kind":"bytes","value":123})),
            (to_value(BytesPerSecond::into_wire(10.5).unwrap()).unwrap(), json!({"kind":"bytes_per_second","value":10.5})),
            (to_value(Count::into_wire(7).unwrap()).unwrap(), json!({"kind":"count","value":7})),
            (to_value(DurationSeconds::into_wire(2.5).unwrap()).unwrap(), json!({"kind":"duration_seconds","value":2.5})),
            (to_value(Number::into_wire(3.25).unwrap()).unwrap(), json!({"kind":"number","value":3.25})),
            (to_value(Text::into_wire("ok".to_owned()).unwrap()).unwrap(), json!({"kind":"text","value":"ok"})),
            (to_value(Boolean::into_wire(true).unwrap()).unwrap(), json!({"kind":"boolean","value":true})),
            (to_value(Table::into_wire(TableValue::new(["A"], [["x"]]).unwrap()).unwrap()).unwrap(), json!({"kind":"table","columns":["A"],"rows":[["x"]]})),
        ];

        for (actual, expected) in cases {
            assert_eq!(actual, expected);
        }
    }

    #[test]
    fn rejects_invalid_floating_point_values() {
        assert!(Ratio::into_wire(-0.1).is_err());
        assert!(Ratio::into_wire(1.1).is_err());
        assert!(Number::into_wire(f64::NAN).is_err());
        assert!(BytesPerSecond::into_wire(f64::INFINITY).is_err());
        assert!(DurationSeconds::into_wire(-1.0).is_err());
    }

    #[test]
    fn compact_status_serializes_to_the_exact_wire_shape() {
        let value = CompactStatusValue::new("☁️", "💾", StatusLight::Amber)
            .age(Duration::from_secs(123))
            .glyph_scale(0.55);
        assert_eq!(
            to_value(CompactStatus::into_wire(value).unwrap()).unwrap(),
            json!({
                "kind":"compact_status",
                "leading":"☁️",
                "trailing":"💾",
                "light":"amber",
                "age_seconds":123.0,
                "glyph_scale":0.55
            })
        );
        assert_eq!(
            to_value(
                CompactStatus::into_wire(CompactStatusValue::new(
                    "A",
                    "B",
                    StatusLight::Gray
                ))
                .unwrap()
            )
            .unwrap(),
            json!({"kind":"compact_status","leading":"A","trailing":"B","light":"gray"})
        );
    }

    #[test]
    fn compact_status_validates_glyphs_and_age() {
        for value in [
            CompactStatusValue::new("", "B", StatusLight::Green),
            CompactStatusValue::new("A", "x".repeat(33), StatusLight::Blue),
            CompactStatusValue::new("abc", "B", StatusLight::Amber),
            CompactStatusValue::new("A\n", "B", StatusLight::Red),
            CompactStatusValue::new("A", "B", StatusLight::Gray).age_seconds(-1.0),
            CompactStatusValue::new("A", "B", StatusLight::Gray).age_seconds(f64::NAN),
        ] {
            assert!(value.validate().is_err());
            assert!(CompactStatus::into_wire(value).is_err());
        }
        assert!(
            CompactStatusValue::new("☁️💾", "a\u{301}", StatusLight::Green)
                .validate()
                .is_ok()
        );
    }

    #[test]
    fn compact_status_validates_glyph_scale_bounds() {
        for glyph_scale in [0.4, 1.5] {
            let value = CompactStatusValue::new("A", "B", StatusLight::Green)
                .glyph_scale(glyph_scale);
            assert_eq!(value.glyph_scale_value(), Some(glyph_scale));
            assert!(value.validate().is_ok());
            assert!(CompactStatus::into_wire(value).is_ok());
        }

        for glyph_scale in [0.39, 1.51, f64::NAN, f64::INFINITY] {
            let value = CompactStatusValue::new("A", "B", StatusLight::Red)
                .glyph_scale(glyph_scale);
            assert!(value.validate().is_err());
            assert!(CompactStatus::into_wire(value).is_err());
        }
    }

    #[test]
    fn status_lights_use_fixed_wire_names() {
        let cases = [
            (StatusLight::Green, "green"),
            (StatusLight::Blue, "blue"),
            (StatusLight::Amber, "amber"),
            (StatusLight::Red, "red"),
            (StatusLight::Gray, "gray"),
        ];
        for (light, expected) in cases {
            assert_eq!(to_value(light).unwrap(), json!(expected));
        }
    }
}
