//! The Agent VMM worker of one Salix node (`SalixStore.AgentVMM.Worker` owns
//! it as a port). It terminates the Hosts' `agent-vmm/rpc/1` connections,
//! calls the node's Salix for every control decision over its stdio, runs the
//! typed runtime operations Salix asks for over a private Unix socket, and
//! dials outbound iroh service tunnels. It keeps transport state only.

pub mod connect;
pub mod control;
pub mod gateway;
pub mod image_import;
pub mod iroh_tunnel;
pub mod json;
pub mod local;
pub mod mux;
pub mod operations;
pub mod pb;
pub mod registry;
pub mod rpc;
pub mod runtime_error;
pub mod server;
pub mod session;
pub mod status;
#[cfg(feature = "test-host")]
pub mod testing;

pub use server::{Config, run};
