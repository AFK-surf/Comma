defmodule SalixIM.ProviderConnects do
  @moduledoc """
  Owns IM provider-connect lifecycle and runtime state.

  Group and agent records are read through `SalixIM.GroupDirectory`; provider
  identity, receipt, and observation records have separate domain owners.
  """

  alias SalixIM.Ports.ProviderAppStore
  alias SalixIM.Provider.Slack
  alias SalixIM.Provider.Slack.API, as: SlackAPI
  alias SalixIM.Provider.Slack.ConversationIngress, as: SlackConversationIngress
  alias SalixIM.Triage.ExpressionContext

  alias SalixIM.{
    GroupDirectory,
    ProviderAttachments,
    ProviderConversationInput,
    ProviderIdentity,
    ProviderIdentityBarrier,
    SlackScopes
  }

  alias SalixStore.{
    CasRecord,
    Ids,
    Keys,
    ReadScope,
    S3,
    SlackTriageChannelCutover,
    SlackTriageChannels,
    ULID
  }

  @connect_scan_max_records 1_000
  @active_connect_lookup_max_keys 1_000
  @slack_triage_recovery_batch_max 25
  @slack_triage_channel_page_max 200
  @slack_triage_recovery_cursor_prefix "v1."
  @slack_bot_identity_backfill_cursor_prefix "v1."
  @slack_generation_backfill_page_max 1_000
  @slack_triage_expression_modes ~w(project social)
  # `approved_channel_name` is deliberately absent: it is a presentation field
  # like `bot_username`/`workspace_name`, never part of the authority pin, and a
  # change to it must never rotate the connect generation. The pin is written
  # against the channel *id*, which is what Slack routes on.
  @slack_triage_authority_keys ~w(
    provider tenant_id group_id connect_id connect_generation workspace_id
    approved_channel_id inbound_agent_id app_id bot_user_id bot_id oauth_completed_at
    triage_enabled
  )
  @slack_connect_snapshot_non_authority_keys ~w(
    approved_channel_name bot_username workspace_name slack_commands
  )
  @slack_projected_connect_snapshot_compatibility_keys ~w(approved_channel_id)

  # ---- connect lifecycle ----

  def list_group_im_connects(group_id, provider \\ nil) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id),
         {:ok, records} <- scan_connect_records(Keys.ctl_im_connects_prefix(group_id)) do
      {:ok,
       records
       |> Enum.reject(& &1["deleted_at"])
       |> Enum.filter(&(blank?(provider) or &1["provider"] == provider))
       |> Enum.sort_by(&(&1["created_at"] || 0), :desc)
       |> Enum.map(&im_connect_public/1)}
    end
  end

  def list_tool_connects(group_id, supported_providers \\ nil, agent_id \\ nil, agent_role \\ nil) do
    with {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, records} <- scan_connect_records(Keys.ctl_im_connects_prefix(group_id)) do
      supported_providers =
        case supported_providers do
          nil -> nil
          providers -> List.wrap(providers)
        end

      agent_id = trim(agent_id)
      agent_role = trim(agent_role)
      router_agent_id = trim(group["router_agent_id"])

      connects =
        records
        |> Enum.reject(& &1["deleted_at"])
        |> Enum.reject(& &1["disabled_at"])
        |> Enum.filter(&(is_nil(supported_providers) or &1["provider"] in supported_providers))
        |> Enum.filter(&tool_connect_visible_to_agent?(&1, agent_id, router_agent_id, agent_role))
        |> Enum.filter(&tool_visible_connect?/1)
        |> Enum.sort_by(&{&1["provider"] || "", &1["created_at"] || 0, &1["connect_id"] || ""})
        |> Enum.map(&tool_connect_summary/1)

      {:ok, connects}
    end
  end

  def get_active_connect_by_id(group_id, connect_id, provider \\ nil) do
    with {:ok, rec} <- CasRecord.get(Keys.ctl_im_connect(group_id, trim(connect_id))),
         true <- is_nil(rec["deleted_at"]) and is_nil(rec["disabled_at"]),
         true <- blank?(provider) or rec["provider"] == provider do
      {:ok, rec}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Resolve one current Router-owned connection for a validated Task grant."
  def get_delegatable_connect_by_id(group_id, connect_id, provider) do
    with {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, router_scope} <- GroupDirectory.scope_for_agent(group["router_agent_id"]),
         {:ok, connect} <- get_agent_visible_connect_by_id(router_scope, connect_id, provider),
         true <- tool_visible_connect?(connect) do
      {:ok, connect}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def delegated_tool_summary(connect), do: tool_connect_summary(connect)

  @doc "Reads the current stored IM connect record for one exact {group, connect} key."
  def fetch_im_connect(group_id, connect_id),
    do: read_im_connect(Keys.ctl_im_connect(trim(group_id), trim(connect_id)))

  # The inbound resolver and the ingress re-read address the same physical
  # record inside one callback; the read scope serves the second from the
  # first. Outside a scope this is a plain store read.
  defp read_im_connect(key),
    do: ReadScope.fetch({:record, key}, fn -> CasRecord.get(key) end)

  @doc """
  Current group-connect authorization for a finite message-search candidate set.

  This does not reuse provider-operation role policy or personal Slack identity.
  At most 64 distinct candidate connects, four local reads in flight, and a
  three-second batch deadline. There is no per-channel/file provider request.
  Modeled in tla/salix/MessageSearchGroupScope.tla.
  """
  def authorize_message_search(scope, candidates) when length(candidates) <= 200 do
    connects = Enum.map(candidates, & &1["connect_id"]) |> Enum.uniq()

    with true <- length(connects) <= 64,
         {:ok, _} <- GroupDirectory.get_group(scope.group_id, scope.tenant_id) do
      task = Task.async(fn -> read_search_connects(scope, connects) end)

      case Task.yield(task, 3000) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, :search_scope_unavailable}
      end
    else
      false -> {:error, :search_scope_over_budget}
      _ -> {:error, :search_scope_unavailable}
    end
  end

  defp read_search_connects(scope, connects) do
    connects
    |> Task.async_stream(
      fn id ->
        case get_active_connect_by_id(scope.group_id, id, "slack") do
          {:ok, current} ->
            if current["tenant_id"] == scope.tenant_id and current["group_id"] == scope.group_id and
                 message_search_connect_active?(current),
               do: {:ok, {id, current["workspace_id"]}},
               else: {:ok, nil}

          {:error, :not_found} ->
            {:ok, nil}

          _ ->
            {:error, :search_scope_unavailable}
        end
      end,
      max_concurrency: 4,
      timeout: 3000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce_while({:ok, MapSet.new()}, fn
      {:ok, {:ok, nil}}, acc -> {:cont, acc}
      {:ok, {:ok, identity}}, {:ok, allowed} -> {:cont, {:ok, MapSet.put(allowed, identity)}}
      _, _ -> {:halt, {:error, :search_scope_unavailable}}
    end)
  rescue
    _ -> {:error, :search_scope_unavailable}
  catch
    :exit, _ -> {:error, :search_scope_unavailable}
  end

  @doc """
  Reads the current stored IM connect record addressed by an opaque physical
  locator (as handed out by `SalixIM.ProviderIdentity`).

  The locator is only ever produced by this domain, but it travels through
  caller-held snapshots, so it is confined to the IM connect prefix here:
  anything else is `{:error, :invalid_key}` and the caller falls back to the
  record's body coordinates.

  The locator is a raw S3 key and is never normalized: a trailing space is a
  legal, distinct key, so trimming here would GET a nonexistent sibling of the
  exact record the resolver listed.
  """
  def fetch_im_connect_by_key(key) when is_binary(key) do
    if String.starts_with?(key, Keys.ctl_im_connects_all_prefix()),
      do: read_im_connect(key),
      else: {:error, :invalid_key}
  end

  def fetch_im_connect_by_key(_key), do: {:error, :invalid_key}

  def get_im_connect_public(tenant_id, group_id, connect_id) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, rec} <- CasRecord.get(Keys.ctl_im_connect(group_id, trim(connect_id))),
         true <- is_nil(rec["deleted_at"]) and rec["tenant_id"] == tenant_id do
      {:ok, im_connect_public(rec)}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def get_slack_triage_authority(tenant_id, group_id, connect_id) do
    with {:ok, group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, rec} <- CasRecord.get(Keys.ctl_im_connect(group_id, trim(connect_id))),
         true <- slack_triage_authority_eligible?(rec, group, tenant_id) do
      get_slack_triage_authority(tenant_id, group_id, connect_id, rec["approved_channel_id"])
    else
      false -> {:error, :slack_triage_authority_ineligible}
      {:error, :not_found} -> {:error, :slack_triage_authority_ineligible}
      {:error, _reason} -> {:error, :slack_triage_authority_unavailable}
    end
  end

  @doc "Reads the current authority for one exact configured Slack channel."
  def get_slack_triage_authority(tenant_id, group_id, connect_id, channel_id) do
    channel_id = trim(channel_id)

    with {:ok, group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, rec} <- CasRecord.get(Keys.ctl_im_connect(group_id, trim(connect_id))),
         true <- slack_triage_connect_ready?(rec, group, tenant_id),
         true <- rec["triage_enabled"] == true do
      case SlackTriageChannelCutover.mode() do
        :legacy ->
          legacy_slack_triage_authority(rec, group, tenant_id, channel_id)

        :projected ->
          projected_slack_triage_authority(rec, tenant_id, group_id, channel_id)

        {:error, :unavailable} ->
          {:error, :slack_triage_authority_unavailable}
      end
    else
      false -> {:error, :slack_triage_authority_ineligible}
      {:error, :not_found} -> {:error, :slack_triage_authority_ineligible}
      {:error, _reason} -> {:error, :slack_triage_authority_unavailable}
    end
  end

  @doc """
  Lists one bounded page of Slack channels visible to an exact active connect.

  This is the product picker projection for BFT Triage setup. Credentials stay
  inside this domain; callers receive only channel identity, display name,
  privacy, and Slack's opaque continuation cursor. Archived channels are
  excluded at the provider boundary.
  """
  def list_slack_triage_channels(
        tenant_id,
        group_id,
        connect_id,
        cursor \\ nil,
        limit \\ 100
      )

  def list_slack_triage_channels(tenant_id, group_id, connect_id, cursor, limit)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and
             group_id != "" and is_binary(connect_id) and connect_id != "" and
             (is_binary(cursor) or is_nil(cursor)) and is_integer(limit) and
             limit in 1..@slack_triage_channel_page_max and
             (is_nil(cursor) or byte_size(cursor) <= 1_024) do
    with true <- valid_page_cursor?(cursor),
         {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, connect} <- get_active_connect_by_id(group_id, connect_id, "slack"),
         true <- connect["tenant_id"] == tenant_id do
      page =
        SlackAPI.list_conversation_page(SlackAPI.installation(connect),
          limit: limit,
          cursor: cursor,
          types: ["public_channel", "private_channel"],
          exclude_archived: true
        )

      {:ok,
       %{
         channels: channel_options(page["channels"]),
         next_cursor: present_cursor(page["next_cursor"])
       }}
    else
      _unavailable -> {:error, :unavailable}
    end
  rescue
    _error in SlackAPI.Error -> {:error, :unavailable}
  end

  def list_slack_triage_channels(_tenant_id, _group_id, _connect_id, _cursor, _limit),
    do: {:error, :unavailable}

  @doc """
  Returns one credential-free expression context for an exact configured Slack channel.

  The provider catalog is one call through the existing `slack.list_emoji`
  operation. Provider failures degrade to the standard fallback catalog inside
  `ExpressionContext`; installation and channel identity mismatches fail before
  provider I/O.
  """
  def triage_slack_expression_context(tenant_id, group_id, connect_id, channel_id)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and
             group_id != "" and is_binary(connect_id) and is_binary(channel_id) do
    read_slack_triage_expression_context(
      tenant_id,
      group_id,
      connect_id,
      channel_id,
      nil
    )
  end

  def triage_slack_expression_context(_tenant_id, _group_id, _connect_id, _channel_id),
    do: {:error, :slack_triage_authority_ineligible}

  @doc "Reads expression context only while one captured channel authority is still current."
  def triage_slack_expression_context(
        tenant_id,
        group_id,
        connect_id,
        channel_id,
        expected_connect_generation
      )
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and
             group_id != "" and is_binary(connect_id) and is_binary(channel_id) and
             is_binary(expected_connect_generation) do
    read_slack_triage_expression_context(
      tenant_id,
      group_id,
      connect_id,
      channel_id,
      expected_connect_generation
    )
  end

  def triage_slack_expression_context(
        _tenant_id,
        _group_id,
        _connect_id,
        _channel_id,
        _expected_connect_generation
      ),
      do: {:error, :slack_triage_authority_ineligible}

  defp read_slack_triage_expression_context(
         tenant_id,
         group_id,
         connect_id,
         channel_id,
         expected_connect_generation
       ) do
    connect_id = trim(connect_id)
    channel_id = trim(channel_id)

    with true <- connect_id != "" and channel_id != "",
         {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, connect} <- get_active_connect_by_id(group_id, connect_id, "slack"),
         true <- connect["tenant_id"] == tenant_id,
         {:ok, policy} <-
           expression_context_policy(connect, tenant_id, group_id, channel_id),
         :ok <-
           verify_expression_context_generation(
             expected_connect_generation,
             policy.authority_generation
           ),
         {:ok, context} <-
           ExpressionContext.build(
             policy.expression_mode,
             slack_emoji_catalog(tenant_id, connect)
           ),
         {:ok, current_policy} <-
           expression_context_policy(connect, tenant_id, group_id, channel_id),
         :ok <-
           verify_expression_context_generation(
             policy.authority_generation,
             current_policy.authority_generation
           ),
         :ok <- verify_slack_triage_connect_snapshot(connect) do
      {:ok, context}
    else
      false -> {:error, :slack_triage_authority_ineligible}
      {:error, :not_found} -> {:error, :slack_triage_authority_ineligible}
      {:error, :slack_triage_authority_ineligible} = error -> error
      {:error, :slack_triage_authority_stale} = error -> error
      {:error, _reason} -> {:error, :slack_triage_authority_unavailable}
    end
  end

  @doc "Re-reads and verifies one exact credential-free Slack Triage authority snapshot."
  def verify_slack_triage_authority(authority) when is_map(authority) do
    with true <- exact_keys?(authority, @slack_triage_authority_keys),
         true <- valid_slack_triage_authority_snapshot?(authority),
         {:ok, current} <-
           get_slack_triage_authority(
             authority["tenant_id"],
             authority["group_id"],
             authority["connect_id"],
             authority["approved_channel_id"]
           ) do
      if current == authority,
        do: :ok,
        else: {:error, :slack_triage_authority_stale}
    else
      false ->
        {:error, :slack_triage_authority_stale}

      {:error, :slack_triage_authority_unavailable} ->
        {:error, :slack_triage_authority_unavailable}

      {:error, _ineligible_or_missing} ->
        {:error, :slack_triage_authority_stale}
    end
  end

  def verify_slack_triage_authority(_authority),
    do: {:error, :slack_triage_authority_stale}

  @doc "Re-reads canonical ingress authority, excluding presentation and unrelated slash-command settings."
  def verify_slack_triage_connect_snapshot(connect) when is_map(connect) do
    with group_id when is_binary(group_id) <- connect["group_id"],
         connect_id when is_binary(connect_id) <- connect["connect_id"],
         {:ok, current} <- CasRecord.get(Keys.ctl_im_connect(group_id, connect_id)),
         {:ok, ignored_keys} <- slack_connect_snapshot_ignored_keys(),
         true <-
           Map.drop(current, ignored_keys) == Map.drop(connect, ignored_keys) do
      :ok
    else
      {:error, :slack_triage_authority_unavailable} = error -> error
      {:error, _reason} -> {:error, :slack_triage_authority_unavailable}
      _stale -> {:error, :slack_triage_authority_stale}
    end
  end

  def verify_slack_triage_connect_snapshot(_connect),
    do: {:error, :slack_triage_authority_stale}

  defp slack_connect_snapshot_ignored_keys do
    case SlackTriageChannelCutover.mode() do
      :legacy ->
        {:ok, @slack_connect_snapshot_non_authority_keys}

      :projected ->
        {:ok,
         @slack_connect_snapshot_non_authority_keys ++
           @slack_projected_connect_snapshot_compatibility_keys}

      {:error, :unavailable} ->
        {:error, :slack_triage_authority_unavailable}
    end
  end

  @doc """
  Checks one verified ambient root's explicit mentions against sibling connects.

  Returns `{:ok, true}` when another connect in the same group currently holds
  an eligible Slack Triage authority for the same workspace and approved
  channel whose bot user is explicitly mentioned: the ambient copy seen by
  `authority` is that peer's explicit-mention traffic, not a triage root. The
  scan is bounded to the group's connect records; an unreadable group or
  connect record returns `{:error, :slack_triage_authority_unavailable}` so
  callers fail closed and the provider retries.
  """
  def slack_triage_peer_mentioned?(authority, mentioned_user_ids)
      when is_map(authority) and is_list(mentioned_user_ids) do
    mentioned =
      mentioned_user_ids
      |> Enum.map(&trim/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    if MapSet.size(mentioned) == 0 do
      {:ok, false}
    else
      with {:ok, group} <-
             GroupDirectory.get_group(authority["group_id"], authority["tenant_id"]),
           {:ok, records} <-
             scan_connect_records(Keys.ctl_im_connects_prefix(authority["group_id"])) do
        peers =
          Enum.filter(records, fn rec ->
            rec["connect_id"] != authority["connect_id"] and
              slack_triage_authority_eligible?(rec, group, authority["tenant_id"]) and
              rec["workspace_id"] == authority["workspace_id"] and
              MapSet.member?(mentioned, trim(rec["bot_user_id"]))
          end)

        peer_mentioned_for_cutover_mode(authority, peers)
      else
        _missing_or_unavailable -> {:error, :slack_triage_authority_unavailable}
      end
    end
  end

  def slack_triage_peer_mentioned?(_authority, _mentioned_user_ids),
    do: {:error, :slack_triage_authority_unavailable}

  defp peer_mentioned_for_cutover_mode(authority, peers) do
    case SlackTriageChannelCutover.mode() do
      :legacy ->
        {:ok,
         Enum.any?(peers, &(trim(&1["approved_channel_id"]) == authority["approved_channel_id"]))}

      :projected ->
        projected_peer_mentioned?(authority, peers)

      {:error, :unavailable} ->
        {:error, :slack_triage_authority_unavailable}
    end
  end

  defp projected_peer_mentioned?(authority, peers) do
    with {:ok, %{memberships: memberships, scan_complete: true}} <-
           SlackTriageChannels.list_channel_memberships(
             authority["tenant_id"],
             authority["group_id"],
             authority["workspace_id"],
             authority["approved_channel_id"]
           ) do
      projected = Map.new(memberships, &{&1["connect_id"], &1})

      {:ok,
       Enum.any?(peers, fn rec ->
         case projected[rec["connect_id"]] do
           membership when is_map(membership) ->
             membership["installation_generation"] == rec["connect_generation"] and
               membership["enabled"] == true

           nil ->
             false
         end
       end)}
    else
      _incomplete_or_unavailable -> {:error, :slack_triage_authority_unavailable}
    end
  end

  @doc "Resolves one bounded receipt page to current credential-free Triage authorities."
  def resolve_slack_triage_recovery_authorities(connect_ids, cursor \\ nil)

  def resolve_slack_triage_recovery_authorities(connect_ids, cursor)
      when is_list(connect_ids) and (is_binary(cursor) or is_nil(cursor)) do
    requested =
      connect_ids
      |> Enum.map(&trim/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    cond do
      MapSet.size(requested) != length(connect_ids) ->
        {:error, :invalid_slack_triage_recovery_authorities}

      MapSet.size(requested) > @slack_triage_recovery_batch_max ->
        {:error, :invalid_slack_triage_recovery_authorities}

      MapSet.size(requested) == 0 ->
        {:ok,
         %{
           authorities: %{},
           seen_connect_ids: [],
           unavailable_connect_ids: [],
           next_cursor: nil,
           scan_complete: true
         }}

      true ->
        resolve_slack_triage_recovery_authority_page(requested, cursor)
    end
  end

  def resolve_slack_triage_recovery_authorities(_connect_ids, _cursor),
    do: {:error, :invalid_slack_triage_recovery_authorities}

  @doc "Resolves exact connect/channel receipt identities for the recovery ring."
  def resolve_slack_triage_recovery_authority_refs(authority_refs, cursor \\ nil)

  def resolve_slack_triage_recovery_authority_refs(authority_refs, cursor)
      when is_list(authority_refs) and (is_binary(cursor) or is_nil(cursor)) do
    normalized =
      Enum.map(authority_refs, fn
        {connect_id, channel_id} -> {trim(connect_id), trim(channel_id)}
        _invalid -> {"", ""}
      end)

    requested = Enum.group_by(normalized, &elem(&1, 0), &elem(&1, 1))

    cond do
      Enum.any?(normalized, fn {connect_id, channel_id} ->
        connect_id == "" or channel_id == ""
      end) ->
        {:error, :invalid_slack_triage_recovery_authorities}

      length(Enum.uniq(normalized)) != length(normalized) ->
        {:error, :invalid_slack_triage_recovery_authorities}

      length(normalized) > @slack_triage_recovery_batch_max ->
        {:error, :invalid_slack_triage_recovery_authorities}

      normalized == [] ->
        {:ok,
         %{
           authorities: %{},
           seen_connect_ids: [],
           unavailable_connect_ids: [],
           next_cursor: nil,
           scan_complete: true
         }}

      true ->
        resolve_slack_triage_recovery_authority_ref_page(requested, cursor)
    end
  end

  def resolve_slack_triage_recovery_authority_refs(_authority_refs, _cursor),
    do: {:error, :invalid_slack_triage_recovery_authorities}

  def provision_slack_triage_authority(
        tenant_id,
        group_id,
        connect_id,
        approved_channel_id
      ) do
    SlackTriageChannelCutover.with_authority_write(fn ->
      approved_channel_id = trim(approved_channel_id)
      key = Keys.ctl_im_connect(group_id, trim(connect_id))

      with {:ok, group} <- GroupDirectory.get_group(group_id, tenant_id),
           {:ok, current} <- get_active_connect_by_id(group_id, connect_id, "slack"),
           true <- current["tenant_id"] == tenant_id,
           true <- trim(group["router_agent_id"]) != "",
           true <- slack_triage_provisionable?(current),
           {:ok, approved_channel_name} <-
             validate_slack_triage_channel(current, approved_channel_id),
           mode when mode in [:legacy, :projected] <- SlackTriageChannelCutover.mode(),
           :ok <- allow_slack_triage_provision?(mode, current, approved_channel_id) do
        with {:ok, prepared} <-
               update_existing(key, fn rec ->
                 if rec == current do
                   first_channel? = not provisioned?(rec)

                   router_changed? =
                     provisioned?(rec) and
                       trim(rec["inbound_agent_id"]) != trim(group["router_agent_id"])

                   rec
                   # Compatibility display fields only. PostgreSQL owns the
                   # configured channel set; these retain the last provisioned
                   # channel for old readers during the source-compatible roll.
                   |> Map.put("approved_channel_id", approved_channel_id)
                   |> Map.put("approved_channel_name", approved_channel_name)
                   |> Map.put("inbound_agent_id", trim(group["router_agent_id"]))
                   |> establish_slack_triage_generation_if_missing()
                   |> Map.put_new("triage_activation_generation", ULID.generate())
                   |> then(fn next ->
                     if first_channel? or router_changed? do
                       next
                       |> maybe_rotate_slack_triage_activation(false)
                       |> Map.put("triage_enabled", false)
                     else
                       next
                     end
                   end)
                   # One-way family marker: channel rows may be stale after an
                   # installation change, but legacy ingress never returns.
                   |> Map.put("triage_provisioned_at", rec["triage_provisioned_at"] || now())
                   |> Map.put("updated_at", now())
                 else
                   {:error, :slack_triage_authority_conflict}
                 end
               end),
             :ok <-
               maybe_provision_projected_channel(
                 mode,
                 prepared,
                 tenant_id,
                 group_id,
                 approved_channel_id,
                 approved_channel_name
               ) do
          {:ok, im_connect_public(prepared)}
        end
      else
        false -> {:error, :slack_triage_authority_ineligible}
        {:error, :not_found} -> {:error, :slack_triage_authority_ineligible}
        {:error, :unavailable} -> {:error, :slack_triage_authority_unavailable}
        other -> other
      end
    end)
  end

  defp allow_slack_triage_provision?(:projected, _current, _channel_id), do: :ok

  defp allow_slack_triage_provision?(:legacy, current, channel_id) do
    existing = trim(current["approved_channel_id"])

    if existing in ["", channel_id],
      do: :ok,
      else: {:error, :slack_triage_channel_cutover_pending}
  end

  defp maybe_provision_projected_channel(
         :legacy,
         _prepared,
         _tenant_id,
         _group_id,
         _channel_id,
         _channel_name
       ),
       do: :ok

  defp maybe_provision_projected_channel(
         :projected,
         prepared,
         tenant_id,
         group_id,
         channel_id,
         channel_name
       ) do
    case SlackTriageChannels.provision(%{
           "tenant_id" => tenant_id,
           "group_id" => group_id,
           "connect_id" => trim(prepared["connect_id"]),
           "channel_id" => channel_id,
           "installation_generation" => prepared["connect_generation"],
           "workspace_id" => prepared["workspace_id"],
           "channel_name" => channel_name
         }) do
      {:ok, _channel} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def set_slack_triage_enabled(tenant_id, group_id, connect_id, enabled?)
      when is_boolean(enabled?) do
    SlackTriageChannelCutover.with_authority_write(fn ->
      key = Keys.ctl_im_connect(group_id, trim(connect_id))

      with {:ok, group} <- GroupDirectory.get_group(group_id, tenant_id),
           {:ok, current} <- get_active_or_disabled_connect(group_id, connect_id),
           true <- current["tenant_id"] == tenant_id and current["provider"] == "slack",
           :ok <-
             if(enabled?,
               do: ensure_slack_triage_master_ready(current, group, tenant_id),
               else: :ok
             ) do
        update_existing(key, fn rec ->
          if rec == current do
            rec
            |> maybe_rotate_slack_triage_activation(enabled?)
            |> Map.put("triage_enabled", enabled?)
            |> Map.put("updated_at", now())
          else
            {:error, :slack_triage_authority_conflict}
          end
        end)
        |> case do
          {:ok, _rec} -> :ok
          other -> other
        end
      else
        false -> {:error, :slack_triage_authority_ineligible}
        {:error, :not_found} -> {:error, :slack_triage_authority_ineligible}
        {:error, :unavailable} -> {:error, :slack_triage_authority_unavailable}
        other -> other
      end
    end)
  end

  @doc """
  Projects one already-read Slack member-channel page into default listening.

  Called by shared mirror discovery, never a second Slack discovery loop. The
  installation master pause remains authoritative. Only non-archived, unshared
  public member channels are admitted; private channels and DMs are not inferred
  from archive visibility. A stale discovery cannot authorize a new installation:
  rows retain its exact installation generation and current readers fence it out.
  """
  def observe_slack_member_channels(connect, channels)
      when is_map(connect) and is_list(channels) and length(channels) <= 200 do
    tenant_id = connect["tenant_id"]
    group_id = connect["group_id"]

    with {:ok, group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, current} <- get_active_connect_by_id(group_id, connect["connect_id"], "slack"),
         true <- current["connect_generation"] == connect["connect_generation"],
         true <- current["workspace_id"] == connect["workspace_id"],
         true <- current["triage_enabled"] == true,
         true <- slack_triage_connect_ready?(current, group, tenant_id),
         :projected <- SlackTriageChannelCutover.mode() do
      channels
      |> Enum.filter(&default_slack_triage_channel?/1)
      |> Enum.reduce_while(:ok, fn channel, :ok ->
        case maybe_provision_projected_channel(
               :projected,
               current,
               tenant_id,
               group_id,
               channel["id"],
               channel["name"]
             ) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      false -> :ok
      :legacy -> :ok
      {:error, _reason} = error -> error
    end
  end

  def observe_slack_member_channels(_connect, _channels), do: {:error, :invalid_channel_page}

  defp default_slack_triage_channel?(channel) when is_map(channel) do
    # users.conversations proves membership and omits is_member. Do not reuse
    # this predicate with conversations.list (workspace visibility is not membership).
    trim(channel["id"]) != "" and trim(channel["name"]) != "" and
      channel["is_member"] != false and channel["is_private"] == false and
      channel["is_archived"] == false and channel["is_shared"] == false and
      channel["is_im"] != true and channel["is_mpim"] != true
  end

  defp default_slack_triage_channel?(_channel), do: false

  @doc "Lists the current installation's discovered/configured Triage channels."
  def list_configured_slack_triage_channels(tenant_id, group_id, connect_id) do
    with {:ok, group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, rec} <- get_active_connect_by_id(group_id, connect_id, "slack"),
         true <- rec["tenant_id"] == tenant_id do
      configured_channels_for_cutover_mode(
        rec,
        tenant_id,
        group_id,
        slack_triage_connect_ready?(rec, group, tenant_id)
      )
    else
      false -> {:error, :slack_triage_authority_ineligible}
      {:error, :not_found} -> {:error, :slack_triage_authority_ineligible}
      {:error, _reason} -> {:error, :slack_triage_authority_unavailable}
    end
  end

  defp configured_channels_for_cutover_mode(rec, tenant_id, group_id, connect_ready?) do
    case SlackTriageChannelCutover.mode() do
      :legacy ->
        channels = legacy_configured_channel_projection(rec)

        {:ok,
         %{
           channels: channels,
           scan_complete: true,
           channel_controls_available?: false,
           authority_valid?:
             connect_ready? and channels != [] and valid_expression_modes?(channels)
         }}

      :projected ->
        with {:ok, page} <-
               SlackTriageChannels.list_page(tenant_id, group_id, trim(rec["connect_id"])) do
          channels =
            page.channels
            |> Enum.filter(&current_slack_triage_channel?(&1, rec))
            |> projected_configured_channel_projection()

          {:ok,
           %{
             channels: channels,
             scan_complete: page.scan_complete,
             channel_controls_available?: true,
             authority_valid?:
               connect_ready? and page.scan_complete and channels != [] and
                 valid_expression_modes?(channels)
           }}
        end

      {:error, :unavailable} ->
        {:error, :slack_triage_authority_unavailable}
    end
  end

  defp legacy_configured_channel_projection(rec) do
    channel_id = trim(rec["approved_channel_id"])
    channel_name = trim(rec["approved_channel_name"])

    if provisioned?(rec) and channel_id != "" do
      [
        %{
          channel_id: channel_id,
          channel_name: channel_name,
          expression_mode: "project",
          enabled: true
        }
      ]
    else
      []
    end
  end

  defp projected_configured_channel_projection(channels) do
    Enum.map(channels, fn channel ->
      %{
        channel_id: channel["channel_id"],
        channel_name: channel["channel_name"],
        expression_mode: channel["expression_mode"],
        enabled: channel["enabled"] == true
      }
    end)
  end

  @doc "Enables or pauses one configured channel without touching its siblings."
  def set_slack_triage_channel_enabled(
        tenant_id,
        group_id,
        connect_id,
        channel_id,
        enabled?
      )
      when is_boolean(enabled?) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, rec} <- get_active_or_disabled_connect(group_id, connect_id),
         true <- rec["tenant_id"] == tenant_id and rec["provider"] == "slack",
         :projected <- SlackTriageChannelCutover.mode(),
         :ok <-
           set_projected_or_legacy_channel_enabled(
             rec,
             tenant_id,
             group_id,
             trim(channel_id),
             enabled?
           ) do
      :ok
    else
      false -> {:error, :slack_triage_authority_ineligible}
      :legacy -> {:error, :slack_triage_channel_cutover_pending}
      {:error, :unavailable} -> {:error, :slack_triage_authority_unavailable}
      {:error, :not_found} -> {:error, :slack_triage_authority_ineligible}
      {:error, _reason} -> {:error, :slack_triage_authority_unavailable}
    end
  end

  def set_slack_triage_channel_enabled(
        _tenant_id,
        _group_id,
        _connect_id,
        _channel_id,
        _enabled?
      ),
      do: {:error, :slack_triage_authority_ineligible}

  @doc "Updates one projected channel's explicit expression policy without enabling it."
  def set_slack_triage_channel_expression_mode(
        tenant_id,
        group_id,
        connect_id,
        channel_id,
        expression_mode
      )
      when expression_mode in @slack_triage_expression_modes do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, rec} <- get_active_or_disabled_connect(group_id, connect_id),
         true <- rec["tenant_id"] == tenant_id and rec["provider"] == "slack",
         :projected <- SlackTriageChannelCutover.mode(),
         :ok <-
           set_projected_channel_expression_mode(
             rec,
             tenant_id,
             group_id,
             trim(channel_id),
             expression_mode
           ),
         :ok <- verify_slack_triage_connect_snapshot(rec) do
      :ok
    else
      false -> {:error, :slack_triage_authority_ineligible}
      :legacy -> {:error, :slack_triage_channel_cutover_pending}
      {:error, :unavailable} -> {:error, :slack_triage_authority_unavailable}
      {:error, :not_found} -> {:error, :slack_triage_authority_ineligible}
      {:error, :slack_triage_authority_stale} = error -> error
      {:error, _reason} -> {:error, :slack_triage_authority_unavailable}
    end
  end

  def set_slack_triage_channel_expression_mode(
        _tenant_id,
        _group_id,
        _connect_id,
        _channel_id,
        _expression_mode
      ),
      do: {:error, :invalid_slack_triage_expression_mode}

  def get_agent_visible_connect_by_id(
        %{group_id: group_id, agent_id: agent_id} = scope,
        connect_id,
        provider
      ) do
    agent_role =
      case scope do
        %{agent: %{"role" => role}} when is_binary(role) -> trim(role)
        _missing_agent -> ""
      end

    with {:ok, rec} <- get_active_connect_by_id(group_id, connect_id, provider),
         {:ok, group} <- GroupDirectory.get_group(group_id),
         true <-
           tool_connect_visible_to_agent?(
             rec,
             trim(agent_id),
             trim(group["router_agent_id"]),
             agent_role
           ) do
      {:ok, rec}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp set_projected_or_legacy_channel_enabled(
         rec,
         tenant_id,
         group_id,
         channel_id,
         enabled?
       ) do
    case SlackTriageChannels.get(tenant_id, group_id, trim(rec["connect_id"]), channel_id) do
      {:ok, _channel} ->
        SlackTriageChannels.set_enabled(
          tenant_id,
          group_id,
          trim(rec["connect_id"]),
          channel_id,
          rec["connect_generation"],
          enabled?
        )

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp set_projected_channel_expression_mode(
         rec,
         tenant_id,
         group_id,
         channel_id,
         expression_mode
       ) do
    case SlackTriageChannels.get(tenant_id, group_id, trim(rec["connect_id"]), channel_id) do
      {:ok, channel} ->
        if current_slack_triage_channel?(channel, rec) do
          SlackTriageChannels.set_expression_mode(
            tenant_id,
            group_id,
            trim(rec["connect_id"]),
            channel_id,
            rec["connect_generation"],
            expression_mode
          )
        else
          {:error, :not_found}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_runtime_provider_connects(providers \\ ["telegram", "wechat"]) do
    providers = providers |> List.wrap() |> Enum.map(&trim/1)

    with {:ok, records} <- scan_connect_records(Keys.ctl_im_connects_all_prefix()) do
      {:ok,
       records
       |> Enum.reject(& &1["deleted_at"])
       |> Enum.reject(& &1["disabled_at"])
       |> Enum.reject(&(&1["runtime_mode"] == "webhook"))
       |> Enum.filter(&(&1["provider"] in providers))
       |> Enum.filter(&tool_visible_connect?/1)
       |> Enum.sort_by(&{&1["provider"] || "", &1["created_at"] || 0, &1["connect_id"] || ""})}
    end
  end

  def create_slack_im_connect(tenant_id, group_id, attrs) when is_map(attrs) do
    SlackTriageChannelCutover.with_authority_write(fn ->
      with {:ok, group} <- GroupDirectory.get_group(group_id, tenant_id),
           :ok <-
             validate_required_attrs(attrs, [
               "app_id",
               "client_id",
               "client_secret",
               "signing_secret"
             ]),
           {:ok, inbound_agent} <- resolve_slack_inbound_agent(group, attrs),
           app_id <- trim(attrs["app_id"]),
           :ok <- ProviderIdentity.ensure_available("slack", app_id) do
        now = now()
        connect_id = Ids.new_connect_id()

        rec =
          %{
            "connect_id" => connect_id,
            "tenant_id" => tenant_id,
            "group_id" => group_id,
            "provider" => "slack",
            "app_name" => nonblank(attrs["app_name"], "Comma"),
            "app_id" => trim(attrs["app_id"]),
            "slack_commands" => %{
              "app_id" => trim(attrs["app_id"]),
              "revision" => 0,
              "commands" => [],
              "status" => "not_configured"
            },
            "client_id" => trim(attrs["client_id"]),
            "client_secret" => trim(attrs["client_secret"]),
            "signing_secret" => trim(attrs["signing_secret"]),
            "inbound_agent_id" => inbound_agent["agent_id"],
            "connect_generation" => ULID.generate(),
            "triage_activation_generation" => ULID.generate(),
            "triage_enabled" => false,
            "oauth_state" => random_id(),
            "oauth_completed_at" => 0,
            "created_at" => now,
            "updated_at" => now
          }
          |> maybe_put_nonblank(
            "inbound_event_not_before_ms",
            attrs["inbound_event_not_before_ms"]
          )

        with :ok <-
               ProviderIdentity.reserve_provider("slack", app_id, tenant_id, group_id, connect_id),
             {:ok, rec} <- CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), rec) do
          {:ok, im_connect_public(rec)}
        else
          other ->
            _ = ProviderIdentity.release_provider("slack", app_id, connect_id)
            other
        end
      end
    end)
  end

  def update_slack_im_connect(tenant_id, group_id, connect_id, attrs) when is_map(attrs) do
    SlackTriageChannelCutover.with_authority_write(fn ->
      with {:ok, group} <- GroupDirectory.get_group(group_id, tenant_id),
           {:ok, current} <- get_active_connect_by_id(group_id, connect_id, "slack"),
           true <- current["tenant_id"] == tenant_id,
           next_app_id <- nonblank(attrs["app_id"], current["app_id"]),
           {:ok, inbound_agent} <- resolve_slack_inbound_agent(group, attrs, current),
           :ok <- ProviderIdentity.ensure_available("slack", next_app_id, connect_id) do
        ProviderIdentity.update(
          "slack",
          tenant_id,
          group_id,
          connect_id,
          current["app_id"],
          next_app_id,
          fn ->
            # Test pause point INSIDE the protocol's in-flight window: the
            # NEW identity is reserved, the canonical CAS has not landed.
            ProviderIdentityBarrier.hit(:connect_update_canonical)

            update_existing(Keys.ctl_im_connect(group_id, connect_id), fn rec ->
              rec
              |> maybe_revoke_slack_triage_on_update(
                next_app_id,
                inbound_agent["agent_id"],
                attrs
              )
              |> maybe_put_nonblank("app_name", attrs["app_name"])
              |> then(fn record ->
                if current["app_id"] == next_app_id,
                  do: record,
                  else:
                    Map.put(record, "slack_commands", %{
                      "app_id" => next_app_id,
                      "revision" => 0,
                      "commands" => [],
                      "status" => "not_configured"
                    })
              end)
              |> Map.put("app_id", next_app_id)
              |> maybe_put_nonblank("client_id", attrs["client_id"])
              |> maybe_put_nonblank("client_secret", attrs["client_secret"])
              |> maybe_put_nonblank("signing_secret", attrs["signing_secret"])
              |> Map.put("inbound_agent_id", inbound_agent["agent_id"])
              |> maybe_reset_slack_oauth(attrs["reset_oauth"] == true)
              |> Map.put("updated_at", now())
            end)
          end
        )
        |> public_result()
      else
        false -> {:error, :not_found}
        other -> other
      end
    end)
  end

  def create_telegram_im_connect(tenant_id, group_id, attrs) when is_map(attrs) do
    with {:ok, bot} <- validate_telegram_bot_token(attrs["bot_token"]) do
      create_secret_connect(
        tenant_id,
        group_id,
        "telegram",
        attrs,
        ["bot_token"],
        fn rec ->
          rec
          |> Map.put("bot_token", trim(attrs["bot_token"]))
          |> Map.put("bot_user_id", trim(bot["id"]))
          |> Map.put("bot_username", trim(bot["username"]))
          |> Map.put("bot_display_name", trim(bot["first_name"]))
          |> Map.put("updates_offset", 0)
          |> Map.put("status", "connected")
          |> Map.put("last_error", "")
          |> Map.put("connected_at", now())
        end
      )
    end
  end

  @doc "Prepares a disabled Comma iMessage DM route; uses CommaTelegramBinding.tla's prepare transition."
  def ensure_managed_imessage_im_connect(tenant_id, group_id, attrs) when is_map(attrs) do
    relay = SalixIM.IMessageRelay

    if relay.configured?() do
      create_secret_connect(
        tenant_id,
        group_id,
        "imessage",
        attrs,
        ["sender_handle", "chat_guid"],
        fn rec ->
          Map.merge(rec, %{
            "managed_by" => "comma_product",
            "managed_peer_id" => trim(attrs["sender_handle"]),
            "managed_chat_id" => trim(attrs["chat_guid"]),
            "relay_id" => relay.relay_id(),
            "bot_user_id" => relay.shared_handle(),
            "bot_display_name" => relay.shared_identity(),
            "runtime_mode" => "product_relay",
            "status" => "connected",
            "disabled_at" => now()
          })
        end
      )
    else
      {:error, :imessage_unavailable}
    end
  end

  @doc "Comma coordinator only, after the authoritative binding has committed."
  def activate_managed_imessage_im_connect(tenant_id, group_id, connect_id) do
    with {:ok, rec} <- get_active_or_disabled_connect(group_id, connect_id),
         true <- rec["managed_by"] == "comma_product" and rec["provider"] == "imessage" do
      set_im_connect_disabled(tenant_id, group_id, connect_id, false)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Prepares a fresh, disabled Comma product Telegram connect for one Group.

  The bot token is shared product configuration, while `managed_peer_id` is the
  only Telegram DM this Group may address. Comma activates it only AFTER its
  binding transaction commits. A failed/ambiguous prepare cannot grant send
  authority. Ids and peers are immutable; deletion is terminal, including when
  a delayed activation CAS races deletion. Modeled in CommaTelegramBinding.tla.
  These connects are excluded from ProviderRuntime polling.
  """
  def ensure_managed_telegram_im_connect(tenant_id, group_id, attrs) when is_map(attrs) do
    telegram_user_id = trim(attrs["telegram_user_id"])

    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         true <- telegram_user_id != "",
         {:ok, bot} <- validate_telegram_bot_token(attrs["bot_token"]) do
      managed_fields = fn rec ->
        rec
        |> Map.put("bot_token", trim(attrs["bot_token"]))
        |> Map.put("bot_user_id", trim(bot["id"]))
        |> Map.put("bot_username", trim(bot["username"]))
        |> Map.put("bot_display_name", trim(bot["first_name"]))
        |> Map.put("managed_by", "comma_product")
        |> Map.put("managed_peer_id", telegram_user_id)
        |> Map.put("runtime_mode", "webhook")
        |> Map.put("status", "connected")
        |> Map.put("last_error", "")
        |> Map.put("connected_at", now())
        |> Map.put("disabled_at", now())
      end

      create_secret_connect(
        tenant_id,
        group_id,
        "telegram",
        attrs,
        ["bot_token", "telegram_user_id"],
        managed_fields
      )
    else
      false -> {:error, {:bad_request, "telegram_user_id is required"}}
      other -> other
    end
  end

  @doc "Comma lifecycle coordinator only; the binding must already be committed."
  def activate_managed_telegram_im_connect(tenant_id, group_id, connect_id) do
    with {:ok, rec} <- get_active_or_disabled_connect(group_id, connect_id),
         true <- rec["managed_by"] == "comma_product" and rec["provider"] == "telegram" do
      set_im_connect_disabled(tenant_id, group_id, connect_id, false)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def update_telegram_im_connect(tenant_id, group_id, connect_id, attrs) when is_map(attrs) do
    with :ok <- reject_managed_telegram_mutation(group_id, connect_id),
         {:ok, bot} <- validate_telegram_bot_token(attrs["bot_token"]) do
      update_secret_connect(
        tenant_id,
        group_id,
        connect_id,
        "telegram",
        attrs,
        ["bot_token"],
        fn rec ->
          rec
          |> Map.put("bot_token", trim(attrs["bot_token"]))
          |> Map.put("bot_user_id", trim(bot["id"]))
          |> Map.put("bot_username", trim(bot["username"]))
          |> Map.put("bot_display_name", trim(bot["first_name"]))
          |> Map.put("updates_offset", 0)
          |> Map.put("status", "connected")
          |> Map.put("last_error", "")
          |> Map.put("connected_at", now())
        end
      )
    end
  end

  def create_feishu_im_connect(tenant_id, group_id, attrs) when is_map(attrs) do
    app_id = trim(attrs["app_id"])

    with :ok <- reject_feishu_connect_secrets(attrs),
         {:ok, attrs} <- resolve_feishu_bot_secrets(tenant_id, attrs),
         {:ok, token} <- validate_feishu_credentials(app_id, attrs["app_secret"]),
         :ok <- ProviderIdentity.ensure_available("feishu", app_id) do
      bot_open_id = fetch_feishu_bot_open_id(token)

      create_secret_connect(
        tenant_id,
        group_id,
        "feishu",
        attrs,
        ["app_id"],
        fn rec ->
          rec
          |> Map.put("app_name", nonblank(attrs["app_name"], "Bridge"))
          |> Map.put("app_id", app_id)
          |> Map.put("bot_open_id", bot_open_id)
          |> Map.put("webhook_url", public_base_url() <> "/v1/im/feishu/events")
          |> Map.put("status", "connected")
          |> Map.put("last_error", "")
          |> Map.put("connected_at", now())
        end,
        identity: {"feishu", app_id}
      )
    end
  end

  def update_feishu_im_connect(tenant_id, group_id, connect_id, attrs) when is_map(attrs) do
    app_id = trim(attrs["app_id"])

    with {:ok, current} <- get_active_or_disabled_connect(group_id, connect_id),
         true <- current["tenant_id"] == tenant_id and current["provider"] == "feishu",
         :ok <- reject_feishu_connect_secrets(attrs),
         {:ok, attrs} <- resolve_feishu_bot_secrets(tenant_id, attrs),
         {:ok, token} <- validate_feishu_credentials(app_id, attrs["app_secret"]),
         :ok <- ProviderIdentity.ensure_available("feishu", app_id, connect_id) do
      bot_open_id = fetch_feishu_bot_open_id(token)

      ProviderIdentity.update(
        "feishu",
        tenant_id,
        group_id,
        connect_id,
        current["app_id"],
        app_id,
        fn ->
          update_secret_connect(
            tenant_id,
            group_id,
            connect_id,
            "feishu",
            attrs,
            ["app_id"],
            fn rec ->
              rec
              |> Map.put("app_name", nonblank(attrs["app_name"], "Bridge"))
              |> Map.put("app_id", app_id)
              |> Map.put("bot_open_id", bot_open_id)
              |> Map.put("webhook_url", public_base_url() <> "/v1/im/feishu/events")
              |> Map.put("status", "connected")
              |> Map.put("last_error", "")
              |> Map.put("connected_at", now())
            end
          )
        end
      )
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  # ---- voice (SalixIM.VoiceConnects owns the voice connect contract) ----

  defdelegate ensure_voice_im_connect(tenant_id, group_id), to: SalixIM.VoiceConnects
  defdelegate get_voice_im_connect(tenant_id, group_id), to: SalixIM.VoiceConnects

  defdelegate check_voice_number_available(tenant_id, group_id, carrier, line, e164),
    to: SalixIM.VoiceConnects

  defdelegate confirm_voice_number(tenant_id, group_id, carrier, line, e164),
    to: SalixIM.VoiceConnects

  defdelegate remove_voice_number(tenant_id, group_id, e164, opts \\ []),
    to: SalixIM.VoiceConnects

  defdelegate set_voice_number_pin(tenant_id, group_id, e164, pin), to: SalixIM.VoiceConnects

  defdelegate verify_voice_pin(group_id, connect_id, carrier, line, e164, pin, opts \\ []),
    to: SalixIM.VoiceConnects

  defdelegate find_voice_connect(carrier, line, e164), to: SalixIM.VoiceConnects

  # ---- signal (SalixIM.SignalConnects owns the Signal connect contract) ----

  defdelegate ensure_signal_im_connect(tenant_id, group_id), to: SalixIM.SignalConnects
  defdelegate get_signal_im_connect(tenant_id, group_id), to: SalixIM.SignalConnects
  defdelegate find_signal_connect(account_id, peer), to: SalixIM.SignalConnects

  def disable_im_connect(tenant_id, group_id, connect_id),
    do: set_im_connect_disabled(tenant_id, group_id, connect_id, true)

  def enable_im_connect(tenant_id, group_id, connect_id) do
    with :ok <- reject_managed_telegram_mutation(group_id, connect_id) do
      set_im_connect_disabled(tenant_id, group_id, connect_id, false)
    end
  end

  defp reject_managed_telegram_mutation(group_id, connect_id) do
    case get_active_or_disabled_connect(group_id, connect_id) do
      {:ok, %{"managed_by" => "comma_product", "provider" => "wechat"}} ->
        {:error, {:bad_request, "Manage this WeChat connection in Comma Settings"}}

      {:ok, %{"managed_by" => "comma_product", "provider" => "imessage"}} ->
        {:error, {:bad_request, "Manage this iMessage connection in Comma Settings"}}

      {:ok, %{"managed_by" => "comma_product", "provider" => "telegram"}} ->
        {:error, {:bad_request, "Manage this Telegram connection in Comma Settings"}}

      {:ok, _connect} ->
        :ok

      other ->
        other
    end
  end

  def delete_im_connect(tenant_id, group_id, connect_id) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, rec} <- CasRecord.get(Keys.ctl_im_connect(group_id, connect_id)),
         true <- rec["tenant_id"] == tenant_id do
      retire_connect(rec)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Retire a group's provider routes, including disabled routes and orphaned
  records whose group has already been removed. Internal lifecycle operation:
  the caller must supply the owning tenant and its canonical group ID.
  """
  def delete_group_im_connects(tenant_id, group_id) do
    if Ids.valid_group_id_for_tenant?(group_id, tenant_id) do
      prefix = Keys.ctl_im_connects_prefix(group_id)

      with {:ok, %{objects: objects, next: nil}}
           when length(objects) <= @connect_scan_max_records <-
             S3.list(prefix, max_keys: @connect_scan_max_records),
           {:ok, records} <- owned_connect_records(objects, tenant_id, group_id) do
        Enum.reduce_while(records, :ok, fn rec, :ok ->
          case retire_connect(rec) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
      else
        {:ok, %{next: _}} -> {:error, :connect_scan_limit_exceeded}
        {:error, _} = error -> error
      end
    else
      {:error, :not_found}
    end
  end

  defp owned_connect_records(objects, tenant_id, group_id) do
    Enum.reduce_while(objects, {:ok, []}, fn %{key: key}, {:ok, records} ->
      case CasRecord.get(key) do
        {:ok, rec} ->
          if owned_connect?(rec, key, tenant_id, group_id) do
            {:cont, {:ok, [rec | records]}}
          else
            {:halt, {:error, :invalid_connect_record}}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  defp owned_connect?(rec, key, tenant_id, group_id) do
    is_binary(rec["connect_id"]) and rec["connect_id"] != "" and
      rec["tenant_id"] == tenant_id and rec["group_id"] == group_id and
      key == Keys.ctl_im_connect(group_id, rec["connect_id"])
  end

  defp retire_connect(rec) do
    key = Keys.ctl_im_connect(rec["group_id"], rec["connect_id"])

    maybe_with_slack_authority_write(rec, fn ->
      update_existing(key, fn current ->
        cond do
          not owned_connect?(current, key, rec["tenant_id"], rec["group_id"]) ->
            {:error, :invalid_connect_record}

          not is_nil(current["deleted_at"]) ->
            {:unchanged, current}

          true ->
            current
            |> establish_or_rotate_slack_triage_generation()
            |> Map.put("deleted_at", now())
            |> Map.put("updated_at", now())
        end
      end)
      |> case do
        # Retry release even after the tombstone landed: a failed release must
        # not strand the provider reservation permanently.
        {:ok, deleted} -> ProviderIdentity.release(deleted)
        error -> error
      end
    end)
  end

  def find_slack_im_connect_by_oauth_state(state) do
    state = trim(state)

    with {:ok, records} <- scan_connect_records(Keys.ctl_im_connects_all_prefix()) do
      records
      |> Enum.find(fn rec ->
        rec["provider"] == "slack" and rec["oauth_state"] == state and is_nil(rec["deleted_at"])
      end)
      |> case do
        nil -> {:error, :not_found}
        rec -> {:ok, rec}
      end
    end
  end

  def complete_slack_im_connect_oauth(connect, oauth) do
    SlackTriageChannelCutover.with_authority_write(fn ->
      key = Keys.ctl_im_connect(connect["group_id"], connect["connect_id"])
      now = now()

      update_existing(key, fn current ->
        case prepare_slack_triage_oauth_completion(current, oauth) do
          {:error, _reason} = error ->
            error

          rec ->
            rec
            |> Map.put("bot_token", oauth["bot_token"])
            |> Map.put("bot_id", oauth["bot_id"])
            |> Map.put("bot_user_id", oauth["bot_user_id"])
            |> Map.put("bot_username", oauth["bot_username"])
            |> Map.put("workspace_id", oauth["workspace_id"])
            |> Map.put("workspace_name", oauth["workspace_name"])
            |> Map.put("enterprise_id", oauth["enterprise_id"])
            |> Map.put("owner_user_id", oauth["owner_user_id"])
            # `oauth_completed_at` is a Triage-authority member and every captured
            # pin compares the authority map byte-exactly, so a completion that
            # moves the timestamp — including a plain re-completion of the SAME
            # Slack identity — must retire those pins under a fresh generation.
            # Fencing it here is what makes the reply-settlement model's premise
            # true: every connect-owned change that retires a pinnable authority
            # carries a generation rotation, so no captured pin can survive a
            # change it cannot see.
            |> Map.put("oauth_completed_at", now)
            |> Map.put("updated_at", now)
            |> fence_slack_triage_authority_change(current)
            |> put_slack_scope_snapshot(oauth)
        end
      end)
      |> public_result()
    end)
  end

  def list_slack_bot_identity_backfill_candidates(limit \\ 100, cursor \\ nil),
    do: scan_slack_connect_page(limit, cursor, &slack_bot_identity_backfill_candidate?/1)

  @doc """
  One bounded page of Slack connects whose messages the mirror may backfill.

  Same paginated scan as the bot-identity backfill above with a different
  predicate; the error atoms below still name that caller because it is the
  one they were published under and tests pin them.

  The predicate is broader than the bot-identity one: this wants every
  installation that can currently read Slack, not the subset missing a field.
  `workspace_id` is required because it is part of the mirror's ClickHouse
  key, so a connect without one has nowhere to file its messages.
  """
  def list_slack_mirror_backfill_connects(limit \\ 100, cursor \\ nil),
    do: scan_slack_connect_page(limit, cursor, &slack_mirror_backfill_connect?/1)

  @doc "Reference-only search discovery, including revoked records to update the catalog."
  def list_slack_search_connects(limit \\ 20, cursor \\ nil) do
    with {:ok, page} <- scan_slack_connect_page(limit, cursor, &(&1["provider"] == "slack")) do
      references =
        Enum.map(page.candidates, fn connect ->
          Map.take(connect, ~w(tenant_id group_id connect_id connect_generation workspace_id))
          |> Map.put("active", message_search_connect_active?(connect))
        end)

      {:ok, %{page | candidates: references}}
    end
  end

  defp scan_slack_connect_page(limit, cursor, candidate?) do
    limit = limit |> max(1) |> min(1_000)
    prefix = Keys.ctl_im_connects_all_prefix()

    with {:ok, start_after} <- decode_slack_bot_identity_backfill_cursor(cursor, prefix),
         {:ok, page} <- list_slack_bot_identity_backfill_page(prefix, limit, start_after),
         {:ok, records} <- hydrate_slack_bot_identity_backfill_page(page.objects, prefix) do
      candidates = Enum.filter(records, candidate?)
      scan_complete = not continuation?(page.next)

      {:ok,
       %{
         candidates: candidates,
         scanned_count: length(records),
         next_cursor: slack_bot_identity_backfill_next_cursor(page.objects, scan_complete),
         scan_complete: scan_complete
       }}
    end
  end

  defp slack_mirror_backfill_connect?(rec) do
    rec["provider"] == "slack" and is_nil(rec["deleted_at"]) and
      is_nil(rec["disabled_at"]) and num(rec["oauth_completed_at"]) > 0 and
      trim(rec["bot_token"]) != "" and trim(rec["workspace_id"]) != "" and
      trim(rec["tenant_id"]) != "" and trim(rec["group_id"]) != "" and
      trim(rec["connect_id"]) != "" and trim(rec["connect_generation"]) != ""
  end

  # Retained data belongs to the logical connect/workspace. Credential and
  # Triage generations do not revoke or re-index that data; the owner may
  # explicitly disable/delete the connect or change its workspace.
  defp message_search_connect_active?(rec) do
    rec["provider"] == "slack" and is_nil(rec["deleted_at"]) and is_nil(rec["disabled_at"]) and
      Enum.all?(~w(tenant_id group_id connect_id workspace_id), &(trim(rec[&1]) != ""))
  end

  defp list_slack_bot_identity_backfill_page(prefix, limit, start_after) do
    opts = [max_keys: limit]
    opts = if start_after, do: Keyword.put(opts, :start_after, start_after), else: opts

    case S3.list(prefix, opts) do
      {:ok, %{objects: objects, next: next}} when is_list(objects) ->
        if continuation?(next) and objects == [] do
          {:error, {:slack_bot_identity_backfill_list_failed, :empty_continuation_page}}
        else
          {:ok, %{objects: objects, next: next}}
        end

      {:error, reason} ->
        {:error, {:slack_bot_identity_backfill_list_failed, reason}}

      other ->
        {:error, {:slack_bot_identity_backfill_list_failed, other}}
    end
  end

  defp hydrate_slack_bot_identity_backfill_page(objects, prefix) do
    Enum.reduce_while(objects, {:ok, []}, fn object, {:ok, acc} ->
      case hydrate_slack_bot_identity_backfill_object(object, prefix) do
        {:ok, rec} -> {:cont, {:ok, [rec | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      other -> other
    end
  end

  defp hydrate_slack_bot_identity_backfill_object(%{key: key}, prefix)
       when is_binary(key) do
    cond do
      not slack_bot_identity_backfill_key?(key, prefix) ->
        {:error,
         {:slack_bot_identity_backfill_connect_unavailable, key, :invalid_record_identity}}

      true ->
        case CasRecord.get(key) do
          {:ok, rec} when is_map(rec) ->
            if slack_bot_identity_backfill_record_matches_key?(rec, key) do
              {:ok, rec}
            else
              {:error,
               {:slack_bot_identity_backfill_connect_unavailable, key, :invalid_record_identity}}
            end

          {:error, reason} ->
            {:error, {:slack_bot_identity_backfill_connect_unavailable, key, reason}}
        end
    end
  end

  defp hydrate_slack_bot_identity_backfill_object(_object, _prefix) do
    {:error,
     {:slack_bot_identity_backfill_connect_unavailable, :invalid_key, :invalid_record_identity}}
  end

  defp slack_bot_identity_backfill_candidate?(rec) do
    rec["provider"] == "slack" and is_nil(rec["deleted_at"]) and
      is_nil(rec["disabled_at"]) and num(rec["oauth_completed_at"]) > 0 and
      trim(rec["bot_token"]) != "" and
      (trim(rec["bot_id"]) == "" or trim(rec["bot_user_id"]) == "" or
         trim(rec["bot_username"]) == "")
  end

  defp slack_bot_identity_backfill_next_cursor(_objects, true), do: nil

  defp slack_bot_identity_backfill_next_cursor(objects, false) do
    objects
    |> List.last()
    |> Map.fetch!(:key)
    |> then(
      &(@slack_bot_identity_backfill_cursor_prefix <> Base.url_encode64(&1, padding: false))
    )
  end

  defp decode_slack_bot_identity_backfill_cursor(nil, _prefix), do: {:ok, nil}
  defp decode_slack_bot_identity_backfill_cursor("", _prefix), do: {:ok, nil}

  defp decode_slack_bot_identity_backfill_cursor(
         @slack_bot_identity_backfill_cursor_prefix <> encoded,
         prefix
       ) do
    with {:ok, key} <- Base.url_decode64(encoded, padding: false),
         true <- slack_bot_identity_backfill_key?(key, prefix) do
      {:ok, key}
    else
      _ -> {:error, :invalid_slack_bot_identity_backfill_cursor}
    end
  end

  defp decode_slack_bot_identity_backfill_cursor(_cursor, _prefix),
    do: {:error, :invalid_slack_bot_identity_backfill_cursor}

  defp slack_bot_identity_backfill_key?(key, prefix) when is_binary(key),
    do: connect_record_key?(key, prefix)

  # Whether one listed object under the connect prefix is a connect RECORD and
  # not a folder marker or some other stray object sharing the prefix.
  defp connect_record_key?(key, prefix) when is_binary(key) do
    if String.starts_with?(key, prefix) do
      case String.replace_prefix(key, prefix, "") |> String.split("/") do
        [group_id, connect_file] ->
          group_id != "" and connect_file not in ["", ".json"] and
            String.ends_with?(connect_file, ".json")

        _ ->
          false
      end
    else
      false
    end
  end

  defp slack_bot_identity_backfill_record_matches_key?(rec, key) do
    group_id = trim(rec["group_id"])
    connect_id = trim(rec["connect_id"])

    group_id != "" and connect_id != "" and Keys.ctl_im_connect(group_id, connect_id) == key
  end

  defp continuation?(value), do: is_binary(value) and value != ""

  @doc """
  Establishes a `connect_generation` on every ACTIVE Slack connect lacking one.

  Operator-invoked once per environment: the writer only establishes a
  generation on records it happens to write, so connects provisioned before the
  fence and untouched since stay bare until this runs. Idempotent — a record
  that already carries a valid ULID generation is never written, and deleted
  records are skipped so a tombstone's retired epoch is never resurrected.

  Options:

    * `:dry_run` — defaults to `true`. A dry run reports what a real run would
      establish and writes nothing.

  Returns `{:ok, summary}` where `summary` counts `:scanned` objects,
  `:slack` connect records among them, `:already_generation`,
  `:skipped_deleted`, and `:established` (would-establish under `dry_run`),
  plus an `:errors` list of `%{key: key, reason: reason}` for records that
  could not be read or written. Listing failures abort with `{:error, reason}`.
  """
  def backfill_slack_connect_generations(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :dry_run, true) do
      dry_run? when is_boolean(dry_run?) ->
        summary = %{
          dry_run: dry_run?,
          scanned: 0,
          slack: 0,
          already_generation: 0,
          skipped_deleted: 0,
          established: 0,
          errors: []
        }

        scan_slack_connect_generation_backfill(
          Keys.ctl_im_connects_all_prefix(),
          nil,
          summary,
          dry_run?
        )

      _invalid ->
        {:error, :invalid_slack_generation_backfill_options}
    end
  end

  defp scan_slack_connect_generation_backfill(prefix, start_after, summary, dry_run?) do
    with {:ok, %{objects: objects, next: next}} <-
           slack_connect_generation_backfill_page(prefix, start_after) do
      summary =
        Enum.reduce(
          objects,
          summary,
          &backfill_slack_connect_generation(&1, &2, prefix, dry_run?)
        )

      if continuation?(next) do
        scan_slack_connect_generation_backfill(
          prefix,
          objects |> List.last() |> Map.fetch!(:key),
          summary,
          dry_run?
        )
      else
        {:ok, %{summary | errors: Enum.reverse(summary.errors)}}
      end
    end
  end

  defp slack_connect_generation_backfill_page(prefix, start_after) do
    opts = [max_keys: @slack_generation_backfill_page_max] |> maybe_start_after(start_after)

    with {:ok, %{objects: objects, next: next}} when is_list(objects) <- S3.list(prefix, opts),
         :ok <- validate_slack_connect_generation_backfill_page(objects, start_after, next) do
      {:ok, %{objects: objects, next: next}}
    else
      {:error, reason} -> {:error, {:slack_generation_backfill_list_failed, reason}}
      other -> {:error, {:slack_generation_backfill_list_failed, other}}
    end
  end

  # Keys must strictly advance past `start_after`, or a paged scan of a large
  # prefix could loop forever on a backend that ignores the continuation.
  defp validate_slack_connect_generation_backfill_page(objects, start_after, next) do
    keys = Enum.map(objects, &Map.get(&1, :key))

    valid? =
      Enum.all?(keys, &is_binary/1) and keys == Enum.sort(keys) and keys == Enum.uniq(keys) and
        (is_nil(start_after) or Enum.all?(keys, &(&1 > start_after))) and
        not (objects == [] and continuation?(next))

    if valid?, do: :ok, else: {:error, :invalid_slack_generation_backfill_page}
  end

  defp backfill_slack_connect_generation(%{key: key}, summary, prefix, dry_run?)
       when is_binary(key) do
    summary = Map.update!(summary, :scanned, &(&1 + 1))

    if connect_record_key?(key, prefix) do
      case CasRecord.get(key) do
        {:ok, rec} when is_map(rec) ->
          classify_slack_connect_generation_backfill(key, rec, summary, dry_run?)

        {:error, reason} ->
          record_slack_generation_backfill_error(summary, key, reason)
      end
    else
      summary
    end
  end

  defp backfill_slack_connect_generation(_object, summary, _prefix, _dry_run?),
    do: Map.update!(summary, :scanned, &(&1 + 1))

  defp classify_slack_connect_generation_backfill(key, rec, summary, dry_run?) do
    if rec["provider"] == "slack" do
      summary = Map.update!(summary, :slack, &(&1 + 1))

      cond do
        not is_nil(rec["deleted_at"]) ->
          Map.update!(summary, :skipped_deleted, &(&1 + 1))

        ULID.valid?(rec["connect_generation"]) ->
          Map.update!(summary, :already_generation, &(&1 + 1))

        dry_run? ->
          Map.update!(summary, :established, &(&1 + 1))

        true ->
          establish_backfilled_slack_connect_generation(key, summary)
      end
    else
      summary
    end
  end

  defp establish_backfilled_slack_connect_generation(key, summary) do
    SlackTriageChannelCutover.with_authority_write(fn ->
      update_existing(key, fn rec ->
        # Re-checked inside the CAS: the record read during the scan may have
        # gained a generation, or been deleted, since it was listed. The refusal
        # returns `{:unchanged, rec}` — the CAS primitive's abort — so no PUT is
        # issued at all. Returning `rec` here would still commit a same-body write
        # over whatever the concurrent writer just landed, which for a racing
        # delete means the backfill rewrites a tombstone it must never touch.
        if rec["provider"] == "slack" and is_nil(rec["deleted_at"]) and
             not ULID.valid?(rec["connect_generation"]) do
          rec
          |> establish_or_rotate_slack_triage_generation()
          |> Map.put("updated_at", now())
        else
          {:unchanged, rec}
        end
      end)
    end)
    |> case do
      {:ok, rec} ->
        # Deleted-ness is classified FIRST. `delete_im_connect/3` establishes a
        # generation on the tombstone it writes, so a record deleted between the
        # scan's read and this CAS comes back carrying BOTH `deleted_at` and a
        # valid generation. Checking the generation first would bucket that
        # tombstone as `established` and report work this backfill never did.
        cond do
          not is_nil(rec["deleted_at"]) ->
            Map.update!(summary, :skipped_deleted, &(&1 + 1))

          ULID.valid?(rec["connect_generation"]) ->
            Map.update!(summary, :established, &(&1 + 1))

          true ->
            record_slack_generation_backfill_error(summary, key, :generation_not_established)
        end

      {:error, reason} ->
        record_slack_generation_backfill_error(summary, key, reason)
    end
  end

  defp record_slack_generation_backfill_error(summary, key, reason),
    do: Map.update!(summary, :errors, &[%{key: key, reason: reason} | &1])

  def put_slack_bot_identity(connect, bot_id, bot_user_id, bot_username \\ "") do
    bot_id = trim(bot_id)
    bot_user_id = trim(bot_user_id)
    bot_username = trim(bot_username)

    if bot_id == "" or bot_user_id == "" do
      {:error, {:bad_request, "bot_id and bot_user_id are required"}}
    else
      SlackTriageChannelCutover.with_authority_write(fn ->
        key = Keys.ctl_im_connect(connect["group_id"], connect["connect_id"])
        expected_token = trim(connect["bot_token"])
        now = now()

        update_existing(key, fn rec ->
          if rec["provider"] == "slack" and is_nil(rec["deleted_at"]) and
               trim(rec["bot_token"]) == expected_token do
            # `bot_id`/`bot_user_id` are Triage-authority members, so a non-no-op
            # rewrite must retire every captured authority pin: the reply-settlement
            # model proves no-ABA only on a monotone epoch, and without this a
            # B_ONE -> B_TWO -> B_ONE rewrite would leave the generation untouched
            # and let an old captured authority re-verify field-for-field. The
            # common identity backfill / OAuth-reuse re-write carries the same
            # values and stays generation-stable, so in-flight callbacks are not
            # invalidated by a no-op; `bot_username` is presentation only and
            # never rotates.
            rec =
              if trim(rec["bot_id"]) == bot_id and trim(rec["bot_user_id"]) == bot_user_id,
                do: rec,
                else: establish_or_rotate_slack_triage_generation(rec)

            rec
            |> Map.put("bot_id", bot_id)
            |> Map.put("bot_user_id", bot_user_id)
            |> maybe_put_nonblank("bot_username", bot_username)
            |> Map.put("bot_identity_resolved_at", now)
            |> Map.put("updated_at", now)
          else
            rec
          end
        end)
        |> case do
          {:ok, %{"bot_id" => ^bot_id} = rec} -> {:ok, slack_connect_public(rec)}
          {:ok, _rec} -> {:error, :stale_connect}
          other -> other
        end
      end)
    end
  end

  @doc "Record that this Feishu bot has joined a group thread."
  def record_feishu_thread_participation(connect, chat_id, thread_id)
      when is_map(connect) do
    group_id = trim(connect["group_id"])
    connect_id = trim(connect["connect_id"])
    chat_id = trim(chat_id)
    thread_id = trim(thread_id)

    with :ok <- require_thread_participation_identity(group_id, connect_id, chat_id, thread_id) do
      key = Keys.ctl_im_feishu_thread_participation(group_id, connect_id, chat_id, thread_id)
      timestamp = now()

      record = %{
        "group_id" => group_id,
        "connect_id" => connect_id,
        "chat_id" => chat_id,
        "thread_id" => thread_id,
        "created_at" => timestamp,
        "last_active_at" => timestamp,
        "expires_at" => timestamp + feishu_thread_participation_ttl_ms()
      }

      case CasRecord.create(key, record) do
        {:ok, _record} ->
          :ok

        {:error, :exists} ->
          touch_feishu_thread_participation(key, record)

        {:error, _} = error ->
          error
      end
    end
  end

  @doc "Return true only for an unexpired Feishu bot-participated thread."
  def feishu_thread_participating?(connect, chat_id, thread_id) when is_map(connect) do
    group_id = trim(connect["group_id"])
    connect_id = trim(connect["connect_id"])
    chat_id = trim(chat_id)
    thread_id = trim(thread_id)

    with :ok <- require_thread_participation_identity(group_id, connect_id, chat_id, thread_id),
         key <- Keys.ctl_im_feishu_thread_participation(group_id, connect_id, chat_id, thread_id),
         true <- feishu_thread_participation_active?(connect, chat_id, thread_id) do
      _ =
        touch_feishu_thread_participation(key, %{
          "last_active_at" => now(),
          "expires_at" => now() + feishu_thread_participation_ttl_ms()
        })

      true
    else
      false -> false
      {:error, _reason} -> false
    end
  end

  @doc "Read an unexpired Feishu participation marker without extending its TTL."
  def feishu_thread_participation_active?(connect, chat_id, thread_id) when is_map(connect) do
    group_id = trim(connect["group_id"])
    connect_id = trim(connect["connect_id"])
    chat_id = trim(chat_id)
    thread_id = trim(thread_id)

    with :ok <- require_thread_participation_identity(group_id, connect_id, chat_id, thread_id),
         key <- Keys.ctl_im_feishu_thread_participation(group_id, connect_id, chat_id, thread_id),
         {:ok, record} <- CasRecord.get(key),
         true <- num(record["expires_at"]) > now(),
         true <- record["group_id"] == group_id and record["connect_id"] == connect_id,
         true <- record["chat_id"] == chat_id and record["thread_id"] == thread_id do
      true
    else
      false -> false
      {:error, :not_found} -> false
      {:error, _reason} -> false
    end
  end

  defp touch_feishu_thread_participation(key, updates) do
    update_existing(key, fn current ->
      current
      |> Map.put("last_active_at", updates["last_active_at"])
      |> Map.put("expires_at", updates["expires_at"])
    end)
    |> case do
      {:ok, _record} -> :ok
      {:error, _} = error -> error
    end
  end

  defp require_thread_participation_identity(group_id, connect_id, chat_id, thread_id) do
    if Enum.all?([group_id, connect_id, chat_id, thread_id], &(&1 != "")),
      do: :ok,
      else: {:error, :invalid_feishu_thread_participation}
  end

  defp feishu_thread_participation_ttl_ms do
    Application.get_env(:salix_im, :feishu_thread_participation_ttl_seconds, 30 * 24 * 60 * 60) *
      1_000
  end

  def find_active_im_connect_by_id(connect_id) do
    connect_id = trim(connect_id)

    with {:ok, records} <- scan_connect_records(Keys.ctl_im_connects_all_prefix()) do
      records
      |> Enum.find(fn rec ->
        rec["connect_id"] == connect_id and is_nil(rec["deleted_at"]) and
          is_nil(rec["disabled_at"])
      end)
      |> case do
        nil -> {:error, :not_found}
        rec -> {:ok, rec}
      end
    end
  end

  defp resolve_slack_triage_recovery_authority_page(requested, cursor) do
    prefix = Keys.ctl_im_connects_all_prefix()

    with {:ok, start_after} <- decode_slack_triage_recovery_cursor(cursor, prefix),
         opts <- [max_keys: @active_connect_lookup_max_keys] |> maybe_start_after(start_after),
         {:ok, %{objects: objects, next: next}} <- S3.list(prefix, opts),
         :ok <- validate_slack_triage_recovery_objects(objects, start_after, next, prefix),
         page <- collect_slack_triage_recovery_authorities(objects, requested),
         {:ok, next_cursor} <-
           next_slack_triage_recovery_cursor(objects, next, @slack_triage_recovery_cursor_prefix) do
      {:ok,
       Map.merge(page, %{
         next_cursor: next_cursor,
         scan_complete: is_nil(next)
       })}
    else
      {:error, :invalid_slack_triage_recovery_cursor} = error -> error
      {:error, _reason} -> {:error, :slack_triage_authority_unavailable}
      _invalid -> {:error, :slack_triage_authority_unavailable}
    end
  end

  defp resolve_slack_triage_recovery_authority_ref_page(requested, cursor) do
    prefix = Keys.ctl_im_connects_all_prefix()

    with {:ok, start_after} <- decode_slack_triage_recovery_cursor(cursor, prefix),
         opts <- [max_keys: @active_connect_lookup_max_keys] |> maybe_start_after(start_after),
         {:ok, %{objects: objects, next: next}} <- S3.list(prefix, opts),
         :ok <- validate_slack_triage_recovery_objects(objects, start_after, next, prefix),
         page <- collect_slack_triage_recovery_authority_refs(objects, requested),
         {:ok, next_cursor} <-
           next_slack_triage_recovery_cursor(objects, next, @slack_triage_recovery_cursor_prefix) do
      {:ok,
       Map.merge(page, %{
         next_cursor: next_cursor,
         scan_complete: is_nil(next)
       })}
    else
      {:error, :invalid_slack_triage_recovery_cursor} = error -> error
      {:error, _reason} -> {:error, :slack_triage_authority_unavailable}
      _invalid -> {:error, :slack_triage_authority_unavailable}
    end
  end

  defp collect_slack_triage_recovery_authority_refs(objects, requested) do
    initial = %{
      authorities: %{},
      seen_connect_ids: MapSet.new(),
      unavailable_connect_ids: MapSet.new()
    }

    Enum.reduce(objects, initial, fn %{key: key}, acc ->
      connect_id = connect_id_from_key(key)

      if Map.has_key?(requested, connect_id) do
        if MapSet.member?(acc.seen_connect_ids, connect_id) do
          acc
          |> drop_recovery_authority_refs(connect_id)
          |> update_in([:unavailable_connect_ids], &MapSet.put(&1, connect_id))
        else
          acc
          |> update_in([:seen_connect_ids], &MapSet.put(&1, connect_id))
          |> resolve_recovery_authority_ref_record(connect_id, requested[connect_id], key)
        end
      else
        acc
      end
    end)
    |> then(fn page ->
      %{
        authorities: page.authorities,
        seen_connect_ids: page.seen_connect_ids |> MapSet.to_list() |> Enum.sort(),
        unavailable_connect_ids: page.unavailable_connect_ids |> MapSet.to_list() |> Enum.sort()
      }
    end)
  end

  defp resolve_recovery_authority_ref_record(acc, connect_id, channel_ids, key) do
    with {:ok, record} <- CasRecord.get(key),
         true <- record["connect_id"] == connect_id,
         true <- canonical_nonblank?(record["tenant_id"]),
         true <- canonical_nonblank?(record["group_id"]),
         true <- key == Keys.ctl_im_connect(record["group_id"], connect_id) do
      Enum.reduce_while(channel_ids, acc, fn channel_id, current ->
        case get_slack_triage_authority(
               record["tenant_id"],
               record["group_id"],
               connect_id,
               channel_id
             ) do
          {:ok, authority} ->
            {:cont, put_in(current, [:authorities, {connect_id, channel_id}], authority)}

          {:error, :slack_triage_authority_unavailable} ->
            {:halt,
             current
             |> drop_recovery_authority_refs(connect_id)
             |> update_in([:unavailable_connect_ids], &MapSet.put(&1, connect_id))}

          {:error, _inactive} ->
            {:cont, current}
        end
      end)
    else
      _invalid_or_unavailable ->
        acc
        |> drop_recovery_authority_refs(connect_id)
        |> update_in([:unavailable_connect_ids], &MapSet.put(&1, connect_id))
    end
  end

  defp drop_recovery_authority_refs(acc, connect_id) do
    update_in(acc, [:authorities], fn authorities ->
      Map.reject(authorities, fn {{candidate, _channel_id}, _authority} ->
        candidate == connect_id
      end)
    end)
  end

  defp collect_slack_triage_recovery_authorities(objects, requested) do
    initial = %{
      authorities: %{},
      seen_connect_ids: MapSet.new(),
      unavailable_connect_ids: MapSet.new()
    }

    Enum.reduce(objects, initial, fn %{key: key}, acc ->
      connect_id = connect_id_from_key(key)

      if MapSet.member?(requested, connect_id) do
        collect_slack_triage_recovery_authority(connect_id, key, acc)
      else
        acc
      end
    end)
    |> then(fn page ->
      %{
        authorities: page.authorities,
        seen_connect_ids: page.seen_connect_ids |> MapSet.to_list() |> Enum.sort(),
        unavailable_connect_ids: page.unavailable_connect_ids |> MapSet.to_list() |> Enum.sort()
      }
    end)
  end

  defp collect_slack_triage_recovery_authority(connect_id, key, acc) do
    if MapSet.member?(acc.seen_connect_ids, connect_id) do
      acc
      |> update_in([:authorities], &Map.delete(&1, connect_id))
      |> update_in([:unavailable_connect_ids], &MapSet.put(&1, connect_id))
    else
      acc
      |> update_in([:seen_connect_ids], &MapSet.put(&1, connect_id))
      |> resolve_recovery_authority_record(connect_id, key)
    end
  end

  defp resolve_recovery_authority_record(acc, connect_id, key) do
    with {:ok, record} <- CasRecord.get(key),
         true <- record["connect_id"] == connect_id,
         true <- canonical_nonblank?(record["tenant_id"]),
         true <- canonical_nonblank?(record["group_id"]),
         true <- key == Keys.ctl_im_connect(record["group_id"], connect_id) do
      case get_slack_triage_authority(
             record["tenant_id"],
             record["group_id"],
             connect_id
           ) do
        {:ok, authority} ->
          put_in(acc, [:authorities, connect_id], authority)

        {:error, :slack_triage_authority_unavailable} ->
          update_in(acc, [:unavailable_connect_ids], &MapSet.put(&1, connect_id))

        {:error, _inactive} ->
          acc
      end
    else
      _invalid_or_unavailable ->
        update_in(acc, [:unavailable_connect_ids], &MapSet.put(&1, connect_id))
    end
  end

  defp decode_slack_triage_recovery_cursor(nil, _prefix), do: {:ok, nil}

  defp decode_slack_triage_recovery_cursor(
         @slack_triage_recovery_cursor_prefix <> encoded,
         prefix
       ) do
    with {:ok, key} <- Base.url_decode64(encoded, padding: false),
         true <- valid_slack_triage_recovery_cursor_key?(key, prefix) do
      {:ok, key}
    else
      _invalid -> {:error, :invalid_slack_triage_recovery_cursor}
    end
  end

  defp decode_slack_triage_recovery_cursor(_cursor, _prefix),
    do: {:error, :invalid_slack_triage_recovery_cursor}

  defp validate_slack_triage_recovery_objects(objects, start_after, next, prefix)
       when is_list(objects) do
    keys = Enum.map(objects, &Map.get(&1, :key))

    valid? =
      Enum.all?(keys, &valid_slack_triage_recovery_cursor_key?(&1, prefix)) and
        keys == Enum.sort(keys) and keys == Enum.uniq(keys) and
        (is_nil(start_after) or Enum.all?(keys, &(&1 > start_after))) and
        not (objects == [] and not is_nil(next))

    if valid?, do: :ok, else: {:error, :invalid_slack_triage_recovery_page}
  end

  defp validate_slack_triage_recovery_objects(_objects, _start_after, _next, _prefix),
    do: {:error, :invalid_slack_triage_recovery_page}

  # The recovery cursor is an opaque raw S3 key. Any listed object under the
  # connect prefix — including a folder marker at exactly the prefix or a
  # malformed/trailing-space key — must remain a valid cursor position, so
  # one poison object is skipped by the requested-id filter instead of
  # failing the page and pinning the authority scan forever.
  defp valid_slack_triage_recovery_cursor_key?(key, prefix) when is_binary(key),
    do: String.starts_with?(key, prefix)

  defp valid_slack_triage_recovery_cursor_key?(_key, _prefix), do: false

  defp next_slack_triage_recovery_cursor(_objects, nil, _cursor_prefix), do: {:ok, nil}

  defp next_slack_triage_recovery_cursor(objects, _continuation, cursor_prefix) do
    case List.last(objects) do
      %{key: key} -> {:ok, cursor_prefix <> Base.url_encode64(key, padding: false)}
      _missing -> {:error, :invalid_slack_triage_recovery_page}
    end
  end

  defp maybe_start_after(opts, nil), do: opts
  defp maybe_start_after(opts, key), do: Keyword.put(opts, :start_after, key)

  @doc "Resolve configured connect ids with one bounded scan, never one global scan per id."
  def find_active_im_connects_by_ids(connect_ids, provider \\ nil) do
    requested =
      connect_ids
      |> List.wrap()
      |> Enum.map(&trim/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    if MapSet.size(requested) == 0 do
      {:ok, %{}}
    else
      case S3.list(Keys.ctl_im_connects_all_prefix(), max_keys: @active_connect_lookup_max_keys) do
        {:ok, %{objects: objects, next: next}} ->
          with {:ok, seen, active} <- collect_requested_connects(objects, requested, provider) do
            unresolved = MapSet.difference(requested, seen)

            if next && MapSet.size(unresolved) > 0,
              do: {:error, :active_connect_lookup_limit_exceeded},
              else: {:ok, active}
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp collect_requested_connects(objects, requested, provider) do
    Enum.reduce_while(objects, {:ok, MapSet.new(), %{}}, fn object, {:ok, seen, active} ->
      connect_id = connect_id_from_key(object.key)

      if MapSet.member?(requested, connect_id) do
        case CasRecord.get(object.key) do
          {:ok, rec} ->
            cond do
              trim(rec["connect_id"]) != connect_id ->
                {:halt, {:error, :invalid_connect_record}}

              MapSet.member?(seen, connect_id) ->
                {:halt, {:error, :duplicate_connect_id}}

              rec["deleted_at"] || rec["disabled_at"] ||
                  (not blank?(provider) and rec["provider"] != provider) ->
                {:cont, {:ok, MapSet.put(seen, connect_id), active}}

              true ->
                {:cont, {:ok, MapSet.put(seen, connect_id), Map.put(active, connect_id, rec)}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      else
        {:cont, {:ok, seen, active}}
      end
    end)
  end

  defp scan_connect_records(prefix) do
    with {:ok, %{objects: objects, next: nil}}
         when length(objects) <= @connect_scan_max_records <-
           S3.list(prefix, max_keys: @connect_scan_max_records) do
      Enum.reduce_while(objects, {:ok, []}, fn %{key: key}, {:ok, records} ->
        case CasRecord.get(key, :invalid_connect_record) do
          {:ok, record} -> {:cont, {:ok, [record | records]}}
          {:error, reason} -> {:halt, {:error, {:connect_record_unavailable, key, reason}}}
        end
      end)
      |> then(fn
        {:ok, records} -> {:ok, Enum.reverse(records)}
        error -> error
      end)
    else
      {:ok, %{next: _continuation}} -> {:error, :connect_scan_limit_exceeded}
      {:error, _reason} = error -> error
      other -> {:error, {:connect_scan_failed, other}}
    end
  end

  defp connect_id_from_key(key) do
    key
    |> String.split("/")
    |> List.last()
    |> to_string()
    |> String.trim_trailing(".json")
  end

  # ---- provider inbound router session ----

  def agent_group_router_session_id(router_agent_id, group_id) do
    with {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, router_agent} <- GroupDirectory.get_agent(router_agent_id),
         :ok <- ensure_group_router_agent(group, router_agent) do
      SalixStore.RuntimeIds.persisted_router_session_id(router_agent)
    end
  end

  defp ensure_group_router_agent(group, router_agent) do
    cond do
      trim(router_agent["agent_id"]) == "" ->
        {:error, :router_agent_id_required}

      trim(router_agent["role"]) != "router" ->
        {:error, :not_group_router_agent}

      trim(group["router_agent_id"]) != trim(router_agent["agent_id"]) ->
        {:error, :not_group_router_agent}

      true ->
        :ok
    end
  end

  @doc false
  def validate_group_router(group_id) do
    with {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, _router} <- resolve_group_router_agent(group),
         do: :ok
  end

  def enqueue_group_router_im_provider_message(
        group_id,
        content,
        metadata,
        source_message_id,
        opts \\ []
      ) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id),
         :ok <-
           validate_required_attrs(
             %{"source_message_id" => source_message_id},
             ["source_message_id"]
           ),
         # A `<salix-command>` block in what the SENDER TYPED is an instruction
         # to Salix, not agent input. Interception is here — the single funnel
         # every provider inbound crosses — so no provider can deliver such a
         # message as a prompt, and none can both execute and deliver it.
         #
         # It reads `opts[:command_text]` and never `content`: `content` is
         # Salix-composed and interpolates provider-supplied names (a Slack
         # display name, a new channel's name, a meeting summary), so scanning
         # it would let anyone who can pick a display name run commands on
         # every message they send. `:command_text` is a per-provider GRANT,
         # not merely "the text" — an ingress path passes it only for a human
         # message that addressed the bot and is not a receipt replay, and a
         # path that passes none cannot produce a command at all.
         :none <-
           SalixIM.ControlCommand.intercept(
             group_id,
             Keyword.get(opts, :command_text),
             metadata,
             replayed?: Keyword.get(opts, :command_replayed?, false)
           ) do
      deliver_router_provider_message(group_id, content, metadata, source_message_id, opts)
    end
  end

  defp deliver_router_provider_message(
         group_id,
         content,
         metadata,
         source_message_id,
         opts
       ) do
    with {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, router_agent} <- resolve_group_router_agent(group),
         {:ok, staged_attachments, failed_attachments} <-
           ProviderAttachments.stage(
             router_agent["agent_id"],
             Keyword.get(opts, :attachments, [])
           ),
         {:ok, delivery} <-
           SalixIM.AgentDeliveryPayload.provider_router_delivery(
             group,
             router_agent,
             content,
             metadata,
             Keyword.put(opts, :source_message_id, source_message_id)
           ) do
      agent_id = router_agent["agent_id"]

      pre_deliveries =
        opts
        |> Keyword.get(:pre_deliveries, [])
        |> List.wrap()
        |> Enum.filter(&is_map/1)

      model_content =
        router_model_content(delivery["content"], staged_attachments, failed_attachments)

      payload =
        %{
          content: model_content.content,
          trusted_attachment_refs: model_content.trusted_attachment_refs,
          session_id: get_in(delivery, ["participant_payload", "session_id"]),
          name: delivery["delivery_session_name"],
          billing_context: delivery["delivery_billing_context"],
          provider_reply_obligation: delivery["provider_reply_obligation"],
          trusted_origin: delivery["trusted_origin"],
          source_sent_at_ms: delivery["source_sent_at_ms"],
          # Provider messages are user input. The canonical role is required
          # by external-runtime admission (an external ROUTER is a legal
          # control-plane combination), and harmless for internal targets
          # (#870 review round 3).
          role: "user",
          no_wake: context_only_router_input?(metadata),
          pre_deliveries: if(pre_deliveries == [], do: nil, else: pre_deliveries)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" or value == %{} end)
        |> Map.new()

      case SalixIM.RouterConversationInput.append_provider_input(
             group_id,
             source_message_id,
             payload,
             metadata
           ) do
        {:ok, _status} ->
          SalixIM.PrivateChatStatus.record_inbound(
            group_id,
            metadata,
            source_message_id,
            agent_id,
            Map.get(payload, :session_id)
          )

          {:ok, :queued}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp context_only_router_input?(metadata) do
    metadata["router_activation_mode"] == "context_only" and
      (metadata["event_type"] == "meeting.completed" or metadata["provider"] == "api")
  end

  defp resolve_group_router_agent(group) do
    case trim(group["router_agent_id"]) do
      "" ->
        {:error, :router_not_configured}

      agent_id ->
        with {:ok, router_agent} <- GroupDirectory.get_agent(agent_id),
             :ok <- ensure_group_router_agent(group, router_agent) do
          {:ok, router_agent}
        end
    end
  end

  defp router_model_content(content, staged_attachments, failed_attachments) do
    blocks =
      ProviderConversationInput.content_with_attachments(
        staged_attachments,
        content,
        failed_attachments
      )

    refs = Enum.filter(blocks, &(&1["type"] in ["file", "image"]))

    %{
      content:
        if(refs == [] and failed_attachments == [], do: content, else: Jason.encode!(blocks)),
      trusted_attachment_refs: if(refs == [], do: nil, else: refs)
    }
  end

  defp resolve_slack_inbound_agent(group, attrs, current \\ %{}) do
    inbound_agent_id =
      attrs
      |> Map.get("inbound_agent_id")
      |> nonblank(nonblank(current["inbound_agent_id"], group["router_agent_id"]))
      |> trim()

    cond do
      inbound_agent_id == "" ->
        {:error, {:bad_request, "inbound_agent_id is required"}}

      true ->
        with {:ok, agent} <- GroupDirectory.get_agent(inbound_agent_id),
             :ok <- validate_slack_inbound_agent(group, agent) do
          {:ok, agent}
        else
          {:error, :not_found} ->
            {:error, {:bad_request, "inbound_agent_id is not a group agent"}}

          {:error, {:bad_request, _}} = error ->
            error

          other ->
            other
        end
    end
  end

  defp validate_slack_inbound_agent(group, agent) do
    cond do
      trim(agent["group_id"]) != trim(group["group_id"]) ->
        {:error, {:bad_request, "inbound_agent_id is not a group agent"}}

      trim(agent["role"]) not in ["router", "worker"] ->
        {:error, {:bad_request, "inbound agent role must be router or worker"}}

      trim(agent["role"]) == "router" and trim(group["router_agent_id"]) == "" ->
        {:error, :router_not_configured}

      trim(agent["role"]) == "router" and
          trim(agent["agent_id"]) != trim(group["router_agent_id"]) ->
        {:error, {:bad_request, "router inbound agent must be the group router"}}

      true ->
        :ok
    end
  end

  def resolve_im_connect_inbound_agent(connect, attrs \\ %{})

  def resolve_im_connect_inbound_agent(%{"provider" => "slack"} = connect, attrs) do
    with {:ok, group} <- GroupDirectory.get_group(connect["group_id"]),
         {:ok, agent} <- resolve_slack_thread_or_connect_agent(group, connect, attrs) do
      {:ok, agent}
    end
  end

  def resolve_im_connect_inbound_agent(_connect, _attrs), do: {:error, :unsupported_provider}

  defp resolve_slack_thread_or_connect_agent(group, connect, attrs) do
    channel_id = trim(attrs["channel_id"])
    thread_ts = trim(attrs["thread_ts"])

    if channel_id != "" and thread_ts != "" do
      case SlackConversationIngress.get_thread_binding(
             group["group_id"],
             connect["connect_id"],
             channel_id,
             thread_ts
           ) do
        {:ok, binding} ->
          if SlackConversationIngress.task_thread_binding_record?(binding),
            do: resolve_slack_inbound_agent(group, %{}, connect),
            else: resolve_bound_slack_worker(group, binding)

        {:error, :not_found} ->
          resolve_slack_inbound_agent(group, %{}, connect)

        {:error, _} = error ->
          error
      end
    else
      resolve_slack_inbound_agent(group, %{}, connect)
    end
  end

  defp resolve_bound_slack_worker(group, binding) do
    with {:ok, agent} <- GroupDirectory.get_agent(binding["worker_agent_id"]),
         :ok <- validate_slack_inbound_agent(group, agent),
         true <- trim(agent["role"]) == "worker" do
      {:ok, agent}
    else
      false -> {:error, :invalid_slack_thread_binding}
      {:error, :not_found} -> {:error, :slack_thread_worker_not_found}
      {:error, _} = error -> error
    end
  end

  def update_wechat_im_context(group_id, connect_id, context_token, event_id) do
    context_token = trim(context_token)

    if context_token == "" do
      :ok
    else
      update_existing(Keys.ctl_im_connect(group_id, connect_id), fn rec ->
        rec
        |> Map.put("latest_context_token", context_token)
        |> Map.put("latest_context_message_id", trim(event_id))
        |> Map.put("updated_at", now())
      end)
      |> case do
        {:ok, _} -> :ok
        other -> other
      end
    end
  end

  # The IM Connect owns unfinished polling work. Revision comparisons and the
  # pending head share one CAS object; a lease only reduces duplicate requests.
  # Never truncate a provider batch and then acknowledge its next cursor.
  def admit_wechat_poll(connect, messages, next_cursor) do
    pending = %{"messages" => messages, "next_cursor" => next_cursor}

    if is_list(messages) and length(messages) <= 100 and
         Enum.all?(messages, &is_map/1) and
         byte_size(Jason.encode!(pending)) <= 1_048_576 do
      update_wechat_poll(connect, fn current ->
        cond do
          is_map(current["pending_wechat_poll"]) ->
            {:unchanged, current}

          wechat_poll_revision(current) != wechat_poll_revision(connect) or
              current["updates_buf"] != connect["updates_buf"] ->
            {:error, :stale_wechat_poll}

          true ->
            current
            |> Map.put("wechat_poll_revision", wechat_poll_revision(current) + 1)
            |> Map.put("pending_wechat_poll", pending)
        end
      end)
    else
      {:error, :wechat_poll_batch_limit}
    end
  end

  def advance_wechat_poll(connect, context_token, event_id) do
    update_wechat_poll(connect, fn current ->
      if wechat_poll_revision(current) == wechat_poll_revision(connect) and
           is_map(current["pending_wechat_poll"]) do
        pending = current["pending_wechat_poll"]
        remaining = Enum.drop(pending["messages"], 1)

        current =
          current
          |> Map.put("wechat_poll_revision", wechat_poll_revision(current) + 1)
          |> Map.put("updated_at", now())

        current =
          if trim(context_token) == "" do
            current
          else
            current
            |> Map.put("latest_context_token", trim(context_token))
            |> Map.put("latest_context_message_id", trim(event_id))
          end

        if remaining == [] do
          current
          |> Map.put("updates_buf", pending["next_cursor"])
          |> Map.delete("pending_wechat_poll")
        else
          Map.put(current, "pending_wechat_poll", %{pending | "messages" => remaining})
        end
      else
        {:error, :stale_wechat_poll}
      end
    end)
  end

  def prepare_wechat_poll(connect, revision, context_token, event_id) do
    update_wechat_poll(connect, fn current ->
      if wechat_poll_revision(current) == revision and is_map(current["pending_wechat_poll"]) do
        if trim(context_token) == "" do
          {:unchanged, current}
        else
          current
          |> Map.put("latest_context_token", trim(context_token))
          |> Map.put("latest_context_message_id", trim(event_id))
        end
      else
        {:error, :stale_wechat_poll}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp wechat_poll_revision(connect), do: connect["wechat_poll_revision"] || 0

  defp update_wechat_poll(connect, fun) do
    update_existing(Keys.ctl_im_connect(connect["group_id"], connect["connect_id"]), fn current ->
      if current["provider"] == "wechat" and is_nil(current["deleted_at"]) and
           is_nil(current["disabled_at"]),
         do: fun.(current),
         else: {:error, :not_found}
    end)
  end

  def update_telegram_im_offset(group_id, connect_id, offset) do
    update_existing(Keys.ctl_im_connect(group_id, connect_id), fn rec ->
      rec
      |> Map.put("updates_offset", num(offset))
      |> Map.put("updated_at", now())
    end)
    |> case do
      {:ok, _} -> :ok
      other -> other
    end
  end

  def mark_im_connect_error(group_id, connect_id, message) do
    update_existing(Keys.ctl_im_connect(group_id, connect_id), fn rec ->
      rec
      |> Map.put("status", "error")
      |> Map.put("last_error", trim(message))
      |> Map.put("updated_at", now())
    end)
    |> case do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp update_existing(key, fun), do: CasRecord.update(key, fun, create: false)

  # ---- projection helpers ----

  defp tool_visible_connect?(%{"provider" => "slack"} = rec),
    do:
      trim(rec["workspace_id"]) != "" and trim(rec["bot_token"]) != "" and
        num(rec["oauth_completed_at"]) > 0

  defp tool_visible_connect?(%{"provider" => "telegram"} = rec),
    do:
      rec["status"] == "connected" and trim(rec["bot_token"]) != "" and
        (trim(rec["bot_user_id"]) != "" or trim(rec["bot_username"]) != "")

  defp tool_visible_connect?(%{"provider" => "imessage"} = rec),
    do: rec["status"] == "connected" and SalixIM.Provider.IMessage.current_relay?(rec)

  defp tool_visible_connect?(%{"provider" => "feishu"} = rec),
    do:
      rec["status"] == "connected" and trim(rec["app_id"]) != "" and
        feishu_tenant_app_configured?(rec)

  defp tool_visible_connect?(%{"provider" => "wechat"} = rec),
    do:
      rec["status"] == "connected" and trim(rec["wechat_id"]) != "" and
        trim(rec["token"]) != "" and trim(rec["base_url"]) != ""

  defp tool_visible_connect?(%{"provider" => "voice"} = rec), do: rec["status"] == "connected"
  defp tool_visible_connect?(%{"provider" => "signal"} = rec), do: rec["status"] == "connected"

  defp tool_visible_connect?(_), do: false

  defp tool_connect_visible_to_agent?(
         %{"provider" => "slack"} = rec,
         agent_id,
         router_agent_id,
         agent_role
       ) do
    bound_agent_id = trim(rec["inbound_agent_id"])
    effective_bound_agent_id = nonblank(bound_agent_id, router_agent_id)

    cond do
      agent_id == "" -> true
      effective_bound_agent_id == "" -> false
      effective_bound_agent_id != router_agent_id -> false
      # A router-bound Slack connect is the group's canonical Slack API
      # surface: the router owns it fully, and workers may reach it for the
      # provider's read-only operations (the dispatch fence rejects the rest).
      # Worker-bound connects stay ingress-only and tool-invisible.
      agent_role == "worker" -> true
      true -> agent_id == router_agent_id
    end
  end

  defp tool_connect_visible_to_agent?(_rec, agent_id, router_agent_id, _agent_role) do
    cond do
      agent_id == "" -> true
      router_agent_id == "" -> false
      true -> agent_id == router_agent_id
    end
  end

  defp tool_connect_summary(%{"provider" => "slack"} = rec) do
    %{
      "connect_id" => rec["connect_id"],
      "provider" => "slack",
      "workspace_id" => rec["workspace_id"],
      "workspace_name" => rec["workspace_name"] || "",
      "oauth_bot_scopes" => slack_scope_projection(rec)
    }
    |> put_optional_nonblank("enterprise_id", rec["enterprise_id"])
  end

  defp tool_connect_summary(%{"provider" => "telegram"} = rec) do
    %{
      "connect_id" => rec["connect_id"],
      "provider" => "telegram"
    }
    |> put_optional_nonblank("bot_user_id", rec["bot_user_id"])
    |> put_optional_nonblank("bot_username", rec["bot_username"])
  end

  defp tool_connect_summary(%{"provider" => "imessage"} = rec) do
    Map.take(rec, ["connect_id", "provider", "bot_user_id", "bot_display_name"])
  end

  defp tool_connect_summary(%{"provider" => "wechat"} = rec) do
    %{
      "connect_id" => rec["connect_id"],
      "provider" => "wechat"
    }
    |> put_optional_nonblank("wechat_id", rec["wechat_id"])
  end

  defp tool_connect_summary(%{"provider" => "feishu"} = rec) do
    %{
      "connect_id" => rec["connect_id"],
      "provider" => "feishu"
    }
    |> put_optional_nonblank("app_name", rec["app_name"])
    |> put_optional_nonblank("tenant_key", rec["tenant_key"])
  end

  defp tool_connect_summary(rec),
    do: %{"connect_id" => rec["connect_id"], "provider" => rec["provider"]}

  defp im_connect_public(%{"provider" => "slack"} = rec), do: slack_connect_public(rec)
  defp im_connect_public(%{"provider" => "feishu"} = rec), do: feishu_connect_public(rec)
  defp im_connect_public(%{"provider" => "voice"} = rec), do: SalixIM.VoiceConnects.public(rec)
  defp im_connect_public(%{"provider" => "signal"} = rec), do: SalixIM.SignalConnects.public(rec)

  defp im_connect_public(rec) do
    rec
    |> Map.take([
      "connect_id",
      "tenant_id",
      "group_id",
      "provider",
      "app_name",
      "app_id",
      "tenant_key",
      "client_id",
      "workspace_id",
      "workspace_name",
      "enterprise_id",
      "owner_user_id",
      "bot_user_id",
      "bot_username",
      "bot_display_name",
      "webhook_url",
      "status",
      "last_error",
      "connected_at",
      "disabled_at",
      "created_at",
      "updated_at"
    ])
    |> Map.put("bot_token_configured", trim(rec["bot_token"]) != "")
  end

  defp feishu_connect_public(rec) do
    app = feishu_tenant_app_for_connect(rec)

    rec
    |> Map.take([
      "connect_id",
      "tenant_id",
      "group_id",
      "provider",
      "app_name",
      "app_id",
      "tenant_key",
      "bot_open_id",
      "webhook_url",
      "status",
      "last_error",
      "connected_at",
      "disabled_at",
      "created_at",
      "updated_at"
    ])
    |> Map.put("app_secret_configured", trim(app["app_secret"]) != "")
    |> Map.put("verification_token_configured", trim(app["verification_token"]) != "")
    |> Map.put("encrypt_key_configured", trim(app["encrypt_key"]) != "")
  end

  defp slack_connect_public(rec) do
    rec
    |> Map.take([
      "connect_id",
      "tenant_id",
      "group_id",
      "provider",
      "app_name",
      "app_id",
      "client_id",
      "workspace_id",
      "workspace_name",
      "enterprise_id",
      "owner_user_id",
      "bot_id",
      "bot_user_id",
      "bot_username",
      "inbound_agent_id",
      "approved_channel_id",
      "approved_channel_name",
      "oauth_completed_at",
      "disabled_at",
      "created_at",
      "updated_at"
    ])
    |> Map.put("oauth_bot_scopes", slack_scope_projection(rec))
    |> Map.put("triage_enabled", rec["triage_enabled"] == true)
    |> Map.put("client_secret_configured", trim(rec["client_secret"]) != "")
    |> Map.put("signing_secret_configured", trim(rec["signing_secret"]) != "")
    |> Map.put("oauth_url", slack_oauth_url(rec))
  end

  defp slack_triage_authority_eligible?(rec, group, tenant_id) do
    rec["triage_enabled"] == true and slack_triage_authority_ready?(rec, group, tenant_id)
  end

  defp slack_triage_authority_ready?(rec, group, tenant_id) do
    slack_triage_connect_ready?(rec, group, tenant_id) and
      trim(rec["approved_channel_id"]) != ""
  end

  defp slack_triage_connect_ready?(rec, group, tenant_id) do
    rec["provider"] == "slack" and rec["tenant_id"] == tenant_id and
      rec["group_id"] == group["group_id"] and
      ULID.valid?(rec["connect_generation"]) and
      ULID.valid?(slack_triage_activation_generation(rec)) and
      trim(rec["workspace_id"]) != "" and trim(rec["app_id"]) != "" and
      trim(rec["bot_token"]) != "" and trim(rec["bot_user_id"]) != "" and
      trim(rec["bot_id"]) != "" and
      trim(rec["inbound_agent_id"]) == trim(group["router_agent_id"]) and
      is_integer(rec["oauth_completed_at"]) and rec["oauth_completed_at"] > 0 and
      is_nil(rec["disabled_at"]) and is_nil(rec["deleted_at"])
  end

  defp ensure_slack_triage_master_ready(rec, group, tenant_id) do
    if slack_triage_connect_ready?(rec, group, tenant_id) and provisioned?(rec) do
      ensure_slack_triage_master_authority(rec, group, tenant_id)
    else
      {:error, :slack_triage_authority_ineligible}
    end
  end

  # Before the fleet marker, S3 is the sole authority and prepared PostgreSQL
  # rows are deliberately dark. After the marker, PostgreSQL is the sole
  # authority and an empty, stale, incomplete, or unreadable projection can
  # never be repaired by falling back to the legacy channel.
  defp ensure_slack_triage_master_authority(rec, group, tenant_id) do
    case SlackTriageChannelCutover.mode() do
      :legacy ->
        if slack_triage_authority_ready?(rec, group, tenant_id),
          do: :ok,
          else: {:error, :slack_triage_authority_ineligible}

      :projected ->
        case SlackTriageChannels.list_page(tenant_id, rec["group_id"], rec["connect_id"]) do
          {:ok, %{channels: channels, scan_complete: true}} ->
            if Enum.any?(channels, &current_slack_triage_channel?(&1, rec)),
              do: :ok,
              else: {:error, :slack_triage_authority_ineligible}

          {:ok, _incomplete} ->
            {:error, :unavailable}

          {:error, _reason} ->
            {:error, :unavailable}
        end

      {:error, :unavailable} ->
        {:error, :unavailable}
    end
  end

  defp slack_triage_provisionable?(rec) do
    is_integer(rec["oauth_completed_at"]) and rec["oauth_completed_at"] > 0 and
      trim(rec["bot_token"]) != "" and trim(rec["workspace_id"]) != "" and
      is_nil(rec["disabled_at"]) and is_nil(rec["deleted_at"])
  end

  defp validate_slack_triage_channel(_rec, ""),
    do: {:error, {:bad_request, "approved_channel_id is required"}}

  # Returns the channel's display name alongside the validation verdict: the
  # call that proves the id is reachable is also the only place the name is
  # available, so capturing it here costs no extra Slack round trip.
  defp validate_slack_triage_channel(rec, approved_channel_id) do
    channel = SlackAPI.conversation_info(SlackAPI.installation(rec), approved_channel_id)

    if trim(channel["id"]) == approved_channel_id do
      {:ok, trim(channel["name"])}
    else
      {:error, {:bad_request, "approved_channel_id is not accessible in this Slack workspace"}}
    end
  rescue
    _error in [SlackAPI.Error, ArgumentError] ->
      {:error, {:bad_request, "approved_channel_id is not accessible in this Slack workspace"}}
  end

  defp slack_triage_authority(rec) do
    Map.take(rec, @slack_triage_authority_keys -- ["triage_enabled"])
    |> Map.put("connect_generation", legacy_slack_triage_generation(rec))
    |> Map.put("triage_enabled", true)
  end

  defp legacy_slack_triage_generation(rec) do
    case rec["triage_activation_generation"] do
      activation when is_binary(activation) ->
        ULID.derive("comma.slack-triage-legacy-authority.v1", [
          rec["connect_generation"],
          activation
        ])

      _legacy ->
        rec["connect_generation"]
    end
  end

  defp slack_triage_channel_authority(rec, channel) do
    legacy_generation = legacy_slack_triage_generation(rec)

    authority_generation =
      if channel["channel_generation"] == legacy_generation do
        legacy_generation
      else
        SlackTriageChannels.authority_generation(
          rec["connect_generation"],
          slack_triage_activation_generation(rec),
          channel["channel_generation"]
        )
      end

    rec
    |> slack_triage_authority()
    |> Map.put("approved_channel_id", channel["channel_id"])
    |> Map.put("connect_generation", authority_generation)
  end

  defp legacy_slack_triage_authority(rec, group, tenant_id, channel_id) do
    if slack_triage_authority_eligible?(rec, group, tenant_id) and
         trim(rec["approved_channel_id"]) == channel_id,
       do: {:ok, slack_triage_authority(rec)},
       else: {:error, :slack_triage_authority_ineligible}
  end

  defp projected_slack_triage_authority(rec, tenant_id, group_id, channel_id) do
    case SlackTriageChannels.get(tenant_id, group_id, trim(rec["connect_id"]), channel_id) do
      {:ok, channel} ->
        if current_slack_triage_channel?(channel, rec) and channel["enabled"] == true do
          {:ok, slack_triage_channel_authority(rec, channel)}
        else
          {:error, :slack_triage_authority_ineligible}
        end

      {:error, :not_found} ->
        {:error, :slack_triage_authority_ineligible}

      {:error, _reason} ->
        {:error, :slack_triage_authority_unavailable}
    end
  end

  defp expression_context_policy(rec, tenant_id, group_id, channel_id) do
    case SlackTriageChannelCutover.mode() do
      :legacy ->
        if provisioned?(rec) and trim(rec["approved_channel_id"]) == channel_id do
          {:ok,
           %{
             expression_mode: "project",
             authority_generation: legacy_slack_triage_generation(rec)
           }}
        else
          {:error, :slack_triage_authority_ineligible}
        end

      :projected ->
        case SlackTriageChannels.get(tenant_id, group_id, trim(rec["connect_id"]), channel_id) do
          {:ok, channel} ->
            cond do
              not current_slack_triage_channel?(channel, rec) or channel["enabled"] != true ->
                {:error, :slack_triage_authority_ineligible}

              channel["expression_mode"] not in @slack_triage_expression_modes ->
                {:error, :slack_triage_authority_unavailable}

              true ->
                {:ok,
                 %{
                   expression_mode: channel["expression_mode"],
                   authority_generation:
                     slack_triage_channel_authority(rec, channel)["connect_generation"]
                 }}
            end

          {:error, :not_found} ->
            {:error, :slack_triage_authority_ineligible}

          {:error, _reason} ->
            {:error, :slack_triage_authority_unavailable}
        end

      {:error, :unavailable} ->
        {:error, :slack_triage_authority_unavailable}
    end
  end

  defp verify_expression_context_generation(nil, _current_generation), do: :ok

  defp verify_expression_context_generation(expected_generation, current_generation) do
    if ULID.valid?(expected_generation) and expected_generation == current_generation,
      do: :ok,
      else: {:error, :slack_triage_authority_stale}
  end

  defp slack_emoji_catalog(tenant_id, connect) do
    case Slack.call(nil, tenant_id, connect, "slack.list_emoji", %{}) do
      {:ok, %{"emoji" => emoji}} when is_map(emoji) -> {:ok, emoji}
      _provider_failure -> {:error, :unavailable}
    end
  rescue
    _error in ArgumentError -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp current_slack_triage_channel?(channel, rec) do
    channel["installation_generation"] == rec["connect_generation"] and
      channel["workspace_id"] == rec["workspace_id"]
  end

  defp valid_expression_modes?(channels) do
    Enum.all?(channels, &(&1[:expression_mode] in @slack_triage_expression_modes))
  end

  defp slack_triage_activation_generation(rec),
    do: rec["triage_activation_generation"] || rec["connect_generation"]

  defp provisioned?(rec) do
    (is_integer(rec["triage_provisioned_at"]) and rec["triage_provisioned_at"] > 0) or
      trim(rec["approved_channel_id"]) != ""
  end

  defp exact_keys?(value, keys) when is_map(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp valid_slack_triage_authority_snapshot?(authority) do
    authority["provider"] == "slack" and authority["triage_enabled"] == true and
      is_integer(authority["oauth_completed_at"]) and authority["oauth_completed_at"] > 0 and
      ULID.valid?(authority["connect_generation"]) and
      Enum.all?(
        @slack_triage_authority_keys --
          ["connect_generation", "oauth_completed_at", "triage_enabled"],
        &canonical_nonblank?(authority[&1])
      )
  end

  defp canonical_nonblank?(value),
    do:
      is_binary(value) and value != "" and value == String.trim(value) and
        not String.contains?(value, <<0>>)

  @doc false
  def slack_oauth_url(rec) do
    scopes = SlackScopes.bot()

    scopes =
      if SalixIM.SlackCommands.list(rec) == [],
        do: scopes,
        else: Enum.uniq(scopes ++ ["commands"])

    URI.encode_query(%{
      "client_id" => trim(rec["client_id"]),
      "scope" => Enum.join(scopes, ","),
      "redirect_uri" => public_base_url() <> "/v1/im/slack/oauth/callback",
      "state" => trim(rec["oauth_state"])
    })
    |> then(&("https://slack.com/oauth/v2/authorize?" <> &1))
  end

  defp validate_telegram_bot_token(token) do
    token = trim(token)

    if token == "" do
      {:error, {:bad_request, "bot_token is required"}}
    else
      base =
        :salix_im
        |> Application.get_env(:telegram_api_base_url, "https://api.telegram.org")
        |> trim()
        |> default_base("https://api.telegram.org")

      case Req.get("#{base}/bot#{token}/getMe", retry: false) do
        {:ok, %{status: status, body: %{"ok" => true, "result" => bot}}}
        when status in 200..299 and is_map(bot) ->
          {:ok, bot}

        {:ok, %{body: %{"ok" => false, "description" => desc}}} ->
          {:error, {:bad_request, "Telegram getMe failed: #{desc}"}}

        {:ok, %{status: status}} ->
          {:error, {:bad_request, "Telegram getMe failed: HTTP #{status}"}}

        {:error, reason} ->
          {:error, {:bad_request, "Telegram getMe failed: #{inspect(reason)}"}}
      end
    end
  end

  # Feishu bot secrets live only in the tenant Feishu-app store. Connect records
  # carry app identity and webhook status; they never own app_secret,
  # verification_token, or encrypt_key.
  defp reject_feishu_connect_secrets(attrs) do
    case Enum.find(["app_secret", "verification_token", "encrypt_key"], &(trim(attrs[&1]) != "")) do
      nil ->
        :ok

      field ->
        {:error,
         {:bad_request,
          "#{field} is managed by the tenant Feishu app store and must not be sent to the Feishu connect API"}}
    end
  end

  defp resolve_feishu_bot_secrets(tenant_id, attrs) do
    app_id = trim(attrs["app_id"])

    cond do
      app_id == "" ->
        # Let validate_feishu_credentials/2 surface the "app_id is required" error.
        {:ok, attrs}

      true ->
        case tenant_feishu_app(tenant_id) do
          {:ok, app} ->
            case trim(app["app_id"]) do
              tenant_app_id when tenant_app_id in ["", app_id] ->
                {:ok,
                 attrs
                 |> Map.put("app_secret", trim(app["app_secret"]))
                 |> Map.put("verification_token", trim(app["verification_token"]))
                 |> Map.put("encrypt_key", trim(app["encrypt_key"]))}

              _other ->
                {:error,
                 {:bad_request,
                  "Feishu tenant app_id does not match the connect app_id. Update the tenant Feishu app first."}}
            end

          :none ->
            {:error,
             {:bad_request,
              "Feishu app secret is not configured. Configure the tenant Feishu app first."}}

          {:error, reason} ->
            {:error,
             {:bad_request,
              "The tenant Feishu app store is unavailable (#{inspect(reason)}). Retry once it recovers."}}
        end
    end
  end

  # Read the tenant Feishu-app store through the provider app port.
  # Returns `{:ok, app_map}` (string-keyed) when configured, `:none` otherwise.
  defp tenant_feishu_app(""), do: :none

  defp tenant_feishu_app(tenant_id), do: ProviderAppStore.get_feishu_tenant_app(trim(tenant_id))

  defp feishu_tenant_app(tenant_id) do
    case tenant_feishu_app(trim(tenant_id)) do
      {:ok, app} when is_map(app) -> app
      _ -> %{}
    end
  end

  defp feishu_tenant_app_configured?(rec) do
    rec
    |> feishu_tenant_app_for_connect()
    |> Map.get("app_secret")
    |> trim()
    |> Kernel.!=("")
  end

  defp feishu_tenant_app_for_connect(rec) do
    app = feishu_tenant_app(rec["tenant_id"])
    connect_app_id = trim(rec["app_id"])

    case trim(app["app_id"]) do
      "" -> app
      app_id when app_id == connect_app_id -> app
      _ -> %{}
    end
  end

  defp validate_feishu_credentials(app_id, app_secret) do
    app_id = trim(app_id)
    app_secret = trim(app_secret)

    cond do
      app_id == "" ->
        {:error, {:bad_request, "app_id is required"}}

      app_secret == "" ->
        {:error, {:bad_request, "app_secret is required"}}

      true ->
        base = feishu_api_base()

        case Req.post("#{base}/auth/v3/tenant_access_token/internal",
               json: %{"app_id" => app_id, "app_secret" => app_secret},
               retry: false
             ) do
          {:ok, %{status: status, body: %{"code" => 0, "tenant_access_token" => token}}}
          when status in 200..299 and is_binary(token) and token != "" ->
            {:ok, token}

          {:ok, %{body: %{"code" => code, "msg" => msg}}} ->
            {:error, {:bad_request, "Feishu credential validation failed: #{code} #{msg}"}}

          {:ok, %{status: status}} ->
            {:error, {:bad_request, "Feishu credential validation failed: HTTP #{status}"}}

          {:error, reason} ->
            {:error, {:bad_request, "Feishu credential validation failed: #{inspect(reason)}"}}
        end
    end
  end

  defp feishu_api_base do
    :salix_im
    |> Application.get_env(:feishu_api_base_url, "https://open.feishu.cn/open-apis")
    |> trim()
    |> default_base("https://open.feishu.cn/open-apis")
  end

  defp fetch_feishu_bot_open_id(token) do
    token = trim(token)

    if token == "" do
      ""
    else
      case Req.get("#{feishu_api_base()}/bot/v3/info",
             headers: [{"authorization", "Bearer #{token}"}],
             retry: false
           ) do
        {:ok, %{status: status, body: %{"code" => 0, "bot" => %{"open_id" => open_id}}}}
        when status in 200..299 ->
          trim(open_id)

        _ ->
          ""
      end
    end
  rescue
    _ -> ""
  end

  defp default_base("", fallback), do: fallback
  defp default_base(base, _fallback), do: String.trim_trailing(base, "/")

  defp create_secret_connect(
         tenant_id,
         group_id,
         provider,
         attrs,
         required,
         put_fields,
         opts \\ []
       ) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         :ok <- validate_required_attrs(attrs, required) do
      now = now()
      connect_id = Ids.new_connect_id()
      identity = Keyword.get(opts, :identity)

      rec =
        %{
          "connect_id" => connect_id,
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "provider" => provider,
          "created_at" => now,
          "updated_at" => now
        }
        |> put_fields.()

      with :ok <- ProviderIdentity.reserve(identity, tenant_id, group_id, connect_id),
           {:ok, rec} <- CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), rec) do
        {:ok, im_connect_public(rec)}
      else
        other ->
          _ = ProviderIdentity.release(identity, connect_id)
          other
      end
    end
  end

  defp update_secret_connect(
         tenant_id,
         group_id,
         connect_id,
         provider,
         attrs,
         required,
         put_fields
       ) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         :ok <- validate_required_attrs(attrs, required),
         {:ok, current} <- get_active_or_disabled_connect(group_id, connect_id),
         true <- current["tenant_id"] == tenant_id and current["provider"] == provider do
      update_existing(Keys.ctl_im_connect(group_id, connect_id), fn rec ->
        rec
        |> put_fields.()
        |> Map.put("updated_at", now())
      end)
      |> public_result()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp get_active_or_disabled_connect(group_id, connect_id) do
    case CasRecord.get(Keys.ctl_im_connect(group_id, trim(connect_id))) do
      {:ok, rec} -> if rec["deleted_at"], do: {:error, :not_found}, else: {:ok, rec}
      other -> other
    end
  end

  defp set_im_connect_disabled(tenant_id, group_id, connect_id, disabled?) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, rec} <- get_active_or_disabled_connect(group_id, connect_id),
         true <- rec["tenant_id"] == tenant_id do
      maybe_with_slack_authority_write(rec, fn ->
        update_existing(Keys.ctl_im_connect(group_id, connect_id), fn rec ->
          rec =
            if disabled? do
              rec
              |> Map.put("disabled_at", now())
              |> maybe_revoke_disabled_slack_triage()
            else
              Map.delete(rec, "disabled_at")
            end

          Map.put(rec, "updated_at", now())
        end)
        |> case do
          {:ok, _} -> :ok
          other -> other
        end
      end)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp maybe_revoke_disabled_slack_triage(%{"provider" => "slack"} = rec) do
    if rec["triage_enabled"] == true do
      rec
      |> establish_slack_triage_generation_if_missing()
      |> maybe_rotate_slack_triage_activation(false)
      |> Map.put("triage_enabled", false)
    else
      rec
    end
  end

  defp maybe_revoke_disabled_slack_triage(rec), do: rec

  defp maybe_rotate_slack_triage_activation(rec, false) do
    if rec["triage_enabled"] == true,
      do: Map.put(rec, "triage_activation_generation", ULID.generate()),
      else: rec
  end

  defp maybe_rotate_slack_triage_activation(rec, true), do: rec

  defp maybe_with_slack_authority_write(%{"provider" => "slack"}, fun),
    do: SlackTriageChannelCutover.with_authority_write(fun)

  defp maybe_with_slack_authority_write(_rec, fun), do: fun.()

  defp public_result({:ok, rec}), do: {:ok, im_connect_public(rec)}
  defp public_result(other), do: other

  defp validate_required_attrs(attrs, required) do
    case Enum.find(required, &(trim(attrs[&1]) == "")) do
      nil -> :ok
      field -> {:error, {:bad_request, "#{field} is required"}}
    end
  end

  defp maybe_reset_slack_oauth(rec, false), do: rec

  defp maybe_reset_slack_oauth(rec, true) do
    rec
    |> Map.put("oauth_state", random_id())
    |> Map.put("oauth_completed_at", 0)
    |> Map.put("triage_enabled", false)
    |> Map.delete("approved_channel_id")
    # The name is only ever a label for the id; it must not outlive it.
    |> Map.delete("approved_channel_name")
    |> establish_or_rotate_slack_triage_generation()
    |> Map.drop([
      "bot_token",
      "bot_id",
      "bot_user_id",
      "bot_username",
      "workspace_id",
      "workspace_name",
      "enterprise_id",
      "owner_user_id",
      "granted_bot_scopes",
      "granted_bot_scopes_generation"
    ])
  end

  defp put_slack_scope_snapshot(rec, oauth) do
    case normalize_scope_list(if(is_map(oauth), do: oauth["granted_bot_scopes"])) do
      {:ok, scopes} ->
        rec
        |> Map.put("granted_bot_scopes", scopes)
        |> Map.put("granted_bot_scopes_generation", rec["connect_generation"])

      :error ->
        # Reauthorization replaces the installation evidence. Never carry a
        # prior token's scope snapshot into a completion that supplied none or
        # malformed evidence.
        rec
        |> Map.delete("granted_bot_scopes")
        |> Map.delete("granted_bot_scopes_generation")
    end
  end

  defp slack_scope_projection(rec) do
    generation_matches? =
      trim(rec["connect_generation"]) != "" and
        rec["granted_bot_scopes_generation"] == rec["connect_generation"]

    case {generation_matches?, rec["granted_bot_scopes"]} do
      {true, scopes} when is_list(scopes) ->
        case normalize_scope_list(scopes) do
          {:ok, normalized} ->
            %{
              "status" => "known",
              "scopes" => normalized,
              "observed_at" => rec["oauth_completed_at"]
            }

          :error ->
            %{"status" => "unknown"}
        end

      _missing_stale_or_invalid ->
        %{
          "status" => "unknown"
        }
    end
  end

  defp normalize_scope_list(scopes) when is_list(scopes) do
    if scopes != [] and
         Enum.all?(scopes, &(is_binary(&1) and Regex.match?(~r/\A[a-zA-Z0-9._:-]+\z/, &1))) do
      {:ok, scopes |> Enum.uniq() |> Enum.sort()}
    else
      :error
    end
  end

  defp normalize_scope_list(_scopes), do: :error

  # Establish-if-missing, rotate-if-present, for Slack connect records only.
  #
  # A Slack connect provisioned before the generation fence carries no
  # `connect_generation` at all, and the previous rotate-only helper left those
  # records bare forever: a credential or identity change moved a pinnable
  # authority member with no epoch move to fence it. Every trigger point below
  # is a change that retires a pinnable authority, so the record must come out
  # of it carrying a generation either way — a first one when it had none, a
  # fresh one when it had one. The generation is therefore mandatory for every
  # Slack connect that has been written since; `backfill_slack_connect_generations/1`
  # closes the same gap for records nothing has written to yet.
  #
  # The provider guard is load-bearing: `delete_im_connect/3` runs this over
  # connects of EVERY provider, and only Slack has a generation in its model.
  defp establish_or_rotate_slack_triage_generation(%{"provider" => "slack"} = rec),
    do: Map.put(rec, "connect_generation", ULID.generate())

  defp establish_or_rotate_slack_triage_generation(rec), do: rec

  # Provisioning a sibling channel must not rotate a valid installation fence,
  # but legacy Slack records may predate the fence entirely. Establish the
  # missing value in the same S3 CAS before the PostgreSQL channel row refers to
  # it; otherwise a valid first provision fails after the compatibility rollout.
  defp establish_slack_triage_generation_if_missing(%{"provider" => "slack"} = rec) do
    if ULID.valid?(rec["connect_generation"]),
      do: rec,
      else: Map.put(rec, "connect_generation", ULID.generate())
  end

  defp establish_slack_triage_generation_if_missing(rec), do: rec

  # Connect-record invariant: any change that can RETIRE an existing pinnable
  # authority lands under a fresh `connect_generation` in the same CAS, so a
  # captured pin can never verify field-for-field against an authority the
  # writer has since retired. That covers moving a Triage-authority member,
  # disabling, and deleting. It is deliberately not universal over the authority
  # keys: `set_slack_triage_enabled(..., true)` changes `triage_enabled` without
  # rotating, because the disabled state holds no live pin — there is nothing to
  # retire, and the preceding disable already rotated. Callers pass the record as
  # read; a write that already rotated (identity change, OAuth reset,
  # provisioning) keeps its single rotation, and a write that touches only
  # non-authority fields (`bot_username`, `updated_at`, cursors, status) stays
  # generation-stable so in-flight callbacks are not invalidated by a no-op.
  defp fence_slack_triage_authority_change(next, current) do
    cond do
      next["connect_generation"] != current["connect_generation"] ->
        next

      slack_triage_authority_fence_fields(next) == slack_triage_authority_fence_fields(current) ->
        next

      true ->
        establish_or_rotate_slack_triage_generation(next)
    end
  end

  defp slack_triage_authority_fence_fields(rec),
    do: Map.take(rec, @slack_triage_authority_keys -- ["connect_generation"])

  defp prepare_slack_triage_oauth_completion(rec, oauth) do
    if established_slack_oauth_identity?(rec) and slack_oauth_identity_changed?(rec, oauth) do
      if rec["triage_enabled"] == true do
        {:error, :slack_triage_authority_conflict}
      else
        rec
        |> Map.put("triage_enabled", false)
        |> Map.delete("approved_channel_id")
        |> Map.delete("approved_channel_name")
        |> establish_or_rotate_slack_triage_generation()
      end
    else
      rec
    end
  end

  defp established_slack_oauth_identity?(rec) do
    num(rec["oauth_completed_at"]) > 0 or
      Enum.any?(["bot_token", "bot_id", "bot_user_id", "workspace_id"], fn field ->
        trim(rec[field]) != ""
      end)
  end

  defp slack_oauth_identity_changed?(rec, oauth) do
    Enum.any?(["bot_token", "bot_id", "bot_user_id", "workspace_id"], fn field ->
      trim(rec[field]) != trim(oauth[field])
    end)
  end

  defp maybe_revoke_slack_triage_on_update(rec, next_app_id, next_inbound_agent_id, attrs) do
    changed? =
      trim(next_app_id) != trim(rec["app_id"]) or
        trim(next_inbound_agent_id) != trim(rec["inbound_agent_id"]) or
        slack_attr_changed?(rec, attrs, "client_id") or
        slack_attr_changed?(rec, attrs, "client_secret") or
        slack_attr_changed?(rec, attrs, "signing_secret")

    if changed? and attrs["reset_oauth"] != true do
      rec
      |> Map.put("triage_enabled", false)
      |> establish_or_rotate_slack_triage_generation()
    else
      rec
    end
  end

  defp slack_attr_changed?(rec, attrs, field) do
    case trim(attrs[field]) do
      "" -> false
      value -> value != trim(rec[field])
    end
  end

  # ---- validation / primitives ----

  defp channel_options(channels) when is_list(channels) do
    Enum.flat_map(channels, fn
      %{} = channel ->
        id = trim(channel["id"])
        name = trim(channel["name"])

        shared? =
          Enum.any?(~w(is_shared is_ext_shared is_org_shared), &(channel[&1] == true))

        if id != "" and name != "" and channel["is_archived"] != true do
          [
            %{
              id: id,
              name: name,
              private?: channel["is_private"] == true,
              shared?: shared?,
              member?: channel["is_member"] == true
            }
          ]
        else
          []
        end

      _invalid ->
        []
    end)
  end

  defp channel_options(_invalid), do: []

  defp present_cursor(cursor) do
    case trim(cursor) do
      "" -> nil
      cursor -> cursor
    end
  end

  defp valid_page_cursor?(nil), do: true

  defp valid_page_cursor?(cursor) when is_binary(cursor),
    do: cursor != "" and cursor == String.trim(cursor)

  defp put_optional_nonblank(map, key, value) do
    case trim(value) do
      "" -> map
      value -> Map.put(map, key, value)
    end
  end

  defp maybe_put_nonblank(map, key, value) do
    case trim(value) do
      "" -> map
      value -> Map.put(map, key, value)
    end
  end

  defp nonblank(value, fallback) do
    case trim(value) do
      "" -> fallback
      value -> value
    end
  end

  defp blank?(value), do: trim(value) == ""

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp num(value) when is_integer(value), do: value
  defp num(value) when is_float(value), do: trunc(value)

  defp num(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp num(_), do: 0

  def public_base_url do
    Application.get_env(:salix_im, :public_base_url, "http://127.0.0.1:4000")
    |> trim()
    |> String.trim_trailing("/")
  end

  defp random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  defp now, do: System.system_time(:millisecond)
end
