defmodule SalixSignal.Account.Transport do
  @moduledoc """
  Where an account request goes: the chat socket or plain HTTPS to the chat
  host. Registration and account paths accept both, with the same JSON
  (CRS-02 §0).

    * `{:chat, server}`: a `SalixSignal.Service.Chat` process. An
      authenticated socket authenticates every request; an unauthenticated
      socket carries requests that need no account.
    * `{:http, base_url, options}`: `SalixSignal.Service.Http` requests to
      `base_url` (for example `https://chat.signal.org`). `options` are
      `SalixSignal.Service.Http.request/3` options, such as `:credentials`
      and `:roots`.
    * a function `(method, path, opts) -> {:ok, response} | {:error,
      reason}`, for example a test service.

  Comma sends plain HTTPS with an unrecognized `User-Agent`, so the service
  does not answer 498 "use websockets" (CRS-15 §1.2).
  """

  alias SalixSignal.Service.{Chat, Credentials, Endpoints, Http, Response}

  @type t ::
          {:chat, GenServer.server()}
          | {:http, String.t(), keyword()}
          | (String.t(), String.t(), keyword() -> {:ok, Response.t()} | {:error, term()})

  @methods %{
    "GET" => :get,
    "PUT" => :put,
    "POST" => :post,
    "PATCH" => :patch,
    "DELETE" => :delete
  }

  @doc "Plain HTTPS to the chat host of `environment`."
  @spec http(:production | :staging, keyword()) :: t()
  def http(environment, options \\ []),
    do: {:http, "https://" <> Endpoints.host(environment, :chat), options}

  @doc "The same HTTPS transport with other credentials."
  @spec with_credentials(t(), Credentials.t() | nil) :: t()
  def with_credentials({:http, base_url, options}, credentials),
    do: {:http, base_url, Keyword.put(options, :credentials, credentials)}

  @doc """
  Sends one request. Options: `:json` (a term sent as the JSON body),
  `:body` (raw bytes, with a `content-type` in `:headers`) and `:headers`. On a chat socket, `:credentials` adds an `Authorization`
  header line to this request only.
  """
  @spec request(t(), String.t(), String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def request(fun, method, path, opts) when is_function(fun, 3), do: fun.(method, path, opts)

  def request({:chat, chat}, method, path, opts) do
    headers =
      case Keyword.get(opts, :credentials) do
        nil ->
          Keyword.get(opts, :headers, [])

        credentials ->
          [
            {"authorization", Credentials.authorization(credentials)}
            | Keyword.get(opts, :headers, [])
          ]
      end

    Chat.request(
      chat,
      method,
      path,
      opts |> Keyword.take([:json, :body, :timeout]) |> Keyword.put(:headers, headers)
    )
  end

  def request({:http, base_url, options}, method, path, opts) do
    Http.request(
      Map.fetch!(@methods, method),
      base_url <> path,
      Keyword.merge(options, Keyword.take(opts, [:json, :body, :headers, :credentials]))
    )
  end

  @doc """
  Decodes a JSON object body, or returns `nil` for an empty or non-object
  body.
  """
  @spec json_object(Response.t()) :: map() | nil
  def json_object(%Response{} = response) do
    case Response.json(response) do
      {:ok, %{} = map} -> map
      _ -> nil
    end
  end

  @doc """
  The common error classes of a failed request (CRS-01 §12 to §14):
  `{:rate_limited, seconds | nil}`, `:unauthorized`, `:client_deprecated`,
  `{:challenge_required, challenge}`, `{:unavailable, status}` for 5xx, and
  `{:http_error, status}` for any other status.
  """
  @spec error(Response.t()) :: term()
  def error(%Response{} = response) do
    case Response.outcome(response) do
      {:server_error, status} -> {:unavailable, status}
      :rejected -> {:http_error, 508}
      :forbidden -> {:http_error, 403}
      :use_websocket -> {:http_error, 498}
      other -> other
    end
  end
end
