defmodule BridgeForTeams.TriageInvestigationSearch do
  @moduledoc """
  Finite local-corpus reader for the production group-owned Slack search path.

  Only the index reader is substituted. Catalog discovery, source publication,
  current Group/connect authorization and result-window ownership remain real.
  This reader matches case-insensitive whitespace-separated terms in text for
  every requested mode; it does not simulate embeddings or semantic ranking.
  Returned excerpts explicitly identify that test-only search semantics.

  Install only in an isolated test process/store. Stop callers before restoring
  the reader. The caller owns the supplied Agent and retains its read receipts.
  """

  alias SalixIM.Provider
  alias SalixIM.SlackMessageMirror.Row
  alias SalixStore.{SlackSearchCatalog, SlackSearchSources}

  @state_key :triage_investigation_search_state
  @scope_keys ~w(tenant_id group_id connect_id connect_generation workspace_id channel_id)
  @max_rows 50
  @max_text_bytes 16_384
  @max_read_events 200
  @semantics "Local fixture corpus: case-insensitive text terms, not semantic ranking."

  def install!(state, connect, messages)
      when is_pid(state) and is_map(connect) and is_list(messages) do
    unless length(messages) in 1..@max_rows,
      do: raise(ArgumentError, "local search corpus requires 1..#{@max_rows} messages")

    Enum.each(@scope_keys -- ["channel_id"], &required_string!(connect, &1))
    rows = Enum.map(messages, &prepare_row!(connect, &1))

    if length(Enum.uniq_by(rows, &source_key(&1.candidate))) != length(rows),
      do: raise(ArgumentError, "local search corpus has duplicate message identities")

    previous =
      for key <- [:slack_message_search_reader, @state_key],
          do: {key, Application.get_env(:salix_im, key)}

    :ok = SlackSearchCatalog.remember_connects([connect])
    :ok = SlackSearchCatalog.remember_channels(connect, Enum.map(messages, & &1["channel"]))

    rows = Enum.map(rows, &capture_row!/1)

    # The local index acknowledges complete rows before real PG publication.
    # No ClickHouse or embedding work is claimed by this test-only seam.
    Agent.update(state, &Map.put(&1, :search_rows, rows))
    Enum.each(rows, fn row -> :ok = SlackSearchSources.publish(row.candidate) end)

    Application.put_env(:salix_im, @state_key, state)
    Application.put_env(:salix_im, :slack_message_search_reader, __MODULE__)

    fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:salix_im, key)
        {key, value} -> Application.put_env(:salix_im, key, value)
      end)
    end
  end

  def active? do
    case Application.get_env(:salix_im, @state_key) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  def candidates(scope, connects, request) do
    allowed = MapSet.new(connects, &{&1["connect_id"], &1["workspace_id"]})
    terms = request["query"] |> String.downcase() |> String.split(~r/\s+/u, trim: true)

    found =
      rows()
      |> Enum.filter(fn row ->
        candidate = row.candidate

        owned?(candidate, scope) and
          MapSet.member?(allowed, {candidate["connect_id"], candidate["workspace_id"]}) and
          matches_request?(row, request, terms)
      end)
      |> Enum.map(& &1.candidate)
      |> Enum.sort_by(&{-&1["message_ts_us"], &1["channel_id"], &1["build_id"]})

    record(scope, "slack.message_search.candidates", [], %{
      request: request,
      candidate_refs: Enum.map(found, &reference/1)
    })

    {:ok, found}
  end

  def current_sources(tenant, candidates) do
    requested = MapSet.new(candidates, &source_key/1)

    current =
      rows()
      |> Enum.filter(fn row ->
        row.candidate["tenant_id"] == tenant and
          MapSet.member?(requested, source_key(row.candidate))
      end)
      |> Map.new(&{source_key(&1.candidate), &1.current_source})

    {:ok, current}
  end

  def excerpts(scope, candidates) do
    by_unit =
      rows()
      |> Enum.filter(&owned?(&1.candidate, scope))
      |> Map.new(&{{&1.candidate["build_id"], &1.candidate["unit"]}, &1.excerpt})

    result =
      Enum.map(candidates, fn candidate ->
        Map.fetch!(by_unit, {candidate["build_id"], candidate["unit"]})
      end)

    record(scope, "slack.message_search.excerpts", result, %{})
    {:ok, result}
  end

  defp prepare_row!(connect, message) when is_map(message) do
    channel = required_string!(message, "channel")
    timestamp = required_string!(message, "ts")
    text = required_string!(message, "text")
    user = required_string!(message, "user")
    {:ok, timestamp_us} = Row.slack_ts_micros(timestamp)
    root = message["thread_ts"] || timestamp
    {:ok, _} = Row.slack_ts_micros(root)

    unless byte_size(text) <= @max_text_bytes,
      do: raise(ArgumentError, "local search message exceeds #{@max_text_bytes} bytes")

    candidate =
      connect
      |> Map.take(@scope_keys)
      |> Map.merge(%{
        "channel_id" => channel,
        "message_ts_us" => timestamp_us,
        "component" => "lexical",
        "build_id" => Ecto.UUID.generate(),
        "message_identity" => Ecto.UUID.generate(),
        "payload_identity" => Ecto.UUID.generate(),
        "unit" => 1,
        "unit_count" => 1,
        "file_id" => "",
        "file_epoch" => 0
      })

    %{
      candidate: candidate,
      current_source: %{
        deleted: false,
        message_identity: candidate["message_identity"],
        payload_identity: candidate["payload_identity"]
      },
      excerpt: %{
        "build_id" => candidate["build_id"],
        "unit" => 1,
        "ts" => timestamp,
        "thread_ts" => root,
        "workspace_id" => connect["workspace_id"],
        "channel" => channel,
        "connect_id" => connect["connect_id"],
        "actor_id" => user,
        "actor_kind" => Map.get(message, "actor_kind", "human"),
        "text" => text,
        "content_kind" => "message_text",
        "fixture_search_semantics" => @semantics
      }
    }
  end

  defp prepare_row!(_connect, _message),
    do: raise(ArgumentError, "local search messages must be Slack maps")

  defp capture_row!(row) do
    {:ok, captured} =
      SlackSearchSources.capture(row.candidate, row.candidate["message_ts_us"])

    candidate =
      Map.merge(row.candidate, %{
        "change_epoch" => captured.change_epoch,
        "build_sequence" => captured.build_sequence
      })

    %{row | candidate: candidate}
  end

  defp matches_request?(row, request, terms) do
    candidate = row.candidate
    haystack = String.downcase(row.excerpt["text"])

    Enum.all?(terms, &String.contains?(haystack, &1)) and
      optional_match?(request["channel"], candidate["channel_id"]) and
      optional_match?(request["workspace"], candidate["workspace_id"]) and
      optional_match?(request["sender"], row.excerpt["actor_id"]) and
      request["kind"] in ["", "message_text"] and
      candidate["message_ts_us"] >= request["oldest"] and
      candidate["message_ts_us"] < request["latest"]
  end

  defp optional_match?(value, actual), do: value in [nil, "", actual]

  defp owned?(candidate, scope),
    do: candidate["tenant_id"] == scope.tenant_id and candidate["group_id"] == scope.group_id

  defp source_key(candidate),
    do: {candidate["workspace_id"], candidate["channel_id"], candidate["message_ts_us"]}

  defp reference(candidate),
    do: Map.take(candidate, @scope_keys ++ ~w(message_ts_us build_id unit))

  defp rows,
    do: Agent.get(Application.fetch_env!(:salix_im, @state_key), &Map.fetch!(&1, :search_rows))

  defp record(scope, operation, messages, extra) do
    context_agent = Provider.current_tool_context()["agent_id"]

    # MessageSearch executes the reader in Task.async. The Provider's process
    # dictionary context normally does not cross that boundary; scope.agent_id
    # is still the actual GroupDirectory-derived caller, not a fixture guess.
    event =
      Map.merge(extra, %{
        operation: operation,
        agent_id: scope.agent_id,
        agent_id_source: "provider_group_scope",
        provider_context_agent_id: context_agent,
        tool_call_id: Map.get(scope, :tool_call_id),
        messages: messages,
        search_semantics: @semantics
      })

    result =
      Agent.get_and_update(Application.fetch_env!(:salix_im, @state_key), fn state ->
        previous = Map.get(state, :context_reads, [])

        if length(previous) >= @max_read_events,
          do: {:budget_exhausted, state},
          else: {:ok, Map.put(state, :context_reads, previous ++ [event])}
      end)

    if result == :budget_exhausted,
      do: raise(ArgumentError, "local context read receipt budget exceeded")

    :ok
  end

  defp required_string!(map, key) do
    case map[key] do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _ -> raise ArgumentError, "local search fixture requires #{key}"
    end
  end
end
