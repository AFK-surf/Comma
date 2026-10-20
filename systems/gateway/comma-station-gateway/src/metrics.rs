//! Prometheus metrics, served on the admin listener's `/metrics`.
//!
//! Labels are finite: the op is folded into the contract's v1 op set (else
//! `other`) and the outcome into a fixed set. No station, user, workspace or
//! request identifier is ever a label.
//!
//! Operational questions (see k8s/comma-station-gateway/chart/templates/monitoring.yaml):
//! - Are stations reachable? `requests_total{outcome="unreachable"|"disconnected"}`
//!   and `connects_total{result="failed"}` against all requests.
//! - Are requests slow or timing out? `request_duration_seconds` and
//!   `requests_total{outcome="timeout"}`.
//! - Is the gateway saturated? `in_flight` against its limit, and
//!   `requests_total{outcome="overloaded"}`.

use std::time::Duration;

use prometheus_client::{
    encoding::{EncodeLabelSet, text::encode},
    metrics::{counter::Counter, family::Family, gauge::Gauge, histogram::Histogram},
    registry::Registry,
};

const OPS: &[&str] = &[
    "exec",
    "fs.read",
    "fs.write",
    "fs.list",
    "fs.stat",
    "process.start",
    "process.write",
    "process.tail",
    "process.stop",
    "process.list",
    "runtime.probe",
    "session.start",
    "session.say",
    "session.status",
];

#[derive(Clone, Debug, Hash, PartialEq, Eq, EncodeLabelSet)]
struct RequestLabels {
    op: &'static str,
    outcome: &'static str,
}

#[derive(Clone, Debug, Hash, PartialEq, Eq, EncodeLabelSet)]
struct OutcomeLabels {
    outcome: &'static str,
}

#[derive(Clone, Debug, Hash, PartialEq, Eq, EncodeLabelSet)]
struct ConnectLabels {
    result: &'static str,
}

pub struct Metrics {
    registry: Registry,
    requests: Family<RequestLabels, Counter>,
    durations: Family<OutcomeLabels, Histogram>,
    connects: Family<ConnectLabels, Counter>,
    pub connections: Gauge,
    pub in_flight: Gauge,
}

impl Default for Metrics {
    fn default() -> Self {
        Self::new()
    }
}

impl Metrics {
    pub fn new() -> Self {
        let mut registry = Registry::with_prefix("comma_station_gateway");
        let requests = Family::<RequestLabels, Counter>::default();
        let durations = Family::<OutcomeLabels, Histogram>::new_with_constructor(|| {
            Histogram::new([
                0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 300.0, 900.0,
            ])
        });
        let connects = Family::<ConnectLabels, Counter>::default();
        let connections = Gauge::default();
        let in_flight = Gauge::default();
        registry.register(
            "requests",
            "Tool requests by op and outcome",
            requests.clone(),
        );
        registry.register(
            "request_duration_seconds",
            "Tool request latency by outcome",
            durations.clone(),
        );
        registry.register(
            "connects",
            "Station dial attempts by result",
            connects.clone(),
        );
        registry.register(
            "connections",
            "Open cached station connections",
            connections.clone(),
        );
        registry.register("in_flight", "Tool requests in flight", in_flight.clone());
        Self {
            registry,
            requests,
            durations,
            connects,
            connections,
            in_flight,
        }
    }

    pub fn request(&self, op: &str, outcome: &'static str, elapsed: Duration) {
        let op = OPS
            .iter()
            .copied()
            .find(|known| *known == op)
            .unwrap_or("other");
        self.requests
            .get_or_create(&RequestLabels { op, outcome })
            .inc();
        self.durations
            .get_or_create(&OutcomeLabels { outcome })
            .observe(elapsed.as_secs_f64());
    }

    pub fn connect(&self, ok: bool) {
        let result = if ok { "ok" } else { "failed" };
        self.connects.get_or_create(&ConnectLabels { result }).inc();
    }

    pub fn render(&self) -> String {
        let mut out = String::new();
        // Encoding into a String cannot fail.
        let _ = encode(&mut out, &self.registry);
        out
    }
}
