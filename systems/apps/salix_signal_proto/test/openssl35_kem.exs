# Runs the OpenSSL KEM tests with plain `elixir`, without the umbrella, on a
# host whose OTP links OpenSSL 3.5 or later (the test-signal-proto-trixie CI
# job). Usage, from apps/salix_signal_proto: elixir test/openssl35_kem.exs
#
# Covers Kyber1024Openssl (PQXDH, CRS-03 section 6) and the ML-KEM-768 path
# of the post-quantum ratchet (CRS-04b section 8). The modules are compiled
# with Mix.env() == :dev, as in a release: SalixSignalProto.KemBackend then
# refuses the plain-Elixir fallback, so every secret-key KEM operation here
# must run in OpenSSL.
#
# Compiles every crypto module except the NIF loader, which needs the
# compiled NIF in priv/, plus the KEM backend gate and the post-quantum
# ratchet, which use no NIF.
for kem <- [:mlkem1024, :mlkem768] do
  unless kem in Keyword.get(:crypto.supports(), :kems, []) do
    raise "the linked OpenSSL has no #{kem}"
  end
end

# KemBackend reads Mix.env() at compile time.
{:ok, _apps} = Application.ensure_all_started(:mix)
:dev = Mix.env()

files =
  (Path.wildcard("lib/salix_signal_proto/crypto/*.ex") --
     ["lib/salix_signal_proto/crypto/native.ex"]) ++
    [
      "lib/salix_signal_proto/kem_backend.ex",
      "lib/salix_signal_proto/session/spqr.ex"
      | Path.wildcard("lib/salix_signal_proto/session/spqr/*.ex")
    ]

# Warnings about the missing NIF loader are expected here.
{:ok, _modules, _diagnostics} =
  Kernel.ParallelCompiler.compile(["test/support/vectors.ex" | files], return_diagnostics: true)

ExUnit.start()
Code.require_file("test/salix_signal_proto/crypto/kyber1024_openssl_test.exs")
Code.require_file("test/salix_signal_proto/crypto/ml_kem768_openssl_test.exs")
