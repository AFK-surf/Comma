# Differential tests against the external oracle run only with
# `--include signal_oracle` and COMMA_SIGNAL_ORACLE set.
ExUnit.start(exclude: [:signal_oracle], timeout: 180_000)

# Development hosts and the default CI image link OpenSSL 3.0, without
# ML-KEM; tests may run secret-key KEM operations in plain Elixir
# (SalixSignalProto.KemBackend).
SystemsRuntime.put_env(:salix_signal_proto, :plain_kem_in_tests, true)

SalixStore.RepoTestSetup.ensure!()

# Modules load on first use. Under CPU load the code server loads them one
# at a time, and the first TLS sockets of many concurrent tests then wait
# for it inside their timed windows (a Bandit handler or the chat client
# blocked in `:code_server`). Loading the network stack and the Signal code
# here keeps that wait out of the tests.
for app <- [
      :crypto,
      :public_key,
      :ssl,
      :mint,
      :mint_web_socket,
      :finch,
      :req,
      :plug,
      :thousand_island,
      :bandit,
      :websock_adapter,
      :ex_ice,
      :salix_signal_proto,
      :salix_voice,
      :salix_signal
    ] do
  Application.load(app)
  Code.ensure_all_loaded(Application.spec(app, :modules) || [])
end
