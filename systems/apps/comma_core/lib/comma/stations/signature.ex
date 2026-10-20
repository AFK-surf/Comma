defmodule Comma.Stations.Signature do
  @moduledoc """
  Station-signed messages (station↔Comma contract §1–§3). A station proves it
  holds the Ed25519 key whose public half is its id; the message binds the
  Comma origin, so a signature made for another control plane does not verify
  here. Timestamped messages are accepted within 300 seconds of now.
  """

  @skew_seconds 300

  def valid_id?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  def fresh?(ts, now \\ SystemsClock.system_time(:second))
  def fresh?(ts, now) when is_integer(ts), do: abs(now - ts) <= @skew_seconds
  def fresh?(_ts, _now), do: false

  def parse_ts(value) when is_binary(value) do
    case Integer.parse(value) do
      {ts, ""} -> {:ok, ts}
      _ -> :error
    end
  end

  def parse_ts(_value), do: :error

  def sha256hex(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  def enroll_message(origin, token, station),
    do: "comma-station-enroll-v1:#{origin}:#{token}:#{station}"

  def connect_message(origin, station, ts),
    do: "comma-station-connect-v1:#{origin}:#{station}:#{ts}"

  def request_message(tag, origin, station, ts, body),
    do: "#{tag}:#{origin}:#{station}:#{ts}:#{sha256hex(body)}"

  @doc "Whether `signature_hex` is the station's Ed25519 signature over `message`."
  def verify(station, signature_hex, message) when is_binary(message) do
    with true <- valid_id?(station),
         true <- is_binary(signature_hex) and Regex.match?(~r/\A[0-9a-f]{128}\z/, signature_hex) do
      :crypto.verify(:eddsa, :none, message, Base.decode16!(signature_hex, case: :lower), [
        Base.decode16!(station, case: :lower),
        :ed25519
      ])
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Checks a station-signed request: id, timestamp, and the signature over
  `<tag>:<origin>:<station>:<ts>:<sha256hex(body)>`.
  """
  def verify_request(tag, origin, station, ts_header, signature, body) do
    with true <- valid_id?(station) || :invalid_request,
         {:ok, ts} <- parse_ts(ts_header),
         true <- fresh?(ts) || :invalid_request,
         true <- verify(station, signature, request_message(tag, origin, station, ts, body)) do
      :ok
    else
      false -> {:error, :invalid_signature}
      _ -> {:error, :invalid_request}
    end
  end

  def verify_connect(origin, station, ts_header, signature) do
    with true <- valid_id?(station) || :invalid_request,
         {:ok, ts} <- parse_ts(ts_header),
         true <- fresh?(ts) || :invalid_request,
         true <- verify(station, signature, connect_message(origin, station, ts)) do
      :ok
    else
      false -> {:error, :invalid_signature}
      _ -> {:error, :invalid_request}
    end
  end
end
