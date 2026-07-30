use crate::{ConfigError, MetricId, Widget};
use serde::Serialize;
use std::collections::HashSet;

const MAX_LAYOUT_DEPTH: usize = 32;
const MAX_LAYOUT_NODES: usize = 256;

/// A native presentation surface kind. A plan may contain at most one of each.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SurfaceKind {
    /// Main-screen desktop overlay.
    Desktop,
    /// Large widget-family surface.
    WidgetLarge,
    /// Medium widget-family surface.
    WidgetMedium,
    /// Small widget-family surface.
    WidgetSmall,
}

/// Screen corner used as the origin for desktop surface coordinates.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SurfaceOrigin {
    /// X moves right and Y moves up from the bottom-left.
    BottomLeft,
    /// X moves right and Y moves down from the top-left.
    TopLeft,
    /// X moves left and Y moves up from the bottom-right.
    BottomRight,
    /// X moves left and Y moves down from the top-right.
    TopRight,
}

/// An independently composed Wallstats surface.
#[derive(Clone, Debug, Serialize)]
pub struct Surface {
    kind: SurfaceKind,
    root: LayoutNode,
    #[serde(skip_serializing_if = "Option::is_none")]
    x: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    y: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    origin: Option<SurfaceOrigin>,
    #[serde(skip_serializing_if = "Option::is_none")]
    width: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    content_inset: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    background_opacity: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    click_through: Option<bool>,
}

impl Surface {
    /// Creates a desktop surface with practical transparent-overlay defaults.
    pub fn desktop(root: LayoutNode) -> Self {
        Self {
            kind: SurfaceKind::Desktop,
            root,
            x: Some(0.0),
            y: Some(0.0),
            origin: Some(SurfaceOrigin::BottomLeft),
            width: Some(640.0),
            content_inset: Some(16.0),
            background_opacity: Some(0.0),
            click_through: Some(true),
        }
    }

    /// Creates a large widget surface.
    pub fn widget_large(root: LayoutNode) -> Self {
        Self::widget_family(SurfaceKind::WidgetLarge, root)
    }

    /// Creates a medium widget surface.
    pub fn widget_medium(root: LayoutNode) -> Self {
        Self::widget_family(SurfaceKind::WidgetMedium, root)
    }

    /// Creates a small widget surface.
    pub fn widget_small(root: LayoutNode) -> Self {
        Self::widget_family(SurfaceKind::WidgetSmall, root)
    }

    fn widget_family(kind: SurfaceKind, root: LayoutNode) -> Self {
        Self {
            kind,
            root,
            x: None,
            y: None,
            origin: None,
            width: None,
            content_inset: None,
            background_opacity: None,
            click_through: None,
        }
    }

    /// Sets inward desktop offsets from the selected main-screen corner.
    pub fn position(mut self, x: f64, y: f64, origin: SurfaceOrigin) -> Self {
        self.x = Some(x);
        self.y = Some(y);
        self.origin = Some(origin);
        self
    }

    /// Sets desktop width in points.
    pub fn width(mut self, width: f64) -> Self {
        self.width = Some(width);
        self
    }

    /// Sets uniform space between the desktop panel edge and its root layout.
    pub fn content_inset(mut self, inset: f64) -> Self {
        self.content_inset = Some(inset);
        self
    }

    /// Sets desktop background opacity.
    pub fn background_opacity(mut self, opacity: f64) -> Self {
        self.background_opacity = Some(opacity);
        self
    }

    /// Sets whether desktop mouse events pass through.
    pub fn click_through(mut self, click_through: bool) -> Self {
        self.click_through = Some(click_through);
        self
    }

    /// Returns this surface's kind.
    pub fn kind(&self) -> SurfaceKind {
        self.kind
    }

    pub(crate) fn validate(&self, registered: &HashSet<&MetricId>) -> Result<(), ConfigError> {
        match self.kind {
            SurfaceKind::Desktop => {
                validate_finite(self.x, "desktop x")?;
                validate_finite(self.y, "desktop y")?;
                if self.origin.is_none() {
                    return Err(ConfigError::InvalidLayout(
                        "desktop origin is missing".to_owned(),
                    ));
                }
                let width = self.width.ok_or_else(|| {
                    ConfigError::InvalidLayout("desktop width is missing".to_owned())
                })?;
                if !width.is_finite() || width <= 0.0 {
                    return Err(ConfigError::InvalidLayout(
                        "desktop width must be finite and greater than zero".to_owned(),
                    ));
                }
                let content_inset = self.content_inset.ok_or_else(|| {
                    ConfigError::InvalidLayout("desktop content inset is missing".to_owned())
                })?;
                if !content_inset.is_finite() || content_inset < 0.0 {
                    return Err(ConfigError::InvalidLayout(
                        "desktop content inset must be finite and nonnegative".to_owned(),
                    ));
                }
                let opacity = self.background_opacity.ok_or_else(|| {
                    ConfigError::InvalidLayout("desktop background opacity is missing".to_owned())
                })?;
                if !opacity.is_finite() || !(0.0..=1.0).contains(&opacity) {
                    return Err(ConfigError::InvalidLayout(
                        "desktop background opacity must be between zero and one".to_owned(),
                    ));
                }
                if self.click_through.is_none() {
                    return Err(ConfigError::InvalidLayout(
                        "desktop click-through setting is missing".to_owned(),
                    ));
                }
            }
            _ => {
                if self.x.is_some()
                    || self.y.is_some()
                    || self.origin.is_some()
                    || self.width.is_some()
                    || self.content_inset.is_some()
                    || self.background_opacity.is_some()
                    || self.click_through.is_some()
                {
                    return Err(ConfigError::InvalidLayout(
                        "widget-family surfaces cannot contain desktop geometry".to_owned(),
                    ));
                }
            }
        }

        let mut nodes = 0;
        self.root.validate(1, &mut nodes, registered)
    }
}

fn validate_finite(value: Option<f64>, name: &str) -> Result<(), ConfigError> {
    match value {
        Some(value) if value.is_finite() => Ok(()),
        Some(_) => Err(ConfigError::InvalidLayout(format!("{name} must be finite"))),
        None => Err(ConfigError::InvalidLayout(format!("{name} is missing"))),
    }
}

/// Insets in top, right, bottom, left order.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Insets {
    top: f64,
    right: f64,
    bottom: f64,
    left: f64,
}

impl Insets {
    /// Creates explicit top, right, bottom, and left insets.
    pub fn new(top: f64, right: f64, bottom: f64, left: f64) -> Self {
        Self {
            top,
            right,
            bottom,
            left,
        }
    }

    /// Creates equal insets on all edges.
    pub fn all(value: f64) -> Self {
        Self::new(value, value, value, value)
    }

    /// Creates vertical and horizontal insets.
    pub fn symmetric(vertical: f64, horizontal: f64) -> Self {
        Self::new(vertical, horizontal, vertical, horizontal)
    }

    fn validate(self) -> Result<(), ConfigError> {
        for (name, value) in [
            ("top", self.top),
            ("right", self.right),
            ("bottom", self.bottom),
            ("left", self.left),
        ] {
            validate_dimension(value, &format!("section {name} inset"))?;
        }
        Ok(())
    }
}

impl Default for Insets {
    fn default() -> Self {
        Self::all(0.0)
    }
}

/// One weighted child track in a split layout.
#[derive(Clone, Debug, Serialize)]
pub struct LayoutTrack {
    weight: f64,
    child: LayoutNode,
}

impl LayoutTrack {
    /// Creates a weighted split track.
    pub fn new(weight: f64, child: LayoutNode) -> Self {
        Self { weight, child }
    }
}

/// An immutable editorial layout tree interpreted by the native renderer.
#[derive(Clone, Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum LayoutNode {
    /// A leaf containing an existing widget protocol object.
    Widget {
        /// Type-erased widget protocol object.
        widget: Widget,
    },
    /// A titled and inset editorial section.
    Section {
        /// Visible section title.
        title: String,
        /// Insets around the child.
        insets: Insets,
        /// Section content.
        child: Box<LayoutNode>,
    },
    /// A vertical stack.
    Stack {
        /// Gap between children.
        gap: f64,
        /// Ordered children.
        children: Vec<LayoutNode>,
    },
    /// Weighted tracks that may be re-homed to a stack by the native renderer.
    Split {
        /// Gap between tracks.
        gap: f64,
        /// Minimum width for each native track.
        minimum_track_width: f64,
        /// Ordered weighted tracks.
        tracks: Vec<LayoutTrack>,
    },
    /// Deterministic row-major flow.
    Flow {
        /// Horizontal item gap.
        horizontal_gap: f64,
        /// Vertical row gap.
        vertical_gap: f64,
        /// Minimum item width used to derive columns.
        minimum_item_width: f64,
        /// Ordered row-major children.
        children: Vec<LayoutNode>,
    },
}

impl LayoutNode {
    /// Creates a widget leaf from a typed builder or type-erased widget.
    pub fn widget(widget: impl Into<Widget>) -> Self {
        Self::Widget {
            widget: widget.into(),
        }
    }

    /// Creates a titled section.
    pub fn section(title: impl Into<String>, insets: Insets, child: LayoutNode) -> Self {
        Self::Section {
            title: title.into(),
            insets,
            child: Box::new(child),
        }
    }

    /// Creates a vertical stack.
    pub fn stack(gap: f64, children: Vec<LayoutNode>) -> Self {
        Self::Stack { gap, children }
    }

    /// Creates weighted split tracks.
    pub fn split(gap: f64, minimum_track_width: f64, tracks: Vec<LayoutTrack>) -> Self {
        Self::Split {
            gap,
            minimum_track_width,
            tracks,
        }
    }

    /// Creates a deterministic row-major flow.
    pub fn flow(
        horizontal_gap: f64,
        vertical_gap: f64,
        minimum_item_width: f64,
        children: Vec<LayoutNode>,
    ) -> Self {
        Self::Flow {
            horizontal_gap,
            vertical_gap,
            minimum_item_width,
            children,
        }
    }

    fn validate(
        &self,
        depth: usize,
        nodes: &mut usize,
        registered: &HashSet<&MetricId>,
    ) -> Result<(), ConfigError> {
        if depth > MAX_LAYOUT_DEPTH {
            return Err(ConfigError::InvalidLayout(format!(
                "surface layout exceeds depth {MAX_LAYOUT_DEPTH}"
            )));
        }
        *nodes += 1;
        if *nodes > MAX_LAYOUT_NODES {
            return Err(ConfigError::InvalidLayout(format!(
                "surface layout exceeds {MAX_LAYOUT_NODES} nodes"
            )));
        }

        match self {
            Self::Widget { widget } => {
                widget.validate()?;
                for metric in widget.metrics() {
                    if !registered.contains(metric) {
                        return Err(ConfigError::UnknownMetricReference {
                            section: "surface".to_owned(),
                            metric: metric.clone(),
                        });
                    }
                }
            }
            Self::Section {
                title,
                insets,
                child,
            } => {
                if title.trim().is_empty() {
                    return Err(ConfigError::InvalidLayout(
                        "surface section title cannot be empty".to_owned(),
                    ));
                }
                insets.validate()?;
                child.validate(depth + 1, nodes, registered)?;
            }
            Self::Stack { gap, children } => {
                validate_dimension(*gap, "stack gap")?;
                validate_children(children, depth, nodes, registered, "stack")?;
            }
            Self::Split {
                gap,
                minimum_track_width,
                tracks,
            } => {
                validate_dimension(*gap, "split gap")?;
                validate_dimension(*minimum_track_width, "minimum track width")?;
                if tracks.is_empty() {
                    return Err(ConfigError::InvalidLayout(
                        "split must contain at least one track".to_owned(),
                    ));
                }
                for track in tracks {
                    if !track.weight.is_finite() || track.weight <= 0.0 {
                        return Err(ConfigError::InvalidLayout(
                            "split track weight must be finite and greater than zero".to_owned(),
                        ));
                    }
                    track.child.validate(depth + 1, nodes, registered)?;
                }
            }
            Self::Flow {
                horizontal_gap,
                vertical_gap,
                minimum_item_width,
                children,
            } => {
                validate_dimension(*horizontal_gap, "flow horizontal gap")?;
                validate_dimension(*vertical_gap, "flow vertical gap")?;
                validate_dimension(*minimum_item_width, "minimum item width")?;
                validate_children(children, depth, nodes, registered, "flow")?;
            }
        }
        Ok(())
    }
}

fn validate_children(
    children: &[LayoutNode],
    depth: usize,
    nodes: &mut usize,
    registered: &HashSet<&MetricId>,
    kind: &str,
) -> Result<(), ConfigError> {
    if children.is_empty() {
        return Err(ConfigError::InvalidLayout(format!(
            "{kind} must contain at least one child"
        )));
    }
    for child in children {
        child.validate(depth + 1, nodes, registered)?;
    }
    Ok(())
}

fn validate_dimension(value: f64, name: &str) -> Result<(), ConfigError> {
    if !value.is_finite() || value < 0.0 {
        return Err(ConfigError::InvalidLayout(format!(
            "{name} must be finite and nonnegative"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{Insets, LayoutNode, LayoutTrack, Surface, SurfaceOrigin};
    use crate::{CompactStatus, CompactStatusWidget, Metric, MetricId, Ratio, Stat};
    use serde_json::json;
    use std::collections::HashSet;

    #[test]
    fn four_surface_tree_serialization_is_exact() {
        let cpu = Metric::<Ratio>::new(MetricId::new("cpu").unwrap());
        let backup = Metric::<CompactStatus>::new(MetricId::new("backup").unwrap());
        let cpu_widget = crate::Widget::from(Stat::new("CPU", &cpu).percent());
        let backup_widget = crate::Widget::from(CompactStatusWidget::new("Backup", backup));
        let surfaces = vec![
            Surface::desktop(LayoutNode::stack(
                4.0,
                vec![LayoutNode::widget(cpu_widget.clone())],
            ))
            .position(32.0, 32.0, SurfaceOrigin::BottomLeft)
            .width(400.0)
            .background_opacity(0.0)
            .click_through(true),
            Surface::widget_large(LayoutNode::section(
                "Perf",
                Insets::all(8.0),
                LayoutNode::widget(cpu_widget.clone()),
            )),
            Surface::widget_medium(LayoutNode::split(
                6.0,
                120.0,
                vec![
                    LayoutTrack::new(2.0, LayoutNode::widget(cpu_widget.clone())),
                    LayoutTrack::new(1.0, LayoutNode::widget(backup_widget.clone())),
                ],
            )),
            Surface::widget_small(LayoutNode::flow(
                3.0,
                4.0,
                80.0,
                vec![LayoutNode::widget(backup_widget)],
            )),
        ];
        assert_eq!(
            serde_json::to_value(surfaces).unwrap(),
            json!([
                {"kind":"desktop","root":{"kind":"stack","gap":4.0,"children":[{"kind":"widget","widget":{"kind":"value","label":"CPU","metric":"cpu","format":"percent"}}]},"x":32.0,"y":32.0,"origin":"bottom_left","width":400.0,"content_inset":16.0,"background_opacity":0.0,"click_through":true},
                {"kind":"widget_large","root":{"kind":"section","title":"Perf","insets":{"top":8.0,"right":8.0,"bottom":8.0,"left":8.0},"child":{"kind":"widget","widget":{"kind":"value","label":"CPU","metric":"cpu","format":"percent"}}}},
                {"kind":"widget_medium","root":{"kind":"split","gap":6.0,"minimum_track_width":120.0,"tracks":[{"weight":2.0,"child":{"kind":"widget","widget":{"kind":"value","label":"CPU","metric":"cpu","format":"percent"}}},{"weight":1.0,"child":{"kind":"widget","widget":{"kind":"compact_status","label":"Backup","metric":"backup","format":"compact_status"}}}]}},
                {"kind":"widget_small","root":{"kind":"flow","horizontal_gap":3.0,"vertical_gap":4.0,"minimum_item_width":80.0,"children":[{"kind":"widget","widget":{"kind":"compact_status","label":"Backup","metric":"backup","format":"compact_status"}}]}}
            ])
        );
    }

    #[test]
    fn validates_depth_node_geometry_and_references() {
        let cpu = Metric::<Ratio>::new(MetricId::new("cpu").unwrap());
        let widget = crate::Widget::from(Stat::new("CPU", &cpu).percent());
        let registered = HashSet::from([cpu.id()]);

        let mut deep = LayoutNode::widget(widget.clone());
        for _ in 0..32 {
            deep = LayoutNode::section("deep", Insets::default(), deep);
        }
        assert!(Surface::widget_small(deep).validate(&registered).is_err());

        let many = LayoutNode::stack(
            0.0,
            (0..257)
                .map(|_| LayoutNode::widget(widget.clone()))
                .collect(),
        );
        assert!(Surface::widget_large(many).validate(&registered).is_err());

        assert!(
            Surface::desktop(LayoutNode::widget(widget.clone()))
                .width(0.0)
                .validate(&registered)
                .is_err()
        );
        assert!(
            Surface::widget_medium(LayoutNode::stack(
                f64::NAN,
                vec![LayoutNode::widget(widget.clone())]
            ))
            .validate(&registered)
            .is_err()
        );
        assert!(
            Surface::widget_medium(LayoutNode::split(
                0.0,
                100.0,
                vec![LayoutTrack::new(0.0, LayoutNode::widget(widget.clone()))]
            ))
            .validate(&registered)
            .is_err()
        );
        assert!(
            Surface::widget_medium(LayoutNode::section(
                "bad",
                Insets::all(-1.0),
                LayoutNode::widget(widget.clone())
            ))
            .validate(&registered)
            .is_err()
        );
        assert!(
            Surface::widget_small(LayoutNode::widget(widget))
                .validate(&HashSet::new())
                .is_err()
        );
    }
}
