defmodule SalixLlm.Http do
  @moduledoc """
  Provider network I/O and callback delivery. Lean owns request encoding,
  response decoding, stream state, and retry decisions.
  """
  alias SalixAgent.LLM.{Error, ReasoningDelta}
  alias SalixLlm.ProviderConfig
  alias SalixVerifiedKernel.Provider, as: Kernel

  def post(%{transport: transport}, url, opts) when is_function(transport, 2),
    do: transport.(url, opts)

  def post(_cfg, url, opts) do
    if opts[:into], do: SalixLlm.StreamWatchdog.post(url, opts), else: Req.post(url, opts)
  rescue
    error in ArgumentError ->
      if opts[:into], do: {:error, error, nil}, else: {:error, error}
  end

  def complete(protocol, messages, tools, opts, mode \\ "complete") do
    cfg = ProviderConfig.resolve(opts)
    body = Kernel.body(protocol, cfg, messages, tools, mode)
    {url, headers} = Kernel.endpoint(protocol, cfg, mode)

    {observe?, retry, redirect} =
      Kernel.call(:blocking_policy, {mode, ProviderConfig.transport_retry(opts)})

    observer = if observe?, do: ProviderConfig.before_send(opts)

    with :ok <- observe(observer, body) do
      case post(cfg, url,
             body: body,
             headers: headers,
             receive_timeout: receive_timeout(),
             retry: retry,
             redirect: redirect
           ) do
        {:ok, %{status: 200, body: response}} ->
          Kernel.call(:complete, {protocol, normalize(response), cfg.model, mode == "compact"})

        {:ok, %{status: status, body: response} = resp} ->
          {protocol, status, response}
          |> then(&Kernel.call(:http_error, &1))
          |> with_retry_after(resp)

        {:error, reason} ->
          Kernel.call(:transport_error, {protocol, Error.preview(reason)})
      end
    else
      {:error, reason} ->
        Kernel.call(:configuration_error, {protocol, Error.preview(reason)})
    end
  end

  def complete_stream(protocol, messages, tools, on_delta, opts, transport_opts \\ []) do
    cfg = ProviderConfig.resolve(opts)
    body = Kernel.body(protocol, cfg, messages, tools, "stream")
    endpoint = Kernel.endpoint(protocol, cfg, "stream")
    callbacks = {on_delta, ProviderConfig.tool_delta(opts), ProviderConfig.reasoning_delta(opts)}
    attempts = Kernel.call(:stream_attempts, {protocol, is_function(cfg.transport, 2)})
    stream(protocol, cfg, body, endpoint, callbacks, attempts, transport_opts)
  end

  defp stream(protocol, cfg, body, {url, headers} = endpoint, callbacks, attempts, opts) do
    {_, on_tool, _} = callbacks
    {initial, :opened} = Kernel.stream(nil, :new, {protocol, cfg.model, is_function(on_tool, 1)})
    seen_key = {__MODULE__, make_ref()}
    Process.put(seen_key, false)

    into = fn {:data, chunk}, {req, resp} ->
      if resp.status == 200 and chunk != "", do: Process.put(seen_key, true)
      # Every body chunk, keep-alives included: the same activity the stream
      # watchdog sees, kept where the job's owner can still read it after a
      # deadline kill.
      SalixAgent.StreamProgress.observe_body(byte_size(chunk), resp.status)
      resident = Req.Response.get_private(resp, :provider_stream, initial)
      {next, actions} = Kernel.stream(resident, :feed, {chunk, resp.status == 200})
      deliver(actions, callbacks)
      {:cont, {req, Req.Response.put_private(resp, :provider_stream, next)}}
    end

    try do
      result =
        post(cfg, url,
          body: body,
          headers: headers,
          receive_timeout: receive_timeout(opts),
          retry: false,
          into: into
        )

      case result do
        {:ok, %{status: 200} = resp} ->
          resident = Req.Response.get_private(resp, :provider_stream, initial)
          {_, {actions, result}} = Kernel.stream(resident, :finish, nil)
          deliver(actions, callbacks)
          result

        {:ok, %{status: status} = resp} ->
          case Kernel.call(:retry, {status, Process.get(seen_key), attempts}) do
            {:retry, delay, remaining} ->
              Process.sleep(delay)
              stream(protocol, cfg, body, endpoint, callbacks, remaining, opts)

            :stop ->
              resident = Req.Response.get_private(resp, :provider_stream, initial)
              {_, raw} = Kernel.stream(resident, :raw, nil)

              {protocol, status, decompress(raw)}
              |> then(&Kernel.call(:stream_http_error, &1))
              |> with_retry_after(resp)
          end

        {:error, reason, _partial} ->
          case Kernel.call(:retry, {:transport, Process.get(seen_key), attempts}) do
            {:retry, delay, remaining} ->
              Process.sleep(delay)
              stream(protocol, cfg, body, endpoint, callbacks, remaining, opts)

            :stop ->
              Kernel.call(:transport_error, {protocol, Error.preview(reason)})
          end
      end
    after
      Process.delete(seen_key)
    end
  end

  defp deliver(actions, {on_text, on_tool, on_reasoning}) do
    Enum.each(actions, fn
      {:text, text} ->
        on_text.(text)

      {:tool, fragment} ->
        if on_tool, do: on_tool.(fragment)

      {visibility, text} when visibility in [:private_reasoning, :public_summary] ->
        if on_reasoning, do: on_reasoning.(%ReasoningDelta{visibility: visibility, text: text})
    end)
  end

  defp observe(nil, _body), do: :ok

  defp observe(observer, body) when is_function(observer, 1) do
    case observer.(body) do
      :ok -> :ok
      {:error, reason} -> {:error, {:before_send_rejected, reason}}
      other -> {:error, {:before_send_invalid_return, other}}
    end
  rescue
    error -> {:error, {:before_send_raised, error}}
  catch
    kind, reason -> {:error, {:before_send_threw, kind, reason}}
  end

  defp observe(observer, _body), do: {:error, {:invalid_before_send, observer}}

  def normalize(body), do: Kernel.call(:normalize, decompress(body))

  defp decompress(<<0x1F, 0x8B, _::binary>> = gz), do: :zlib.gunzip(gz)
  defp decompress(body), do: body

  # A provider that rate-limits (429) or sheds load (503/529) says how long to
  # stay away in `Retry-After`. Round's retry loop honors `retry_after_ms` on
  # the error; without it the loop backs off in milliseconds and burns its
  # whole budget inside one rate-limit window.
  defp with_retry_after({:error, %{} = error}, %Req.Response{} = resp) do
    case retry_after_ms(resp.headers) do
      ms when is_integer(ms) -> {:error, Map.put(error, "retry_after_ms", ms)}
      _ -> {:error, error}
    end
  end

  defp with_retry_after(result, _resp), do: result

  @doc """
  The `Retry-After` header as milliseconds, or `nil`. Accepts the delay-seconds
  form and the HTTP-date form; a date in the past reads as zero.
  """
  @spec retry_after_ms(map() | list()) :: non_neg_integer() | nil
  def retry_after_ms(headers) do
    headers
    |> header_values("retry-after")
    |> Enum.find_value(&parse_retry_after/1)
  end

  defp header_values(headers, name) when is_map(headers),
    do: headers |> Map.get(name, []) |> List.wrap()

  defp header_values(headers, name) when is_list(headers),
    do: for({key, value} <- headers, String.downcase(to_string(key)) == name, do: value)

  defp header_values(_headers, _name), do: []

  defp parse_retry_after(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {seconds, ""} when seconds >= 0 ->
        seconds * 1_000

      _ ->
        case parse_http_date(trimmed) do
          {:ok, at} -> max(DateTime.diff(at, DateTime.utc_now(), :millisecond), 0)
          :error -> nil
        end
    end
  end

  defp parse_retry_after(_value), do: nil

  # RFC 7231 IMF-fixdate, e.g. "Sun, 06 Nov 1994 08:49:37 GMT".
  defp parse_http_date(value) do
    with [_, day, month, year, time] <-
           Regex.run(~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}:\d{2}:\d{2}) GMT$/, value),
         month when is_integer(month) <- month_number(month),
         {:ok, naive} <-
           NaiveDateTime.from_iso8601("#{year}-#{pad(month)}-#{day}T#{time}") do
      {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
    else
      _ -> :error
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  defp month_number(name), do: Enum.find_index(@months, &(&1 == name)) |> then(&(&1 && &1 + 1))
  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  def receive_timeout(opts \\ []) do
    case Keyword.get(opts, :receive_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> SalixAgent.LLM.request_timeout_ms()
    end
  end
end
