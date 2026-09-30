defmodule SalixVoice.StreamToken do
  @moduledoc """
  Short-lived Twilio media stream token (docs/messaging-voice.md).

  Threat: anyone who learns the public stream URL could open a media socket and
  take over or listen to an admitted call. The signed voice webhook is the
  independent authority: only Salix, after it validates the Twilio signature,
  mints this token into the `<Stream url>` it returns. The token binds the call,
  its connect, Group and carrier call ID, and expires 60 s after minting.
  `SalixVoice.attach/3` then checks the Twilio `start.callSid` and allows one
  socket per call, so a replayed token fails closed with no audio.

  Format: `base64url(JSON payload) <> "." <> base64url(HMAC-SHA256)`, keyed
  from the deployment credential root with a voice-only purpose.
  """

  @purpose "salix_voice_stream_token"
  @ttl_seconds 60
  @claims ~w(call_id connect_id group_id carrier_call_id)

  @doc "Token lifetime in seconds."
  def ttl_seconds, do: @ttl_seconds

  @doc """
  Mint a token for `claims` at unix time `now` (seconds). Raises when the
  deployment credential root is not configured.
  """
  @spec mint(map(), integer()) :: String.t()
  def mint(claims, now) when is_map(claims) and is_integer(now) do
    payload =
      @claims
      |> Map.new(fn key -> {key, claim(claims, key)} end)
      |> Map.put("exp", now + @ttl_seconds)
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    payload <> "." <> Base.url_encode64(mac!(payload), padding: false)
  end

  @doc """
  Verify MAC and expiry, and that the call still has a live `CallActor`.
  Returns the string-keyed claims.
  """
  @spec verify(String.t(), integer()) ::
          {:ok, map()} | {:error, :invalid_token | :expired | :call_not_found}
  def verify(token, now) when is_binary(token) and is_integer(now) do
    with [payload, mac] <- String.split(token, ".", parts: 2),
         {:ok, mac} <- Base.url_decode64(mac, padding: false),
         {:ok, expected} <- mac(payload),
         true <- byte_size(mac) == byte_size(expected) and :crypto.hash_equals(mac, expected),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"exp" => exp} = claims} when is_integer(exp) <- Jason.decode(json),
         true <- Enum.all?(@claims, &is_binary(claims[&1])) do
      cond do
        exp < now -> {:error, :expired}
        SalixVoice.whereis(claims["call_id"]) == nil -> {:error, :call_not_found}
        true -> {:ok, claims}
      end
    else
      _ -> {:error, :invalid_token}
    end
  end

  def verify(_token, _now), do: {:error, :invalid_token}

  defp claim(claims, key) do
    value = Map.get(claims, key) || Map.get(claims, String.to_existing_atom(key))

    if is_binary(value) and value != "",
      do: value,
      else: raise(ArgumentError, "stream token claim #{key} must be a non-empty string")
  end

  defp mac!(payload) do
    case mac(payload) do
      {:ok, mac} -> mac
      {:error, reason} -> raise "stream token key unavailable: #{inspect(reason)}"
    end
  end

  defp mac(payload) do
    with {:ok, key} <- SalixStore.Crypto.derived_key(@purpose) do
      {:ok, :crypto.mac(:hmac, :sha256, key, payload)}
    end
  end
end
