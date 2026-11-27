defmodule SalixAgent.Tools.GroupSearch do
  @moduledoc """
  Cross-Group conversation search and read tools: `group.search_conversations`
  and `group.read_conversation`.

  Visibility is gated on the caller Group's control record (`search_group_ids`,
  configured via `Salix.Control.Groups` and checked in
  `SalixAgent.ToolDisclosure`). A Group with no authorized target Groups never
  carries these tools in its session disclosure.

  Only a supervisor of the caller Group (`ifc.supervisors`, set on the Data
  policy page) may have the agent search or read, directly or through a
  schedule or Loop they created. Every call checks that each input of the turn
  (`source_message_ids`) has a sealed origin naming it, and that every origin's
  person (`SalixAgent.IFC.principal/1`; a schedule's or Loop's sealed creator,
  recorded by `SalixAgent.IFC.unchecked_creator/1` when IFC is `off` or `easy`)
  is a current supervisor. A turn with an input that has no sealed origin, with
  anyone else's message, an automation whose creator is not a supervisor, or a
  Group record that cannot be read is refused.

  Execution dispatches through `SalixAgent.GroupRuntime` to
  `SalixIM.GroupConversationSearch`. Results are stamped with the caller Group's
  own audience (`{:group, caller_group_id}`) via
  `SalixAgent.IFC.ConnectorLabels.group_audience/2`, so content read from an
  authorized peer Group may flow within the caller Group while remaining blocked
  from public or external egress under IFC enforcement.
  """

  alias SalixAgent.{GroupContext, GroupRuntime}
  alias SalixAgent.IFC.ConnectorLabels
  alias SalixAgent.Tools.AsyncPolicy

  @auto_wait_seconds AsyncPolicy.normal_tool_auto_wait_seconds()
  @read_opts [safety: "read"]

  @spec defs() :: [{String.t(), String.t(), (map(), map() -> term()), pos_integer(), keyword()}]
  def defs do
    [
      {"group.search_conversations",
       "Search Task conversations and non-private IM group chats across other authorized Groups in this tenant. " <>
         "Omit group_ids to search all authorized Groups in one call, or pass a subset of authorized group_ids. " <>
         "Returns hits with hit_id, group_id, group_name, source, snippet and timestamp; pass hit_id to group.read_conversation for full context. " <>
         "Only this group's supervisors may ask for it; tell anyone else it is for supervisors only.",
       &__MODULE__.search_conversations/2, @auto_wait_seconds, @read_opts},
      {"group.read_conversation",
       "Read a bounded window of visible messages for one hit_id returned by group.search_conversations, re-verifying current Group search authorization.",
       &__MODULE__.read_conversation/2, @auto_wait_seconds, @read_opts}
    ]
  end

  @doc "Normalized `search_group_ids` on a Salix Group control record."
  @spec search_group_ids(map()) :: [String.t()]
  def search_group_ids(group_record) when is_map(group_record) do
    group_record["search_group_ids"]
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def search_group_ids(_group_record), do: []

  @doc """
  The target Groups `group_id` may search, as `[{group_id, name}]` in
  `search_group_ids` order: those that still exist in the Tenant, leaving out a
  Group with information-flow control on when the caller has it off (the same
  rule as `SalixIM.GroupConversationSearch.authorized_groups/1`).

  `:unknown` when no `GroupContext` is wired or the caller's record cannot be
  read for a reason other than its absence; `[]` when it has none.
  """
  @spec authorized_targets(String.t(), String.t()) :: [{String.t(), String.t()}] | :unknown
  def authorized_targets(tenant, group) when is_binary(tenant) and is_binary(group) do
    cond do
      is_nil(SystemsRuntime.get_env(:salix_agent, :group_context_mod)) ->
        :unknown

      tenant == "" or group == "" ->
        :unknown

      true ->
        case GroupContext.get(group, tenant) do
          {:ok, record} ->
            caller_ifc? = ifc_enabled?(record)

            record
            |> search_group_ids()
            |> Enum.reject(&(&1 == group))
            |> Enum.flat_map(&authorized_target(&1, tenant, caller_ifc?))

          {:error, :not_found} ->
            []

          _other ->
            :unknown
        end
    end
  end

  def authorized_targets(_tenant, _group), do: :unknown

  defp authorized_target(target_id, tenant, caller_ifc?) do
    case GroupContext.get(target_id, tenant) do
      {:ok, %{} = target} ->
        if ifc_enabled?(target) and not caller_ifc?,
          do: [],
          else: [{target_id, target_name(target, target_id)}]

      _gone ->
        []
    end
  end

  defp target_name(target, target_id) do
    case target["name"] do
      name when is_binary(name) ->
        if String.trim(name) == "", do: target_id, else: String.trim(name)

      _ ->
        target_id
    end
  end

  # `SalixIM.IFC.Ingress.enabled?/1`, which this app cannot call.
  defp ifc_enabled?(%{"ifc" => %{"mode" => mode}}) when is_binary(mode),
    do: String.trim(mode) in ["audit", "enforce", "hard", "easy"]

  defp ifc_enabled?(_group), do: false

  @doc """
  What the `group.*` disclosure of `group_id` depends on: its authorized
  targets with their names. A round snapshot built for another fingerprint is
  rebuilt (`SalixAgent.RoundConfig`).
  """
  @spec disclosure_fingerprint(term(), term()) :: [{String.t(), String.t()}] | :unknown
  def disclosure_fingerprint(tenant, group), do: authorized_targets(text(tenant), text(group))

  @doc """
  Appends the caller Group's authorized target `group_id` and `name` list to
  `group.search_conversations` when a `GroupContext` is wired.
  """
  @spec describe(map(), map()) :: map()
  def describe(%{"name" => "group.search_conversations"} = candidate, ctx) when is_map(ctx) do
    case authorized_targets(ctx_string(ctx, :tenant_id), ctx_string(ctx, :group_id)) do
      [_ | _] = targets ->
        note =
          "Authorized target groups: " <>
            Enum.map_join(targets, ", ", fn {id, name} -> "#{name} (#{id})" end) <> "."

        candidate
        |> Map.update("summary", note, &(&1 <> " " <> note))
        |> Map.update("manual", note, &(&1 <> " " <> note))

      _none ->
        candidate
    end
  end

  def describe(candidate, _ctx), do: candidate

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value), do: value |> to_string() |> String.trim()

  defp ctx_string(ctx, key) do
    ctx
    |> Map.get(key, Map.get(ctx, Atom.to_string(key), ""))
    |> to_string()
    |> String.trim()
  end

  @doc false
  def search_conversations(args, ctx) when is_map(args) and is_map(ctx) do
    query = arg(args, "query")
    if query == "", do: raise("'query' is required")
    admit!("group.search_conversations", ctx)

    case GroupRuntime.call(
           ctx.agent_id,
           :group_conversation_search_mod,
           :group_search_not_configured,
           :search,
           [args]
         ) do
      {:ok, payload} ->
        payload
        |> Jason.encode!()
        |> ConnectorLabels.group_audience(ctx)

      {:error, reason} ->
        raise format_error("group.search_conversations", reason)
    end
  end

  @doc false
  def read_conversation(args, ctx) when is_map(args) and is_map(ctx) do
    hit_id = arg(args, "hit_id")
    if hit_id == "", do: raise("'hit_id' is required")
    admit!("group.read_conversation", ctx)

    case GroupRuntime.call(
           ctx.agent_id,
           :group_conversation_search_mod,
           :group_search_not_configured,
           :read,
           [args]
         ) do
      {:ok, payload} ->
        payload
        |> Jason.encode!()
        |> ConnectorLabels.group_audience(ctx)

      {:error, reason} ->
        raise format_error("group.read_conversation", reason)
    end
  end

  # Every input of the turn must be attributable to one of the caller Group's
  # supervisors: each of the turn's source ids needs a sealed origin naming
  # that id, and every origin of the turn must name a supervisor, a schedule
  # or Loop acting for its creator. An input
  # with no sealed origin (a system post, a member's message batched with a
  # supervisor's) leaves its id uncovered and refuses the call. Checked on
  # every call, so removing a supervisor takes effect at once.
  defp admit!(tool, ctx) do
    case supervisor_requesters?(ctx) do
      true ->
        :ok

      false ->
        raise "#{tool} is only for this group's supervisors: the person who asked is not one"

      :unavailable ->
        raise "#{tool} is unavailable: this group's supervisors could not be read"
    end
  end

  defp supervisor_requesters?(ctx) do
    origins = origins(ctx)
    principals = Enum.map(origins, &(&1 |> SalixAgent.IFC.principal() |> person()))

    if covered?(ctx, origins) and Enum.all?(principals, &(&1 != nil)) do
      case GroupContext.get(ctx_string(ctx, :group_id), ctx_string(ctx, :tenant_id)) do
        {:ok, %{"ifc" => %{"supervisors" => supervisors}}} when is_list(supervisors) ->
          Enum.all?(principals, &(SalixIFC.Codec.encode_principal!(&1) in supervisors))

        {:ok, _group} ->
          false

        _error ->
          :unavailable
      end
    else
      false
    end
  end

  # A round (`SalixAgent.Round`, `SalixAgent.SessionToolExecution`) names the
  # turn's inputs in `source_message_ids`; each needs an origin sealed for it.
  # A station Task's call (`SalixAgent.StationToolCalls`) has no Session: its
  # one input is the call itself, sealed with the Task requester's origin.
  defp covered?(ctx, origins) do
    case Map.fetch(ctx, :source_message_ids) do
      {:ok, ids} ->
        ids = ids |> List.wrap() |> Enum.map(&text/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
        ids != [] and Enum.all?(ids, fn id -> Enum.any?(origins, &names?(&1, id)) end)

      :error ->
        match?([_], origins) and Map.get(ctx, :trusted_origin) in origins
    end
  end

  # The person a principal speaks for: a provider user, or the provider user
  # who created the schedule or Loop (`{:schedule, id, creator}`), whose
  # authority it carries.
  defp person({:provider_user, _connect_id, _user} = principal), do: principal
  defp person({:schedule, _id, {:provider_user, _, _} = creator}), do: creator
  defp person(_principal), do: nil

  # An origin names its input by `source_message_id`. A schedule fire
  # (`SalixCluster.Schedules`, `schedule:<id>:<at>`) and a Loop notification
  # (`SalixAgent.Loops.Capabilities`, `loop:<id>:<dedup>`) are delivered under
  # an id their sealed origin's `schedule_id` or `loop_id` names.
  defp names?(origin, id) do
    cond do
      text(origin["source_message_id"]) == id -> true
      origin["provider"] == "schedule" -> prefixed?(id, "schedule:", origin["schedule_id"])
      origin["provider"] == "loop" -> prefixed?(id, "loop:", origin["loop_id"])
      true -> false
    end
  end

  defp prefixed?(id, kind, owner) do
    owner = text(owner)
    owner != "" and String.starts_with?(id, kind <> owner <> ":")
  end

  defp origins(ctx) do
    rest = Map.get(ctx, :trusted_origins) || []
    rest = if is_map(rest), do: Map.values(rest), else: List.wrap(rest)

    [Map.get(ctx, :trusted_origin) | rest]
    |> Enum.filter(&is_map/1)
    |> Enum.uniq()
  end

  defp format_error(tool, :no_authorized_groups),
    do: "#{tool} is not available: no target groups are authorized for this group"

  defp format_error(tool, :unauthorized_group),
    do: "#{tool}: one or more requested group_ids are not authorized for this group"

  defp format_error(tool, :invalid_hit_id),
    do: "#{tool}: invalid hit_id"

  defp format_error(tool, :conversation_not_accessible),
    do: "#{tool}: target conversation is not accessible"

  defp format_error(_tool, :query_required),
    do: "'query' is required"

  defp format_error(tool, :search_timeout),
    do: "#{tool} timed out; narrow the query or specify group_ids"

  defp format_error(tool, reason),
    do: "#{tool} failed: #{inspect(reason)}"

  defp arg(args, key) do
    args
    |> Map.get(key, Map.get(args, String.to_atom(key), ""))
    |> to_string()
    |> String.trim()
  end
end
