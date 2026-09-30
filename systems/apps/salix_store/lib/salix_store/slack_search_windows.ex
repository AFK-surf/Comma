defmodule SalixStore.SlackSearchWindows do
  @moduledoc """
  Fifteen-minute, finite search result windows. Tokens carry no authority.

  Each page rechecks current source/publication/group-connect facts. Only
  authorized remaining candidates are retained, without excerpts or vectors;
  opaque page IDs expose neither rejected-match counts nor raw offsets.
  """
  alias SalixStore.Repo

  def put(scope, request, candidates, expires_at \\ nil)
  def put(_scope, _request, [], _expires_at), do: {:ok, nil}

  def put(scope, request, candidates, expires_at)
      when is_list(candidates) and length(candidates) <= 200 do
    safe(fn ->
      id = Ecto.UUID.generate()

      Repo.query!(
        """
        INSERT INTO slack_semantic.search_windows
          (id, tenant_id, group_id, request, candidates, expires_at)
        VALUES ($1::text::uuid, $2, $3, $4, $5,
          COALESCE($6::timestamp, timezone('UTC', clock_timestamp()) + interval '15 minutes'))
        """,
        [id, scope.tenant_id, scope.group_id, request, candidates, expires_at]
      )

      {:ok, id}
    end)
  end

  def get(scope, token) do
    with {:ok, _} <- Ecto.UUID.cast(token) do
      safe(fn ->
        case Repo.query!(
               """
               SELECT request, candidates, expires_at FROM slack_semantic.search_windows
               WHERE id=$1::text::uuid AND tenant_id=$2 AND group_id=$3
                 AND expires_at > timezone('UTC', clock_timestamp())
               """,
               [token, scope.tenant_id, scope.group_id]
             ).rows do
          [[request, candidates, expires_at]] -> {:ok, request, candidates, expires_at}
          [] -> {:error, :search_window_expired}
        end
      end)
    else
      _ -> {:error, :invalid_search_cursor}
    end
  end

  @doc "Bounded cleanup on the existing semantic queue maintenance tick."
  def prune do
    safe(fn ->
      Repo.query!("""
      DELETE FROM slack_semantic.search_windows WHERE id IN (
        SELECT id FROM slack_semantic.search_windows
        WHERE expires_at <= timezone('UTC', clock_timestamp())
        ORDER BY expires_at, id LIMIT 1000 FOR UPDATE SKIP LOCKED)
      """)

      :ok
    end)
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, :search_metadata_unavailable}
  catch
    :exit, _ -> {:error, :search_metadata_unavailable}
  end
end
