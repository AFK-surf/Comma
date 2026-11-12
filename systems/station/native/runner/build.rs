//! Builds the LAN script runtime (lan-script/, the firmware's components/lan_script with Micro QuickJS) into the runner.
//! Micro QuickJS keeps its standard library as tables a host program makes from lan_script_stdlib.c: that program is
//! built with this machine's compiler and run here, for the target's word size.

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("lan-script");
    let q = dir.join("mquickjs");
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    println!("cargo:rerun-if-changed=lan-script");

    let host = env::var("HOST").unwrap();
    let host_cc = cc::Build::new().target(&host).host(&host).opt_level(2).cargo_metadata(false).get_compiler();
    let generator = out.join(if host.contains("windows") { "stdlib_gen.exe" } else { "stdlib_gen" });
    let status = host_cc
        .to_command()
        .args(["-D_GNU_SOURCE", "-I"])
        .arg(&q)
        .arg("-o")
        .arg(&generator)
        .arg(dir.join("lan_script_stdlib.c"))
        .arg(q.join("mquickjs_build.c"))
        .status()
        .expect("the host C compiler");
    assert!(status.success(), "building the Micro QuickJS stdlib generator failed");
    let word32 = env::var("CARGO_CFG_TARGET_POINTER_WIDTH").unwrap() == "32";
    for (flag, file) in [(Some("-a"), "mquickjs_atom.h"), (None, "lan_script_stdlib.h")] {
        let mut cmd = Command::new(&generator);
        cmd.args(flag).args(word32.then_some("-m32"));
        let output = cmd.output().expect("the stdlib generator");
        assert!(output.status.success(), "the stdlib generator failed");
        std::fs::write(out.join(file), output.stdout).unwrap();
    }

    let mut build = cc::Build::new();
    build
        .include(&out)
        .include(&q)
        .include(dir.join("include"))
        .define("_GNU_SOURCE", None)
        .flag_if_supported("-fno-math-errno")
        .flag_if_supported("-fno-trapping-math")
        .warnings(false)
        .file(dir.join("lan_script.c"));
    for f in ["mquickjs.c", "cutils.c", "dtoa.c", "libm.c"] {
        build.file(q.join(f));
    }
    build.compile("lan_script");
}
