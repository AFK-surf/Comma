//! A test Host as a process, for tests that own the worker as a port:
//!
//! * `salix_vmm_test_host gen-cert <dir>` writes `tls.crt` and `tls.key`;
//! * `salix_vmm_test_host run <addr> <trust.pem> <registration_id> <credential_b64> <epoch>`
//!   connects and prints one JSON line per event. When the controller ends the
//!   connection for a fresh inventory, it reconnects under the next epoch with
//!   the allocations it was given. It exits when its stdin closes.

use base64::{Engine, engine::general_purpose::STANDARD};
use salix_vmm_worker::{
    pb::{
        self,
        remote::{self, controller_command::Command},
    },
    status::Status,
    testing::{Event, Host, HostConfig, generate_certificate},
};
use serde_json::{Value, json};
use std::{io::Write, path::Path, process::exit};
use tokio::io::AsyncReadExt;

fn line(value: Value) {
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{value}");
    let _ = stdout.flush();
}

/// Prints one connection's events and returns its terminal status.
async fn events(host: &mut Host, config: &mut HostConfig) -> Status {
    loop {
        match host.next().await {
            Event::Ready(ready) => line(json!({
                "event": "ready", "connection_epoch": ready.connection_epoch.to_string(),
            })),
            Event::Command(command) => {
                if let Some(Command::EnsureAllocation(ensure)) = &command.command
                    && !ensure.allocation_id.starts_with("full")
                {
                    config
                        .inventory
                        .retain(|held| held.allocation_id != ensure.allocation_id);
                    config.inventory.push(remote::Allocation {
                        allocation_id: ensure.allocation_id.clone(),
                        display_label: ensure.display_label.clone(),
                        limits: ensure.limits,
                        egress_mode: ensure.egress_mode,
                        revision: ensure.policy_revision.max(1),
                        state: remote::AllocationState::Ready as i32,
                        generation: ensure.generation,
                    });
                    config.inventory_watermark += 1;
                }
                line(json!({
                    "event": "command", "command": pb::to_json(&command).unwrap_or(Value::Null),
                }));
            }
            Event::Runtime {
                method, request, ..
            } => line(json!({"event": "runtime", "method": method, "request": request})),
            Event::Ended(status) => {
                line(json!({
                    "event": "ended", "code": status.code as i32, "message": status.message,
                }));
                return status;
            }
        }
    }
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    match args.as_slice() {
        ["gen-cert", directory] => {
            let (certificate, key) = generate_certificate();
            let directory = Path::new(directory);
            std::fs::write(directory.join("tls.crt"), certificate)
                .expect("the certificate is written");
            std::fs::write(directory.join("tls.key"), key).expect("the key is written");
        }
        ["run", addr, trust, registration_id, credential, epoch] => {
            let trust = std::fs::read(trust).expect("the trust bundle is readable");
            let credential = STANDARD
                .decode(credential)
                .expect("the credential is base64");
            let epoch = epoch.parse().expect("the epoch is a number");
            let mut config = HostConfig::new(registration_id, &credential, epoch);
            let stdin_closed = async {
                let mut stdin = tokio::io::stdin();
                let mut buffer = [0u8; 64];
                while matches!(stdin.read(&mut buffer).await, Ok(count) if count > 0) {}
            };
            let connections = async {
                loop {
                    let mut host = match Host::start(addr, &trust, config.clone()).await {
                        Ok(host) => host,
                        Err(error) => {
                            line(json!({"event": "failed", "error": error.to_string()}));
                            return 1;
                        }
                    };
                    if !events(&mut host, &mut config).await.is_ok() {
                        return 1;
                    }
                    config.connection_epoch += 1;
                }
            };
            let code = tokio::select! {
                _ = stdin_closed => 0,
                code = connections => code,
            };
            exit(code);
        }
        _ => {
            eprintln!(
                "usage: salix_vmm_test_host gen-cert <dir> | run <addr> <trust.pem> <registration_id> <credential_b64> <epoch>"
            );
            exit(2);
        }
    }
}
