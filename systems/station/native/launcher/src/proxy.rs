//! An entrance the launcher keeps for a port it cannot hand to Node (Windows: Node cannot listen on a socket handed
//! down): the launcher holds the listening socket for good and carries each connection to the Node that serves it now.
//!
//! Which Node that is the lifecycle says (`serve`): the one that said it serves on that port, which a Node says only once
//! it has taken over (its agents' door opens after the previous one has handed its sessions over), so a connection never
//! reaches a Node that has not. A connection that comes while none serves (a handover's moment between the old Node
//! leaving and the new one taking over, a restart) waits for one, at most `wait`, then is closed. One already carried
//! stays with the Node it went to until either end closes it: nothing is moved or replayed.

use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use crate::log;

/// Where connections go now: the port of the Node serving, on 127.0.0.1; none while none does.
type Target = Arc<(Mutex<Option<u16>>, Condvar)>;

pub struct Entrance {
    target: Target,
}

impl Entrance {
    /// Carries what comes to `listener` (`name` for what is said of it), from now on.
    pub fn open(name: &'static str, listener: TcpListener, wait: Duration) -> Entrance {
        let target: Target = Arc::new((Mutex::new(None), Condvar::new()));
        let theirs = target.clone();
        std::thread::spawn(move || {
            for client in listener.incoming() {
                match client {
                    Ok(client) => {
                        let target = theirs.clone();
                        std::thread::spawn(move || carry(name, client, &target, wait));
                    }
                    Err(error) => log::warn(&format!("{name}: a connection not taken: {error}")),
                }
            }
        });
        Entrance { target }
    }

    /// New connections go to `port` (a Node's, on 127.0.0.1) from now on; none: they wait.
    pub fn serve(&self, port: Option<u16>) {
        let (lock, changed) = &*self.target;
        *lock.lock().unwrap_or_else(|e| e.into_inner()) = port;
        changed.notify_all();
    }
}

/// One connection to the Node serving (waiting, at most `wait`, for one to), both ways until either end is done.
fn carry(name: &str, client: TcpStream, target: &Target, wait: Duration) {
    let port = {
        let (lock, changed) = &**target;
        let until = Instant::now() + wait;
        let mut port = lock.lock().unwrap_or_else(|e| e.into_inner());
        while port.is_none() {
            let left = until.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            port = changed.wait_timeout(port, left).unwrap_or_else(|e| e.into_inner()).0;
        }
        *port
    };
    let Some(port) = port else {
        log::warn(&format!("{name}: no station serving within {} s; a connection closed", wait.as_secs_f32()));
        return;
    };
    let node = match TcpStream::connect(("127.0.0.1", port)) {
        Ok(node) => node,
        Err(error) => {
            log::warn(&format!("{name}: the station on port {port} not reached: {error}"));
            return;
        }
    };
    let _ = client.set_nodelay(true);
    let _ = node.set_nodelay(true);
    let (Ok(client_out), Ok(node_out)) = (client.try_clone(), node.try_clone()) else { return };
    let up = std::thread::spawn(move || pipe(client, node_out));
    pipe(node, client_out);
    let _ = up.join();
}

/// What `from` sends, to `to`, until `from` is done; then `to` is told nothing more comes.
fn pipe(mut from: TcpStream, mut to: TcpStream) {
    let mut buf = [0u8; 16 * 1024];
    loop {
        match from.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                if to.write_all(&buf[..n]).is_err() {
                    break;
                }
            }
        }
    }
    let _ = to.shutdown(Shutdown::Write);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{self, BufRead};

    /// A Node of the test's: answers each line with its name and the line.
    fn node(name: &'static str) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for conn in listener.incoming().flatten() {
                std::thread::spawn(move || {
                    let mut out = conn.try_clone().unwrap();
                    for line in io::BufReader::new(conn).lines().map_while(Result::ok) {
                        if writeln!(out, "{name}:{line}").is_err() {
                            return;
                        }
                    }
                });
            }
        });
        port
    }

    fn entrance(wait: Duration) -> (Entrance, u16) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        (Entrance::open("test", listener, wait), port)
    }

    /// A line through the entrance on `conn`, and what came back.
    fn ask(conn: &mut io::BufReader<TcpStream>, line: &str) -> String {
        writeln!(conn.get_mut(), "{line}").unwrap();
        let mut said = String::new();
        conn.read_line(&mut said).unwrap();
        said.trim_end().to_string()
    }

    fn connect(port: u16) -> io::BufReader<TcpStream> {
        let conn = TcpStream::connect(("127.0.0.1", port)).unwrap();
        conn.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        io::BufReader::new(conn)
    }

    #[test]
    fn a_connection_goes_to_the_node_serving_and_stays_with_it_when_another_takes_over() {
        let (entrance, port) = entrance(Duration::from_secs(10));
        entrance.serve(Some(node("old")));
        let mut first = connect(port);
        assert_eq!(ask(&mut first, "a"), "old:a");
        entrance.serve(Some(node("new")));
        // Carried before: still the old one's (nothing moved); new ones the new one's.
        assert_eq!(ask(&mut first, "b"), "old:b");
        let mut second = connect(port);
        assert_eq!(ask(&mut second, "c"), "new:c");
    }

    #[test]
    fn a_connection_while_none_serves_waits_for_the_one_that_takes_over() {
        let (entrance, port) = entrance(Duration::from_secs(10));
        let mut waiting = connect(port);
        writeln!(waiting.get_mut(), "early").unwrap();
        std::thread::sleep(Duration::from_millis(300));
        entrance.serve(Some(node("next")));
        let mut said = String::new();
        waiting.read_line(&mut said).unwrap();
        assert_eq!(said.trim_end(), "next:early");
    }

    #[test]
    fn a_connection_none_takes_up_in_time_is_closed() {
        let (_entrance, port) = entrance(Duration::from_millis(200));
        let mut conn = connect(port);
        let mut said = String::new();
        // Closed by the entrance: the end of what comes, nothing said.
        assert_eq!(conn.read_line(&mut said).unwrap(), 0);
    }
}
