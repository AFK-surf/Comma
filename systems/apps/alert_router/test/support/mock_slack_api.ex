defmodule AlertRouter.MockSlackAPI do
  @moduledoc false

  use Agent
  @behaviour Plug

  import Plug.Conn

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        %{
          requests: [],
          messages: [],
          scripts: [],
          next_sequence: 1,
          base_seconds: System.system_time(:second),
          history_complete?: true,
          replies_complete?: true
        }
      end,
      name: __MODULE__
    )
  end

  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  def messages,
    do: Agent.get(__MODULE__, &Enum.sort_by(&1.messages, fn message -> message["ts"] end))

  def script_next(path, response) when is_binary(path) do
    Agent.update(__MODULE__, fn state ->
      %{state | scripts: state.scripts ++ [{path, response}]}
    end)
  end

  def set_complete(:history, complete?) when is_boolean(complete?) do
    Agent.update(__MODULE__, &%{&1 | history_complete?: complete?})
  end

  def set_complete(:replies, complete?) when is_boolean(complete?) do
    Agent.update(__MODULE__, &%{&1 | replies_complete?: complete?})
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    {body, conn} = read_json_body(conn)

    request = %{
      path: conn.request_path,
      method: conn.method,
      authorization: get_req_header(conn, "authorization"),
      body: body,
      query: conn.query_params
    }

    response =
      Agent.get_and_update(__MODULE__, fn state ->
        {script, state} = pop_script(state, conn.request_path)

        {response, state} =
          handle_request(conn.request_path, body, conn.query_params, script, state)

        {response, %{state | requests: [request | state.requests]}}
      end)

    send_json(conn, response)
  end

  defp handle_request(path, body, _query, {:commit, status, response_body}, state)
       when path in ["/api/chat.postMessage", "/api/chat.update"] do
    {_success_body, state} = commit_mutation(path, body, state)
    {{status, response_body, []}, state}
  end

  defp handle_request(path, body, _query, {:gate_commit, notify_pid, ref}, state)
       when path in ["/api/chat.postMessage", "/api/chat.update"] and is_pid(notify_pid) do
    {response_body, state} = commit_mutation(path, body, state)
    send(notify_pid, {:mock_slack_gate, ref, self()})

    receive do
      {:release_mock_slack_gate, ^ref} -> {{200, response_body, []}, state}
    after
      2_000 -> {{500, %{"ok" => false, "error" => "gate_timeout"}, []}, state}
    end
  end

  defp handle_request(_path, _body, _query, {:respond, status, response_body}, state) do
    {{status, response_body, []}, state}
  end

  defp handle_request(_path, _body, _query, {:respond, status, response_body, headers}, state) do
    {{status, response_body, headers}, state}
  end

  defp handle_request(path, body, _query, nil, state)
       when path in ["/api/chat.postMessage", "/api/chat.update"] do
    {response_body, state} = commit_mutation(path, body, state)
    {{200, response_body, []}, state}
  end

  defp handle_request("/api/conversations.history", _body, query, nil, state) do
    messages =
      state.messages
      |> Enum.filter(&(is_nil(&1["thread_ts"]) and &1["channel"] == query["channel"]))
      |> in_window(query)
      |> Enum.sort_by(& &1["ts"], :desc)

    {page, natural_complete?} = page(messages, query["limit"])
    complete? = natural_complete? and state.history_complete?

    body = %{
      "ok" => true,
      "messages" => page,
      "has_more" => not complete?,
      "response_metadata" => %{"next_cursor" => if(complete?, do: "", else: "next")}
    }

    {{200, body, []}, state}
  end

  defp handle_request("/api/chat.getPermalink", _body, query, nil, state) do
    url =
      "https://comma-test.slack.com/archives/#{query["channel"]}/p#{String.replace(query["message_ts"], ".", "")}"

    {{200, %{"ok" => true, "permalink" => url}, []}, state}
  end

  defp handle_request("/api/conversations.replies", _body, query, nil, state) do
    messages =
      state.messages
      |> Enum.filter(fn message ->
        message["channel"] == query["channel"] and
          (message["ts"] == query["ts"] or message["thread_ts"] == query["ts"])
      end)
      |> in_window(query)
      |> Enum.sort_by(& &1["ts"])

    {page, natural_complete?} = page(messages, query["limit"])
    complete? = natural_complete? and state.replies_complete?

    body = %{
      "ok" => true,
      "messages" => page,
      "has_more" => not complete?,
      "response_metadata" => %{"next_cursor" => if(complete?, do: "", else: "next")}
    }

    {{200, body, []}, state}
  end

  defp handle_request(_path, _body, _query, nil, state) do
    {{404, %{"ok" => false, "error" => "unknown_method"}, []}, state}
  end

  defp commit_mutation("/api/chat.update", body, state) do
    message =
      body
      |> Map.take(["channel", "text", "blocks"])
      |> Map.put("ts", body["ts"])

    messages =
      Enum.map(state.messages, fn existing ->
        if existing["channel"] == body["channel"] and existing["ts"] == body["ts"] do
          Map.merge(existing, message)
        else
          existing
        end
      end)

    {%{"ok" => true, "ts" => body["ts"], "channel" => body["channel"]},
     %{state | messages: messages}}
  end

  defp commit_mutation("/api/chat.postMessage", body, state) do
    ts = slack_ts(state.base_seconds, state.next_sequence)

    message =
      body
      |> Map.take(["channel", "thread_ts", "text", "blocks"])
      |> Map.put("ts", ts)

    {%{"ok" => true, "ts" => ts, "channel" => body["channel"]},
     %{state | messages: [message | state.messages], next_sequence: state.next_sequence + 1}}
  end

  defp pop_script(%{scripts: scripts} = state, path) do
    case Enum.split_while(scripts, fn {script_path, _response} -> script_path != path end) do
      {before, [{^path, response} | after_scripts]} ->
        {response, %{state | scripts: before ++ after_scripts}}

      {_before, []} ->
        {nil, state}
    end
  end

  defp read_json_body(conn) do
    case read_body(conn) do
      {:ok, "", conn} -> {%{}, conn}
      {:ok, raw_body, conn} -> {Jason.decode!(raw_body), conn}
    end
  end

  defp send_json(conn, {status, body, headers}) do
    conn =
      Enum.reduce(headers, conn, fn {key, value}, acc -> put_resp_header(acc, key, value) end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp in_window(messages, query) do
    Enum.filter(messages, fn message ->
      after_oldest? = is_nil(query["oldest"]) or message["ts"] >= query["oldest"]
      before_latest? = is_nil(query["latest"]) or message["ts"] <= query["latest"]
      after_oldest? and before_latest?
    end)
  end

  defp page(messages, limit) do
    limit = parse_limit(limit)
    {Enum.take(messages, limit), length(messages) <= limit}
  end

  defp parse_limit(nil), do: 100

  defp parse_limit(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> min(integer, 100)
      _ -> 100
    end
  end

  defp slack_ts(seconds, sequence) do
    Integer.to_string(seconds) <> "." <> String.pad_leading(Integer.to_string(sequence), 6, "0")
  end
end
