pub const PerformanceOptions = struct {
    focus_poll_interval_seconds: f64 = 0.08,
    fallback_snapshot_poll_interval_seconds: f64 = 0.75,
    observer_backstop_snapshot_poll_interval_seconds: f64 = 0.20,
    control_poll_interval_seconds: f64 = 0.02,
    immediate_relayout_delay_seconds: f64 = 0.01,
    burst_relayout_delay_seconds: f64 = 0.04,
    burst_window_seconds: f64 = 0.12,
    min_relayout_interval_seconds: f64 = 0.03,
    self_event_suppression_window_seconds: f64 = 0.20,
    swap_double_tap_window_seconds: f64 = 0.35,
};
