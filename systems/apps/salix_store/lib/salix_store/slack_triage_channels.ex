defmodule SalixStore.SlackTriageChannels do
  @moduledoc """
  PostgreSQL authority for the Slack channels configured on one Triage connect.

  The Slack installation remains canonical in the provider connect record. A
  row pins the installation generation it was validated against; an OAuth or
  bot-identity rotation therefore invalidates every row without scanning it.
  The independently rotated channel generation fences only that channel.
  Revalidating a same-workspace installation preserves the channel's explicit
  exclusion; installation identity and listening preference are separate facts.
  """

  alias SalixStore.{Repo, ULID}

  @max_list 200
  @authority_generation_domain "comma.slack-triage-channel-authority.v1"
  @expression_modes ~w(project social)

  @doc "Creates or revalidates one channel under an exact Slack installation."
  def provision(attrs) when is_map(attrs) do
    expression_mode = expression_mode(attrs)

    values =
      Enum.map(
        ~w(tenant_id group_id connect_id channel_id installation_generation workspace_id channel_name),
        &Map.get(attrs, &1)
      )

    generation = attrs["channel_generation"] || ULID.generate()

    if valid_values?(values) and valid_expression_mode?(expression_mode) and
         ULID.valid?(attrs["installation_generation"]) and
         ULID.valid?(generation) do
      now = DateTime.utc_now()

      sql = """
      INSERT INTO slack_triage_channels (
        tenant_id, group_id, connect_id, channel_id, installation_generation,
        workspace_id, channel_name, channel_generation, expression_mode, enabled,
        provisioned_at, updated_at
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, TRUE, $10, $10)
      ON CONFLICT (tenant_id, group_id, connect_id, channel_id)
      DO UPDATE SET
        installation_generation = EXCLUDED.installation_generation,
        workspace_id = EXCLUDED.workspace_id,
        channel_name = EXCLUDED.channel_name,
        expression_mode = CASE
          WHEN slack_triage_channels.workspace_id <> EXCLUDED.workspace_id
          THEN EXCLUDED.expression_mode
          ELSE slack_triage_channels.expression_mode
        END,
        channel_generation = CASE
          WHEN slack_triage_channels.installation_generation <> EXCLUDED.installation_generation
            OR slack_triage_channels.workspace_id <> EXCLUDED.workspace_id
          THEN EXCLUDED.channel_generation
          ELSE slack_triage_channels.channel_generation
        END,
        enabled = CASE
          WHEN slack_triage_channels.workspace_id <> EXCLUDED.workspace_id
          THEN TRUE
          ELSE slack_triage_channels.enabled
        END,
        updated_at = EXCLUDED.updated_at
      RETURNING tenant_id, group_id, connect_id, channel_id,
        installation_generation, workspace_id, channel_name,
        channel_generation, expression_mode, enabled, provisioned_at, updated_at
      """

      query_one(sql, values ++ [generation, expression_mode, now])
    else
      {:error, :invalid_slack_triage_channel}
    end
  end

  def provision(_attrs), do: {:error, :invalid_slack_triage_channel}

  @doc "Materializes a channel and applies its first enabled state atomically."
  def provision_and_set_enabled(attrs, enabled) when is_map(attrs) and is_boolean(enabled) do
    case Repo.transaction(fn ->
           with {:ok, channel} <- provision(attrs),
                :ok <-
                  set_enabled(
                    attrs["tenant_id"],
                    attrs["group_id"],
                    attrs["connect_id"],
                    attrs["channel_id"],
                    attrs["installation_generation"],
                    enabled
                  ) do
             channel
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, channel} -> {:ok, channel}
      {:error, reason} -> {:error, reason}
    end
  end

  def provision_and_set_enabled(_attrs, _enabled),
    do: {:error, :invalid_slack_triage_channel}

  @doc """
  Reconciles one dark PostgreSQL row to the exact legacy S3 authority.

  This is reserved for the fleet-wide release cutover while PostgreSQL rows
  are still non-authoritative. Unlike interactive provisioning, it replaces
  the channel generation so an authority captured immediately before the
  barrier remains byte-identical after publication.
  """
  def materialize_legacy_authority(attrs) when is_map(attrs) do
    values =
      Enum.map(
        ~w(tenant_id group_id connect_id channel_id installation_generation workspace_id channel_name channel_generation),
        &Map.get(attrs, &1)
      )

    if valid_values?(values) and ULID.valid?(attrs["installation_generation"]) and
         ULID.valid?(attrs["channel_generation"]) do
      now = DateTime.utc_now()

      query_one(
        """
        INSERT INTO slack_triage_channels (
          tenant_id, group_id, connect_id, channel_id, installation_generation,
          workspace_id, channel_name, channel_generation, expression_mode, enabled,
          provisioned_at, updated_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'project', TRUE, $9, $9)
        ON CONFLICT (tenant_id, group_id, connect_id, channel_id)
        DO UPDATE SET
          installation_generation = EXCLUDED.installation_generation,
          workspace_id = EXCLUDED.workspace_id,
          channel_name = EXCLUDED.channel_name,
          expression_mode = CASE
            WHEN slack_triage_channels.workspace_id <> EXCLUDED.workspace_id
            THEN EXCLUDED.expression_mode
            ELSE slack_triage_channels.expression_mode
          END,
          channel_generation = EXCLUDED.channel_generation,
          enabled = TRUE,
          updated_at = EXCLUDED.updated_at
        RETURNING tenant_id, group_id, connect_id, channel_id,
          installation_generation, workspace_id, channel_name,
          channel_generation, expression_mode, enabled, provisioned_at, updated_at
        """,
        values ++ [now]
      )
    else
      {:error, :invalid_slack_triage_channel}
    end
  end

  def materialize_legacy_authority(_attrs),
    do: {:error, :invalid_slack_triage_channel}

  @doc "Reads one exact configured channel."
  def get(tenant_id, group_id, connect_id, channel_id) do
    values = [tenant_id, group_id, connect_id, channel_id]

    if valid_values?(values) do
      query_one(
        """
        SELECT tenant_id, group_id, connect_id, channel_id,
          installation_generation, workspace_id, channel_name,
          channel_generation, expression_mode, enabled, provisioned_at, updated_at
        FROM slack_triage_channels
        WHERE tenant_id = $1 AND group_id = $2 AND connect_id = $3 AND channel_id = $4
        """,
        values
      )
    else
      {:error, :not_found}
    end
  end

  @doc "Lists a bounded deterministic page of channels for one connect."
  def list(tenant_id, group_id, connect_id, limit \\ @max_list)

  def list(tenant_id, group_id, connect_id, limit)
      when is_integer(limit) and limit in 1..@max_list do
    with {:ok, %{channels: channels, scan_complete: true}} <-
           list_page(tenant_id, group_id, connect_id, limit) do
      {:ok, channels}
    else
      {:ok, %{scan_complete: false}} -> {:error, :slack_triage_channel_scan_incomplete}
      other -> other
    end
  end

  def list(_tenant_id, _group_id, _connect_id, _limit),
    do: {:error, :invalid_slack_triage_channel}

  @doc "Lists a bounded deterministic page and says whether it is complete."
  def list_page(tenant_id, group_id, connect_id, limit \\ @max_list)

  def list_page(tenant_id, group_id, connect_id, limit)
      when is_integer(limit) and limit in 1..@max_list do
    values = [tenant_id, group_id, connect_id]

    if valid_values?(values) do
      safe_query(fn ->
        case Repo.query(
               """
               SELECT tenant_id, group_id, connect_id, channel_id,
                 installation_generation, workspace_id, channel_name,
                 channel_generation, expression_mode, enabled, provisioned_at, updated_at
               FROM slack_triage_channels
               WHERE tenant_id = $1 AND group_id = $2 AND connect_id = $3
               ORDER BY channel_id
               LIMIT $4
               """,
               values ++ [limit + 1]
             ) do
          {:ok, result} ->
            {:ok,
             %{
               channels:
                 result.rows
                 |> Enum.take(limit)
                 |> Enum.map(&row(result.columns, &1)),
               scan_complete: length(result.rows) <= limit
             }}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    else
      {:error, :invalid_slack_triage_channel}
    end
  end

  def list_page(_tenant_id, _group_id, _connect_id, _limit),
    do: {:error, :invalid_slack_triage_channel}

  @doc "Lists one bounded, completeness-marked channel membership projection."
  def list_channel_memberships(tenant_id, group_id, workspace_id, channel_id, limit \\ @max_list)

  def list_channel_memberships(tenant_id, group_id, workspace_id, channel_id, limit)
      when is_integer(limit) and limit in 1..@max_list do
    values = [tenant_id, group_id, workspace_id, channel_id]

    if valid_values?(values) do
      safe_query(fn ->
        case Repo.query(
               """
               SELECT connect_id, installation_generation, enabled
               FROM slack_triage_channels
               WHERE tenant_id = $1 AND group_id = $2 AND workspace_id = $3
                 AND channel_id = $4
               ORDER BY connect_id
               LIMIT $5
               """,
               values ++ [limit + 1]
             ) do
          {:ok, result} ->
            complete? = length(result.rows) <= limit

            {:ok,
             %{
               memberships:
                 result.rows
                 |> Enum.take(limit)
                 |> Enum.map(&row(result.columns, &1)),
               scan_complete: complete?
             }}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    else
      {:error, :invalid_slack_triage_channel}
    end
  end

  def list_channel_memberships(_tenant_id, _group_id, _workspace_id, _channel_id, _limit),
    do: {:error, :invalid_slack_triage_channel}

  @doc "Lists a bounded keyset page of globally enabled Triage channels for patrol discovery."
  def list_enabled_page(cursor \\ nil, limit \\ @max_list)

  def list_enabled_page(cursor, limit)
      when (is_binary(cursor) or is_nil(cursor)) and is_integer(limit) and limit in 1..@max_list do
    with {:ok, after_key} <- decode_enabled_cursor(cursor) do
      safe_query(fn ->
        {where_after, params} = enabled_page_boundary(after_key)

        case Repo.query(
               """
               SELECT tenant_id, group_id, connect_id, channel_id,
                 installation_generation, workspace_id, channel_name,
                 channel_generation, expression_mode, enabled, provisioned_at, updated_at
               FROM slack_triage_channels
               WHERE enabled = TRUE#{where_after}
               ORDER BY tenant_id, group_id, connect_id, channel_id
               LIMIT $#{length(params) + 1}
               """,
               params ++ [limit + 1]
             ) do
          {:ok, result} ->
            rows = Enum.map(result.rows, &row(result.columns, &1))
            channels = Enum.take(rows, limit)
            scan_complete? = length(rows) <= limit

            {:ok,
             %{
               channels: channels,
               scan_complete: scan_complete?,
               next_cursor:
                 if(scan_complete?, do: nil, else: encode_enabled_cursor(List.last(channels)))
             }}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  def list_enabled_page(_cursor, _limit), do: {:error, :invalid_slack_triage_channel_cursor}

  @doc "Changes one channel state and rotates only its channel generation."
  def set_enabled(tenant_id, group_id, connect_id, channel_id, installation_generation, enabled)
      when is_boolean(enabled) do
    values = [tenant_id, group_id, connect_id, channel_id, installation_generation]

    if valid_values?(values) and ULID.valid?(installation_generation) do
      generation = ULID.generate()

      safe_query(fn ->
        case Repo.query(
               """
               UPDATE slack_triage_channels
               SET enabled = $6,
                   channel_generation = CASE WHEN enabled = $6 THEN channel_generation ELSE $7 END,
                   updated_at = CASE WHEN enabled = $6 THEN updated_at ELSE timezone('UTC', clock_timestamp()) END
               WHERE tenant_id = $1 AND group_id = $2 AND connect_id = $3 AND channel_id = $4
                 AND installation_generation = $5
               RETURNING channel_id
               """,
               values ++ [enabled, generation]
             ) do
          {:ok, %{num_rows: 1}} -> :ok
          {:ok, %{num_rows: 0}} -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
      end)
    else
      {:error, :not_found}
    end
  end

  def set_enabled(_tenant_id, _group_id, _connect_id, _channel_id, _generation, _enabled),
    do: {:error, :not_found}

  @doc "Changes one channel expression policy and rotates only its channel generation."
  def set_expression_mode(
        tenant_id,
        group_id,
        connect_id,
        channel_id,
        installation_generation,
        expression_mode
      ) do
    values = [tenant_id, group_id, connect_id, channel_id, installation_generation]

    if valid_values?(values) and ULID.valid?(installation_generation) and
         valid_expression_mode?(expression_mode) do
      generation = ULID.generate()

      safe_query(fn ->
        case Repo.query(
               """
               UPDATE slack_triage_channels
               SET expression_mode = $6,
                   channel_generation = CASE
                     WHEN expression_mode = $6 THEN channel_generation
                     ELSE $7
                   END,
                   updated_at = CASE
                     WHEN expression_mode = $6 THEN updated_at
                     ELSE timezone('UTC', clock_timestamp())
                   END
               WHERE tenant_id = $1 AND group_id = $2 AND connect_id = $3 AND channel_id = $4
                 AND installation_generation = $5
               RETURNING channel_id
               """,
               values ++ [expression_mode, generation]
             ) do
          {:ok, %{num_rows: 1}} -> :ok
          {:ok, %{num_rows: 0}} -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
      end)
    else
      {:error, :not_found}
    end
  end

  @doc "Derives the downstream generation from installation, global, and channel fences."
  def authority_generation(installation_generation, activation_generation, channel_generation) do
    ULID.derive(@authority_generation_domain, [
      installation_generation,
      activation_generation,
      channel_generation
    ])
  end

  defp enabled_page_boundary(nil), do: {"", []}

  defp enabled_page_boundary([tenant_id, group_id, connect_id, channel_id]) do
    {
      " AND (tenant_id, group_id, connect_id, channel_id) > ($1, $2, $3, $4)",
      [tenant_id, group_id, connect_id, channel_id]
    }
  end

  defp encode_enabled_cursor(channel) do
    ~w(tenant_id group_id connect_id channel_id)
    |> Enum.map(&channel[&1])
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
    |> then(&("v1." <> &1))
  end

  defp decode_enabled_cursor(nil), do: {:ok, nil}

  defp decode_enabled_cursor("v1." <> encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, values} when is_list(values) <- Jason.decode(json),
         true <- length(values) == 4 and valid_values?(values) do
      {:ok, values}
    else
      _invalid -> {:error, :invalid_slack_triage_channel_cursor}
    end
  end

  defp decode_enabled_cursor(_cursor), do: {:error, :invalid_slack_triage_channel_cursor}

  defp query_one(sql, params) do
    safe_query(fn ->
      case Repo.query(sql, params) do
        {:ok, %{num_rows: 1} = result} -> {:ok, row(result.columns, hd(result.rows))}
        {:ok, %{num_rows: 0}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp row(columns, values), do: columns |> Enum.zip(values) |> Map.new()

  defp expression_mode(attrs) do
    case Map.fetch(attrs, "expression_mode") do
      {:ok, mode} -> mode
      :error -> "project"
    end
  end

  defp valid_expression_mode?(mode), do: mode in @expression_modes

  defp valid_values?(values),
    do: Enum.all?(values, &(is_binary(&1) and &1 != "" and &1 == String.trim(&1)))

  defp safe_query(fun) do
    fun.()
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end
end
