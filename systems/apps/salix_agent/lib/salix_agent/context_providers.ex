defmodule SalixAgent.ContextProviders do
  @moduledoc false

  require SalixAgent.InternalSession

  alias SalixAgent.InternalSession
  alias SalixAgent.MigrationNotice

  @doc false
  def current_state(session_config) when is_map(session_config) do
    tool_disclosure = value(session_config, :tool_disclosure)
    tool_revision = value(session_config, :tool_disclosure_revision)
    skill_revision = value(session_config, :skill_projection_revision)
    mcp_state = value(session_config, :mcp_provider_state)
    plugin_revision = value(session_config, :plugin_projection_revision)

    %{
      "model_context" => %{"version" => 1},
      "migration_notice" => %{"version" => MigrationNotice.version()},
      "tool_disclosure" =>
        %{
          "revision" => tool_revision || disclosure_revision(tool_disclosure)
        }
        |> compact_map(),
      "skill_projection" => %{"revision" => skill_revision} |> compact_map(),
      "plugins" => %{"revision" => plugin_revision} |> compact_map(),
      "mcp" => normalize_mcp_state(mcp_state)
    }
    |> Enum.reject(fn {_provider, state} -> empty_map?(state) end)
    |> Map.new()
  end

  @doc false
  def prepare_activation_delta(session, session_config)
      when (is_map(session) or InternalSession.is_session(session)) and is_map(session_config) do
    current = current_state(session_config)
    known = provider_states(session)

    {time_messages, time_state} =
      SalixAgent.TimeContext.prepare(time_context_view(session), known)

    current = Map.put(current, "time_context", time_state)

    {queue_messages, queue_state} =
      SalixAgent.QueuePressure.prepare(session, session_config, known)

    # Absent until the first message, so sessions that never saw queue
    # pressure keep comparing equal to their adopted state.
    current =
      if empty_map?(queue_state),
        do: current,
        else: Map.put(current, "queue_pressure", queue_state)

    {budget_messages, budget_state} = SalixAgent.RoundBudgetNotice.prepare(session, known)

    # Present only while the warning stands; fresh input clears it so the
    # next input can be warned again.
    current =
      if empty_map?(budget_state),
        do: current,
        else: Map.put(current, "round_budget", budget_state)

    messages =
      cond do
        get_in(known, ["model_context", "version"]) != 1 and
            (not empty_map?(known) or adopted_llm_context?(session)) ->
          baseline_messages(current, session_config)

        true ->
          delta_messages(known, current, session_config)
      end

    messages = messages ++ time_messages ++ queue_messages ++ budget_messages

    if messages == [] and current == known do
      :none
    else
      {:delta, %{messages: messages, provider_state: current}}
    end
  end

  defp baseline_messages(current, session_config) do
    # The owner filters superseded rules. Do not replay stored notifications,
    # whose body may contain obsolete instructions or a legacy projection.
    notices = migration_notice_delta(%{}, current)

    parts = [
      authoritative_tool_names(value(session_config, :tool_disclosure)),
      "Current skills are indexed at /.runtime/skills/index.md. Read relevant skills when needed.",
      "Use current plugin visibility and mcp.list/help for current MCP bindings and operations. Older availability notices are historical."
    ]

    notices ++ [runtime_guidance_payload(%{}, current, parts)]
  end

  @doc false
  def provider_states(session) when InternalSession.is_session(session),
    do: InternalSession.provider_states(session)

  def provider_states(session) when is_map(session) do
    session
    |> value(:context_provider_states)
    |> normalize_provider_states()
  end

  # `TimeContext.prepare/3` reads only the newest user message and the session
  # id, so the handle supplies exactly that instead of a whole transcript.
  defp time_context_view(session) when InternalSession.is_session(session) do
    latest = InternalSession.query(session, :latest_user_input_message)

    %{
      session_id: InternalSession.session_id(session),
      messages: List.wrap(latest)
    }
  end

  defp time_context_view(session), do: session

  @doc false
  def migration_provider_states(attrs) when is_map(attrs) do
    %{}
    |> maybe_put_migration_notice(attrs)
    |> maybe_put_migration_tool_disclosure(attrs)
    |> normalize_provider_states()
  end

  def migration_provider_states(_attrs), do: %{}

  @doc false
  def activation_commit_events(_session_id, nil, _first_id), do: {[], 0}

  def activation_commit_events(session_id, %{messages: messages}, first_id)
      when is_list(messages) and is_integer(first_id) do
    {events, next_id} =
      Enum.map_reduce(messages, first_id, fn payload, id ->
        event =
          payload
          |> stringify()
          |> Map.merge(%{
            "type" => "runtime_message",
            "session_id" => session_id,
            "from_context_provider" => true,
            "message_id" => id,
            "no_wake" => true,
            "created_at" => payload["created_at"] || System.system_time(:second)
          })

        {event, id + 1}
      end)

    {events, next_id - first_id}
  end

  @doc false
  def adopted_provider_state(%{provider_state: state}), do: normalize_provider_states(state)
  def adopted_provider_state(_delta), do: %{}

  @doc false
  def model_messages(delta),
    do: InternalSession.request_projection({:model_messages, delta})

  @doc false
  def strip_llm_private_metadata(messages) when is_list(messages),
    do: Enum.map(messages, &strip_llm_private_metadata/1)

  def strip_llm_private_metadata(%{} = message),
    do:
      Map.drop(message, [
        :do_not_send_to_llm,
        "do_not_send_to_llm",
        :accepted_input,
        "accepted_input"
      ])

  def strip_llm_private_metadata(message), do: message

  defp delta_messages(known, current, session_config) do
    migration_notice_messages = migration_notice_delta(known, current)

    guidance_parts =
      [
        tool_disclosure_delta(known, current, value(session_config, :tool_disclosure)),
        plugin_delta(known, current),
        skill_projection_delta(known, current),
        mcp_delta(known, current)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    guidance_messages =
      case guidance_parts do
        [] -> []
        _ -> [runtime_guidance_payload(known, current, guidance_parts)]
      end

    migration_notice_messages ++ guidance_messages
  end

  defp migration_notice_delta(known, current) do
    known_version =
      get_in(known, ["migration_notice", "version"]) |> migration_notice_version_value()

    current_version =
      get_in(current, ["migration_notice", "version"]) |> migration_notice_version_value()

    if current_version > known_version do
      payloads =
        known_version
        |> MigrationNotice.payloads_since()

      case payloads do
        [] -> []
        _ -> [migration_notice_payload(known_version, current_version, payloads)]
      end
    else
      []
    end
  end

  defp migration_notice_payload(known_version, current_version, payloads) do
    content = migration_notice_content(known_version, current_version, payloads)
    summary = migration_notice_summary(known_version, current_version, payloads)

    digest =
      :crypto.hash(
        :sha256,
        Jason.encode!(%{
          "from_version" => known_version,
          "to_version" => current_version,
          "payloads" => payloads
        })
      )
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    %{
      "runtime_message_id" => "migration-notice:#{digest}",
      "runtime_message_type" => "migration_notice",
      "summary" => summary,
      "content_kind" => "model_context",
      "content" => content,
      "source_refs" => %{"providers" => ["migration_notice"]}
    }
  end

  defp migration_notice_content(known_version, current_version, payloads) do
    summary = migration_notice_summary(known_version, current_version, payloads)

    changes =
      payloads
      |> Enum.map(fn payload ->
        version = payload["version"]
        content = payload["content"]

        cond do
          missing_text?(content) ->
            nil

          is_integer(version) ->
            "- v#{version}: #{content}"

          true ->
            "- #{content}"
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    [
      "Migration notice",
      "from_version: #{known_version}",
      "to_version: #{current_version}",
      "summary: #{summary}",
      "",
      "Changes:",
      changes
    ]
    |> Enum.reject(&missing_text?/1)
    |> Enum.join("\n")
  end

  defp migration_notice_summary(known_version, current_version, payloads) do
    summaries =
      payloads
      |> Enum.map(& &1["summary"])
      |> Enum.reject(&missing_text?/1)
      |> Enum.join("; ")

    "migration notice v#{known_version}->v#{current_version}: #{summaries}"
  end

  defp tool_disclosure_delta(known, current, disclosure) do
    known_revision = get_in(known, ["tool_disclosure", "revision"])
    current_revision = get_in(current, ["tool_disclosure", "revision"])

    cond do
      missing_text?(current_revision) ->
        []

      missing_text?(known_revision) ->
        []

      known_revision == current_revision ->
        []

      true ->
        [authoritative_tool_names(disclosure)]
    end
  end

  defp authoritative_tool_names(%{"tools" => tools}) when is_list(tools) do
    names =
      tools
      |> Enum.filter(&(&1["callable"] == true and &1["prompt_visibility"] != "hidden"))
      |> Enum.map(& &1["name"])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.sort()

    "Tool availability changed. The current preloaded callable tools are: " <>
      Enum.join(names, ", ") <>
      ". This list excludes on-demand tools. Discover those through help namespaces or mcp.list. It updates the older Tool Disclosure in the session system-prompt " <>
      "snapshot; a listed tool is callable even if older context says it is missing. " <>
      "Call business tools through the current runtime envelope and use help when you " <>
      "need a listed tool's current manual or schema."
  end

  defp authoritative_tool_names(_disclosure) do
    "Tool availability changed. If relevant, use help for known tools and provider " <>
      "discovery APIs for provider-specific operations."
  end

  defp skill_projection_delta(known, current) do
    known_revision = get_in(known, ["skill_projection", "revision"])
    current_revision = get_in(current, ["skill_projection", "revision"])

    cond do
      missing_text?(current_revision) ->
        []

      missing_text?(known_revision) ->
        []

      known_revision == current_revision ->
        []

      true ->
        ["Available skills changed. If relevant, read /.runtime/skills/index.md."]
    end
  end

  defp plugin_delta(known, current) do
    known_revision = get_in(known, ["plugins", "revision"])
    current_revision = get_in(current, ["plugins", "revision"])

    cond do
      missing_text?(current_revision) ->
        []

      missing_text?(known_revision) ->
        []

      known_revision == current_revision ->
        []

      true ->
        [
          "Plugin projection changed. If relevant, inspect current plugin visibility before using affected tools, skills, MCP bindings, OAuth credentials, or IM connects."
        ]
    end
  end

  defp mcp_delta(known, current) do
    known_revision = get_in(known, ["mcp", "revision"])
    current_revision = get_in(current, ["mcp", "revision"])

    cond do
      missing_text?(current_revision) ->
        []

      missing_text?(known_revision) ->
        []

      known_revision == current_revision ->
        []

      true ->
        [
          "MCP bindings or discovered MCP capabilities changed. If relevant, use mcp.list and help for MCP tools."
        ]
    end
  end

  defp runtime_guidance_payload(known, current, parts) do
    digest =
      :crypto.hash(
        :sha256,
        Jason.encode!(%{"known" => known, "current" => current, "parts" => parts})
      )
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    %{
      "runtime_message_id" => "context-provider:#{digest}",
      "runtime_message_type" => "runtime_guidance",
      "summary" => "runtime guidance changed",
      "content_kind" => "model_context",
      "content" => Enum.join(parts, "\n\n"),
      "source_refs" => %{"providers" => changed_providers(known, current)}
    }
  end

  defp changed_providers(known, current) do
    (Map.keys(known) ++ Map.keys(current))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(known, &1) != Map.get(current, &1)))
    |> Enum.sort()
  end

  defp disclosure_revision(%{"revision" => revision}), do: revision
  defp disclosure_revision(%{revision: revision}), do: revision
  defp disclosure_revision(_), do: nil

  defp maybe_put_migration_notice(states, attrs) do
    if adopted_llm_context?(attrs) do
      Map.put(states, "migration_notice", %{"version" => 0})
    else
      states
    end
  end

  defp maybe_put_migration_tool_disclosure(states, attrs) do
    snapshot_revision = value(attrs, :tool_disclosure_snapshot) |> disclosure_revision()
    revision = value(attrs, :tool_disclosure_revision) || snapshot_revision

    if missing_text?(revision) do
      states
    else
      Map.put(states, "tool_disclosure", %{"revision" => revision})
    end
  end

  defp adopted_llm_context?(session) when InternalSession.is_session(session),
    do: InternalSession.query(session, :adopted_llm_context?)

  defp adopted_llm_context?(attrs) do
    adopted_message?(value(attrs, :messages)) or
      nonempty_map?(value(attrs, :provider_compaction)) or
      not missing_text?(value(attrs, :summary))
  end

  defp adopted_message?(messages) when is_list(messages) do
    Enum.any?(messages, fn
      %{} = message ->
        role = value(message, :role)
        role in ["assistant", "tool"]

      _message ->
        false
    end)
  end

  defp adopted_message?(_value), do: false

  defp nonempty_map?(value) when is_map(value), do: map_size(value) > 0
  defp nonempty_map?(_value), do: false

  def normalize_provider_states(states) when is_map(states) do
    states
    |> stringify()
    |> normalize_legacy_migration_provider()
    |> Enum.reject(fn {_provider, state} -> empty_map?(state) end)
    |> Map.new()
  end

  def normalize_provider_states(_), do: %{}

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" or value == %{} end)
    |> Map.new()
  end

  defp empty_map?(map) when is_map(map), do: map_size(map) == 0
  defp empty_map?(_), do: true

  defp normalize_mcp_state(state) when is_map(state), do: compact_map(stringify(state))
  defp normalize_mcp_state(_state), do: %{}

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp missing_text?(value) when is_binary(value), do: String.trim(value) == ""
  defp missing_text?(nil), do: true
  defp missing_text?(_), do: false

  defp migration_notice_version_value(value),
    do: MigrationNotice.normalize_version(value)

  defp normalize_legacy_migration_provider(%{"migration_notice" => _state} = states), do: states

  defp normalize_legacy_migration_provider(
         %{"runtime_context" => %{"version" => version}} = states
       ) do
    states
    |> Map.delete("runtime_context")
    |> Map.put("migration_notice", %{
      "version" => MigrationNotice.normalize_version(version)
    })
  end

  defp normalize_legacy_migration_provider(states), do: states

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
