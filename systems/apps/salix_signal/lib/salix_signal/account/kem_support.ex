defmodule SalixSignal.Account.KemSupport do
  @moduledoc """
  The account-level gate for secret-key KEM operations.

  Owner decision (KEM use, fail closed): an account's KEM key generation and
  decapsulation run in constant time in OTP `:crypto` (OpenSSL 3.5 or later).
  `SalixSignalProto.KemBackend` enforces it per operation and allows the
  plain-Elixir fallback only in test builds. This gate asks the same
  question before an account starts to make keys, so that a node without the
  support refuses with an error instead of raising midway.
  """

  alias SalixSignalProto.KemBackend

  @doc "`:ok` when this node may create and use an account's KEM keys."
  @spec check() :: :ok | {:error, :kem_unsupported}
  def check do
    if KemBackend.constant_time?() do
      :ok
    else
      # Returns :plain only in a test build that allows it; raises otherwise.
      _ = KemBackend.select!(:mlkem1024)
      _ = KemBackend.select!(:mlkem768)
      :ok
    end
  rescue
    KemBackend.UnsupportedError -> {:error, :kem_unsupported}
  end
end
