//! `comma-runner --lan-script`: runs one LAN script (the station's `lan_script`, src/connector/lan-script.ts) in the
//! firmware's runtime (lan-script/, Micro QuickJS), so a script behaves the same on a computer as on a gateway board.
//!
//! JSON lines over stdin and stdout. The station sends `{"source", "args", "timeout_ms", "heap_bytes",
//! "max_result_bytes"}`; each LAN call of the script goes out as `{"call": method, "params": …}` and waits for
//! `{"result": …}` or `{"error": "…"}`; the end is `{"done": {"result" | "error", "logs", …}}`. The station does the
//! network work itself, with its own limits. The crypto the runtime asks for (lan_script_crypto.h) is RustCrypto's.

use std::ffi::{c_char, c_void};
use std::io::{self, BufRead, Write};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

#[repr(C)]
struct Host {
    call: unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char, usize, *mut *mut c_char) -> bool,
    wall_ms: unsafe extern "C" fn(*mut c_void) -> i64,
    monotonic_ms: unsafe extern "C" fn(*mut c_void) -> i64,
    sleep_ms: unsafe extern "C" fn(*mut c_void, u32),
    cancelled: Option<unsafe extern "C" fn(*mut c_void) -> *const c_char>,
    ctx: *mut c_void,
}

#[repr(C)]
struct Limits {
    heap: *mut c_void,
    heap_bytes: usize,
    deadline_ms: i64,
    max_result_bytes: usize,
    max_log_bytes: usize,
}

unsafe extern "C" {
    fn lan_script_run(host: *const Host, limits: *const Limits, source: *const c_char, source_len: usize, args: *const c_char, args_len: usize) -> *mut c_char;
    fn malloc(n: usize) -> *mut c_void;
    fn free(p: *mut c_void);
}

const DEFAULT_TIMEOUT_MS: u64 = 10_000;
const MAX_TIMEOUT_MS: u64 = 30_000;
const DEFAULT_HEAP: usize = 1 << 20;
const DEFAULT_RESULT: usize = 64 * 1024;
const MAX_LOGS: usize = 4096;

struct Io {
    lines: io::Lines<io::StdinLock<'static>>,
    out: io::Stdout,
    start: Instant,
}

fn send(out: &mut io::Stdout, value: &Value) -> io::Result<()> {
    let mut lock = out.lock();
    serde_json::to_writer(&mut lock, value)?;
    lock.write_all(b"\n")?;
    lock.flush()
}

/// A malloc'd C string, as the runtime frees what `call` returns.
fn c_string(text: &str) -> *mut c_char {
    unsafe {
        let p = malloc(text.len() + 1) as *mut u8;
        if !p.is_null() {
            std::ptr::copy_nonoverlapping(text.as_ptr(), p, text.len());
            *p.add(text.len()) = 0;
        }
        p as *mut c_char
    }
}

unsafe extern "C" fn call(ctx: *mut c_void, method: *const c_char, params: *const c_char, len: usize, out: *mut *mut c_char) -> bool {
    let io = unsafe { &mut *(ctx as *mut Io) };
    let method = unsafe { std::ffi::CStr::from_ptr(method) }.to_string_lossy().into_owned();
    let params = unsafe { std::slice::from_raw_parts(params as *const u8, len) };
    let (ok, text) = match serde_json::from_slice::<Value>(params) {
        Ok(params) if params.is_object() => match send(&mut io.out, &json!({ "call": method, "params": params })) {
            Ok(()) => match io.lines.next() {
                Some(Ok(line)) => match serde_json::from_str::<Value>(&line) {
                    Ok(reply) => match (reply.get("result"), reply.get("error")) {
                        (Some(result), _) => (true, result.to_string()),
                        (None, Some(Value::String(error))) => (false, error.clone()),
                        _ => (false, "the station answered without a result".to_string()),
                    },
                    Err(_) => (false, "the station answered with something other than JSON".to_string()),
                },
                // The station is gone: nothing more to do.
                _ => std::process::exit(1),
            },
            Err(_) => std::process::exit(1),
        },
        _ => (false, "params must be a JSON object".to_string()),
    };
    unsafe { *out = c_string(&text) };
    ok
}

unsafe extern "C" fn wall_ms(_ctx: *mut c_void) -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

unsafe extern "C" fn monotonic_ms(ctx: *mut c_void) -> i64 {
    let io = unsafe { &*(ctx as *const Io) };
    io.start.elapsed().as_millis() as i64
}

unsafe extern "C" fn sleep_ms(_ctx: *mut c_void, ms: u32) {
    std::thread::sleep(Duration::from_millis(ms as u64));
}

/// Runs the one script stdin names; the exit status is 0 when it answered `done`.
pub fn serve() -> i32 {
    let stdin: &'static io::Stdin = Box::leak(Box::new(io::stdin()));
    let mut io = Io { lines: stdin.lock().lines(), out: io::stdout(), start: Instant::now() };
    let request: Value = match io.lines.next() {
        Some(Ok(line)) => match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("comma-runner: the lan script request is not JSON: {e}");
                return 2;
            }
        },
        _ => return 2,
    };
    let source = request.get("source").and_then(Value::as_str).unwrap_or_default().to_string();
    let args = request.get("args").filter(|a| !a.is_null()).map(Value::to_string).unwrap_or_default();
    let number = |key: &str, default: u64| request.get(key).and_then(Value::as_u64).unwrap_or(default);
    let timeout = number("timeout_ms", DEFAULT_TIMEOUT_MS).clamp(1, MAX_TIMEOUT_MS);
    let heap_bytes = number("heap_bytes", DEFAULT_HEAP as u64) as usize;
    let mut heap = vec![0u8; heap_bytes];
    let host = Host { call, wall_ms, monotonic_ms, sleep_ms, cancelled: None, ctx: &mut io as *mut Io as *mut c_void };
    let limits = Limits {
        heap: heap.as_mut_ptr() as *mut c_void,
        heap_bytes,
        deadline_ms: io.start.elapsed().as_millis() as i64 + timeout as i64,
        max_result_bytes: number("max_result_bytes", DEFAULT_RESULT as u64) as usize,
        max_log_bytes: MAX_LOGS,
    };
    let outcome = unsafe { lan_script_run(&host, &limits, source.as_ptr() as *const c_char, source.len(), args.as_ptr() as *const c_char, args.len()) };
    if outcome.is_null() {
        eprintln!("comma-runner: out of memory");
        return 1;
    }
    let text = unsafe { std::ffi::CStr::from_ptr(outcome) }.to_string_lossy().into_owned();
    unsafe { free(outcome as *mut c_void) };
    let done: Value = serde_json::from_str(&text).unwrap_or_else(|_| json!({ "error": "the runtime's answer was not JSON", "logs": [] }));
    if send(&mut io.out, &json!({ "done": done })).is_err() {
        return 1;
    }
    0
}

// ── lan_script_crypto.h ──

mod crypto {
    use std::ffi::c_int;

    use aes::cipher::{BlockDecrypt, BlockEncrypt, KeyInit, generic_array::GenericArray};
    use aes::{Aes128, Aes192, Aes256};
    use aes_gcm::aead::AeadInPlace;
    use aes_gcm::{AesGcm, Nonce, Tag};
    use hmac::{Hmac, Mac};
    use md5::Md5;
    use sha1::Sha1;
    use sha2::{Digest, Sha256};

    const MD5: c_int = 0;
    const SHA1: c_int = 1;

    fn hash_len(alg: c_int) -> usize {
        match alg {
            MD5 => 16,
            SHA1 => 20,
            _ => 32,
        }
    }

    unsafe fn slice<'a>(p: *const u8, n: usize) -> &'a [u8] {
        if n == 0 { &[] } else { unsafe { std::slice::from_raw_parts(p, n) } }
    }

    unsafe fn put(out: *mut u8, data: &[u8]) {
        unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), out, data.len()) };
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn lan_crypto_hash_len(alg: c_int) -> usize {
        hash_len(alg)
    }

    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn lan_crypto_hash(alg: c_int, input: *const u8, len: usize, out: *mut u8) -> c_int {
        let data = unsafe { slice(input, len) };
        let digest: Vec<u8> = match alg {
            MD5 => Md5::digest(data).to_vec(),
            SHA1 => Sha1::digest(data).to_vec(),
            _ => Sha256::digest(data).to_vec(),
        };
        unsafe { put(out, &digest) };
        0
    }

    fn hmac<M: Mac + KeyInit>(key: &[u8], data: &[u8]) -> Vec<u8> {
        let mut mac = <M as Mac>::new_from_slice(key).expect("HMAC takes any key");
        mac.update(data);
        mac.finalize().into_bytes().to_vec()
    }

    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn lan_crypto_hmac(alg: c_int, key: *const u8, key_len: usize, input: *const u8, len: usize, out: *mut u8) -> c_int {
        let (key, data) = unsafe { (slice(key, key_len), slice(input, len)) };
        let digest = match alg {
            MD5 => hmac::<Hmac<Md5>>(key, data),
            SHA1 => hmac::<Hmac<Sha1>>(key, data),
            _ => hmac::<Hmac<Sha256>>(key, data),
        };
        unsafe { put(out, &digest) };
        0
    }

    fn blocks<C: BlockEncrypt + BlockDecrypt + KeyInit>(key: &[u8], cbc: bool, encrypt: bool, iv: &[u8], data: &mut [u8]) -> bool {
        let Ok(cipher) = C::new_from_slice(key) else { return false };
        let mut chain = [0u8; 16];
        if cbc {
            chain.copy_from_slice(iv);
        }
        for block in data.chunks_exact_mut(16) {
            if encrypt {
                if cbc {
                    block.iter_mut().zip(chain).for_each(|(b, c)| *b ^= c);
                }
                cipher.encrypt_block(GenericArray::from_mut_slice(block));
                chain.copy_from_slice(block);
            } else {
                let mut next = [0u8; 16];
                next.copy_from_slice(block);
                cipher.decrypt_block(GenericArray::from_mut_slice(block));
                if cbc {
                    block.iter_mut().zip(chain).for_each(|(b, c)| *b ^= c);
                }
                chain = next;
            }
        }
        true
    }

    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn lan_crypto_aes_block(cbc: bool, encrypt: bool, key: *const u8, key_len: usize, iv: *const u8, input: *const u8, len: usize, out: *mut u8) -> c_int {
        let key = unsafe { slice(key, key_len) };
        let iv = if cbc { unsafe { slice(iv, 16) } } else { &[][..] };
        let mut data = unsafe { slice(input, len) }.to_vec();
        let ok = match key_len {
            16 => blocks::<Aes128>(key, cbc, encrypt, iv, &mut data),
            24 => blocks::<Aes192>(key, cbc, encrypt, iv, &mut data),
            32 => blocks::<Aes256>(key, cbc, encrypt, iv, &mut data),
            _ => false,
        };
        if !ok {
            return -1;
        }
        unsafe { put(out, &data) };
        0
    }

    fn gcm<C>(key: &[u8], encrypt: bool, iv: &[u8], aad: &[u8], data: &mut Vec<u8>, tag: &mut [u8]) -> bool
    where
        C: BlockEncrypt + KeyInit + aes::cipher::BlockSizeUser<BlockSize = aes::cipher::consts::U16> + aes::cipher::BlockCipher,
    {
        let Ok(cipher) = AesGcm::<C, aes::cipher::consts::U12>::new_from_slice(key) else { return false };
        let nonce = Nonce::from_slice(iv);
        if encrypt {
            match cipher.encrypt_in_place_detached(nonce, aad, data) {
                Ok(t) => {
                    tag.copy_from_slice(&t);
                    true
                }
                Err(_) => false,
            }
        } else {
            cipher.decrypt_in_place_detached(nonce, aad, data, Tag::from_slice(tag)).is_ok()
        }
    }

    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn lan_crypto_aes_gcm(
        encrypt: bool,
        key: *const u8,
        key_len: usize,
        iv: *const u8,
        iv_len: usize,
        aad: *const u8,
        aad_len: usize,
        input: *const u8,
        len: usize,
        out: *mut u8,
        tag: *mut u8,
    ) -> c_int {
        if iv_len != 12 {
            return -1;
        }
        let (key, iv, aad) = unsafe { (slice(key, key_len), slice(iv, iv_len), slice(aad, aad_len)) };
        let tag = unsafe { std::slice::from_raw_parts_mut(tag, 16) };
        let mut data = unsafe { slice(input, len) }.to_vec();
        let ok = match key_len {
            16 => gcm::<Aes128>(key, encrypt, iv, aad, &mut data, tag),
            24 => gcm::<Aes192>(key, encrypt, iv, aad, &mut data, tag),
            32 => gcm::<Aes256>(key, encrypt, iv, aad, &mut data, tag),
            _ => false,
        };
        if !ok {
            return -1;
        }
        unsafe { put(out, &data) };
        0
    }

    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn lan_crypto_random(out: *mut u8, len: usize) -> c_int {
        if len == 0 {
            return 0;
        }
        let buf = unsafe { std::slice::from_raw_parts_mut(out, len) };
        if getrandom::fill(buf).is_ok() { 0 } else { -1 }
    }
}
