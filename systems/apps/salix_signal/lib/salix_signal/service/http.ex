defmodule SalixSignal.Service.Http do
  @moduledoc """
  Plain HTTPS requests to Signal services (CRS-01 sections 3 to 5).

  Use it for hosts that the chat socket does not reach: the storage service
  and the attachment CDNs. Requests to the chat service go over
  `SalixSignal.Service.Chat`.

  Signal-rooted hosts are verified against the pinned roots only
  (`trust: :signal`, the default). Upload URLs that point outside the Signal
  hosts (CRS-10) use `trust: :public`, the ordinary web trust store.

  The client does not retry or follow redirects; callers classify the
  result with `SalixSignal.Service.Response.outcome/1`.
  """

  alias SalixSignal.Service.{Credentials, Endpoints, Response}

  @default_user_agent "Salix-Signal/0.1"

  @doc """
  Sends one request. `url` is an absolute `https://` URL.

  Options: `:credentials` (`SalixSignal.Service.Credentials`; external
  service credentials from the chat service are passed unchanged the same
  way), `:headers`, `:body`, `:json`, `:user_agent`, `:trust` (`:signal` or
  `:public`), `:roots` (DER roots that replace the pinned roots),
  `:receive_timeout` (ms, default 30 s) and `:max_body_bytes` (the request
  stops with `{:error, :too_large}` when the response body grows beyond it).
  """
  @spec request(atom(), String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def request(method, "https://" <> _ = url, opts \\ []) do
    headers =
      [{"user-agent", Keyword.get(opts, :user_agent, @default_user_agent)}] ++
        authorization(opts[:credentials]) ++ Keyword.get(opts, :headers, [])

    body_opts =
      case Keyword.fetch(opts, :json) do
        {:ok, term} -> [json: term]
        :error -> [body: Keyword.get(opts, :body)]
      end

    req_opts =
      [
        method: method,
        url: url,
        headers: headers,
        retry: false,
        redirect: false,
        raw: true,
        receive_timeout: Keyword.get(opts, :receive_timeout, 30_000),
        connect_options: connect_options(opts)
      ] ++ body_opts ++ into(opts[:max_body_bytes])

    case Req.request(req_opts) do
      {:ok, %Req.Response{body: :too_large}} ->
        {:error, :too_large}

      {:ok, %Req.Response{} = response} ->
        {:ok,
         %Response{
           status: response.status,
           headers: for({name, values} <- response.headers, value <- values, do: {name, value}),
           body: IO.iodata_to_binary(response.body || "")
         }}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp into(nil), do: []

  defp into(max) when is_integer(max) and max >= 0 do
    [
      into: fn {:data, data}, {req, resp} ->
        body = resp.body || ""

        if byte_size(body) + byte_size(data) > max,
          do: {:halt, {req, %{resp | body: :too_large}}},
          else: {:cont, {req, %{resp | body: body <> data}}}
      end
    ]
  end

  defp authorization(nil), do: []

  defp authorization(%Credentials{} = credentials),
    do: [{"authorization", Credentials.authorization(credentials)}]

  defp connect_options(opts) do
    case Keyword.get(opts, :trust, :signal) do
      :signal ->
        tls_opts =
          if roots = opts[:roots],
            do: [roots: roots, versions: [:"tlsv1.3", :"tlsv1.2"]],
            else: [versions: [:"tlsv1.3", :"tlsv1.2"]]

        [protocols: [:http1], transport_opts: Endpoints.tls_options(tls_opts)]

      :public ->
        [protocols: [:http1]]
    end
  end
end
