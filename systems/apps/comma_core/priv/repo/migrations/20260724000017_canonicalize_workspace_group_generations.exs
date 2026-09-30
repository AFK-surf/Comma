defmodule Comma.Repo.Migrations.CanonicalizeWorkspaceGroupGenerations do
  use Ecto.Migration

  def up do
    %{rows: rows} =
      repo().query!(
        """
        SELECT
          id,
          salix_tenant_id,
          salix_group_id,
          salix_router_agent_id,
          group_generation
        FROM comma_workspaces
        ORDER BY id
        FOR UPDATE
        """,
        [],
        log: false
      )

    Enum.each(rows, fn [id, tenant_id, group_id, router_id, current] ->
      canonical = generation([tenant_id, group_id])
      legacy = generation([tenant_id, group_id, router_id])

      cond do
        current == canonical ->
          :ok

        current == legacy ->
          %{num_rows: 1} =
            repo().query!(
              """
              UPDATE comma_workspaces
              SET group_generation = $1,
                  updated_at = NOW()
              WHERE id = $2
                AND group_generation = $3
              """,
              [canonical, id, legacy],
              log: false
            )

        true ->
          raise """
          workspace #{id} has a group generation that matches neither the \
          canonical tenant/group binding nor the retired tenant/group/router \
          binding; preserve the row and inspect its provenance
          """
      end
    end)
  end

  def down do
    raise "workspace group generation canonicalization is forward-only"
  end

  defp generation(parts) when is_list(parts) do
    :crypto.hash(:sha256, Enum.join(parts, ":"))
    |> Base.url_encode64(padding: false)
  end
end
