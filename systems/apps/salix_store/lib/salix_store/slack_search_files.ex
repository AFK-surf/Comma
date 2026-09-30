defmodule SalixStore.SlackSearchFiles do
  @moduledoc """
  Accepted Slack file changes invalidate published media immediately.

  Events advance an observation epoch, not a provider version. Duplicate or
  reordered changes may require fresh extraction but never validate an older
  snapshot. Only authenticated webhook observation writes this state. A
  background page schedules at most twenty message references, committing its
  cursor with the jobs. Modeled in tla/salix/MessageSearchFile.tla.
  """
  alias SalixStore.Repo

  def observe(connect, %{"event" => %{"type" => type} = event})
      when type in ["file_change", "file_deleted"] do
    file = event["file_id"] || get_in(event, ["file", "id"])
    key = [connect["tenant_id"], connect["workspace_id"], file]

    if Enum.all?(key, &(is_binary(&1) and byte_size(&1) in 1..256)) do
      safe(fn ->
        Repo.query!(
          """
          INSERT INTO slack_semantic.search_files
            (tenant_id, workspace_id, file_id, change_epoch, deleted, refresh_pending)
          VALUES ($1,$2,$3,1,$4,true)
          ON CONFLICT (tenant_id, workspace_id, file_id) DO UPDATE SET
            change_epoch=search_files.change_epoch+1, deleted=EXCLUDED.deleted,
            refresh_pending=true, refresh_cursor='{}'::jsonb,
            changed_at=timezone('UTC', clock_timestamp())
          """,
          key ++ [type == "file_deleted"]
        )

        :ok
      end)
    else
      {:error, :outbox_unavailable}
    end
  end

  def observe(_, _), do: :ok

  @doc "Lock the file beside the source lock, before allocating the build sequence."
  def capture!(_scope, ""), do: %{file_epoch: 0, file_deleted: false}

  def capture!(scope, file_id) do
    key = [scope["tenant_id"], scope["workspace_id"], file_id]

    Repo.query!(
      """
      INSERT INTO slack_semantic.search_files (tenant_id, workspace_id, file_id)
      VALUES ($1,$2,$3) ON CONFLICT DO NOTHING
      """,
      key
    )

    [[epoch, deleted]] =
      Repo.query!(
        """
        SELECT change_epoch, deleted FROM slack_semantic.search_files
        WHERE tenant_id=$1 AND workspace_id=$2 AND file_id=$3 FOR UPDATE
        """,
        key
      ).rows

    %{file_epoch: epoch, file_deleted: deleted}
  end

  def validate!(component) do
    if (component["file_id"] || "") != "" do
      state = capture!(component, component["file_id"])

      if state.file_epoch != component["file_epoch"] or
           (state.file_deleted and component["unit_count"] != 0 and component["embeddings"] != []) do
        Repo.rollback(:file_changed)
      end
    end

    :ok
  end

  @doc "One indexed pending file and at most twenty references per existing worker tick."
  def reconcile_page(enqueue) do
    safe(fn ->
      Repo.transaction(fn ->
        case Repo.query!("""
             SELECT tenant_id, workspace_id, file_id, refresh_cursor
             FROM slack_semantic.search_files WHERE refresh_pending
             ORDER BY changed_at, tenant_id, workspace_id, file_id
             LIMIT 1 FOR UPDATE SKIP LOCKED
             """).rows do
          [] ->
            :idle

          [[tenant, workspace, file, cursor]] ->
            rows =
              Repo.query!(
                """
                SELECT group_id, connect_id, channel_id, message_ts_us, connect_generation
                FROM slack_semantic.search_components
                WHERE tenant_id=$1 AND workspace_id=$2 AND file_id=$3
                  AND (group_id, connect_id, channel_id, message_ts_us) > ($4,$5,$6,$7)
                ORDER BY group_id, connect_id, channel_id, message_ts_us LIMIT 20
                """,
                [
                  tenant,
                  workspace,
                  file,
                  cursor["group"] || "",
                  cursor["connect"] || "",
                  cursor["channel"] || "",
                  cursor["timestamp"] || 0
                ]
              ).rows

            Enum.each(rows, fn [group, connect, channel, timestamp, generation] ->
              scope = %{
                "tenant_id" => tenant,
                "workspace_id" => workspace,
                "group_id" => group,
                "connect_id" => connect,
                "channel_id" => channel,
                "connect_generation" => generation
              }

              case enqueue.(scope, timestamp, file) do
                {:ok, _} -> :ok
                {:error, reason} -> Repo.rollback(reason)
                error -> Repo.rollback(error)
              end
            end)

            next =
              case List.last(rows) do
                nil ->
                  cursor

                [g, c, ch, ts, _] ->
                  %{"group" => g, "connect" => c, "channel" => ch, "timestamp" => ts}
              end

            Repo.query!(
              """
              UPDATE slack_semantic.search_files SET refresh_cursor=$4, refresh_pending=$5
              WHERE tenant_id=$1 AND workspace_id=$2 AND file_id=$3
              """,
              [tenant, workspace, file, next, length(rows) == 20]
            )

            :advanced
        end
      end)
    end)
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, :outbox_unavailable}
  catch
    :exit, _ -> {:error, :outbox_unavailable}
  end
end
