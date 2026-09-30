defmodule AlertRouter.Slack.ReqClient do
  @moduledoc """
  JSON-only Slack adapter for the three mutations Alert Router owns.

  Automatic HTTP retries are disabled. A transport error, Slack 5xx, or
  `internal_error`/`fatal_error` after a chat mutation is ambiguous because
  Slack may have committed it. Callers reconcile through stable Block Kit
  markers and never blindly repeat the mutation.
  """

  @behaviour AlertRouter.Slack.Client

  alias AlertRouter.Slack.MessageMarker

  @impl true
  def post_root(channel, payload) do
    request(:root_post, "chat.postMessage", Map.put(payload, "channel", channel))
  end

  @impl true
  def update_root(channel, ts, payload) do
    payload = payload |> Map.put("channel", channel) |> Map.put("ts", ts)
    request(:root_update, "chat.update", payload)
  end

  @impl true
  def post_reply(channel, thread_ts, payload) do
    payload = payload |> Map.put("channel", channel) |> Map.put("thread_ts", thread_ts)
    request(:timeline_post, "chat.postMessage", payload)
  end

  @impl true
  def permalink(channel, ts) do
    AlertRouter.Telemetry.observe(:permalink, :slack, fn ->
      with {:ok, token} <- token(),
           {:ok, %Req.Response{status: 200, body: %{"ok" => true, "permalink" => url}}}
           when is_binary(url) <-
             Req.get(base_url() <> "/chat.getPermalink",
               params: [channel: channel, message_ts: ts],
               headers: [authorization: "Bearer #{token}"],
               receive_timeout: timeout(),
               retry: false
             ),
           %URI{scheme: "https", host: host} when is_binary(host) <- URI.parse(url),
           true <- String.ends_with?(host, ".slack.com") do
        {:ok, url}
      else
        _ -> {:error, :permalink_unavailable}
      end
    end)
  end

  @impl true
  def find_root(channel, root_ts, incident_id, render_revision) do
    params = %{
      "channel" => channel,
      "inclusive" => true,
      "latest" => root_ts,
      "limit" => 1
    }

    lookup(
      :root_reconcile,
      "conversations.history",
      params,
      fn message ->
        message["ts"] == root_ts and
          MessageMarker.root?(message, incident_id, render_revision)
      end,
      fn _body -> true end
    )
  end

  @impl true
  def find_roots(channel, incident_id, render_revision, oldest, latest) do
    params = %{
      "channel" => channel,
      "limit" => 100,
      "oldest" => oldest,
      "latest" => latest
    }

    lookup(:root_reconcile, "conversations.history", params, fn message ->
      MessageMarker.root?(message, incident_id, render_revision)
    end)
  end

  @impl true
  def find_replies(channel, root_ts, event_id, oldest, latest) do
    params = %{
      "channel" => channel,
      "ts" => root_ts,
      "limit" => 100,
      "oldest" => oldest,
      "latest" => latest
    }

    method = if is_nil(root_ts), do: "conversations.history", else: "conversations.replies"
    params = if is_nil(root_ts), do: Map.delete(params, "ts"), else: params

    lookup(:timeline_reconcile, method, params, fn message ->
      MessageMarker.timeline?(message, event_id)
    end)
  end

  defp request(operation, method, payload) do
    AlertRouter.Telemetry.observe(operation, :slack, fn ->
      do_request(method, payload)
    end)
  end

  defp do_request(method, payload) do
    with {:ok, token} <- token() do
      case Req.post(base_url() <> "/" <> method,
             json: payload,
             headers: [authorization: "Bearer #{token}"],
             receive_timeout: timeout(),
             retry: false
           ) do
        {:ok, %Req.Response{status: 200, body: %{"ok" => true, "ts" => ts}}}
        when is_binary(ts) and ts != "" ->
          {:ok, %{ts: ts}}

        {:ok, %Req.Response{status: 429} = response} ->
          {:error, {:rate_limited, retry_after(response)}}

        {:ok, %Req.Response{status: status}} when status >= 500 ->
          ambiguous({:slack_http, status})

        {:ok, %Req.Response{status: 200, body: %{"ok" => false, "error" => "ratelimited"} = body}} ->
          {:error, {:rate_limited, body_retry_after(body)}}

        {:ok, %Req.Response{status: 200, body: %{"ok" => false, "error" => error}}}
        when error in ["internal_error", "fatal_error"] ->
          ambiguous({:slack_rejected, 200, error})

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:permanent, {:slack_rejected, status, safe_error(body)}}}

        {:error, exception} ->
          ambiguous({:transport, exception.__struct__})
      end
    end
  end

  defp lookup(operation, method, params, matcher, completeness \\ &complete_page?/1) do
    AlertRouter.Telemetry.observe(operation, :slack, fn ->
      do_lookup(method, params, matcher, completeness)
    end)
  end

  defp do_lookup(method, params, matcher, completeness) do
    with {:ok, token} <- token() do
      case Req.get(base_url() <> "/" <> method,
             params: params,
             headers: [authorization: "Bearer #{token}"],
             receive_timeout: timeout(),
             retry: false
           ) do
        {:ok, %Req.Response{status: 200, body: %{"ok" => true} = body}} ->
          messages = if is_list(body["messages"]), do: body["messages"], else: []

          matches =
            messages
            |> Enum.filter(&(is_map(&1) and matcher.(&1)))
            |> Enum.map(&lookup_match/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.sort_by(& &1.ts)

          {:ok, %{matches: matches, complete?: completeness.(body)}}

        {:ok, %Req.Response{status: 429} = response} ->
          {:error, {:rate_limited, retry_after(response)}}

        {:ok, %Req.Response{status: status}} when status >= 500 ->
          {:error, {:retryable, {:slack_http, status}}}

        {:ok, %Req.Response{status: 200, body: %{"ok" => false, "error" => "ratelimited"} = body}} ->
          {:error, {:rate_limited, body_retry_after(body)}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:permanent, {:slack_rejected, status, safe_error(body)}}}

        {:error, exception} ->
          {:error, {:retryable, {:transport, exception.__struct__}}}
      end
    end
  end

  defp ambiguous(reason), do: {:error, {:ambiguous, reason}}

  defp token do
    case config()[:bot_token] do
      token when is_binary(token) and byte_size(token) > 0 -> {:ok, token}
      _ -> {:error, {:permanent, :slack_bot_token_missing}}
    end
  end

  defp base_url,
    do: config() |> Keyword.get(:base_url, "https://slack.com/api") |> String.trim_trailing("/")

  defp timeout, do: Keyword.get(config(), :request_timeout_ms, 8_000)
  defp config, do: Application.get_env(:alert_router, :slack, [])

  defp retry_after(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value | _] -> parse_positive_integer(value, 1)
      [] -> body_retry_after(response.body)
    end
  end

  defp body_retry_after(%{"retry_after" => value}), do: parse_positive_integer(value, 1)
  defp body_retry_after(_body), do: 1

  defp parse_positive_integer(value, fallback) do
    case Integer.parse(to_string(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> fallback
    end
  end

  defp safe_error(%{"error" => error}) when is_binary(error), do: error
  defp safe_error(_body), do: "invalid_response"

  defp lookup_match(%{"ts" => ts} = message) when is_binary(ts) do
    case MessageMarker.identify(message) do
      %{kind: :root, render_revision: revision} ->
        %{ts: ts, render_revision: revision, event_id: nil}

      %{kind: :timeline, render_revision: revision, event_id: event_id} ->
        %{ts: ts, render_revision: revision, event_id: event_id}

      nil ->
        nil
    end
  end

  defp lookup_match(_message), do: nil

  defp complete_page?(body) do
    cursor = get_in(body, ["response_metadata", "next_cursor"])
    body["has_more"] != true and cursor in [nil, ""]
  end
end
