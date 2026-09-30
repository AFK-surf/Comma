defmodule SalixAgent.ToolCallProvenance do
  @moduledoc false

  require SalixAgent.InternalSession

  alias SalixAgent.InternalSession

  # Modeled in tla/salix/TriageRouterHandoff.tla. A model-authored locator
  # selects one already admitted source; it never creates source authority.
  @task_create "im_api.internal.task.create"
  @triage_schema "comma.triage-delegation-origin.v1"

  def select(call, context) do
    args = value(call, :args) || %{}
    ref = value(args, :triage_delegation_ref)
    source = value(args, :source_message_id)
    origins = origins(context)

    if value(call, :name) == @task_create and is_nil(value(call, :guidance_error)) do
      cond do
        not is_nil(source) and not is_nil(ref) ->
          {:error, "task_source_conflict"}

        not is_nil(source) ->
          select_human(context, origins, source)

        Enum.any?(origins, &triage_origin?/1) or not is_nil(ref) ->
          select_triage(context, origins, ref)

        true ->
          {:ok, context}
      end
    else
      {:ok, context}
    end
  end

  # The argument is only a locator. Role and scope come from the admitted
  # origin, never from model-authored content or the absence of a Triage ref.
  defp select_human(context, origins, source) do
    matches = Enum.filter(origins, &(&1["source_message_id"] == source))

    case {present?(source), matches} do
      {true, [origin]} ->
        if not triage_origin?(origin) and
             origin["source_actor_type"] in ["user", "provider_user"] and
             not String.starts_with?(source, "triage-delegation:") and
             present?(value(context, :group_id)) and
             origin["agent_group_id"] == value(context, :group_id) and
             source in source_ids(context) do
          {:ok, select_origin(context, origin, source)}
        else
          {:error, "task_source_invalid"}
        end

      {false, _} ->
        {:error, "task_source_invalid"}

      {true, []} ->
        {:error, "task_source_unknown"}

      {true, _} ->
        {:error, "task_source_ambiguous"}
    end
  end

  defp select_origin(context, origin, source) do
    context
    |> Map.put(:trusted_origin, origin)
    |> Map.put(:trusted_origins, [origin])
    |> Map.put(:source_message_id, source)
    |> Map.put(:source_message_ids, [source])
  end

  defp select_triage(context, origins, ref) do
    matches =
      Enum.filter(origins, fn origin ->
        case origin["triage_delegation"] do
          %{"request_id" => ^ref} -> true
          _ -> false
        end
      end)

    case {present?(ref), matches} do
      {true, [origin]} ->
        if valid_triage_origin?(origin, context, ref) do
          {:ok, select_origin(context, origin, ref)}
        else
          {:error, "triage_delegation_origin_invalid"}
        end

      {false, _} ->
        {:error, "triage_delegation_ref_required"}

      {true, []} ->
        {:error, "triage_delegation_ref_unknown"}

      {true, _} ->
        {:error, "triage_delegation_ref_ambiguous"}
    end
  end

  defp valid_triage_origin?(origin, context, ref) do
    handoff = origin["triage_delegation"]
    obligation_id = handoff["obligation_id"]
    index = handoff["index"]
    group_id = value(context, :group_id)
    router_agent_id = value(context, :agent_id)

    handoff["schema"] == @triage_schema and present?(handoff["namespace_key"]) and
      present?(obligation_id) and index in [0, 1] and
      ref == "triage-delegation:#{obligation_id}:#{index}" and
      origin["source_actor_type"] == "provider_system" and
      origin["source_message_id"] == ref and ref in source_ids(context) and
      present?(group_id) and origin["agent_group_id"] == group_id and
      handoff["group_id"] == group_id and present?(router_agent_id) and
      handoff["router_agent_id"] == router_agent_id
  end

  defp triage_origin?(origin), do: Map.has_key?(origin, "triage_delegation")

  def origins(context) do
    case value(context, :trusted_origins) do
      origins when is_list(origins) and origins != [] -> Enum.filter(origins, &is_map/1)
      _ -> List.wrap(value(context, :trusted_origin)) |> Enum.filter(&is_map/1)
    end
  end

  def source_ids(context) do
    context
    |> value(:source_message_ids)
    |> normalize_ids()
  end

  @doc """
  The activation's declared source ids plus the ones its unacknowledged runtime
  continuations inherited. The kernel owns the transcript, so this is the
  `current_source_ids` query; callers that still hold a plain state map (the
  external runtime, tools, tests) have it admitted for the one read.
  """
  def current_source_ids(session),
    do: InternalSession.query(handle(session), :current_source_ids)

  defp handle(session) when InternalSession.is_session(session), do: session
  defp handle(session) when is_map(session), do: InternalSession.open_envelope(session)
  defp handle(_session), do: InternalSession.open(%{})

  # Only owner-authored message envelope fields carry provenance. A user's
  # content/JSON and a runtime notification's rendered result are never read.
  def message_origins(message, current_source_ids) do
    current_ids = MapSet.new(current_source_ids)

    case value(message, :role) do
      "user" ->
        if MapSet.member?(current_ids, value(message, :source_message_id)),
          do: List.wrap(value(message, :trusted_origin)) |> Enum.filter(&is_map/1),
          else: []

      "runtime" ->
        inherited_ids = normalize_ids(value(message, :trusted_origin_source_message_ids))

        if Enum.any?(inherited_ids, &MapSet.member?(current_ids, &1)) do
          Enum.filter(origins(message), fn origin ->
            source_id = origin["source_message_id"]

            if present?(source_id),
              do: source_id in inherited_ids and MapSet.member?(current_ids, source_id),
              else: not triage_origin?(origin)
          end)
        else
          []
        end

      _ ->
        []
    end
  end

  def stamp(record, context) do
    ids = source_ids(context)
    origins = origins(context)
    origin = value(context, :trusted_origin)

    if ids != [] and origins != [] do
      record
      |> Map.put("trusted_origins", origins)
      |> Map.put("trusted_origin_source_message_ids", ids)
      |> put_origin(origin)
    else
      record
    end
  end

  def inherit(record, source) do
    stamp(record, %{
      source_message_ids: value(source, :trusted_origin_source_message_ids),
      trusted_origin: value(source, :trusted_origin),
      trusted_origins: origins(source)
    })
  end

  def inherit_many(record, sources) do
    stamp(record, %{
      source_message_ids:
        Enum.flat_map(sources, &List.wrap(value(&1, :trusted_origin_source_message_ids))),
      trusted_origin: sources |> Enum.reverse() |> Enum.find_value(&value(&1, :trusted_origin)),
      trusted_origins: sources |> Enum.flat_map(&origins/1) |> Enum.uniq()
    })
  end

  def stamp_result(result, context) do
    key = if is_list(result[:events]), do: :events, else: "events"

    if is_list(result[key]) do
      Map.update!(result, key, fn events ->
        Enum.map(events, fn
          %{"type" => "async_tool_call_started"} = event ->
            stamp(event, context)

          %{"type" => "wait_set", "wait" => wait} = event when is_map(wait) ->
            Map.put(event, "wait", stamp(wait, context))

          event ->
            event
        end)
      end)
    else
      result
    end
  end

  defp put_origin(record, origin) when is_map(origin),
    do: Map.put(record, "trusted_origin", origin)

  defp put_origin(record, _origin), do: record
  defp normalize_ids(ids), do: ids |> List.wrap() |> Enum.filter(&present?/1) |> Enum.uniq()
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil
end
