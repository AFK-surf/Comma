defmodule SalixMeetNative.SyncLoop do
  @moduledoc false

  alias SalixMeetNative.{Rpc, Sync}

  @min_interval_ms 10_000
  @request_timeout_ms 75_000
  @skip_headers ~w(host content-length accept-encoding connection x-goog-meeting-token)

  defstruct [:url, :headers, :user_agent, :cookie, :space, :first_body, bearer: nil]

  @spec start_link(pid(), %__MODULE__{}, keyword()) :: {:ok, pid()}
  def start_link(parent, %__MODULE__{} = template, opts \\ []) do
    Task.start_link(fn -> run(parent, template, opts) end)
  end

  def run(parent, template, opts) do
    token =
      Enum.find_value(template.headers, fn {k, v} ->
        if String.downcase(k) == "x-goog-meeting-token", do: v
      end)

    loop(%{
      parent: parent,
      template: template,
      opts: opts,
      versions: %{},
      token: token,
      iteration: 0,
      states: %{},
      signatures: %{},
      backoff: 0
    })
  end

  defp loop(s) do
    started = SystemsClock.monotonic_time(:millisecond)

    body =
      if s.iteration == 0 and s.template.first_body not in [nil, ""],
        do: s.template.first_body,
        else: Sync.encode_request(s.template.space, s.versions)

    case Rpc.post(s.template.url, headers(s.template, s.token), body, @request_timeout_ms, s.opts) do
      {:ok, status, resp_body, resp_headers} ->
        s = roll_token(s, Rpc.header(resp_headers, "x-goog-meeting-token"))

        cond do
          status == 200 ->
            s |> handle_response(resp_body) |> pace(started) |> next()

          retryable_status?(status) ->
            send(s.parent, {:meet_sync, self(), {:status, status}})
            s |> backoff() |> next()

          true ->
            # Terminal (4xx other than 408/429): stop the loop instead of hot-looping a request
            # the server will keep rejecting.
            send(s.parent, {:meet_sync, self(), {:status, status}})
            :ok
        end

      {:error, reason} ->
        send(s.parent, {:meet_sync, self(), {:error, reason}})
        s |> backoff() |> next()
    end
  end

  defp next(s), do: loop(%{s | iteration: s.iteration + 1})

  defp retryable_status?(status), do: status == 0 or status in [408, 429] or status >= 500

  defp roll_token(s, nil), do: s
  defp roll_token(%{token: token} = s, token), do: s

  defp roll_token(s, token) do
    send(s.parent, {:meet_sync, self(), {:token, token}})
    %{s | token: token}
  end

  defp handle_response(s, body) do
    t = "#{s.iteration}.0"
    deltas = Sync.parse_response(body)
    events = Sync.events(deltas, t)

    if Sync.devices_changed?(deltas),
      do: send(s.parent, {:meet_sync, self(), {:roster, Sync.roster(events)}})

    {transitions, states} = Sync.membership_transitions(s.states, events, t)
    {events, signatures} = Sync.dedupe_roster(events ++ transitions, s.signatures)
    if events != [], do: send(s.parent, {:meet_sync, self(), {:events, events}})

    %{
      s
      | versions: Sync.apply_versions(s.versions, deltas),
        states: states,
        signatures: signatures,
        backoff: 0
    }
  end

  defp pace(s, started) do
    remaining = @min_interval_ms - (SystemsClock.monotonic_time(:millisecond) - started)
    if remaining > 0, do: SystemsClock.sleep(remaining)
    s
  end

  defp backoff(s) do
    delay = if s.backoff <= 0, do: 5_000, else: min(s.backoff * 2, 60_000)
    SystemsClock.sleep(delay)
    %{s | backoff: delay}
  end

  defp headers(template, token) do
    base =
      for {k, v} <- template.headers,
          k = String.downcase(k),
          not String.starts_with?(k, ":"),
          k not in @skip_headers,
          into: %{},
          do: {k, v}

    base
    |> then(fn h -> if token, do: Map.put(h, "x-goog-meeting-token", token), else: h end)
    |> then(fn h ->
      if template.user_agent not in [nil, ""],
        do: Map.put(h, "user-agent", template.user_agent),
        else: h
    end)
    |> Map.put_new("content-type", "application/x-protobuf")
    |> Map.put_new("x-goog-authuser", "0")
    |> Map.put("origin", "https://meet.google.com")
    |> Map.put("referer", "https://meet.google.com/")
    |> Map.put("accept-encoding", "identity")
    |> auth(template)
  end

  defp auth(headers, %{bearer: bearer}) when is_binary(bearer) and bearer != "",
    do: Map.put(headers, "authorization", "Bearer " <> bearer)

  defp auth(headers, %{cookie: cookie}) when is_binary(cookie) and cookie != "" do
    headers
    |> Map.put("cookie", cookie)
    |> Map.put("authorization", Rpc.sapisidhash(cookie))
  end

  defp auth(headers, _template), do: headers
end
