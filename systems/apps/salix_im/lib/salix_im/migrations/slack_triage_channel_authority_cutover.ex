defmodule SalixIM.Migrations.SlackTriageChannelAuthorityCutover do
  @moduledoc """
  Publishes PostgreSQL as the fleet-wide Slack Triage channel authority.

  The release first freezes every legacy authority-changing write through
  `SalixStore.SlackTriageChannelCutover`, then reconciles the still-dark table
  to the exact current S3 authority set. It re-reads both connect and Router
  identity state before publishing the terminal marker. A failed attempt keeps
  the durable freeze and is recovered by retrying this idempotent operation.
  """

  alias SalixIM.GroupDirectory

  alias SalixStore.{
    CasRecord,
    Ids,
    Keys,
    Repo,
    S3,
    SlackTriageChannelCutover,
    SlackTriageChannels,
    ULID
  }

  @preparation_id "salix-20260824000101"
  @legacy_generation_domain "comma.slack-triage-legacy-authority.v1"
  @legacy_channel_name_fallback "Slack"

  @spec run() ::
          {:ok,
           %{
             required(:already_projected) => boolean(),
             optional(:materialized) => non_neg_integer(),
             optional(:verified) => non_neg_integer()
           }}
          | {:error, term()}
  def run do
    case SlackTriageChannelCutover.mode() do
      :projected ->
        {:ok, %{already_projected: true}}

      :legacy ->
        run_legacy_cutover()

      {:error, :unavailable} ->
        {:error, :slack_triage_channel_cutover_unavailable}
    end
  end

  defp run_legacy_cutover do
    with {:ok, @preparation_id} <-
           SlackTriageChannelCutover.begin_preparing(preparation_evidence()),
         {:ok, before} <- enumerate_legacy_authorities(),
         :ok <- reconcile_projection(before),
         {:ok, after_reconciliation} <- enumerate_legacy_authorities(),
         :ok <- verify_frozen_snapshot(before, after_reconciliation),
         :ok <- verify_projection(after_reconciliation),
         :ok <- SlackTriageChannelCutover.mark_ready(readiness_evidence()) do
      count = length(after_reconciliation)
      {:ok, %{already_projected: false, materialized: count, verified: count}}
    end
  end

  defp preparation_evidence do
    %{
      "schema_version" => 1,
      "preparation_id" => @preparation_id,
      "all_readers_current" => true,
      "old_control_writers_retired" => true
    }
  end

  defp readiness_evidence do
    Map.merge(preparation_evidence(), %{
      "legacy_rows_materialized" => true,
      "generation_fences_verified" => true
    })
  end

  defp enumerate_legacy_authorities do
    prefix = Keys.ctl_im_connects_all_prefix()

    with {:ok, objects} <- S3.list_all(prefix) do
      objects
      |> Enum.sort_by(&Map.get(&1, :key, ""))
      |> Enum.reduce_while({:ok, []}, fn object, {:ok, authorities} ->
        case legacy_authority_from_object(object, prefix) do
          {:ok, nil} -> {:cont, {:ok, authorities}}
          {:ok, authority} -> {:cont, {:ok, [authority | authorities]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, authorities} -> {:ok, authorities |> Enum.reverse() |> Enum.sort()}
        {:error, _reason} = error -> error
      end
    else
      {:error, reason} ->
        {:error, {:slack_triage_channel_scan_failed, safe_storage_reason(reason)}}
    end
  end

  defp legacy_authority_from_object(%{key: key}, prefix) when is_binary(key) do
    if ignorable_directory_marker?(key, prefix) do
      {:ok, nil}
    else
      with {:ok, record} when is_map(record) <- CasRecord.get(key, :invalid_connect_record),
           :ok <- validate_record_address(record, key) do
        classify_legacy_authority(record, key)
      else
        {:error, reason} ->
          {:error,
           {:slack_triage_connect_unavailable, safe_key(key), safe_storage_reason(reason)}}
      end
    end
  end

  defp legacy_authority_from_object(_object, _prefix),
    do: {:error, {:slack_triage_connect_unavailable, :invalid_key, :invalid_connect_record}}

  defp classify_legacy_authority(record, key) do
    if legacy_channel_record?(record) do
      with {:ok, activation_generation} <- activation_generation(record),
           :ok <- validate_legacy_authority_record(record),
           {:ok, group} <- get_group(record),
           router_agent_id when is_binary(router_agent_id) and router_agent_id != "" <-
             canonical(group["router_agent_id"]) do
        {:ok,
         %{
           key: key,
           tenant_id: record["tenant_id"],
           group_id: record["group_id"],
           connect_id: record["connect_id"],
           channel_id: record["approved_channel_id"],
           channel_name: legacy_channel_name(record),
           installation_generation: record["connect_generation"],
           activation_generation: activation_generation,
           channel_generation: legacy_channel_generation(record, activation_generation),
           workspace_id: record["workspace_id"],
           inbound_agent_id: canonical(record["inbound_agent_id"]),
           router_agent_id: router_agent_id,
           app_id: canonical(record["app_id"]),
           bot_id: canonical(record["bot_id"]),
           bot_user_id: canonical(record["bot_user_id"]),
           oauth_completed_at: record["oauth_completed_at"],
           triage_enabled: record["triage_enabled"] == true,
           disabled_at: record["disabled_at"]
         }}
      else
        {:error, reason} ->
          {:error, {:invalid_slack_triage_legacy_authority, safe_key(key), reason}}

        _invalid ->
          {:error,
           {:invalid_slack_triage_legacy_authority, safe_key(key), :invalid_router_identity}}
      end
    else
      {:ok, nil}
    end
  end

  # The approved channel is the legacy authority itself. Older valid records
  # can predate the presentation-only setup timestamp, so using
  # `triage_provisioned_at` as the migration selector would silently drop a
  # channel that pre-gate readers still authorize.
  defp legacy_channel_record?(record) do
    record["provider"] == "slack" and is_nil(record["deleted_at"]) and
      canonical(record["approved_channel_id"]) != ""
  end

  defp validate_legacy_authority_record(record) do
    canonical_fields =
      ~w(tenant_id group_id connect_id approved_channel_id connect_generation workspace_id)

    valid? =
      Enum.all?(canonical_fields, &canonical_nonblank?(record[&1])) and
        Ids.valid_tenant_id?(record["tenant_id"]) and
        Ids.valid_group_id_for_tenant?(record["group_id"], record["tenant_id"]) and
        Ids.valid_connect_id?(record["connect_id"]) and
        ULID.valid?(record["connect_generation"]) and
        is_integer(record["oauth_completed_at"]) and record["oauth_completed_at"] > 0 and
        (is_nil(record["disabled_at"]) or is_integer(record["disabled_at"]))

    if valid?, do: :ok, else: {:error, :invalid_authority_fields}
  end

  defp legacy_channel_name(record) do
    case canonical(record["approved_channel_name"]) do
      "" -> @legacy_channel_name_fallback
      name -> name
    end
  end

  defp get_group(record) do
    case GroupDirectory.get_group(record["group_id"], record["tenant_id"]) do
      {:ok, group} -> {:ok, group}
      {:error, reason} -> {:error, {:group_unavailable, safe_storage_reason(reason)}}
    end
  end

  defp activation_generation(record) do
    case record["triage_activation_generation"] do
      nil ->
        {:ok, record["connect_generation"]}

      generation when is_binary(generation) ->
        if ULID.valid?(generation),
          do: {:ok, generation},
          else: {:error, :invalid_activation_generation}

      _invalid ->
        {:error, :invalid_activation_generation}
    end
  end

  defp legacy_channel_generation(record, activation_generation) do
    if is_binary(record["triage_activation_generation"]) do
      ULID.derive(@legacy_generation_domain, [
        record["connect_generation"],
        activation_generation
      ])
    else
      record["connect_generation"]
    end
  end

  defp reconcile_projection(authorities) do
    case Repo.transaction(fn ->
           case Repo.query("DELETE FROM slack_triage_channels") do
             {:ok, _result} -> :ok
             {:error, reason} -> Repo.rollback({:projection_reset_failed, reason})
           end

           Enum.each(authorities, fn authority ->
             attrs = %{
               "tenant_id" => authority.tenant_id,
               "group_id" => authority.group_id,
               "connect_id" => authority.connect_id,
               "channel_id" => authority.channel_id,
               "installation_generation" => authority.installation_generation,
               "workspace_id" => authority.workspace_id,
               "channel_name" => authority.channel_name,
               "channel_generation" => authority.channel_generation
             }

             case SlackTriageChannels.materialize_legacy_authority(attrs) do
               {:ok, _channel} -> :ok
               {:error, reason} -> Repo.rollback({:projection_write_failed, reason})
             end
           end)
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, {:slack_triage_projection_reconciliation_failed, reason}}
    end
  end

  defp verify_frozen_snapshot(before, after_reconciliation) do
    if before == after_reconciliation,
      do: :ok,
      else: {:error, :slack_triage_generation_fences_changed}
  end

  defp verify_projection(authorities) do
    expected = MapSet.new(authorities, &projection_tuple/1)

    case Repo.query("""
         SELECT tenant_id, group_id, connect_id, channel_id,
           installation_generation, workspace_id, channel_name,
           channel_generation, enabled
         FROM slack_triage_channels
         """) do
      {:ok, result} ->
        actual =
          result.rows
          |> Enum.map(fn row -> result.columns |> Enum.zip(row) |> Map.new() end)
          |> MapSet.new(fn channel ->
            {
              channel["tenant_id"],
              channel["group_id"],
              channel["connect_id"],
              channel["channel_id"],
              channel["installation_generation"],
              channel["workspace_id"],
              channel["channel_name"],
              channel["channel_generation"],
              channel["enabled"]
            }
          end)

        if MapSet.equal?(expected, actual),
          do: :ok,
          else: {:error, :slack_triage_projection_mismatch}

      {:error, reason} ->
        {:error, {:slack_triage_projection_unavailable, reason}}
    end
  end

  defp projection_tuple(authority) do
    {
      authority.tenant_id,
      authority.group_id,
      authority.connect_id,
      authority.channel_id,
      authority.installation_generation,
      authority.workspace_id,
      authority.channel_name,
      authority.channel_generation,
      true
    }
  end

  defp validate_record_address(record, key) do
    group_id = canonical(record["group_id"])
    connect_id = canonical(record["connect_id"])

    if group_id != "" and connect_id != "" and
         Keys.ctl_im_connect(group_id, connect_id) == key do
      :ok
    else
      {:error, :invalid_record_identity}
    end
  end

  defp ignorable_directory_marker?(key, prefix),
    do: key == prefix or String.ends_with?(key, "/")

  defp canonical_nonblank?(value),
    do: is_binary(value) and value != "" and value == String.trim(value)

  defp canonical(value) when is_binary(value), do: String.trim(value)
  defp canonical(_value), do: ""

  # Release failures must be diagnosable without copying tenant/group/connect
  # coordinates from the storage key into logs.
  defp safe_key(key) when is_binary(key) do
    fingerprint =
      :sha256
      |> :crypto.hash(key)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    {:s3_key_fingerprint, fingerprint}
  end

  defp safe_key(_key), do: :invalid_key

  # S3 adapters may include response bodies or transport structures containing
  # customer coordinates. Release migration failures are inspected into logs,
  # so only a bounded operator-useful class may cross this boundary.
  defp safe_storage_reason({:http, status, _body}) when is_integer(status),
    do: {:http, status}

  defp safe_storage_reason({:http, status}) when is_integer(status), do: {:http, status}
  defp safe_storage_reason({:ambiguous, _reason}), do: :ambiguous
  defp safe_storage_reason(reason) when is_atom(reason), do: reason
  defp safe_storage_reason(_reason), do: :unavailable
end
