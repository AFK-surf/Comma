defmodule SalixStore.SlackSearchSources do
  @moduledoc """
  Source admission and component publication for independent Slack search.

  The epoch is an accepted-change fact, not a substitute for ClickHouse's
  current row identity. Pending state is the existing indexed outbox itself;
  there is no second counter to drift when an old drainer deletes a row.
  """
  alias SalixStore.Repo

  @source_keys ~w(tenant_id workspace_id channel_id message_ts_us)
  @component_keys ~w(tenant_id group_id connect_id connect_generation workspace_id channel_id message_ts_us component)
  @max_candidates 200

  @doc "Bump accepted source epochs inside the caller's outbox transaction."
  def admit!(rows) when is_list(rows) and length(rows) <= 200 do
    keys =
      Enum.map(
        rows,
        &(Map.take(&1, @source_keys) |> Map.put("live", &1["ingest_source"] == "webhook"))
      )

    Repo.query!(
      """
      INSERT INTO slack_semantic.search_sources
        (tenant_id, workspace_id, channel_id, message_ts_us, change_epoch, dispatch_live, dispatch_epoch)
      SELECT tenant_id, workspace_id, channel_id, message_ts_us, count(*), bool_or(live), count(*)
      FROM jsonb_to_recordset($1::jsonb) AS r(
        tenant_id text, workspace_id text, channel_id text, message_ts_us bigint, live boolean)
      GROUP BY tenant_id, workspace_id, channel_id, message_ts_us
      ORDER BY tenant_id, workspace_id, channel_id, message_ts_us
      ON CONFLICT (tenant_id, workspace_id, channel_id, message_ts_us)
      DO UPDATE SET change_epoch = search_sources.change_epoch + EXCLUDED.change_epoch,
        dispatch_cursor=CASE WHEN search_sources.dispatched_epoch=search_sources.change_epoch
          THEN '{}'::jsonb ELSE search_sources.dispatch_cursor END,
        dispatch_epoch=CASE WHEN search_sources.dispatched_epoch=search_sources.change_epoch
          THEN search_sources.change_epoch+EXCLUDED.change_epoch ELSE search_sources.dispatch_epoch END,
        dispatch_live=search_sources.dispatch_live OR EXCLUDED.dispatch_live,
        dispatch_due=CASE WHEN search_sources.dispatched_epoch < search_sources.change_epoch
          THEN search_sources.dispatch_due ELSE timezone('UTC', clock_timestamp()) END
      """,
      [keys]
    )

    SalixStore.SlackSearchCatalog.remember_admitted!(rows)

    :ok
  end

  @doc "Commit one source fanout page and its Oban jobs under the source lock."
  def dispatch_page(enqueue) do
    safe(fn ->
      Repo.transaction(fn ->
        live = claim_dispatch_source!(true)
        rows = if live == [], do: claim_dispatch_source!(false), else: live

        case rows do
          [] ->
            :idle

          [[tenant, workspace, channel, timestamp, epoch, live, cursor, dispatch_epoch]] ->
            key = [tenant, workspace, channel, timestamp]

            pending =
              Repo.query!(
                """
                SELECT 1 FROM slack_semantic.search_sources s
                WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3 AND message_ts_us=$4
                  AND EXISTS (#{pending_sql("s")})
                """,
                key
              ).rows != []

            if pending do
              Repo.query!(
                """
                UPDATE slack_semantic.search_sources SET dispatch_due=timezone('UTC', clock_timestamp())+interval '1 second'
                WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3 AND message_ts_us=$4
                """,
                key
              )

              :waiting
            else
              scopes =
                Repo.query!(
                  """
                    WITH candidates AS MATERIALIZED (
                    SELECT group_id, connect_id FROM slack_semantic.search_channels
                    WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3
                      AND (group_id,connect_id) > ($4,$5)
                    ORDER BY group_id,connect_id LIMIT 20
                  )
                  SELECT c.group_id,c.connect_id,i.connect_generation,i.active
                  FROM candidates c LEFT JOIN slack_semantic.search_connects i
                    ON i.tenant_id=$1 AND i.workspace_id=$2
                      AND i.group_id=c.group_id AND i.connect_id=c.connect_id
                  ORDER BY c.group_id,c.connect_id
                  """,
                  [tenant, workspace, channel, cursor["group"] || "", cursor["connect"] || ""]
                ).rows

              Enum.each(scopes, fn
                [group, connect, generation, true] ->
                  scope = %{
                    "tenant_id" => tenant,
                    "workspace_id" => workspace,
                    "channel_id" => channel,
                    "group_id" => group,
                    "connect_id" => connect,
                    "connect_generation" => generation
                  }

                  case enqueue.(scope, timestamp, live) do
                    {:ok, _} -> :ok
                    error -> Repo.rollback(error)
                  end

                _ ->
                  :ok
              end)

              next =
                case List.last(scopes) do
                  nil -> cursor
                  [group, connect, _, _] -> %{"group" => group, "connect" => connect}
                end

              done = length(scopes) < 20

              Repo.query!(
                """
                UPDATE slack_semantic.search_sources
                SET dispatch_cursor=CASE WHEN $6 THEN '{}'::jsonb ELSE $5 END,
                  dispatched_epoch=CASE WHEN $6 THEN $8 ELSE dispatched_epoch END,
                  dispatch_epoch=CASE WHEN $6 THEN $7 ELSE dispatch_epoch END,
                  dispatch_live=CASE WHEN $6 AND $7=$8 THEN false ELSE dispatch_live END,
                  dispatch_due=timezone('UTC', clock_timestamp())+interval '1 millisecond'
                WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3 AND message_ts_us=$4
                """,
                [tenant, workspace, channel, timestamp, next, done, epoch, dispatch_epoch]
              )

              :advanced
            end
        end
      end)
    end)
  end

  defp claim_dispatch_source!(live) do
    priority = if live, do: "dispatch_live", else: "NOT dispatch_live"

    Repo.query!("""
    SELECT tenant_id, workspace_id, channel_id, message_ts_us,
      change_epoch, dispatch_live, dispatch_cursor, dispatch_epoch
    FROM slack_semantic.search_sources
    WHERE dispatched_epoch < change_epoch AND #{priority}
      AND dispatch_due <= timezone('UTC', clock_timestamp())
    ORDER BY dispatch_due, tenant_id, workspace_id, channel_id, message_ts_us
    LIMIT 1 FOR UPDATE SKIP LOCKED
    """).rows
  end

  @doc "Classify one finite initialization page without reading job arguments."
  def live_timestamps!(scope, timestamps) when length(timestamps) <= 20 do
    Repo.query!(
      """
      SELECT message_ts_us FROM slack_semantic.search_sources
      WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3 AND message_ts_us=ANY($4)
        AND dispatched_epoch < change_epoch AND dispatch_live
      """,
      [scope["tenant_id"], scope["workspace_id"], scope["channel_id"], timestamps]
    ).rows
    |> MapSet.new(&hd/1)
  end

  def live_pending? do
    case Repo.query("""
         WITH candidates AS MATERIALIZED (
           SELECT * FROM slack_semantic.search_sources
           WHERE dispatched_epoch < change_epoch AND dispatch_live
             AND dispatch_due <= timezone('UTC', clock_timestamp())
           ORDER BY dispatch_due LIMIT 20
         )
         SELECT 1 FROM candidates s WHERE NOT EXISTS (#{pending_sql("s")}) LIMIT 1
         """) do
      {:ok, %{rows: []}} -> false
      _ -> true
    end
  end

  @doc "Capture one source epoch while no accepted source write remains pending."
  def capture(scope, timestamp, file_id \\ "") do
    safe(fn ->
      key = source_key(scope, timestamp)

      Repo.transaction(fn ->
        Repo.query!(
          """
          INSERT INTO slack_semantic.search_sources
            (tenant_id, workspace_id, channel_id, message_ts_us)
          VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING
          """,
          key
        )

        [[epoch]] =
          Repo.query!(
            """
            SELECT change_epoch FROM slack_semantic.search_sources
            WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3 AND message_ts_us=$4
            FOR UPDATE
            """,
            key
          ).rows

        case Repo.query!(
               """
               SELECT 1 FROM slack_semantic.search_sources AS s
               WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3 AND message_ts_us=$4
                 AND NOT EXISTS (#{pending_sql("s")})
               """,
               key
             ).rows do
          [[1]] ->
            file = SalixStore.SlackSearchFiles.capture!(scope, file_id)
            # Allocate under the same source lock. A delayed old-epoch reader
            # must not obtain a newer replacing sequence after an edit.
            [[sequence]] =
              Repo.query!("SELECT nextval('slack_semantic.search_build_sequence')").rows

            Map.merge(file, %{change_epoch: epoch, build_sequence: sequence})

          [] ->
            Repo.rollback(:source_pending)
        end
      end)
    end)
  end

  @doc "Publish only after the complete ClickHouse component row was acknowledged."
  def publish(component) when is_map(component) do
    safe(fn ->
      Repo.transaction(fn ->
        key = source_key(component, component["message_ts_us"])

        # This lock serializes publication with admission. It is never held
        # while calling ClickHouse or the encoder.
        [[epoch]] =
          Repo.query!(
            """
            SELECT change_epoch FROM slack_semantic.search_sources
            WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3 AND message_ts_us=$4
            FOR UPDATE
            """,
            key
          ).rows

        if epoch != component["change_epoch"], do: Repo.rollback(:source_changed)
        SalixStore.SlackSearchFiles.validate!(component)

        case Repo.query!(
               """
               SELECT 1 FROM slack_semantic.search_sources AS s
               WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3 AND message_ts_us=$4
                 AND EXISTS (#{pending_sql("s")})
               """,
               key
             ).rows do
          [] -> :ok
          _ -> Repo.rollback(:source_pending)
        end

        params =
          Enum.map(@component_keys, &component[&1]) ++
            Enum.map(
              ~w(change_epoch build_id build_sequence message_identity payload_identity),
              &component[&1]
            ) ++
            [
              component["unit_count"] || length(component["embeddings"]),
              component["file_id"] || "",
              component["file_epoch"] || 0
            ]

        result =
          Repo.query!(
            """
            INSERT INTO slack_semantic.search_components
              (tenant_id, group_id, connect_id, connect_generation, workspace_id, channel_id,
               message_ts_us, component, change_epoch, build_id, build_sequence,
               message_identity, payload_identity, unit_count, file_id, file_epoch, published_at)
            VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::text::uuid,$11,$12,$13,$14,$15,$16,
              timezone('UTC', clock_timestamp()))
            ON CONFLICT (tenant_id, group_id, connect_id, workspace_id,
              channel_id, message_ts_us, component)
            DO UPDATE SET connect_generation=EXCLUDED.connect_generation,
              change_epoch=EXCLUDED.change_epoch, build_id=EXCLUDED.build_id,
              build_sequence=EXCLUDED.build_sequence, message_identity=EXCLUDED.message_identity,
              payload_identity=EXCLUDED.payload_identity, unit_count=EXCLUDED.unit_count,
              file_id=EXCLUDED.file_id, file_epoch=EXCLUDED.file_epoch,
              published_at=EXCLUDED.published_at
            WHERE search_components.build_sequence < EXCLUDED.build_sequence
              OR (search_components.build_sequence = EXCLUDED.build_sequence
                AND search_components.build_id = EXCLUDED.build_id)
            """,
            params
          )

        if result.num_rows != 1, do: Repo.rollback(:superseded_build)
        SalixStore.SlackSearchFiles.schedule_refresh!(component)
        :ok
      end)
      |> case do
        {:ok, :ok} -> :ok
        error -> error
      end
    end)
  end

  @doc "Read current publications for at most 200 exact candidate components."
  def visible(candidates) when is_list(candidates) and length(candidates) <= @max_candidates do
    safe(fn ->
      rows = Enum.map(candidates, &Map.take(&1, @component_keys ++ ["build_id"]))

      result =
        Repo.query!(
          """
          SELECT c.build_id::text
          FROM jsonb_to_recordset($1::jsonb) AS q(
            tenant_id text, group_id text, connect_id text, connect_generation text,
            workspace_id text, channel_id text, message_ts_us bigint, component text, build_id uuid)
          JOIN slack_semantic.search_components c
            USING (tenant_id, group_id, connect_id, workspace_id,
              channel_id, message_ts_us, component, build_id)
          JOIN slack_semantic.search_sources s
            USING (tenant_id, workspace_id, channel_id, message_ts_us)
          LEFT JOIN slack_semantic.search_files f
            ON f.tenant_id=c.tenant_id AND f.workspace_id=c.workspace_id AND f.file_id=c.file_id
          WHERE c.change_epoch=s.change_epoch AND NOT EXISTS (#{pending_sql("s")})
            AND (c.file_id='' OR (f.change_epoch=c.file_epoch AND NOT f.deleted))
          """,
          [rows]
        )

      {:ok, MapSet.new(result.rows, &hd/1)}
    end)
  end

  @doc "Current published components used to avoid encoding unchanged source slices."
  def components(scope, timestamp) do
    safe(fn ->
      params =
        Enum.map(
          ~w(tenant_id group_id connect_id workspace_id channel_id),
          &scope[&1]
        ) ++
          [timestamp]

      result =
        Repo.query!(
          """
          SELECT component, change_epoch, message_identity, payload_identity, published_at
          FROM slack_semantic.search_components
          WHERE tenant_id=$1 AND group_id=$2 AND connect_id=$3
            AND workspace_id=$4 AND channel_id=$5 AND message_ts_us=$6
          ORDER BY component LIMIT 8193
          """,
          params
        )

      if length(result.rows) > 8192 do
        {:error, :source_over_budget}
      else
        {:ok,
         Map.new(result.rows, fn [component, epoch, message_id, payload_id, published_at] ->
           {component,
            %{
              epoch: epoch,
              message_identity: message_id,
              payload_identity: payload_id,
              published_at: published_at
            }}
         end)}
      end
    end)
  end

  defp pending_sql(source) do
    ["slack_mirror_outbox", "slack_mirror_source_writes"]
    |> Enum.map_join(" UNION ALL ", fn table ->
      """
      SELECT 1 FROM #{table} o
      WHERE o.kind='message'
        AND o.row->>'tenant_id'=#{source}.tenant_id
        AND o.row->>'workspace_id'=#{source}.workspace_id
        AND o.row->>'channel_id'=#{source}.channel_id
        AND o.row->>'message_ts_us'=#{source}.message_ts_us::text
      """
    end)
  end

  defp source_key(scope, timestamp),
    do: Enum.map(~w(tenant_id workspace_id channel_id), &scope[&1]) ++ [timestamp]

  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, :search_metadata_unavailable}
  catch
    :exit, _ -> {:error, :search_metadata_unavailable}
  end
end
