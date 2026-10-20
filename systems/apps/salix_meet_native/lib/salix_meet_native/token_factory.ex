defmodule SalixMeetNative.TokenFactory do
  @moduledoc false

  require Logger

  alias SalixMeetNative.Handoff

  @handoff_suffix "/v1/handoff"
  @request_timeout_ms 240_000
  @busy_retry_floor_ms 1_000
  @busy_retry_min_budget_ms 70_000
  @max_body_bytes 2 * 1024 * 1024
  @max_retry_after_s 3_600
  @meeting_code ~r/^[a-z]{3}-[a-z]{4}-[a-z]{3}$/
  @profile ~r/^[A-Za-z0-9 ._-]{1,64}$/
  @login_path ~r{^/login/[A-Za-z0-9._~-]+/?$}

  @stages ~w(validate launch new-page navigate handoff container connect account login logout)
  @reasons ~w(login-required meet-rejected unsupported-browser browser-closed timeout navigation-context
              other unavailable invalid-url invalid-guest-name invalid-json invalid-cookies client-aborted
              profile-busy account-capacity login-incomplete invalid-profile unverified too-large
              rate-limited not-found not-confirmed)

  @type error ::
          {:login_required, String.t() | nil}
          | {:busy, non_neg_integer() | nil}
          | {:http, pos_integer(), String.t() | nil, String.t() | nil, non_neg_integer() | nil}
          | atom()
          | {atom(), term()}

  @spec handoff(String.t(), keyword()) :: {:ok, Handoff.t()} | {:error, error()}
  def handoff(meeting_url, opts \\ []) do
    config = config(opts)

    with {:ok, base} <- endpoint(config[:url]),
         {:ok, secret} <- secret(config[:secret]),
         {:ok, profile} <- profile(Keyword.get(opts, :profile)),
         {:ok, url} <- normalize_meeting_url(meeting_url) do
      timeout_ms = Keyword.get(opts, :timeout_ms, @request_timeout_ms)
      deadline = now_ms() + timeout_ms
      wall_deadline = SystemsClock.system_time(:millisecond) + timeout_ms
      body = request_body(url, Keyword.get(opts, :guest_name, ""), profile, wall_deadline)

      request_handoff(base, secret, body, profile != nil, deadline, config)
    end
  end

  @spec normalize_meeting_url(String.t()) :: {:ok, String.t()} | {:error, :invalid_meeting_url}
  def normalize_meeting_url(raw) when is_binary(raw) do
    raw = String.trim(raw)

    raw =
      cond do
        Regex.match?(@meeting_code, String.downcase(raw)) -> "https://meet.google.com/" <> raw
        String.starts_with?(String.downcase(raw), "meet.google.com/") -> "https://" <> raw
        true -> raw
      end

    uri = URI.parse(raw)
    path = uri.path || ""
    code = path |> String.trim("/") |> String.downcase()

    if uri.scheme == "https" and String.downcase(uri.host || "") == "meet.google.com" and
         is_nil(uri.userinfo) and not String.contains?(path, "%") and
         Regex.match?(@meeting_code, code) do
      {:ok, URI.to_string(%URI{uri | host: "meet.google.com", path: "/" <> code, fragment: nil})}
    else
      {:error, :invalid_meeting_url}
    end
  end

  def normalize_meeting_url(_), do: {:error, :invalid_meeting_url}

  defp request_handoff(base, secret, body, account?, deadline, config) do
    remaining = deadline - now_ms()

    case post(base, secret, body, remaining, config) do
      {:ok, 200, data} ->
        with {:ok, frames} <- decode_frames(data) do
          Handoff.decode(frames, account?: account?)
        end

      {:ok, status, data, headers} ->
        case classify(status, data, headers, base) do
          {:busy, retry_after} = busy ->
            wait = max((retry_after || 0) * 1_000, @busy_retry_floor_ms)

            if deadline - now_ms() - wait < @busy_retry_min_budget_ms do
              {:error, busy}
            else
              SystemsClock.sleep(wait)
              request_handoff(base, secret, body, account?, deadline, config)
            end

          error ->
            {:error, error}
        end

      {:error, _} = error ->
        error
    end
  end

  defp post(base, secret, body, timeout_ms, config) when timeout_ms > 0 do
    request =
      Req.new(
        [
          method: :post,
          url: base,
          json: body,
          headers: [{"authorization", "Bearer " <> secret}],
          redirect: false,
          retry: false,
          decode_body: false,
          receive_timeout: timeout_ms,
          into: &collect_limited/2
        ] ++ Keyword.get(config, :req_options, [])
      )

    case Req.request(request) do
      {:ok, %Req.Response{private: %{too_large: true}}} ->
        {:error, :handoff_too_large}

      {:ok, %Req.Response{status: 200, body: data}} ->
        {:ok, 200, IO.iodata_to_binary(data)}

      {:ok, %Req.Response{status: status, body: data, headers: headers}} ->
        {:ok, status, IO.iodata_to_binary(data), headers}

      {:error, %{reason: reason}} when is_atom(reason) ->
        {:error, {:token_factory_unreachable, reason}}

      {:error, %module{}} ->
        {:error, {:token_factory_unreachable, module}}
    end
  end

  defp post(_base, _secret, _body, _timeout_ms, _config), do: {:error, :timeout}

  defp collect_limited({:data, chunk}, {req, resp}) do
    body = [resp.body || [] | chunk]

    if IO.iodata_length(body) > @max_body_bytes do
      {:halt, {req, resp |> Map.put(:body, []) |> Req.Response.put_private(:too_large, true)}}
    else
      {:cont, {req, %{resp | body: body}}}
    end
  end

  defp decode_frames(data) do
    case Jason.decode(data) do
      {:ok, frames} when is_list(frames) -> {:ok, frames}
      _ -> {:error, :invalid_handoff_json}
    end
  end

  defp classify(status, data, headers, base) do
    {stage, reason, login_url} = error_detail(data)
    retry_after = retry_after(status, headers)

    cond do
      status == 401 and stage == "account" and reason == "login-required" ->
        {:login_required, safe_login_url(base, login_url)}

      # The guest factory answers a plain-text 429 while its one browser runs a handoff.
      status == 429 and stage in [nil, "account"] and reason in [nil, "profile-busy"] ->
        {:busy, retry_after}

      true ->
        log_diagnostics(status, stage, reason, data)
        {:http, status, known(stage, @stages), known(reason, @reasons), retry_after}
    end
  end

  defp log_diagnostics(status, stage, reason, data) do
    with {:ok, %{} = map} <- Jason.decode(data),
         diag when diag != %{} <- Map.take(map, ["state", "rpcStatus"]) do
      Logger.warning(
        "meet native: token factory #{status} #{stage}/#{reason} #{inspect(diag, limit: 40, printable_limit: 600)}"
      )
    end
  end

  defp error_detail(data) do
    case Jason.decode(data) do
      {:ok, %{} = map} ->
        {string(map["stage"]), string(map["reason"]), string(map["loginUrl"])}

      _ ->
        {nil, nil, nil}
    end
  end

  defp retry_after(status, headers) when status in [429, 503] do
    headers
    |> Map.get("retry-after", [])
    |> List.first()
    |> parse_retry_after()
  end

  defp retry_after(_status, _headers), do: nil

  defp parse_retry_after(nil), do: nil

  defp parse_retry_after(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 ->
        min(seconds, @max_retry_after_s)

      _ ->
        case http_date(value) do
          {:ok, datetime} ->
            SystemsClock.utc_now()
            |> then(&DateTime.diff(datetime, &1))
            |> max(0)
            |> min(@max_retry_after_s)

          :error ->
            nil
        end
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp http_date(value) do
    with [_, day, month, year, time] <-
           Regex.run(
             ~r/^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}:\d{2}:\d{2}) GMT$/,
             value
           ),
         index when is_integer(index) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, date} <- Date.new(String.to_integer(year), index + 1, String.to_integer(day)),
         {:ok, time} <- Time.from_iso8601(time),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, datetime}
    else
      _ -> :error
    end
  end

  @spec safe_login_url(String.t(), String.t() | nil) :: String.t() | nil
  def safe_login_url(_base, nil), do: nil

  def safe_login_url(base, raw) when byte_size(raw) <= 2048 do
    base_uri = URI.parse(base)
    uri = URI.parse(raw)
    segment = (uri.path || "") |> String.replace_prefix("/login/", "") |> String.trim("/")

    if uri.scheme == "https" and same_host?(uri, base_uri) and is_nil(uri.userinfo) and
         is_nil(uri.query) and is_nil(uri.fragment) and not String.contains?(raw, "?") and
         Regex.match?(@login_path, uri.path || "") and segment not in [".", ".."] do
      raw
    end
  end

  def safe_login_url(_base, _raw), do: nil

  defp same_host?(%URI{host: a, port: pa}, %URI{host: b, port: pb})
       when is_binary(a) and is_binary(b) and a != "" do
    String.downcase(a) == String.downcase(b) and (pa || 443) == (pb || 443)
  end

  defp same_host?(_a, _b), do: false

  defp request_body(url, guest_name, nil, _deadline), do: %{url: url, guestName: guest_name}

  defp request_body(url, guest_name, profile, wall_deadline_ms) do
    %{url: url, guestName: guest_name, profile: profile, deadlineMs: wall_deadline_ms}
  end

  defp endpoint(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and
         is_nil(uri.query) and is_nil(uri.fragment) and is_binary(uri.path) and
         String.ends_with?(uri.path, @handoff_suffix) do
      {:ok, url}
    else
      {:error, :invalid_token_factory_url}
    end
  end

  defp endpoint(_), do: {:error, :token_factory_not_configured}

  defp secret(secret) when is_binary(secret) do
    case String.trim(secret) do
      "" ->
        {:error, :token_factory_secret_missing}

      trimmed ->
        if String.match?(trimmed, ~r/^[\x21-\x7e]+$/),
          do: {:ok, trimmed},
          else: {:error, :invalid_token_factory_secret}
    end
  end

  defp secret(_), do: {:error, :token_factory_secret_missing}

  defp profile(nil), do: {:ok, nil}

  defp profile(name) when is_binary(name) do
    name = String.trim(name)

    if Regex.match?(@profile, name) and name not in [".", ".."],
      do: {:ok, name},
      else: {:error, :invalid_google_profile}
  end

  defp config(opts) do
    SystemsRuntime.get_env(:salix_meet_native, :token_factory, [])
    |> Keyword.merge(Keyword.take(opts, [:url, :secret, :req_options]))
  end

  defp known(value, allowed), do: if(value in allowed, do: value)
  defp string(value) when is_binary(value), do: value
  defp string(_), do: nil
  defp now_ms, do: SystemsClock.monotonic_time(:millisecond)
end
