defmodule Comma.GuestPow do
  @moduledoc """
  Light SHA-256 proof of work for guest creation.

  The server signs a short-lived challenge `gpow1.<payload>.<mac>` whose
  payload holds a random id, the difficulty in bits and an expiry. The client
  finds a decimal `nonce` so that `SHA-256(challenge <> ":" <> nonce)` starts
  with at least `difficulty` zero bits. The default of 12 bits needs about
  4,000 hashes, well under half a second on a phone with WebCrypto.

  The challenge is stateless. `comma_users.guest_pow_id` is unique, so one
  solved challenge creates at most one guest.
  """

  @prefix "gpow1"
  @ttl_seconds 10 * 60
  @max_nonce_bytes 20

  @spec issue(pos_integer()) :: {:ok, map()} | {:error, :guest_mode_unavailable}
  def issue(difficulty) when is_integer(difficulty) and difficulty > 0 do
    expires_at = System.system_time(:second) + @ttl_seconds

    payload =
      %{
        "i" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        "d" => difficulty,
        "e" => expires_at
      }
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    with {:ok, mac} <- mac(payload) do
      {:ok,
       %{
         "challenge" => Enum.join([@prefix, payload, mac], "."),
         "difficulty" => difficulty,
         "expires_at" => expires_at
       }}
    end
  end

  @doc """
  Verify a solved challenge. Returns the challenge id that the new guest
  stores, so the unique index rejects a second use.
  """
  @spec verify(term(), pos_integer()) ::
          {:ok, String.t()} | {:error, :guest_pow_invalid | :guest_mode_unavailable}
  def verify(%{"challenge" => challenge, "nonce" => nonce}, min_difficulty)
      when is_binary(challenge) and is_binary(nonce) do
    with true <- byte_size(nonce) in 1..@max_nonce_bytes and nonce =~ ~r/^[0-9]+$/,
         [@prefix, payload, mac] <- String.split(challenge, ".", parts: 3),
         {:ok, expected} <- mac(payload),
         true <- Plug.Crypto.secure_compare(mac, expected),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"i" => id, "d" => difficulty, "e" => expires_at}} <- Jason.decode(json),
         true <- is_binary(id) and is_integer(difficulty) and is_integer(expires_at),
         true <- difficulty >= min_difficulty,
         true <- expires_at > System.system_time(:second),
         true <- leading_zero_bits(:crypto.hash(:sha256, challenge <> ":" <> nonce)) >= difficulty do
      {:ok, id}
    else
      {:error, :guest_mode_unavailable} = error -> error
      _invalid -> {:error, :guest_pow_invalid}
    end
  end

  def verify(_solution, _min_difficulty), do: {:error, :guest_pow_invalid}

  @doc false
  def leading_zero_bits(<<0::1, rest::bitstring>>), do: 1 + leading_zero_bits(rest)
  def leading_zero_bits(_digest), do: 0

  defp mac(payload) do
    case Application.get_env(:comma_core, :auth, [])[:secret] do
      secret when is_binary(secret) and secret != "" ->
        {:ok,
         :crypto.mac(:hmac, :sha256, secret, "guest_pow:" <> payload)
         |> Base.url_encode64(padding: false)}

      _missing ->
        {:error, :guest_mode_unavailable}
    end
  end
end
