defmodule SalixSignal.GroupCall.Sfu do
  @moduledoc """
  HTTP client of group calls (CRS-14 sections 4 and 5): the membership
  token from the storage service, and peek and join on the calling server
  (SFU). The bodies are in `SalixSignalProto.GroupCall.Sfu`.

  The token proves group membership: it is fetched with the Groups v2 auth
  presentation of a `SalixSignal.Groups` client, then every SFU request
  carries it in the `Authorization` header of CRS-14 section 4.2.

  Options of `peek/3` and `join/4`: `:http` (options for
  `SalixSignal.Service.Http.request/3`). SFU requests trust only the Signal
  roots of CRS-01 section 3.1, never the public web roots (CRS-14 section
  5.1); `http: [roots: ...]` replaces those roots in tests.

  Redirects (CRS-14 section 5.1): a 307 or 308 response is followed to its
  `Location`, resolved against the request URL, with the same method, body
  and headers, at most 20 times. A redirect without a usable `Location`,
  or to a URL that is not `https`, fails the request.

  Comma decision D2 (CRS-14): Comma uses UDP only toward the SFU. `join/4` logs
  the candidate kinds of every join response and fails with
  `{:error, :no_udp_addresses}` when the response has no `udpAddresses`.
  """

  require Logger

  alias SalixSignal.Service.{Http, Response}
  alias SalixSignalProto.Group.{Params, Storage}
  alias SalixSignalProto.GroupCall
  alias SalixSignalProto.GroupCall.Sfu, as: Body

  # A peek lists at most the call's devices; a join response is small.
  @max_body_bytes 1_048_576
  @max_redirects 20

  @doc """
  Fetches the membership token of group `params` (`GET /v2/groups/token`)
  with a fresh auth presentation from a `SalixSignal.Groups` client.
  """
  @spec fetch_token(map(), Params.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch_token(%{server: server, credentials: credentials} = client, %Params{} = params) do
    with {:ok, authorization} <- Storage.authorize(server, params, credentials, client.now.()),
         {:ok, %Response{status: 200, body: body}} <-
           Http.request(
             :get,
             client.base_url <> Body.token_path(),
             Keyword.merge(
               [headers: [{"authorization", authorization}], max_body_bytes: 4096],
               client.http
             )
           ) do
      Body.decode_token(body)
    else
      {:ok, %Response{} = response} -> {:error, Response.outcome(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Peeks the call of the group whose token is `token` (CRS-14 section 5.2)."
  @spec peek(String.t(), String.t(), keyword()) ::
          {:ok, Body.peek()} | {:error, term()}
  def peek(base_url, token, opts \\ []) do
    with {:ok, response} <- request(:get, base_url, token, nil, opts) do
      Body.decode_peek(response.status, response.body)
    end
  end

  @doc """
  Joins the call (CRS-14 section 5.4). `local` is `%{ice_ufrag, ice_pwd,
  public_key}`. Returns the decoded join response, `{:error, :full}`, or
  `{:error, :no_udp_addresses}` (Comma decision D2).
  """
  @spec join(String.t(), String.t(), map(), keyword()) :: {:ok, Body.join()} | {:error, term()}
  def join(base_url, token, local, opts \\ []) do
    with {:ok, response} <- request(:put, base_url, token, Body.join_body(local), opts),
         {:ok, join} <- Body.decode_join(response.status, response.body) do
      Logger.info(
        "signal group call join: udp=#{length(join.udp)} tcp=#{length(join.tcp)} " <>
          "tls=#{length(join.tls)} candidate addresses"
      )

      if join.udp == [], do: {:error, :no_udp_addresses}, else: {:ok, join}
    end
  end

  defp request(method, base_url, token, json, opts) do
    with {:ok, authorization} <- GroupCall.authorization(token) do
      http = Keyword.get(opts, :http, [])

      request_opts =
        Keyword.merge(
          [
            headers: [{"authorization", authorization}],
            max_body_bytes: @max_body_bytes
          ] ++ if(json, do: [json: json], else: []),
          http
        )
        |> Keyword.put(:trust, :signal)

      follow(method, String.trim_trailing(base_url, "/") <> Body.path(), request_opts, 0)
    end
  end

  defp follow(method, url, opts, redirects) do
    case Http.request(method, url, opts) do
      {:ok, %Response{status: status} = response} when status in [307, 308] ->
        with {:ok, next} <- location(url, response),
             true <- redirects < @max_redirects || {:error, :too_many_redirects} do
          follow(method, next, opts, redirects + 1)
        end

      other ->
        other
    end
  end

  defp location(url, %Response{headers: headers}) do
    with {_, value} when value != "" <- List.keyfind(headers, "location", 0),
         %URI{scheme: "https", host: host} = next when is_binary(host) and host != "" <-
           URI.merge(URI.parse(url), value) do
      {:ok, URI.to_string(next)}
    else
      _ -> {:error, :invalid_redirect}
    end
  rescue
    _ -> {:error, :invalid_redirect}
  end
end
