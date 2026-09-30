# spinfoam runtime pin

`SPINFOAM_VERSION` pins the [spinfoam](https://github.com/AFK-surf/spinfoam)
release that runs Agent background Loops; `SHA256SUMS` is that release's
digest list. `fetch.sh` downloads the release package for the current
platform, verifies it against `SHA256SUMS`, and installs the binary into
`apps/salix_agent/priv/spinfoam`. `mix compile`, CI and the release image all
run the same script; nothing is compiled from source. Update both files,
refetch, and run the `:spinfoam` tagged tests together.

The C compiler is embedded: TinyCC compiled to eBPF, run inside spinfoam's
own VM, so neither fetching nor running spinfoam needs a toolchain, sandbox
or privilege. The Host always starts the runtime with `--enable-builds`.
Releases ship Linux (x86_64, aarch64, glibc 2.31 or newer) and macOS
(x86_64, arm64) packages.
