use prost::Message;
use std::{env, fs, path::PathBuf};

// The protos are compiled in-process: the image and CI need no `protoc`.
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let files = [
        "host/v1/runtime.proto",
        "remote/v1/remote.proto",
        "service/v1/service.proto",
        "trust/v1/trust.proto",
        "google/rpc/status.proto",
        "google/rpc/error_details.proto",
    ];
    let descriptors = protox::compile(files, ["proto"])?;
    let out = PathBuf::from(env::var("OUT_DIR")?);
    fs::write(out.join("descriptors.bin"), descriptors.encode_to_vec())?;
    prost_build::Config::new()
        .enable_type_names()
        .compile_fds(descriptors)?;
    println!("cargo:rerun-if-changed=proto");
    Ok(())
}
