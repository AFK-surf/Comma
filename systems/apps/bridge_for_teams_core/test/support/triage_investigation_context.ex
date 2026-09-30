defmodule BridgeForTeams.TriageInvestigationContext do
  @moduledoc false
  @behaviour SalixAgent.Tools.ImRouter

  alias BridgeForTeams.TriageEngineFixture
  alias SalixIM.Provider
  alias SalixIM.Provider.OperationRegistry
  alias SalixIM.SlackMessageMirror.Row

  @state_key :triage_investigation_context_state
  @max_read_events 200
  @observed_params ~w(channel ts oldest latest before_ts limit count cursor inclusive root_already_preloaded query mode sort sort_dir workspace sender kind)
  @context_channel "CLOCALCONTEXT"
  @context_root "1788775560.000000"
  @runbook_url "https://docs.example.test/auth/session-refresh"

  def build(authority, source, incident, source_root),
    do: build(authority, source, incident, source_root, :positive)

  def build(authority, source, incident, source_root, :release_observation) do
    context = build(authority, source, incident, source_root, :sparse)
    channel = "CLOCALRELEASE"
    root = "1787019005.000000"
    link = "https://atlas.slack.com/archives/#{channel}/p1787019005000000"

    messages = [
      context.messages |> hd() |> Map.put("reply_count", 1),
      message(
        authority["approved_channel_id"],
        "1787019010.000000",
        source_root,
        "#{incident} 的发布对象快照和验证请求路由记录在 <#{link}|诊断线程>。"
      ),
      message(channel, root, root, "#{incident} / staging / atlas-api：发布对象快照与单次验证请求记录。")
      |> Map.put("reply_count", 2),
      message(
        channel,
        "1787019006.000000",
        root,
        "#{incident} / staging / atlas-api; observed_at=2026-08-18T02:09:30Z; desired_revision=rev-204; desired_replicas=3; updated_replicas=2; ready_replicas=3."
      ),
      message(
        channel,
        "1787019007.000000",
        root,
        "#{incident} / staging / atlas-api; trace_id=edge-trace-204-1; request_id=probe-204-1; request_at=2026-08-18T02:09:58Z; backend_instance=atlas-api-old-1; backend_revision=rev-203; http_status=200."
      )
    ]

    Map.merge(context, %{
      scenario: :release_observation,
      evidence_incident: incident,
      evidence_marker: "edge-trace-204-1",
      messages: messages,
      evidence: tl(messages),
      context_channel: channel,
      context_channel_name: "release-diagnostics",
      context_root: root,
      runbook_url: "https://docs.example.test/releases/observation-fields",
      runbook_title: "Release observation field definitions (local fixture)",
      runbook_search_terms: ~w(release deployment rollout revision replica staging 发布 部署 版本 副本),
      runbook:
        "Local fixture field definitions. Timestamps use UTC. release_job.status is the recorded job result. desired_revision is the requested deployment revision; desired_replicas is the requested replica count; updated_replicas counts replicas reporting the desired revision; ready_replicas counts ready replicas. A deployment snapshot records one observation time. request_id correlates a captured request; backend_instance and backend_revision describe the selected backend in that request trace. rollback_observation holds exported rollback observations when present."
    })
  end

  def build(authority, source, incident, source_root, scenario)
      when scenario in [:positive, :sparse, :wrong_session] do
    evidence_incident =
      case scenario do
        :positive -> incident
        :sparse -> nil
        :wrong_session -> "other-#{incident}"
      end

    session = if evidence_incident, do: "session-#{evidence_incident}"
    old_ref = if evidence_incident, do: "access-old-#{evidence_incident}"
    new_ref = if evidence_incident, do: "access-new-#{evidence_incident}"
    subject = "orion meet bot"
    context_link = "https://atlas.slack.com/archives/#{@context_channel}/p1788775560000000"

    original =
      message(authority["approved_channel_id"], source_root, source_root, source)
      |> Map.put("user", "U_CAPTURED_HUMAN")
      |> Map.put("reply_count", if(scenario == :sparse, do: 0, else: 1))

    source_followup =
      if scenario == :wrong_session,
        do: "认证同事之前在 #{subject} 的 #{evidence_incident} 排查中留过脱敏记录：<#{context_link}|诊断线程>。",
        else: "本次排查关联 #{incident}。认证同事的脱敏会话记录在 <#{context_link}|诊断线程>。"

    messages =
      if scenario == :sparse,
        do: [original],
        else: [
          original,
          message(
            authority["approved_channel_id"],
            "1788775620.000000",
            source_root,
            source_followup
          ),
          message(
            @context_channel,
            @context_root,
            @context_root,
            "#{subject}：事件 #{evidence_incident} 对应会话 #{session}。下面两条是本次导出的服务端刷新与客户端请求记录；不是全账号历史审计。"
          )
          |> Map.put("reply_count", 2),
          message(
            @context_channel,
            "1788775561.000000",
            @context_root,
            "#{subject} / #{evidence_incident} / #{session}: 2026-09-07T09:59:58Z refresh result=success; old_access_ref=#{old_ref}; issued_access_ref=#{new_ref}; issued_access_expires_at=2026-09-07T11:00:00Z. These refs are diagnostic identifiers, not credential values."
          ),
          message(
            @context_channel,
            "1788775562.000000",
            @context_root,
            "#{subject} / #{evidence_incident} / #{session}: 2026-09-07T10:04:59Z request used_access_ref=#{old_ref}; response=401 token_expired. This record does not identify which cache or update step retained the old reference."
          )
        ]

    %{
      scope:
        Map.take(authority, ~w(tenant_id group_id connect_id connect_generation workspace_id)),
      messages: messages,
      evidence: Enum.reject(messages, &(&1["ts"] == source_root)),
      incident: incident,
      scenario: scenario,
      evidence_incident: evidence_incident,
      evidence_session: session,
      evidence_old_ref: old_ref,
      evidence_new_ref: new_ref,
      evidence_marker: new_ref,
      session: session,
      old_ref: old_ref,
      new_ref: new_ref,
      context_channel: @context_channel,
      context_root: @context_root,
      runbook_url: @runbook_url,
      runbook:
        "A successful refresh issues a new access token. A later request can still fail if a caller uses the previous token. Correlate session identity, issued token reference and the token reference actually used by the failed request before blaming refresh scheduling. References are diagnostic identifiers; never share bearer credentials."
    }
  end

  def install!(state, context) do
    previous =
      for {app, key} <- [
            {:bridge_for_teams_core, @state_key},
            {:salix_agent, :im_provider_mod},
            {:salix_im, :slack_triage_clickhouse_reader_mod},
            {:salix_im, :slack_message_mirror_mod}
          ],
          do: {app, key, Application.fetch_env(app, key)}

    Agent.update(state, &Map.put(&1, :context, context))
    Application.put_env(:bridge_for_teams_core, @state_key, state)
    Application.put_env(:salix_agent, :im_provider_mod, __MODULE__)
    Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, __MODULE__)
    Application.put_env(:salix_im, :slack_message_mirror_mod, __MODULE__)

    fn ->
      Enum.each(previous, fn
        {app, key, :error} -> Application.delete_env(app, key)
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
      end)
    end
  end

  # Observe after the real Provider has applied its role/Group gates and added
  # the actual response wrapper (including MessageRead's coverage metadata).
  # Discovery and dispatch remain the production implementation for every role.
  defdelegate list_connects(agent_id), to: Provider
  defdelegate provider_manual(platform), to: Provider
  defdelegate provider_manual(platform, agent_id), to: Provider
  defdelegate group_providers(agent_id), to: Provider

  def call_api(agent_id, platform, api, args) do
    result = Provider.call_api(agent_id, platform, api, args)

    with "slack" <- platform,
         {:ok, response} <- result,
         {:ok, %{"safety" => "read"}} <- OperationRegistry.metadata(platform, api) do
      event = %{
        agent_id: agent_id,
        api: api,
        params: observed_params(args["params"] || %{}),
        response: response
      }

      state = Application.fetch_env!(:bridge_for_teams_core, @state_key)

      Agent.get_and_update(state, fn current ->
        events = Map.get(current, :provider_responses, [])

        if length(events) < @max_read_events do
          {result, Map.put(current, :provider_responses, events ++ [event])}
        else
          {{:error, "local fixture provider response observation limit exceeded"}, current}
        end
      end)
    else
      _ -> result
    end
  end

  defp observed_params(params) do
    params
    |> Map.take(@observed_params)
    |> Map.new(fn
      {key, value} when is_binary(value) and byte_size(value) <= 4_096 ->
        {key, value}

      {key, value} when is_boolean(value) or is_nil(value) ->
        {key, value}

      {key, value} when is_integer(value) and value in -1_000_000_000..1_000_000_000 ->
        {key, value}

      {key, _value} ->
        {key, "[omitted: outside fixture observation bound]"}
    end)
  end

  # Triage still consumes its original frozen fixture. Supplemental messages
  # belong to ordinary investigation reads, not its initial model input.
  defdelegate tail(scope), to: TriageEngineFixture.ClickHouseReader
  defdelegate list_changes(scope, window, limit), to: TriageEngineFixture.ClickHouseReader
  defdelegate latest_states(scope, timestamps), to: TriageEngineFixture.ClickHouseReader
  defdelegate read_thread(scope, root, opts), to: TriageEngineFixture.ClickHouseReader
  defdelegate read_channel(scope, window, opts), to: TriageEngineFixture.ClickHouseReader

  def record_batch(_rows), do: :ok
  def record_reaction_batch(_rows), do: :ok
  def record_pin_batch(_rows), do: :ok
  def record_metadata_batch(_rows), do: :ok

  def history(scope, opts), do: read(:history, scope, nil, opts)
  def replies(scope, root, opts), do: read(:replies, scope, root, opts)
  def search(scope, opts), do: read(:search, scope, nil, opts)

  def read(operation, scope, root, opts) do
    state = Application.get_env(:bridge_for_teams_core, @state_key)
    context = if is_pid(state), do: Agent.get(state, & &1.context)

    with %{} <- context,
         true <-
           Map.take(scope, ~w(tenant_id workspace_id)) ==
             Map.take(context.scope, ~w(tenant_id workspace_id)),
         {:ok, page} <- page(context.messages, operation, scope, root, opts) do
      tool_context = SalixIM.Provider.current_tool_context()

      event = %{
        operation: operation,
        agent_id: tool_context["agent_id"],
        scope: scope,
        root: root,
        options: Map.new(opts),
        messages: page.messages
      }

      Agent.get_and_update(state, fn current ->
        events = Map.get(current, :context_reads, [])

        if length(events) < @max_read_events do
          {{:ok, page}, Map.put(current, :context_reads, events ++ [event])}
        else
          {{:error, :local_fixture_context_receipts_full}, current}
        end
      end)
    else
      _ -> {:error, :local_fixture_context_unavailable}
    end
  end

  def page(messages, operation, scope, root, opts) do
    channel = scope["channel_id"] || opts[:channel_id]
    direction = if operation == :replies, do: :asc, else: opts[:sort_dir] || :desc

    request = %{
      "operation" => to_string(operation),
      "scope" => scope,
      "root" => root,
      "filters" =>
        opts
        |> Keyword.drop([:cursor, :limit, :cursor_ts_us, :cursor_channel_id])
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Jason.encode!()
    }

    with true <- seeded_target?(messages, operation, channel, root),
         limit when is_integer(limit) and limit in 1..1_000 <- opts[:limit] || 100,
         {:ok, offset} <- offset(opts[:cursor], request),
         {:ok, bounds} <- bounds(opts) do
      rows =
        messages
        |> Enum.filter(&(is_nil(channel) or &1["channel"] == channel))
        |> Enum.filter(&(operation != :replies or &1["thread_ts"] == root))
        |> Enum.filter(&(operation != :history or &1["thread_ts"] == &1["ts"]))
        |> Enum.filter(&in_bounds?(&1, bounds))
        |> Enum.filter(&(is_nil(opts[:actor_id]) or &1["user"] == opts[:actor_id]))
        |> Enum.filter(&(opts[:has_file] != true or List.wrap(&1["files"]) != []))
        |> Enum.filter(&(operation != :search or matches?(&1["text"], opts)))
        |> Enum.sort_by(&{micros!(&1["ts"]), &1["channel"]}, direction)

      rows =
        if operation == :search and opts[:cursor_ts_us] do
          cursor = {opts[:cursor_ts_us], opts[:cursor_channel_id]}

          Enum.filter(rows, fn row ->
            key = {micros!(row["ts"]), row["channel"]}
            if direction == :asc, do: key > cursor, else: key < cursor
          end)
        else
          Enum.drop(rows, offset)
        end

      {selected, remaining} = Enum.split(rows, limit)

      cursor =
        cond do
          remaining == [] ->
            nil

          operation == :search ->
            last = List.last(selected)
            {micros!(last["ts"]), last["channel"]}

          true ->
            encode_cursor(request, offset + length(selected))
        end

      {:ok, %{messages: selected, next_cursor: cursor, has_more?: remaining != []}}
    else
      _ -> {:error, :local_fixture_context_unavailable}
    end
  end

  def web_response(%{source_kind: :captured_collaboration} = context, %{
        method: :post,
        path: path,
        json: params
      })
      when path in ["/search", "/contents"] do
    results =
      case path do
        "/contents" ->
          Enum.filter(
            context.web_documents,
            &(&1["url"] in List.wrap(params["urls"] || params["ids"]))
          )

        "/search" ->
          query = String.downcase(to_string(params["query"] || ""))

          Enum.filter(context.web_documents, fn document ->
            Enum.any?(~w(bug blindness danluu dan luu), &String.contains?(query, &1)) and
              document["url"] == "https://danluu.com/bug-blind/"
          end)
      end

    %Req.Response{
      status: 200,
      headers: %{"content-type" => ["application/json"]},
      body: Jason.encode!(%{"results" => results})
    }
  end

  def web_response(context, %{method: :post, path: path, json: params})
      when path in ["/search", "/contents"] do
    results =
      case path do
        "/search" ->
          query = String.downcase(to_string(params["query"] || ""))

          terms =
            Map.get(context, :runbook_search_terms, ~w(token refresh session auth salix 令牌 刷新))

          if Enum.any?(terms, &String.contains?(query, &1)),
            do: [web_document(context)],
            else: []

        "/contents" ->
          for url <- List.wrap(params["urls"] || params["ids"]),
              url == context.runbook_url,
              do: web_document(context)
      end

    %Req.Response{
      status: 200,
      headers: %{"content-type" => ["application/json"]},
      body: Jason.encode!(%{"results" => results})
    }
  end

  def web_response(_context, _request), do: {:error, :local_fixture_web_request_unavailable}

  def read_methods do
    ~w(emoji.list conversations.replies conversations.history conversations.info
       conversations.list conversations.members users.list users.info auth.test
       files.info canvases.sections.lookup)
  end

  def slack_response(context, method, params) when is_map(context) do
    channels =
      context.messages
      |> Enum.map(& &1["channel"])
      |> Enum.uniq()
      |> Enum.map(
        &%{
          "id" => &1,
          "name" =>
            if(&1 == Map.get(context, :context_channel, @context_channel),
              do: Map.get(context, :context_channel_name, "auth-diagnostics"),
              else: "source"
            ),
          "is_member" => true,
          "is_archived" => false
        }
      )

    users =
      Map.get(context, :users, [
        %{"id" => "ULOCALDIAG", "name" => "diagnostics", "is_bot" => false},
        %{"id" => "U_CAPTURED_HUMAN", "name" => "requester", "is_bot" => false}
      ])

    case method do
      "files.info" ->
        case get_in(context, [:files, params["file"]]) do
          %{body: body, metadata: metadata} when is_binary(body) ->
            %{"ok" => true, "file" => metadata}

          _ ->
            %{"ok" => false, "error" => "local_fixture_file_not_captured"}
        end

      operation when operation in ["conversations.replies", "conversations.history"] ->
        operation = if operation == "conversations.replies", do: :replies, else: :history

        with {limit, ""} <- Integer.parse(to_string(params["limit"] || "100")),
             {:ok, result} <-
               page(
                 context.messages,
                 operation,
                 %{"channel_id" => params["channel"]},
                 params["ts"],
                 limit: limit,
                 cursor: params["cursor"],
                 oldest: params["oldest"],
                 latest: params["latest"],
                 inclusive: params["inclusive"] in [true, "true", "1"]
               ) do
          %{
            "ok" => true,
            "messages" => result.messages,
            "has_more" => result.has_more?,
            "response_metadata" => %{"next_cursor" => result.next_cursor || ""}
          }
        else
          _ -> %{"ok" => false, "error" => "local_fixture_context_unavailable"}
        end

      "conversations.list" ->
        %{"ok" => true, "channels" => channels, "response_metadata" => %{"next_cursor" => ""}}

      "conversations.info" ->
        case Enum.find(channels, &(&1["id"] == params["channel"])) do
          nil -> %{"ok" => false, "error" => "channel_not_found"}
          channel -> %{"ok" => true, "channel" => channel}
        end

      "conversations.members" ->
        if Enum.any?(channels, &(&1["id"] == params["channel"])),
          do: %{
            "ok" => true,
            "members" => Enum.map(users, & &1["id"]),
            "response_metadata" => %{"next_cursor" => ""}
          },
          else: %{"ok" => false, "error" => "channel_not_found"}

      "users.list" ->
        %{"ok" => true, "members" => users, "response_metadata" => %{"next_cursor" => ""}}

      "users.info" ->
        case Enum.find(users, &(&1["id"] == params["user"])) do
          nil -> %{"ok" => false, "error" => "user_not_found"}
          user -> %{"ok" => true, "user" => user}
        end

      _ ->
        %{"ok" => false, "error" => "local_fixture_read_not_seeded"}
    end
  end

  def slack_response(_context, _method, _params),
    do: %{"ok" => false, "error" => "local_fixture_read_not_seeded"}

  defp web_document(context),
    do: %{
      "url" => context.runbook_url,
      "title" => Map.get(context, :runbook_title, "Session refresh diagnostics"),
      "text" => context.runbook
    }

  defp message(channel, ts, root, text),
    do: %{
      "type" => "message",
      "channel" => channel,
      "ts" => ts,
      "thread_ts" => root,
      "user" => "ULOCALDIAG",
      "text" => text
    }

  # This is only a fixture continuation, not a signed authorization token.
  # Preserve the request coordinates so replay cannot silently change pages.
  defp encode_cursor(request, offset) do
    "local-context:" <>
      Base.url_encode64(Jason.encode!(%{"request" => request, "offset" => offset}),
        padding: false
      )
  end

  defp offset(cursor, _request) when cursor in [nil, ""], do: {:ok, 0}

  defp offset("local-context:" <> value, request) do
    with {:ok, json} <- Base.url_decode64(value, padding: false),
         {:ok, %{"request" => ^request, "offset" => n}} <- Jason.decode(json),
         true <- is_integer(n) and n >= 0 do
      {:ok, n}
    else
      _ -> :error
    end
  end

  defp offset(_, _), do: :error

  defp seeded_target?(messages, :search, channel, _root),
    do: is_nil(channel) or Enum.any?(messages, &(&1["channel"] == channel))

  defp seeded_target?(messages, :history, channel, _root),
    do: is_binary(channel) and Enum.any?(messages, &(&1["channel"] == channel))

  defp seeded_target?(messages, :replies, channel, root),
    do:
      Enum.any?(
        messages,
        &(&1["channel"] == channel and &1["ts"] == root and &1["thread_ts"] == root)
      )

  defp seeded_target?(_, _, _, _), do: false

  defp bounds(opts) do
    with {:ok, oldest} <- optional_micros(opts[:after_us] || opts[:oldest]),
         {:ok, latest} <- optional_micros(opts[:before_us] || opts[:latest]) do
      {:ok, %{oldest: oldest, latest: latest, inclusive: opts[:inclusive] == true}}
    end
  end

  defp in_bounds?(row, opts) do
    time = micros!(row["ts"])
    oldest = opts.oldest
    latest = opts.latest
    inclusive = opts.inclusive

    (is_nil(oldest) or time > oldest or (inclusive and time == oldest)) and
      (is_nil(latest) or time < latest or (inclusive and time == latest))
  end

  defp matches?(text, opts) do
    text = String.downcase(text)

    groups =
      case opts[:patterns] || [] do
        [first | _] = patterns when is_list(first) -> patterns
        patterns -> [patterns]
      end

    Enum.any?(groups, fn group -> Enum.all?(group, &String.contains?(text, term(&1))) end) and
      not Enum.any?(opts[:exclude_patterns] || [], &String.contains?(text, term(&1)))
  end

  defp term(pattern),
    do: pattern |> String.trim("%") |> String.replace("\\", "") |> String.downcase()

  defp optional_micros(value) when value in [nil, ""], do: {:ok, nil}
  defp optional_micros(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp optional_micros(value), do: Row.slack_ts_micros(value)

  defp micros!(value) do
    {:ok, micros} = Row.slack_ts_micros(value)
    micros
  end
end
