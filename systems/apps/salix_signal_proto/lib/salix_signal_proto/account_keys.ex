defmodule SalixSignalProto.AccountKeys do
  @moduledoc """
  Account secrets for registration lock and re-registration (CRS-02 §7.1).

  The **account entropy pool** is 64 characters from `0-9` and `a-z`. The
  32-byte **SVR key** comes from the pool:

      svr_key = HKDF(no salt, pool, `20240801_SIGNAL_SVR_MASTER_KEY`, 32)

  Two wire values come from the SVR key:

  | Value | Definition | Wire form |
  | --- | --- | --- |
  | Registration lock | `HMAC(svr_key, "Registration Lock")` | 64 lowercase hex characters in `registrationLock` |
  | Registration recovery password | `HMAC(svr_key, "Registration Recovery")` | base64 in `recoveryPassword` |

  The pool and the SVR key are account secrets. Whoever holds them can
  re-register the number while a recovery password is stored (CRS-02 §7.3).
  """

  alias SalixSignalProto.Crypto.{Hkdf, Hmac}

  @alphabet ~c"0123456789abcdefghijklmnopqrstuvwxyz"
  @pool_length 64
  @svr_key_info "20240801_SIGNAL_SVR_MASTER_KEY"

  @type svr_key :: <<_::256>>

  @doc """
  Returns a new random entropy pool. Each character is uniform over the 36
  allowed characters (rejection sampling of random bytes).
  """
  @spec generate_entropy_pool() :: String.t()
  def generate_entropy_pool, do: collect(<<>>)

  # 252 is the largest multiple of 36 not above 256.
  defp collect(pool) when byte_size(pool) >= @pool_length, do: binary_part(pool, 0, @pool_length)

  defp collect(pool) do
    extra =
      for <<byte <- :crypto.strong_rand_bytes(@pool_length)>>, byte < 252, into: <<>> do
        <<Enum.at(@alphabet, rem(byte, 36))>>
      end

    collect(pool <> extra)
  end

  @doc "True for 64 characters, each in `0-9` or `a-z`."
  @spec valid_entropy_pool?(term()) :: boolean()
  def valid_entropy_pool?(pool) when is_binary(pool) and byte_size(pool) == @pool_length do
    for(<<char <- pool>>, not (char in ?0..?9 or char in ?a..?z), do: char) == []
  end

  def valid_entropy_pool?(_pool), do: false

  @doc "The SVR key of an entropy pool."
  @spec svr_key(String.t()) :: {:ok, svr_key()} | {:error, :invalid_entropy_pool}
  def svr_key(pool) do
    if valid_entropy_pool?(pool),
      do: {:ok, Hkdf.derive(pool, "", @svr_key_info, 32)},
      else: {:error, :invalid_entropy_pool}
  end

  @doc "The 32-byte registration lock value."
  @spec registration_lock(svr_key()) :: <<_::256>>
  def registration_lock(<<_::binary-size(32)>> = svr_key),
    do: Hmac.sha256(svr_key, "Registration Lock")

  @doc "The registration lock as sent in `registrationLock`: 64 lowercase hex characters."
  @spec registration_lock_token(svr_key()) :: String.t()
  def registration_lock_token(svr_key),
    do: svr_key |> registration_lock() |> Base.encode16(case: :lower)

  @doc "The 32-byte registration recovery password."
  @spec recovery_password(svr_key()) :: <<_::256>>
  def recovery_password(<<_::binary-size(32)>> = svr_key),
    do: Hmac.sha256(svr_key, "Registration Recovery")
end
