//! A runtime session: the authority one `OpenSession` gave Salix over one
//! allocation, used on the Host connection that issued it.

use crate::{
    mux::MuxHandle,
    rpc::{self, ClientCall, ClientSender},
    status::Status,
};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::{sync::Notify, task::AbortHandle, time::Instant};

pub const MAX_PROCESSES: usize = 256;
pub const MAX_START_REQUESTS: usize = 1024;
pub const OUTPUT_BOUND: usize = 8 << 20;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SessionKey {
    pub registration_id: String,
    pub allocation_id: String,
    pub allocation_generation: u64,
    pub connection_epoch: u64,
}

pub struct StartRecord {
    pub process_id: String,
    pub fingerprint: String,
}

#[derive(Default)]
pub struct Processes {
    pub starting: usize,
    pub running: HashMap<String, Arc<RuntimeProcess>>,
}

pub struct ProcessState {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub state: &'static str,
    pub exit_code: Option<u32>,
    pub oom_killed: bool,
    pub memory_peak_bytes: Option<u64>,
    pub version: u64,
    pub last_tailed_version: u64,
}

pub struct RuntimeProcess {
    pub created_at: Instant,
    /// Held across a send, so writes and signals reach the Host in order.
    pub sender: tokio::sync::Mutex<ClientSender>,
    pub state: Mutex<ProcessState>,
    pub notify: Notify,
    pub receiver: Mutex<Option<AbortHandle>>,
}

pub struct RuntimeSession {
    mux: MuxHandle,
    metadata: Vec<(String, String)>,
    expires_unix_millis: i64,
    closed: AtomicBool,
    /// A request id is the idempotency authority of `process.start`. Starts
    /// take this before `processes`.
    pub start_requests: tokio::sync::Mutex<HashMap<String, StartRecord>>,
    pub processes: Mutex<Processes>,
}

impl RuntimeSession {
    pub fn new(
        mux: MuxHandle,
        allocation_id: &str,
        allocation_generation: u64,
        tunnel_nonce: &str,
        expires_unix_millis: i64,
    ) -> Arc<Self> {
        Arc::new(Self {
            mux,
            metadata: vec![
                ("x-agentvmm-allocation-id".into(), allocation_id.into()),
                (
                    "x-agentvmm-allocation-generation".into(),
                    allocation_generation.to_string(),
                ),
                ("authorization".into(), format!("Bearer {tunnel_nonce}")),
            ],
            expires_unix_millis,
            closed: AtomicBool::new(false),
            start_requests: tokio::sync::Mutex::default(),
            processes: Mutex::default(),
        })
    }

    pub fn closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }

    /// Open, on a live connection, and inside the time the Host gave it.
    pub fn usable(&self) -> bool {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|elapsed| elapsed.as_millis() as i64)
            .unwrap_or(i64::MAX);
        !self.closed() && !self.mux.closed().is_cancelled() && now < self.expires_unix_millis
    }

    /// Starts one `AgentRuntimeService` call under this session's authority.
    pub async fn call(
        &self,
        method: &str,
        deadline: Option<Instant>,
    ) -> Result<ClientCall, Status> {
        let (read, write) = self.mux.open().await?;
        let path = format!("/agentvmm.host.v1.AgentRuntimeService/{method}");
        rpc::open(read, write, &path, self.metadata.clone(), deadline).await
    }

    /// Closing the carrier makes an in-flight process unknown; it does not
    /// prove that the process exited. The Host keeps the guest exec alive.
    pub fn close(&self) {
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        let mut processes = self.processes.lock().expect("processes");
        for process in processes.running.values() {
            if let Some(receiver) = process.receiver.lock().expect("receiver").take() {
                receiver.abort();
            }
            {
                let mut state = process.state.lock().expect("process state");
                if state.state != "exited" {
                    state.state = "unknown";
                    state.version = state.version.wrapping_add(1);
                }
            }
            process.notify.notify_waiters();
        }
        processes.running.clear();
        processes.starting = 0;
        drop(processes);
        // A start in flight holds the lock; it finds the session closed when it resumes.
        if let Ok(mut requests) = self.start_requests.try_lock() {
            requests.clear();
        }
    }
}
