# SalixLlm

Agent-loop provider calls use `SalixLlm.Http` for network I/O and callback delivery.
The [Lean provider kernel](../../native/verified_kernel/runtime/VerifiedKernel/Provider/Dispatch.lean) owns the three wire protocols and their request-local stream state.
The [kernel contract](../../native/verified_kernel/README.md#provider-domain) lists the responsibilities, proofs, and runtime assumptions.

Elixir resolves credentials, calls Req, executes timeouts and retry delays, and delivers the kernel's ordered callbacks.
Provider wrappers select the existing public entry points. They do not duplicate request or stream logic.
`SiteProxy`, transcription, and audio processing serve separate site and media APIs. Their contracts are outside the agent-loop provider boundary.

Run the provider regression suite from `systems`:

```sh
mix test apps/salix_llm/test
```
