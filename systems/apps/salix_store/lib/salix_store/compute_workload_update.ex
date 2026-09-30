defmodule SalixStore.ComputeWorkloadUpdate do
  @moduledoc false

  import Ecto.Query
  alias SalixStore.{Compute, Repo, RuntimeBundleCatalog}

  def active?(%{runtime_update: %{"phase" => phase}}),
    do: phase not in ["complete", "cancelled"]

  def active?(_), do: false

  def input_paused?(%{runtime_update: %{"phase" => phase} = update} = workload),
    do: active?(workload) and (phase != "preparing" or update["input_paused"] == true)

  def input_paused?(_), do: false

  # The provider holds the Workload operation lock. Existing operations always
  # finish first, even when a newer release publishes another target.
  def start_automatic(workload) do
    if active?(workload) or workload.desired_state != "ready" or
         workload.kind != "external_worker" do
      {:ok, workload}
    else
      with {:ok, target} <- SalixStore.ComputeRuntimeRelease.target(workload.template_key) do
        admit_automatic(workload, target)
      end
    end
  end

  defp admit_automatic(workload, nil), do: {:ok, workload}

  defp admit_automatic(workload, target) do
    previous = workload.runtime_update || %{}
    layout = Enum.map(workload.spec["volume_requirements"] || [], &Map.delete(&1, "volume_id"))

    cond do
      workload.runtime_revision == target["runtime_revision"] ->
        {:ok, workload}

      previous["phase"] == "cancelled" and
          previous["target_revision"] == target["runtime_revision"] ->
        {:ok, workload}

      true ->
        environment = Repo.get!(Compute.Environment, workload.environment_id)

        with {:ok, _} <- authorized(environment.tenant_id, environment.owner_id, workload.id),
             {:ok, _} <- RuntimeBundleCatalog.image_for_workload(workload) do
          update = %{
            "operation_id" =>
              "auto-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
            "automatic" => true,
            "phase" => "preparing",
            "attempt" => 1,
            "source_revision" => workload.runtime_revision,
            "source_artifact" => workload.spec["runtime_artifact"],
            "target_revision" => target["runtime_revision"],
            "target_artifact" => target["artifact"],
            "deadline" => now() + 1_800,
            "error" => if(layout != target["volume_layout"], do: "volume_layout_changed"),
            "action_required" => layout != target["volume_layout"]
          }

          {:ok, save(workload, update)}
        end
    end
  end

  # This lock serializes update steps with ordinary provider recovery. It has
  # no identity or authorization role; a collision only serializes extra work.
  def with_lock(workload_id, fun) do
    Repo.transaction(
      fn ->
        case Repo.query!(
               "SELECT pg_try_advisory_xact_lock(hashtextextended($1, 4412742))",
               [workload_id]
             ).rows do
          [[true]] -> fun.()
          _ -> {:error, :workload_operation_busy}
        end
      end,
      timeout: 900_000
    )
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @budget_seconds 1_800
  @drain_seconds 600
  # Trusted operator RPC only. The caller names an exact tenant/project and
  # reviewed Workload revision. Images come from the serving release catalog.
  def start(%{
        "tenant_id" => tenant,
        "project_id" => project,
        "workload_id" => id,
        "operation_id" => operation,
        "expected_revision" => revision,
        "target_runtime_revision" => target
      }) do
    with true <- is_binary(operation) and Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, operation),
         true <- is_integer(revision) and is_binary(target),
         true <- is_binary(tenant) and is_binary(project) and is_binary(id) do
      with_lock(id, fn ->
        with {:ok, workload} <- authorized(tenant, project, id),
             {:ok, _source} <- RuntimeBundleCatalog.image_for_workload(workload),
             {:ok, materialized} <-
               RuntimeBundleCatalog.materialize(workload.template_key, %{
                 owner_id: id,
                 generation: workload.generation
               }) do
          cond do
            get_in(workload.runtime_update || %{}, ["operation_id"]) == operation ->
              if workload.runtime_update["target_revision"] == target,
                do: {:ok, projection(workload)},
                else: {:error, :update_operation_conflict}

            active?(workload) ->
              {:error, :update_in_progress}

            workload.revision != revision ->
              {:error, :revision_conflict}

            materialized.runtime_revision != target ->
              {:error, :release_target_changed}

            workload.spec["volume_requirements"] != materialized.spec["volume_requirements"] ->
              {:error, :volume_layout_changed}

            workload.runtime_revision == target ->
              {:ok, projection(workload)}

            true ->
              update = %{
                "operation_id" => operation,
                "phase" => "preparing",
                "attempt" => 1,
                "source_revision" => workload.runtime_revision,
                "source_artifact" => workload.spec["runtime_artifact"],
                "target_revision" => target,
                "target_artifact" => materialized.spec["runtime_artifact"],
                "deadline" => now() + @budget_seconds,
                "error" => nil,
                "action_required" => false
              }

              clear_parked_claim(workload)
              {:ok, projection(save(workload, update))}
          end
        end
      end)
    else
      _ -> {:error, :invalid_workload_update}
    end
  end

  def start(_), do: {:error, :invalid_workload_update}

  def status(%{"tenant_id" => tenant, "project_id" => project, "workload_id" => id})
      when is_binary(tenant) and is_binary(project) and is_binary(id) do
    with {:ok, workload} <- authorized(tenant, project, id), do: {:ok, projection(workload)}
  end

  def status(_), do: {:error, :invalid_workload_update}

  def retry(attrs), do: operator_change(attrs, :retry)
  def cancel(attrs), do: operator_change(attrs, :cancel)

  def renew_automatic_attempt(%{runtime_update: %{"automatic" => true} = update} = workload) do
    save(workload, retry_update(update))
  end

  defp retry_update(update) do
    Map.merge(update, %{
      "deadline" => now() + @budget_seconds,
      "drain_deadline" => now() + @drain_seconds,
      "error" => nil,
      "action_required" => false,
      "reset_quiesce" => update["phase"] == "stopping",
      "quiesce_attempt" =>
        if(update["phase"] == "stopping", do: update["quiesce_attempt"] || update["attempt"]),
      "attempt" => update["attempt"] + 1
    })
  end

  # Rebase an exact post-cutover update onto the current serving catalog. This
  # is an operator-authorized forward repair: it never makes the retired image
  # a rollback target and it preserves the Workload, generation, volume, and
  # paused-input boundary.
  def forward_repair(%{
        "tenant_id" => tenant,
        "project_id" => project,
        "workload_id" => id,
        "operation_id" => operation,
        "repair_operation_id" => repair_operation,
        "expected_revision" => revision,
        "target_runtime_revision" => target
      })
      when is_binary(tenant) and is_binary(project) and is_binary(id) and
             is_binary(operation) and is_integer(revision) and is_binary(target) and
             is_binary(repair_operation) do
    with true <- valid_operation_id?(repair_operation) do
      with_lock(id, fn ->
        with {:ok, workload} <- authorized(tenant, project, id),
             true <- workload.revision == revision || {:error, :revision_conflict},
             %{"operation_id" => ^operation, "phase" => "verifying", "action_required" => true} =
               update <- workload.runtime_update,
             true <-
               workload.runtime_revision == update["target_revision"] ||
                 {:error, :update_not_cut_over},
             {:ok, materialized} <-
               RuntimeBundleCatalog.materialize(workload.template_key, %{
                 owner_id: id,
                 generation: workload.generation
               }) do
          cond do
            materialized.runtime_revision != target ->
              {:error, :release_target_changed}

            workload.runtime_revision == target ->
              {:error, :repair_target_unchanged}

            workload.spec["volume_requirements"] != materialized.spec["volume_requirements"] ->
              {:error, :volume_layout_changed}

            true ->
              next =
                update
                |> Map.drop(
                  ~w(container_id container_generation container_instance completed_at drain_deadline error quiesce_attempt reset_quiesce)
                )
                |> Map.merge(%{
                  "operation_id" => repair_operation,
                  "root_operation_id" => update["root_operation_id"] || operation,
                  "supersedes_operation_id" => operation,
                  "phase" => "preparing",
                  "input_paused" => true,
                  "attempt" => update["attempt"] + 1,
                  "source_revision" => workload.runtime_revision,
                  "source_artifact" => workload.spec["runtime_artifact"],
                  "target_revision" => target,
                  "target_artifact" => materialized.spec["runtime_artifact"],
                  "deadline" => now() + @budget_seconds,
                  "error" => nil,
                  "action_required" => false
                })

              clear_parked_claim(workload)
              {:ok, projection(save(workload, next))}
          end
        else
          {:error, _} = error -> error
          _ -> {:error, :update_operation_conflict}
        end
      end)
    else
      _ -> {:error, :invalid_workload_update}
    end
  end

  def forward_repair(_), do: {:error, :invalid_workload_update}

  defp operator_change(
         %{
           "tenant_id" => tenant,
           "project_id" => project,
           "workload_id" => id,
           "operation_id" => operation,
           "expected_revision" => revision
         },
         action
       )
       when is_binary(tenant) and is_binary(project) and is_binary(id) and
              is_binary(operation) and is_integer(revision) do
    with_lock(id, fn ->
      with {:ok, workload} <- authorized(tenant, project, id),
           true <- workload.revision == revision || {:error, :revision_conflict},
           %{"operation_id" => ^operation} = update <- workload.runtime_update do
        cond do
          action == :cancel and update["phase"] in ["preparing", "draining"] ->
            clear_parked_claim(workload)

            {:ok,
             projection(
               save(
                 workload,
                 Map.merge(update, %{
                   "phase" => "cancelled",
                   "error" => nil,
                   "action_required" => false
                 })
               )
             )}

          action == :retry and update["action_required"] == true ->
            next = retry_update(update)

            Repo.update_all(
              from(c in Compute.ReconcilerClaim,
                where: c.workload_id == ^id and c.generation == ^workload.generation
              ),
              set: [last_error: %{}, next_retry_at: nil, updated_at: DateTime.utc_now()]
            )

            {:ok, projection(save(workload, next))}

          true ->
            {:error, :update_transition_not_allowed}
        end
      else
        {:error, _} = error -> error
        _ -> {:error, :update_operation_conflict}
      end
    end)
  end

  defp operator_change(_, _), do: {:error, :invalid_workload_update}

  defp valid_operation_id?(operation),
    do: is_binary(operation) and Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, operation)

  defp authorized(tenant, project, id) do
    query =
      from(w in Compute.Workload,
        join: e in Compute.Environment,
        on: e.id == w.environment_id,
        join: a in Compute.Allocation,
        on: a.id == w.allocation_id,
        join: b in Compute.ProviderBinding,
        on: b.id == a.provider_binding_id,
        where:
          w.id == ^id and e.tenant_id == ^tenant and e.owner_id == ^project and
            e.owner_type == "project" and a.generation == w.generation and
            e.generation == w.generation and w.kind == "external_worker" and
            w.template_key in ["external.codex", "external.claude", "external.pi"] and
            w.desired_state == "ready" and e.desired_state == "ready" and a.status != "released" and
            b.provider == "agent_vmm" and b.status != "revoked",
        select: w
      )

    case Repo.one(query) do
      nil -> {:error, :workload_not_found}
      workload -> {:ok, workload}
    end
  end

  def save(workload, update, extra \\ []) do
    # The row lock also fences concurrent input claims at the pause boundary.
    current =
      Repo.one!(from(w in Compute.Workload, where: w.id == ^workload.id, lock: "FOR UPDATE"))

    if current.revision != workload.revision or current.desired_state != "ready",
      do: Repo.rollback(:revision_conflict)

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^workload.id),
      set:
        [runtime_update: update, observed_state: "pending", updated_at: DateTime.utc_now()] ++
          extra,
      inc: [revision: 1]
    )

    if update["phase"] == "complete" do
      Repo.update_all(
        from(c in Compute.ReconcilerClaim,
          where:
            c.workload_id == ^workload.id and c.generation == ^workload.generation and
              is_nil(c.lease_expires_at) and
              fragment("?->>'code'", c.last_error) == "workload_update_action_required"
        ),
        set: [last_error: %{}, next_retry_at: nil, updated_at: DateTime.utc_now()]
      )
    end

    Repo.get!(Compute.Workload, workload.id)
  end

  defp clear_parked_claim(workload) do
    Repo.update_all(
      from(c in Compute.ReconcilerClaim,
        where: c.workload_id == ^workload.id and c.generation == ^workload.generation
      ),
      set: [last_error: %{}, next_retry_at: nil, updated_at: DateTime.utc_now()]
    )
  end

  defp projection(workload),
    do: %{
      workload_id: workload.id,
      revision: workload.revision,
      runtime_revision: workload.runtime_revision,
      available_runtime_revision: available_revision(workload),
      update:
        if(workload.runtime_update,
          do: Map.drop(workload.runtime_update, ["source_artifact", "target_artifact"]),
          else: nil
        )
    }

  defp available_revision(workload) do
    case RuntimeBundleCatalog.materialize(workload.template_key, %{
           owner_id: workload.id,
           generation: workload.generation
         }) do
      {:ok, target} -> target.runtime_revision
      _ -> nil
    end
  end

  defp now, do: System.system_time(:second)
end
