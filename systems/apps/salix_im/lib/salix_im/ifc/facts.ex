defmodule SalixIM.IFC.Facts do
  @moduledoc """
  The facts resolver behind `SalixAgent.IFC`
  (`docs/verification.md` §5.5).

  `salix_agent` owns the decision and deliberately does not depend on the IM
  domain, so it reaches provider facts through one runtime seam:

      config :salix_agent, ifc_facts_mod: SalixIM.IFC.Facts

  This module answers two questions and decides nothing:

    * `mode/2` — is this Group off, in audit, or enforced? Read from the
      Group control record, once per activation.
    * `resolve/1` — for one effect, what is its destination's audience, who
      may write there, and what is known about every atom the decision can
      touch?

  Everything it returns is the wire shape `SalixIFC.Codec` decodes: encoded
  atoms, encoded principals, membership entries with revisions, placements,
  receipts, the policy, and display names for the one sentence a person
  eventually reads. Content never appears in any of it.

  Bounded by construction: one projection read per atom the effect involves,
  at most one `conversations.info` and one `conversations.members` per
  channel per quarter hour, and no fan-out over workspace users.
  """

  require Logger

  alias SalixIM.GroupDirectory
  alias SalixIM.IFC.{AudiencePlacement, Ingress, Projection}
  alias SalixIM.{Conversations, ProviderConnects}
  alias SalixStore.IFC, as: Store

  @mode_cache :salix_ifc_group_mode
  @mode_cache_ttl_ms 30_000
  @mode_cache_max_entries 5_000

  @doc """
  This Group's information-flow mode.

  Asked once per activation, and cached for half a minute: the mode is a
  control setting that changes by hand, and a control-record read on every
  round would be a cost every workspace pays — including the ones that never
  turn this on.
  """
  @spec mode(String.t(), String.t()) :: String.t()
  def mode(tenant_id, group_id) do
    key = {text(tenant_id), text(group_id)}
    now = System.monotonic_time(:millisecond)

    case cached_mode(key, now) do
      {:ok, mode} -> mode
      :miss -> cache_mode(key, now, read_mode(tenant_id, group_id))
    end
  end

  defp read_mode(tenant_id, group_id) do
    case group(text(group_id), text(tenant_id)) do
      {:ok, group} -> policy_setting(group, "mode", "off")
      _other -> "off"
    end
  end

  defp cached_mode(key, now) do
    case :ets.lookup(mode_cache(), key) do
      [{^key, expires_at, mode}] when expires_at > now -> {:ok, mode}
      _miss -> :miss
    end
  rescue
    _ -> :miss
  end

  defp cache_mode(key, now, mode) do
    table = mode_cache()

    if :ets.member(table, key) or :ets.info(table, :size) < @mode_cache_max_entries do
      :ets.insert(table, {key, now + @mode_cache_ttl_ms, mode})
    end

    mode
  rescue
    _ -> mode
  end

  defp mode_cache do
    case :ets.whereis(@mode_cache) do
      :undefined ->
        try do
          :ets.new(@mode_cache, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> @mode_cache
        end

      table ->
        table
    end
  end

  @doc """
  Facts for one decision. The request names the destination and every atom
  the effect can touch, so the answer is one bounded projection read rather
  than a workspace scan.
  """
  @spec resolve(map()) :: {:ok, map()} | {:error, term()}
  def resolve(%{} = request) do
    tenant_id = text(request["tenant_id"])
    group_id = text(request["group_id"])

    with {:ok, group} <- group(group_id, tenant_id),
         mode when mode != "off" <- policy_setting(group, "mode", "off") do
      {:ok, build(mode, group, tenant_id, group_id, request)}
    else
      "off" ->
        {:ok, %{"mode" => "off"}}

      # A Group that does not exist has nothing to enforce. Any other control
      # fault is an outage, and an outage must not quietly turn an enforced
      # Group into an unenforced one — the dispatcher decides what to do with
      # the error, and for an enforced Group that is a refusal.
      {:error, :not_found} ->
        {:ok, %{"mode" => "off"}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception ->
      Logger.warning("ifc facts resolution failed: #{Exception.message(exception)}")
      {:error, {:ifc_facts_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:ifc_facts_failed, {kind, reason}}}
  end

  def resolve(_request), do: {:error, :invalid_request}

  @doc """
  Spends one declassification receipt.

  The delete is the claim, so two effects racing for the same receipt cannot
  both have it: exactly one gets `{:ok, true}`.
  """
  @spec consume_receipt(map()) :: {:ok, boolean()} | {:error, term()}
  def consume_receipt(%{} = request) do
    tenant_id = text(request["tenant_id"])
    group_id = text(request["group_id"])
    receipt_id = text(request["receipt_id"])

    if group_id == "" or receipt_id == "" do
      {:error, :invalid_request}
    else
      Store.consume_receipt(tenant_id, group_id, receipt_id)
    end
  rescue
    exception ->
      Logger.warning("ifc receipt consume failed: #{Exception.message(exception)}")
      {:error, {:ifc_receipt_consume_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:ifc_receipt_consume_failed, {kind, reason}}}
  end

  def consume_receipt(_request), do: {:error, :invalid_request}

  # ---------------------------------------------------------------------------
  # Assembly
  # ---------------------------------------------------------------------------

  defp build(mode, group, tenant_id, group_id, request) do
    connects = connect_ids(group_id)
    requester = text(request["requester"])
    now = now_ms(request["now"])

    {destination_atoms, writers} = destination(tenant_id, group_id, connects, request)

    atoms =
      (List.wrap(request["atoms"]) ++ destination_atoms)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    resolved = Enum.map(atoms, &resolve_atom(tenant_id, group_id, &1, requester))

    %{
      "mode" => mode,
      # The language the runtime composes its own sentences in — rule A's
      # refusal, rule B's footer, the confirmation card. Chinese unless the
      # Group says otherwise (§6.4).
      "language" => policy_setting(group, "language", "zh"),
      "destination" => %{"label" => destination_atoms, "writers" => writers},
      "scopes" => scopes(resolved, group_id, connects),
      "membership" => membership(resolved, request),
      "placements" =>
        placements(
          tenant_id,
          group_id,
          connects,
          resolved,
          requester,
          request["trusted_origin"]
        ),
      "receipts" => receipts(tenant_id, group_id, requester, now),
      "policy" => policy(group, resolved),
      "display_names" => display_names(resolved),
      "now" => now
    }
  end

  # One atom, resolved to everything the kernel might ask about it.
  defp resolve_atom(tenant_id, group_id, encoded, requester) do
    case SalixIFC.Codec.decode_atom(encoded) do
      {:ok, {:scope, connect_id, scope_id}} ->
        scope = %{tenant_id: tenant_id, group_id: group_id, connect_id: connect_id}
        {_canonical, row} = Projection.facts(scope, scope_id)

        %{
          atom: encoded,
          kind: :scope,
          connect_id: connect_id,
          row: row,
          canonical_members: direct_members(group_id, connect_id, row, requester)
        }

      {:ok, {:tag, name}} ->
        %{atom: encoded, kind: :tag, name: name, row: tag_row(tenant_id, group_id, name)}

      {:ok, {:task, conversation_id}} ->
        %{atom: encoded, kind: :task, row: task_row(group_id, conversation_id)}

      {:ok, {:conversation, conversation_id}} ->
        %{
          atom: encoded,
          kind: :conversation,
          row: conversation_row(group_id, conversation_id, requester)
        }

      {:ok, {:space, connect_id}} ->
        %{atom: encoded, kind: :space, connect_id: connect_id, row: nil}

      {:ok, other} ->
        %{atom: encoded, kind: elem_kind(other), row: nil}

      :error ->
        %{atom: encoded, kind: :unknown, row: nil}
    end
  end

  defp elem_kind(:public), do: :public
  defp elem_kind(:agent_private), do: :agent_private
  defp elem_kind(atom) when is_tuple(atom), do: elem(atom, 0)

  # A scope's structure. `public` is deliberately absent: a public room's
  # audience is its space, so the resolver never emits a scope atom for one
  # and the kernel never sees it.
  defp scopes(resolved, group_id, connects) do
    from_scopes =
      resolved
      |> Enum.filter(&(&1.kind == :scope and is_map(&1.row)))
      |> Enum.flat_map(fn %{atom: atom, row: row} ->
        case row.kind do
          kind when kind in ["room", "direct", "shared"] ->
            [{atom, %{"kind" => kind, "within" => row.within}}]

          _other ->
            []
        end
      end)
      |> Map.new()

    Map.merge(from_scopes, group_scope(group_id, connects))
  end

  # With one connect, the Group's audience and its space are the same people,
  # so Group-wide memory sits inside the space and a public channel's content
  # may be written to it by pure flow. With several connects the Group is
  # strictly wider than any one space, gets no parent, and every write into it
  # from one workspace needs a person to confirm.
  defp group_scope(group_id, [connect_id]) do
    with {:ok, group_atom} <- SalixIFC.Codec.encode_atom({:group, group_id}),
         {:ok, space_atom} <- SalixIFC.Codec.encode_atom({:space, connect_id}) do
      %{group_atom => %{"kind" => "room", "within" => space_atom}}
    else
      _other -> %{}
    end
  end

  defp group_scope(_group_id, _connects), do: %{}

  defp membership(resolved, request) do
    resolved
    |> Enum.flat_map(fn
      %{kind: :scope, atom: atom, canonical_members: members, row: %{revision: revision}}
      when is_list(members) ->
        [{atom, entry(members, revision)}]

      %{kind: :scope, atom: atom, row: %{members: members, revision: revision}, connect_id: c}
      when is_list(members) ->
        [{atom, entry(Enum.map(members, &provider_user(c, &1)), revision)}]

      %{kind: :tag, atom: atom, row: %{members: members, revision: revision}} ->
        [{atom, entry(members, revision)}]

      %{kind: kind, atom: atom, row: %{members: members, revision: revision}}
      when kind in [:task, :conversation] and is_list(members) ->
        [{atom, entry(members, revision)}]

      _unknown ->
        []
    end)
    |> Map.new()
    |> Map.merge(pending_task_membership(request))
  end

  # A Task that does not exist yet is shared with exactly the person asking
  # for it, which is what makes delegating a DM request and reporting back
  # both pure flow (§8).
  defp pending_task_membership(request) do
    with %{"kind" => "pending_task"} = descriptor <- request["destination"],
         requester when is_binary(requester) and requester != "" <- text(request["requester"]),
         {:ok, atom} <- SalixIFC.Codec.encode_atom({:task, pending_id(descriptor)}) do
      # A product-authored Triage Task has no human requester. System command
      # authority must not invent a person in its audience.
      members = if requester == "system", do: [], else: [requester]
      %{atom => entry(members, 0)}
    else
      _other -> %{}
    end
  end

  defp entry(members, revision) do
    %{"members" => Enum.reject(members, &is_nil/1), "revision" => revision || 0}
  end

  # Placement is asked only about principals the decision names: the
  # requester, and the members of the atoms it compares. There is no walk
  # over workspace users.
  defp placements(tenant_id, group_id, connects, resolved, requester, trusted_origin) do
    task_members =
      resolved
      |> Enum.flat_map(fn
        %{kind: :task, row: %{members: members}} when is_list(members) -> members
        _ -> []
      end)

    keys =
      resolved
      |> Enum.flat_map(fn
        %{kind: :scope, row: %{members: members}, connect_id: c} when is_list(members) ->
          Enum.map(members, &provider_user(c, &1))

        _other ->
          []
      end)
      |> Enum.concat(task_members)
      |> Enum.concat([requester])
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    Enum.reduce(connects, sealed_placement(requester, trusted_origin), fn connect_id, acc ->
      users = Enum.flat_map(keys, &user_in_connect(&1, connect_id))
      ids = Enum.map(users, &elem(&1, 1))

      case Store.placement_overrides(tenant_id, group_id, connect_id, ids) do
        {:ok, overrides} ->
          scope = %{tenant_id: tenant_id, group_id: group_id, connect_id: connect_id}

          missing_task_users =
            task_members
            |> Enum.flat_map(&user_in_connect(&1, connect_id))
            |> Enum.reject(fn {key, id} ->
              Map.has_key?(overrides, id) or get_in(acc, [key, connect_id]) != nil
            end)
            |> Enum.map(&elem(&1, 1))

          observed = AudiencePlacement.resolve(scope, missing_task_users)
          placements = Map.merge(observed, overrides)

          Enum.reduce(users, acc, fn {key, user_id}, inner ->
            case placement(placements, user_id) do
              nil -> inner
              value -> put_placement(inner, key, connect_id, value)
            end
          end)

        {:error, _reason} ->
          acc
      end
    end)
  end

  # The requester's own placement was sealed into the message that started
  # this activation, from the profile read ingress already performed. An
  # administrator's override still wins: the store pass above runs after this
  # and replaces it.
  defp sealed_placement(requester, trusted_origin) when is_map(trusted_origin) do
    with %{} = ifc <- Map.get(trusted_origin, "ifc"),
         placement when placement in ["internal", "external"] <- Map.get(ifc, "placement"),
         {:ok, {:provider_user, connect_id, _user}} <-
           SalixIFC.Codec.decode_principal(requester) do
      %{requester => %{connect_id => placement}}
    else
      _other -> %{}
    end
  end

  defp sealed_placement(_requester, _trusted_origin), do: %{}

  defp put_placement(placements, key, connect_id, value),
    do: Map.update(placements, key, %{connect_id => value}, &Map.put(&1, connect_id, value))

  # Only a positive observation places a user. Someone nobody has placed is
  # unknown, which the kernel never reads as an internal member — the
  # difference between "we know they belong here" and "we have not looked" is
  # exactly what keeps a guest from inheriting the workspace's audience.
  defp placement(overrides, user_id) do
    case Map.get(overrides, user_id) do
      "internal" -> "internal"
      "external" -> "external"
      _unknown -> nil
    end
  end

  defp user_in_connect(key, connect_id) do
    case SalixIFC.Codec.decode_principal(key) do
      {:ok, {:provider_user, ^connect_id, user_id}} -> [{key, user_id}]
      _other -> []
    end
  end

  defp receipts(tenant_id, group_id, requester, now) do
    case Store.receipts(tenant_id, group_id, [requester], now) do
      {:ok, receipts} -> receipts
      {:error, _reason} -> []
    end
  end

  # Sealed atoms are the union of the Group's own list and every room or tag
  # an administrator marked sealed: content there never leaves its audience,
  # not in place and not with a receipt.
  defp policy(group, resolved) do
    settings = policy_map(group)

    sealed =
      resolved
      |> Enum.flat_map(fn
        %{atom: atom, row: %{sealed: true}} -> [atom]
        _other -> []
      end)
      |> Enum.concat(List.wrap(settings["sealed_atoms"]))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    %{
      "declassification" => setting(settings, "declassification", "in_place_and_receipt"),
      "sealed_atoms" => sealed,
      "external_principals" => setting(settings, "external_principals", "own_thread_only"),
      "public_egress" => setting(settings, "public_egress", "receipt")
    }
  end

  defp display_names(resolved) do
    resolved
    |> Enum.flat_map(fn
      %{kind: :scope, atom: atom, row: %{display_name: name}} when is_binary(name) ->
        [{atom, name}]

      %{kind: :tag, atom: atom, name: name} ->
        [{atom, name}]

      %{kind: :space, atom: atom} ->
        [{atom, "本工作区"}]

      _other ->
        []
    end)
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # Destinations
  # ---------------------------------------------------------------------------

  defp destination(tenant_id, group_id, connects, request) do
    case request["destination"] do
      %{"kind" => "triage_result"} ->
        case SalixIM.Triage.InvestigationAuthority.destination(request) do
          {:ok, descriptor, principal} ->
            {atoms, _writers} = provider_scope(tenant_id, group_id, connects, descriptor)
            {atoms, [principal]}

          _ ->
            {encode([:public]), "unknown"}
        end

      %{"kind" => "provider_scope"} = descriptor ->
        provider_scope(tenant_id, group_id, connects, descriptor)

      %{"kind" => "provider_direct"} = descriptor ->
        provider_direct(tenant_id, group_id, connects, descriptor)

      # A reply or an edit names a message, not a place. Its audience is the
      # conversation the message is in, so the message is resolved to that
      # conversation and then decided like any other scope.
      %{"kind" => "provider_message"} = descriptor ->
        provider_scope(
          tenant_id,
          group_id,
          connects,
          message_scope(tenant_id, group_id, connects, descriptor)
        )

      %{"kind" => "conversation"} = descriptor ->
        conversation(group_id, descriptor)

      %{"kind" => "pending_task"} = descriptor ->
        pending_task(descriptor)

      # Worker configuration is shared with the caller's Group, just like
      # Group memory. Never take the Group identity from tool arguments.
      %{"kind" => "agent_configuration"} ->
        {encode([{:group, group_id}]), "any"}

      %{"kind" => "memory"} ->
        {encode([{:group, group_id}]), "any"}

      # The user's Drive (`/drive/...`): the Workspace's shared folder, synced
      # to every member's devices. Its audience is the Group's humans, as
      # Group memory's is, so a write there from a narrower source is a
      # cross-scope relay that needs a receipt. Writers are any member, as
      # any device of theirs already publishes into the same folder.
      %{"kind" => "drive"} ->
        {encode([{:group, group_id}]), "any"}

      # The per-audience memory home (§8). Its audience is the effect's own
      # sources, which only the dispatcher can see, so `SalixAgent.IFC.Check`
      # replaces this before the kernel is called. Answering `agent_private`
      # rather than `public` means that if it ever did not, the write is
      # refused rather than allowed.
      %{"kind" => "memory_scoped"} ->
        {encode([:agent_private]), "any"}

      %{"kind" => "schedule"} = descriptor ->
        schedule(group_id, descriptor)

      %{"kind" => "agent_private"} ->
        {encode([:agent_private]), "any"}

      %{"kind" => "public"} ->
        {encode([:public]), "any"}

      _unknown ->
        # An unresolvable destination is a public one with no known writers:
        # it can still carry an effect that declares no sources, and nothing
        # else.
        {encode([:public]), "unknown"}
    end
  end

  # The caller's own hint first — `feishu.reply_text` carries the source
  # `chat_id` for its own reasons — and one bounded provider lookup only when
  # there is none. A message nobody can place leaves the scope empty, which
  # resolves as public with unknown writers and is therefore refused.
  defp message_scope(tenant_id, group_id, connects, descriptor) do
    case text(descriptor["scope_id"]) do
      "" ->
        connect_id = connect_or_default(descriptor["connect_id"], connects)
        scope = %{tenant_id: tenant_id, group_id: group_id, connect_id: connect_id}

        Map.put(
          descriptor,
          "scope_id",
          Projection.message_scope_id(scope, text(descriptor["message_id"]))
        )

      _hinted ->
        descriptor
    end
  end

  defp provider_scope(tenant_id, group_id, connects, descriptor) do
    connect_id = connect_or_default(descriptor["connect_id"], connects)
    scope_id = text(descriptor["scope_id"])

    if connect_id == "" or scope_id == "" do
      {encode([:public]), "unknown"}
    else
      scope = %{tenant_id: tenant_id, group_id: group_id, connect_id: connect_id}
      {canonical, row} = Projection.facts(scope, scope_id)

      atoms =
        if Projection.space_audience?(row),
          do: [{:space, connect_id}],
          else: [{:scope, connect_id, canonical}]

      {encode(atoms ++ Enum.map(row.tags, &{:tag, &1})), scope_writers(connect_id, row)}
    end
  end

  # Anyone in the space may write to a public room, so writer authority adds
  # nothing there; the guest rule is the kernel's, not this table's. A room
  # with a known member set restricts writers to it, and a room whose members
  # are unknown has no writers this resolver can vouch for.
  defp scope_writers(connect_id, row) do
    cond do
      row.kind == "public" and row.audience_mode != "members" -> "any"
      row.kind == "direct" -> "any"
      is_list(row.members) -> Enum.map(row.members, &provider_user(connect_id, &1))
      true -> "unknown"
    end
  end

  defp provider_direct(tenant_id, group_id, connects, descriptor) do
    connect_id = connect_or_default(descriptor["connect_id"], connects)
    user_id = text(descriptor["user_id"])

    if connect_id == "" or user_id == "" do
      {encode([:public]), "unknown"}
    else
      scope = %{tenant_id: tenant_id, group_id: group_id, connect_id: connect_id}
      scope_id = Projection.direct_scope_id(user_id)
      {_canonical, row} = Projection.facts(scope, scope_id)

      {encode([{:scope, connect_id, scope_id} | Enum.map(row.tags, &{:tag, &1})]), "any"}
    end
  end

  defp conversation(group_id, descriptor) do
    conversation_id = text(descriptor["conversation_id"])

    if conversation_id == "" do
      {encode([:public]), "unknown"}
    else
      kind = conversation_kind(group_id, conversation_id)
      {List.wrap(Ingress.conversation_atom(kind, conversation_id)), "any"}
    end
  end

  defp pending_task(descriptor),
    do: {encode([{:task, pending_id(descriptor)}]), "any"}

  defp pending_id(descriptor), do: "pending:" <> text(descriptor["tool_call_id"])

  defp schedule(group_id, descriptor) do
    case text(descriptor["conversation_id"]) do
      "" -> {encode([{:group, group_id}]), "any"}
      conversation_id -> conversation(group_id, %{"conversation_id" => conversation_id})
    end
  end

  # ---------------------------------------------------------------------------
  # Lookups
  # ---------------------------------------------------------------------------

  defp tag_row(tenant_id, group_id, name) do
    connects = connect_ids(group_id)

    {members, revision} =
      Enum.reduce(connects, {[], 0}, fn connect_id, {members, revision} ->
        case Store.tag_clearances(tenant_id, group_id, connect_id, [name]) do
          {:ok, %{^name => %{members: cleared, revision: rev}}} ->
            {members ++ cleared, max(revision, rev)}

          _other ->
            {members, revision}
        end
      end)

    %{members: Enum.uniq(members), revision: revision, sealed: false, display_name: nil, tags: []}
  end

  # A Task's audience is the people it was shared with: its origin principal,
  # recorded on the conversation when the Router created it, plus anyone the
  # Router explicitly added.
  defp task_row(group_id, conversation_id) do
    case Conversations.get_group_conversation_record(group_id, conversation_id) do
      {:ok, record} ->
        members =
          record
          |> Map.get("source_refs", %{})
          |> case do
            %{"ifc_members" => members} when is_list(members) -> members
            _other -> nil
          end

        %{members: members, revision: 0, sealed: false, display_name: nil, tags: []}

      _other ->
        %{members: nil, revision: 0, sealed: false, display_name: nil, tags: []}
    end
  rescue
    _ -> %{members: nil, revision: 0, sealed: false, display_name: nil, tags: []}
  end

  defp conversation_row(group_id, conversation_id, requester) do
    mod = Application.get_env(:salix_im, :task_execution_owner_mod)

    members =
      if mod && Code.ensure_loaded?(mod) && function_exported?(mod, :conversation_members, 3),
        do: mod.conversation_members(group_id, conversation_id, requester)

    %{members: members, revision: 0, sealed: false, display_name: nil, tags: []}
  end

  defp direct_members(group_id, connect_id, %{kind: "direct", members: members}, requester) do
    mod = Application.get_env(:salix_im, :task_execution_owner_mod)

    if mod && Code.ensure_loaded?(mod) && function_exported?(mod, :direct_members, 4),
      do: mod.direct_members(group_id, connect_id, members, requester)
  end

  defp direct_members(_group_id, _connect_id, _row, _requester), do: nil

  defp conversation_kind(group_id, conversation_id) do
    case Conversations.get_group_conversation(group_id, conversation_id) do
      {:ok, %{"kind" => kind}} -> kind
      _other -> nil
    end
  rescue
    _ -> nil
  end

  defp connect_ids(group_id) do
    case ProviderConnects.list_group_im_connects(group_id) do
      {:ok, connects} ->
        connects
        |> Enum.map(&text(&1["connect_id"]))
        |> Enum.reject(&(&1 == ""))
        |> Enum.sort()

      _other ->
        []
    end
  rescue
    _ -> []
  end

  defp connect_or_default(connect_id, connects) do
    case text(connect_id) do
      "" -> if match?([_only], connects), do: hd(connects), else: ""
      value -> value
    end
  end

  defp group(group_id, tenant_id) do
    if group_id == "",
      do: {:error, :not_found},
      else: GroupDirectory.get_group(group_id, tenant_id)
  end

  defp policy_map(group) do
    case Map.get(group, "ifc") do
      %{} = settings -> settings
      _other -> %{}
    end
  end

  defp policy_setting(group, key, default), do: setting(policy_map(group), key, default)

  defp setting(settings, key, default) do
    case Map.get(settings, key) do
      value when is_binary(value) and value != "" -> value
      _other -> default
    end
  end

  defp provider_user(connect_id, user_id) do
    case SalixIFC.Codec.encode_principal({:provider_user, connect_id, to_string(user_id)}) do
      {:ok, encoded} -> encoded
      :error -> nil
    end
  end

  defp encode(atoms) do
    Enum.flat_map(atoms, fn atom ->
      case SalixIFC.Codec.encode_atom(atom) do
        {:ok, encoded} -> [encoded]
        :error -> []
      end
    end)
  end

  defp now_ms(value) when is_integer(value) and value > 0, do: value
  defp now_ms(_value), do: System.system_time(:millisecond)

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value), do: value |> to_string() |> String.trim()
end
