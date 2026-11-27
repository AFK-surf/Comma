//! What one worker process knows: which Host connections it holds and which
//! runtime sessions ride on them. Salix owns every durable fact.

use crate::{
    control::{CALL_TIMEOUT, Control, ControlError},
    session::{RuntimeSession, SessionKey},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

#[derive(Default)]
struct Live {
    epoch: u64,
    handshake: Arc<tokio::sync::Mutex<()>>,
    references: usize,
}

pub struct Gateway {
    pub id: String,
    pub control: Arc<Control>,
    draining: AtomicBool,
    live: Mutex<HashMap<String, Live>>,
    sessions: Mutex<HashMap<SessionKey, Arc<RuntimeSession>>>,
}

impl Gateway {
    pub fn new(id: String, control: Arc<Control>) -> Arc<Self> {
        Arc::new(Self {
            id,
            control,
            draining: AtomicBool::new(false),
            live: Mutex::default(),
            sessions: Mutex::default(),
        })
    }

    pub fn draining(&self) -> bool {
        self.draining.load(Ordering::Acquire)
    }

    pub fn drain(&self) {
        self.draining.store(true, Ordering::Release);
    }

    // ---- registrations ---------------------------------------------------------

    /// Keeps one handshake owner while a stream or waiter uses this
    /// registration. The last stream removes it, a failed first handshake included.
    pub fn retain_registration(&self, registration_id: &str) -> Arc<tokio::sync::Mutex<()>> {
        let mut live = self.live.lock().expect("live registrations");
        let current = live.entry(registration_id.to_owned()).or_default();
        current.references += 1;
        current.handshake.clone()
    }

    pub fn release_registration(&self, registration_id: &str) {
        let mut live = self.live.lock().expect("live registrations");
        if let Some(current) = live.get_mut(registration_id) {
            current.references -= 1;
            if current.references == 0 {
                live.remove(registration_id);
            }
        }
    }

    /// Makes `epoch` this registration's connection here. Refuses the epoch it already has.
    pub fn admit_epoch(&self, registration_id: &str, epoch: u64) -> bool {
        {
            let mut live = self.live.lock().expect("live registrations");
            let current = live.entry(registration_id.to_owned()).or_default();
            if current.epoch == epoch {
                return false;
            }
            current.epoch = epoch;
        }
        self.emit_stats();
        true
    }

    /// Ends `epoch` unless a newer connection has replaced it.
    pub fn retire_epoch(&self, registration_id: &str, epoch: u64) {
        {
            let mut live = self.live.lock().expect("live registrations");
            if let Some(current) = live.get_mut(registration_id)
                && current.epoch == epoch
            {
                current.epoch = 0;
            }
        }
        self.emit_stats();
    }

    // ---- sessions --------------------------------------------------------------

    /// Publishes a session. One it replaces is closed.
    pub fn insert_session(&self, key: SessionKey, session: Arc<RuntimeSession>) {
        let previous = self.sessions.lock().expect("sessions").insert(key, session);
        if let Some(previous) = previous {
            previous.close();
        }
        self.emit_stats();
    }

    pub fn session(&self, key: &SessionKey) -> Option<Arc<RuntimeSession>> {
        self.sessions
            .lock()
            .expect("sessions")
            .get(key)
            .filter(|session| session.usable())
            .cloned()
    }

    pub fn is_current_session(&self, key: &SessionKey, session: &Arc<RuntimeSession>) -> bool {
        self.session(key)
            .is_some_and(|current| Arc::ptr_eq(&current, session))
    }

    pub fn remove_session(&self, key: &SessionKey, session: &Arc<RuntimeSession>) {
        {
            let mut sessions = self.sessions.lock().expect("sessions");
            if sessions
                .get(key)
                .is_some_and(|current| Arc::ptr_eq(current, session))
            {
                sessions.remove(key);
            }
        }
        session.close();
        self.emit_stats();
    }

    /// Closes every session of one Host connection.
    pub fn close_connection_sessions(&self, registration_id: &str, epoch: u64) {
        let closed: Vec<Arc<RuntimeSession>> = {
            let mut sessions = self.sessions.lock().expect("sessions");
            let keys: Vec<SessionKey> = sessions
                .keys()
                .filter(|key| {
                    key.registration_id == registration_id && key.connection_epoch == epoch
                })
                .cloned()
                .collect();
            keys.iter().filter_map(|key| sessions.remove(key)).collect()
        };
        for session in &closed {
            session.close();
        }
        self.emit_stats();
    }

    // ---- facts for Salix -------------------------------------------------------

    fn emit_stats(&self) {
        let connections = self
            .live
            .lock()
            .expect("live registrations")
            .values()
            .filter(|current| current.epoch != 0)
            .count();
        let sessions = self.sessions.lock().expect("sessions").len();
        self.control
            .event(json!({"event": "stats", "connections": connections, "sessions": sessions}));
    }

    pub fn count(&self, name: &'static str) {
        self.control.event(json!({"event": "count", "name": name}));
    }

    // ---- control calls ---------------------------------------------------------

    pub async fn authenticate(
        &self,
        registration_id: &str,
        credential: &[u8],
    ) -> Result<(), ControlError> {
        let body = json!({
            "registration_id": registration_id,
            "credential_b64": STANDARD.encode(credential),
        });
        self.control
            .call("authenticate", body, CALL_TIMEOUT)
            .await
            .map(drop)
    }

    pub async fn call(
        &self,
        op: &'static str,
        body: Value,
        limit: Duration,
    ) -> Result<Option<Value>, ControlError> {
        self.control.call(op, body, limit.min(CALL_TIMEOUT)).await
    }
}
