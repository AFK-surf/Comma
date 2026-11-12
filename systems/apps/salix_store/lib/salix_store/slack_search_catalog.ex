defmodule SalixStore.SlackSearchCatalog do
  @moduledoc """
  Bounded discovery projection owned by Slack provider-connect observation.

  A workspace watermark is not a connect's data domain. Channels enter this
  catalog only through that installation's authenticated observation/discovery.
  The catalog narrows index work; current ProviderConnects records authorize
  returned candidates. No credentials or personal Slack ACLs are stored here.
  Modeled in tla/salix/MessageSearchGroupScope.tla.
  """
  alias SalixStore.Repo

  @scope_keys ~w(tenant_id group_id connect_id workspace_id)
  @reference_keys @scope_keys ++ ["connect_generation"]
  @connect_limit 64

  def remember_connects(connects) when length(connects) <= 200 do
    rows =
      for connect <- connects,
          valid_scope?(connect) do
        Map.take(connect, @reference_keys)
        |> Map.put("connect_generation", connect["connect_generation"] || "")
        |> Map.put(
          "active",
          Map.get(
            connect,
            "active",
            is_nil(connect["deleted_at"]) and is_nil(connect["disabled_at"])
          )
        )
      end

    safe(fn ->
      Repo.transaction(fn ->
        Repo.query!(
          """
          INSERT INTO slack_semantic.search_connects
            (tenant_id, group_id, connect_id, connect_generation, workspace_id, active)
          SELECT tenant_id, group_id, connect_id, connect_generation, workspace_id, active
          FROM jsonb_to_recordset($1::jsonb) AS r(tenant_id text, group_id text, connect_id text,
            connect_generation text, workspace_id text, active boolean)
          ON CONFLICT (tenant_id, group_id, connect_id) DO UPDATE SET
            connect_generation=EXCLUDED.connect_generation, workspace_id=EXCLUDED.workspace_id,
            active=EXCLUDED.active,
            initialization_pending=CASE WHEN search_connects.workspace_id<>EXCLUDED.workspace_id
              OR (NOT search_connects.active AND EXCLUDED.active)
              THEN true ELSE search_connects.initialization_pending END,
            initialization_cursor=CASE WHEN search_connects.workspace_id<>EXCLUDED.workspace_id
              OR (NOT search_connects.active AND EXCLUDED.active)
              THEN '' ELSE search_connects.initialization_cursor END
          """,
          [rows]
        )
      end)
      |> case do
        {:ok, _} -> :ok
        error -> error
      end
    end)
  end

  def remember_channels(connect, channel_ids) when length(channel_ids) <= 200 do
    if valid_scope?(connect) do
      rows =
        channel_ids
        |> Enum.filter(&(is_binary(&1) and byte_size(&1) in 1..128))
        |> Enum.uniq()
        |> Enum.map(fn channel ->
          Map.take(connect, @reference_keys)
          |> Map.put("connect_generation", connect["connect_generation"] || "")
          |> Map.put("channel_id", channel)
        end)

      safe(fn ->
        Repo.transaction(fn -> insert_channels!(rows) end)
        |> case do
          {:ok, :ok} -> :ok
          error -> error
        end
      end)
    else
      {:error, :search_scope_unavailable}
    end
  end

  @doc "Record source provenance in the same transaction as durable admission."
  def remember_admitted!(rows) do
    channels =
      for row <- rows,
          context = row["_semantic_context"] || %{},
          scope =
            Map.merge(
              Map.take(context, ~w(group_id connect_id connect_generation)),
              Map.take(row, ~w(tenant_id workspace_id channel_id))
            ),
          valid_scope?(scope) do
        Map.put(scope, "connect_generation", scope["connect_generation"] || "")
      end

    insert_channels!(Enum.uniq(channels))
  end

  defp insert_channels!([]), do: :ok

  defp insert_channels!(rows) do
    Repo.query!(
      """
      INSERT INTO slack_semantic.search_channels
        (tenant_id, group_id, connect_id, connect_generation, workspace_id, channel_id)
      SELECT tenant_id, group_id, connect_id, connect_generation, workspace_id, channel_id
      FROM jsonb_to_recordset($1::jsonb) AS r(tenant_id text, group_id text, connect_id text,
        connect_generation text, workspace_id text, channel_id text)
      ON CONFLICT DO NOTHING
      """,
      [rows]
    )

    seed_cursors!(rows)
    :ok
  end

  defp seed_cursors!(rows) do
    Repo.query!(
      """
      INSERT INTO slack_semantic.search_cursors
        (tenant_id, workspace_id, channel_id, group_id, connect_id)
      SELECT tenant_id, workspace_id, channel_id, group_id, connect_id
      FROM jsonb_to_recordset($1::jsonb) AS r(tenant_id text, workspace_id text, channel_id text,
        group_id text, connect_id text)
      ON CONFLICT DO NOTHING
      """,
      [rows]
    )

    :ok
  end

  @doc "Initialize at most twenty retained channels after a connect workspace or activation change."
  def initialize_connect_page do
    safe(fn ->
      Repo.transaction(fn ->
        case Repo.query!("""
             SELECT tenant_id, group_id, connect_id, workspace_id, connect_generation, initialization_cursor
             FROM slack_semantic.search_connects
             WHERE active AND initialization_pending
             ORDER BY initialization_due, tenant_id, group_id, connect_id
             LIMIT 1 FOR UPDATE SKIP LOCKED
             """).rows do
          [] ->
            :idle

          [[tenant, group, connect, workspace, generation, cursor]] ->
            channels =
              Repo.query!(
                """
                SELECT channel_id FROM slack_semantic.search_channels
                WHERE tenant_id=$1 AND group_id=$2 AND connect_id=$3 AND workspace_id=$4 AND channel_id>$5
                ORDER BY channel_id LIMIT 20
                """,
                [tenant, group, connect, workspace, cursor]
              ).rows

            rows =
              Enum.map(channels, fn [channel] ->
                %{
                  "tenant_id" => tenant,
                  "group_id" => group,
                  "connect_id" => connect,
                  "workspace_id" => workspace,
                  "connect_generation" => generation,
                  "channel_id" => channel
                }
              end)

            # Re-activation also needs one pass when its generation is unchanged.
            Enum.each(rows, fn row ->
              Repo.query!(
                """
                INSERT INTO slack_semantic.search_cursors
                  (tenant_id, workspace_id, channel_id, group_id, connect_id)
                VALUES ($1,$2,$3,$4,$5)
                ON CONFLICT (tenant_id, workspace_id, channel_id, group_id, connect_id)
                DO UPDATE SET before_ts_us=0, completed=false,
                  due_at=timezone('UTC', clock_timestamp())
                """,
                Enum.map(
                  ~w(tenant_id workspace_id channel_id group_id connect_id),
                  &row[&1]
                )
              )
            end)

            Repo.query!(
              """
              UPDATE slack_semantic.search_connects SET initialization_cursor=$4,
                initialization_pending=NOT $5,
                initialization_due=timezone('UTC', clock_timestamp())+interval '1 millisecond'
              WHERE tenant_id=$1 AND group_id=$2 AND connect_id=$3
              """,
              [
                tenant,
                group,
                connect,
                if(channels == [], do: cursor, else: hd(List.last(channels))),
                length(channels) < 20
              ]
            )

            :advanced
        end
      end)
    end)
  end

  @doc "One unfinished exact channel snapshot. Canonical reads happen outside its transaction."
  def next_initialization do
    safe(fn ->
      Repo.transaction(fn ->
        rows =
          Repo.query!("""
          WITH candidates AS MATERIALIZED (
            SELECT * FROM slack_semantic.search_cursors
            WHERE NOT completed AND due_at <= timezone('UTC',clock_timestamp())
            ORDER BY due_at,tenant_id,workspace_id,channel_id,group_id,connect_id
            LIMIT 20 FOR UPDATE SKIP LOCKED
          )
          SELECT s.tenant_id,s.workspace_id,s.channel_id,s.group_id,s.connect_id,
            s.before_ts_us,c.active,c.connect_generation,c.workspace_id
          FROM candidates s LEFT JOIN slack_semantic.search_connects c
            USING (tenant_id,group_id,connect_id)
          ORDER BY s.due_at,s.tenant_id,s.workspace_id,s.channel_id,s.group_id,s.connect_id
          """).rows

        Enum.reduce(rows, nil, fn row, chosen ->
          [tenant, workspace, channel, group, connect, cursor, active, current, current_workspace] =
            row

          scope =
            Map.new(
              Enum.zip(
                ~w(tenant_id workspace_id channel_id group_id connect_id connect_generation),
                [tenant, workspace, channel, group, connect, current]
              )
            )

          if active == true and current_workspace == workspace do
            chosen || {scope, cursor}
          else
            # Inactive cursors are complete. Their owner seeds
            # a new finite pass on activation or workspace change.
            Repo.query!(
              """
              UPDATE slack_semantic.search_cursors SET completed=$6,
                due_at=timezone('UTC',clock_timestamp())+interval '5 seconds'
              WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3 AND group_id=$4 AND connect_id=$5
              """,
              [tenant, workspace, channel, group, connect, not is_nil(active)]
            )

            chosen
          end
        end)
      end)
    end)
  end

  @doc "A finite candidate set must still have owner-observed channel provenance."
  def known_candidates(candidates) when length(candidates) <= 200 do
    safe(fn ->
      keys = Enum.map(candidates, &Map.take(&1, @scope_keys ++ ~w(channel_id build_id)))

      rows =
        Repo.query!(
          """
          SELECT q.build_id FROM jsonb_to_recordset($1::jsonb) AS q(
            tenant_id text, group_id text, connect_id text, workspace_id text, channel_id text, build_id text)
          JOIN slack_semantic.search_channels c
            USING (tenant_id, group_id, connect_id, workspace_id, channel_id)
          """,
          [keys]
        ).rows

      {:ok, MapSet.new(rows, &hd/1)}
    end)
  end

  @doc "At most 64 indexed connect references; an explicit connect may narrow this."
  def connects(tenant, group, connect_id \\ "") do
    safe(fn ->
      result =
        Repo.query!(
          """
          SELECT connect_id, connect_generation, workspace_id
          FROM slack_semantic.search_connects
          WHERE tenant_id=$1 AND group_id=$2 AND active AND ($3='' OR connect_id=$3)
          ORDER BY connect_id LIMIT 65
          """,
          [tenant, group, connect_id]
        )

      if length(result.rows) > @connect_limit do
        {:error, :search_scope_over_budget}
      else
        {:ok,
         Enum.map(result.rows, fn [id, generation, workspace] ->
           %{
             "tenant_id" => tenant,
             "group_id" => group,
             "connect_id" => id,
             "connect_generation" => generation,
             "workspace_id" => workspace
           }
         end)}
      end
    end)
  end

  @doc "One indexed channel page for background discovery, never a query fan-out."
  def channel_page(connect, after_channel, limit) when limit in 1..200 do
    safe(fn ->
      result =
        Repo.query!(
          """
          SELECT channel_id FROM slack_semantic.search_channels
          WHERE tenant_id=$1 AND group_id=$2 AND connect_id=$3
            AND workspace_id=$4 AND channel_id>$5
          ORDER BY channel_id LIMIT $6
          """,
          Enum.map(@scope_keys, &connect[&1]) ++ [after_channel, limit]
        )

      {:ok,
       Enum.map(result.rows, fn [channel] ->
         Map.put(Map.take(connect, @reference_keys), "channel_id", channel)
       end)}
    end)
  end

  defp valid_scope?(scope),
    do: Enum.all?(@scope_keys, &(is_binary(scope[&1]) and byte_size(scope[&1]) in 1..256))

  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, :search_scope_unavailable}
  catch
    :exit, _ -> {:error, :search_scope_unavailable}
  end
end
