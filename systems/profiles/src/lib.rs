//! Profiles as Comma (Salix's AccountPool) and its stations both use them: one data structure and one logic, loaded by
//! Salix as a NIF (`nif/`) and by a station in its mesh addon (`systems/station/native/mesh`). What stays with each side
//! is storage and the network: Salix keeps the credentials sealed, signs accounts in and reads their allowances; a
//! station runs the runtimes (Claude Code, Codex).
//!
//! - `sources`: what a Profile connects to (generated with the model catalog: scripts/generate-model-catalog.mjs).
//! - `model`: a Profile, its allowance windows and a model's spellings.
//! - `pool`: which Profiles serve a request, best first.
//! - `runtime`: how a runtime is given a Profile (its environment, Codex's provider overrides).
//! - `quota`: a provider's answer about an allowance, as a Profile's quota.

pub mod model;
pub mod pool;
pub mod quota;
pub mod runtime;
pub mod sources;

pub use model::{Credential, Profile, Quota, Status, Window, model_key, same_model};
pub use pool::{Request, Signals, Urgency, rank, serves, urgency, usable};
pub use runtime::{Runtime, RuntimeConfig, codex_overrides, runtime_config, runtimes};
pub use sources::{Auth, Endpoints, Protocol, Source, SourceKind, endpoints, find, sources};
