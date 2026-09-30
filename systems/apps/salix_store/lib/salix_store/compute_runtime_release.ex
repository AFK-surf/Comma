defmodule SalixStore.ComputeRuntimeRelease do
  @moduledoc """
  The successful release runner publishes the desired external Runtime catalog.
  Helm revision orders publications. Runtime digests only test equality.
  This projection does not own release success or Workload update phases.
  """

  alias SalixStore.{Repo, RuntimeBundleCatalog}
  import Ecto.Query
  alias SalixStore.Compute
  @templates ~w(external.codex external.claude external.pi)

  # Called in a Job using the successful release's immutable server image.
  # Helm's existing serving revision fences a late Job from an older release.
  def publish(release_id, helm_revision)
      when is_binary(release_id) and byte_size(release_id) in 1..256 and
             is_integer(helm_revision) and helm_revision > 0 do
    with {:ok, templates} <- templates() do
      case Repo.query(
             """
             INSERT INTO compute_runtime_release (id, helm_revision, release_id, templates, published_at)
             VALUES (1, $1, $2, $3, now())
             ON CONFLICT (id) DO UPDATE SET
               helm_revision = EXCLUDED.helm_revision, release_id = EXCLUDED.release_id,
               templates = EXCLUDED.templates, published_at = EXCLUDED.published_at
             WHERE compute_runtime_release.helm_revision < EXCLUDED.helm_revision
                OR (compute_runtime_release.helm_revision = EXCLUDED.helm_revision
                    AND compute_runtime_release.release_id = EXCLUDED.release_id
                    AND compute_runtime_release.templates = EXCLUDED.templates)
             """,
             [helm_revision, release_id, templates]
           ) do
        {:ok, %{num_rows: 1}} -> :ok
        {:ok, _} -> {:error, :runtime_release_superseded}
        {:error, _} -> {:error, :runtime_release_unavailable}
      end
    end
  end

  def publish(_, _), do: {:error, :invalid_runtime_release}

  def target(template_key) do
    case Repo.query("SELECT templates->$1 FROM compute_runtime_release WHERE id = 1", [
           template_key
         ]) do
      {:ok, %{rows: [[target]]}} when is_map(target) -> {:ok, target}
      {:ok, _} -> {:ok, nil}
      {:error, _} -> {:error, :runtime_release_unavailable}
    end
  end

  @doc "Release-operator projection. At most 50 Workloads, with a stable ID cursor."
  def status_page(after_id \\ "") when is_binary(after_id) do
    rows =
      Repo.all(
        from(w in Compute.Workload,
          join: a in Compute.Allocation,
          on: a.id == w.allocation_id,
          join: b in Compute.ProviderBinding,
          on: b.id == a.provider_binding_id,
          join: e in Compute.Environment,
          on: e.id == w.environment_id,
          where:
            w.id > ^after_id and w.kind == "external_worker" and
              w.template_key in ^@templates and e.owner_type == "project" and
              e.desired_state == "ready" and e.generation == w.generation and
              a.generation == w.generation and
              w.desired_state == "ready" and a.status != "released" and
              b.provider == "agent_vmm" and b.status != "revoked",
          order_by: [asc: w.id],
          limit: 51,
          select: %{
            workload_id: w.id,
            runtime_revision: w.runtime_revision,
            template_key: w.template_key,
            update: w.runtime_update
          }
        )
      )

    case Repo.query(
           "SELECT release_id, helm_revision, templates FROM compute_runtime_release WHERE id = 1"
         ) do
      {:ok, %{rows: [[release, revision, targets]]}} ->
        items =
          rows
          |> Enum.take(50)
          |> Enum.map(fn row ->
            target = get_in(targets, [row.template_key, "runtime_revision"])
            update = row.update || %{}

            state =
              cond do
                update["action_required"] == true -> "failed"
                update["phase"] not in [nil, "complete", "cancelled"] -> "waiting"
                row.runtime_revision == target -> "complete"
                true -> "waiting"
              end

            %{
              workload_id: row.workload_id,
              runtime_revision: row.runtime_revision,
              desired_runtime_revision: target,
              state: state,
              stage: update["phase"] || "pending",
              error: update["error"]
            }
          end)

        {:ok,
         %{
           release_id: release,
           helm_revision: revision,
           items: items,
           next_cursor: if(length(rows) > 50, do: List.last(items).workload_id)
         }}

      {:ok, %{rows: []}} ->
        {:ok, %{publication: "pending", items: [], next_cursor: nil}}

      {:error, _} ->
        {:error, :runtime_release_unavailable}
    end
  end

  defp templates do
    Enum.reduce_while(@templates, {:ok, %{}}, fn key, {:ok, acc} ->
      case RuntimeBundleCatalog.materialize(key, %{owner_id: "release-template", generation: 1}) do
        {:ok, materialized} ->
          # Volume IDs belong to each Workload. Only the product layout travels
          # with the release, so publication cannot replace a named volume.
          layout =
            Enum.map(materialized.spec["volume_requirements"], &Map.delete(&1, "volume_id"))

          target = %{
            "runtime_revision" => materialized.runtime_revision,
            "artifact" => materialized.spec["runtime_artifact"],
            "volume_layout" => layout
          }

          {:cont, {:ok, Map.put(acc, key, target)}}

        error ->
          {:halt, error}
      end
    end)
  end
end
