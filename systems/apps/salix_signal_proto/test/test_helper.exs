# Differential tests against the external oracle (PLAN "Differential testing")
# run only with `--include signal_oracle` and COMMA_SIGNAL_ORACLE set.
ExUnit.start(exclude: [:signal_oracle])

# Development hosts and the default CI image link OpenSSL 3.0, without
# ML-KEM. Tests may run secret-key KEM operations in plain Elixir; nothing
# else may (SalixSignalProto.KemBackend).
Application.put_env(:salix_signal_proto, :plain_kem_in_tests, true)
