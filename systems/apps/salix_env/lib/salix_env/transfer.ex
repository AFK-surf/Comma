defmodule SalixEnv.Transfer do
  @moduledoc """
  Public façade for the cross-node transfer path. The receiving side
  `register/1`s a one-time token and advertises its URL; the sending side
  `send_bytes/3`s the payload to that URL. The receiver gets `{:transfer, token,
  bytes}` and replies with the completion envelope.
  """

  alias SalixEnv.Transfer.Tokens

  @doc "Register a one-time inbound token bound to the caller; returns `{token, url}`."
  @spec register(keyword()) :: {String.t(), String.t()}
  def register(opts \\ []) do
    token = Tokens.register(opts)
    {token, advertise_url(token)}
  end

  @doc "POST `bytes` to a peer's transfer URL. Returns the completion envelope."
  @spec send_bytes(String.t(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_bytes(url, bytes, _opts \\ []) do
    send_stream(url, [bytes])
  end

  @doc "POST an enumerable body to a peer's transfer URL."
  @spec send_stream(String.t(), Enumerable.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_stream(url, stream, _opts \\ []) do
    req =
      Finch.build(:post, url, [{"content-type", "application/octet-stream"}], {:stream, stream})

    case Finch.request(req, SalixStore.Finch, receive_timeout: 180_000) do
      {:ok, %{status: 200, body: env}} -> {:ok, decode_json(env)}
      {:ok, %{status: status, body: env}} -> {:error, {status, decode_json(env)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Advertised URL for a token, using the configured or detected advertise address."
  @spec advertise_url(String.t()) :: String.t()
  def advertise_url(token),
    do: "http://#{advertise_host()}:#{advertise_port()}/stream/#{token}"

  def port, do: Application.get_env(:salix_env, :transfer_port, 4400)

  @doc "Externally reachable port carried in transfer URLs; defaults to the listener port."
  def advertise_port, do: Application.get_env(:salix_env, :advertise_port, port())

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp advertise_host do
    Application.get_env(:salix_env, :advertise_host) || System.get_env("SALIX_ADVERTISE_HOST") ||
      "127.0.0.1"
  end
end
