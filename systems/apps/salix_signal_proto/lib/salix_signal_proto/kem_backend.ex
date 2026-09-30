defmodule SalixSignalProto.KemBackend do
  @moduledoc """
  Where secret-key KEM operations run: key generation and decapsulation for
  Kyber1024 (PQXDH, CRS-03 section 6) and ML-KEM-768 (the post-quantum
  ratchet, CRS-04b section 8).

  Owner decision (KEM use, fail closed): these operations run in constant
  time in OTP `:crypto`, which has ML-KEM-1024 and ML-KEM-768 when it links
  OpenSSL 3.5 or later (the production images). The plain-Elixir
  implementations (`SalixSignalProto.Crypto.Kyber1024`,
  `SalixSignalProto.Crypto.MlKem768`) may stand in for them only in tests:
  the build must be a test build and the application environment
  `:salix_signal_proto, :plain_kem_in_tests` must be true. Otherwise an
  operation raises `SalixSignalProto.KemBackend.UnsupportedError` and changes
  nothing. Code that starts an account should check `constant_time?/0`
  first, so that a node without the support refuses at that point.

  Encapsulation is outside the decision and stays in plain Elixir: OTP
  `:crypto` cannot split an encapsulation or take injected randomness, and it
  must not run the FIPS 203 key check on Kyber1024 keys (CRS-03 section 6.2
  rule 4). Moving it into the C NIF is a recorded timing-risk follow-up.
  """

  defmodule UnsupportedError do
    @moduledoc "Raised when no allowed backend can run a secret-key KEM operation."
    defexception [:kem]

    @impl true
    def message(%{kem: kem}),
      do:
        "#{kem} secret-key operations need OTP :crypto with OpenSSL 3.5 or later; " <>
          "the plain-Elixir fallback is allowed only in tests"
  end

  # Compiled in only for test builds; a release never contains it.
  @plain_allowed_in_build Mix.env() == :test

  @type kem :: :mlkem1024 | :mlkem768

  @doc "True when OTP `:crypto` runs both KEMs of the session protocol."
  @spec constant_time?() :: boolean()
  def constant_time?, do: openssl?(:mlkem1024) and openssl?(:mlkem768)

  @doc "True when OTP `:crypto` provides `kem`."
  @spec openssl?(kem()) :: boolean()
  def openssl?(kem) when kem in [:mlkem1024, :mlkem768],
    do: kem in Keyword.get(:crypto.supports(), :kems, [])

  @doc """
  The backend for a secret-key operation with `kem`: `:openssl`, or `:plain`
  in tests only. Raises `UnsupportedError` when neither is allowed.
  """
  @spec select!(kem()) :: :openssl | :plain
  def select!(kem) do
    cond do
      openssl?(kem) -> :openssl
      plain_allowed?() -> :plain
      true -> raise UnsupportedError, kem: kem
    end
  end

  defp plain_allowed? do
    @plain_allowed_in_build and
      Application.get_env(:salix_signal_proto, :plain_kem_in_tests, false) == true
  end
end
