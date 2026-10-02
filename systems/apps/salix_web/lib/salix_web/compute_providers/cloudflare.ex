defmodule SalixWeb.ComputeProviders.Cloudflare do
  @moduledoc "Group Workload lifecycle executed through Compute; platform transport stays in salix_env."

  require Logger

  import SalixWeb.CloudVM,
    only: [
      validate_enabled: 2,
      worker_release: 0,
      cloudflare_config: 1,
      release_kind: 1
    ]

  alias SalixEnv.Registry
  alias SalixEnv.VM.Providers.Cloudflare.Client, as: CloudflareClient
  alias SalixStore.{Keys, RuntimeIds, S3}
  alias SalixWeb.CloudVM.DurableArchive
  alias SalixStore.Compute, as: GroupCompute

  @env_alias "cloud-vm"

  @config_missing_error "vm.enabled requires tenant vm provider configuration"
  @defaults %{
    auto_provision: true,
    verify_connector: true,
    bootstrap_timeout_ms: 300_000,
    bootstrap_poll_ms: 1_000,
    idle_archive_ms: 300_000,
    stale_claim_ms: 60_000,
    max_provision_age_ms: 300_000,
    metering_provider: "cloudflare"
  }

  @mutating_vm_operations MapSet.new([
                            "exec",
                            "write",
                            "write_stream",
                            "computer_use",
                            "process_write"
                          ])

  @type provision_outcome :: :ready | :failed | :orphaned | :billing_suspended

  defmodule VMAuthorization do
    @moduledoc false
    @callback authorize_vm(map()) :: :ok | {:error, term()}

    defmodule Noop do
      @moduledoc false
      @behaviour SalixWeb.ComputeProviders.Cloudflare.VMAuthorization

      @impl true
      def authorize_vm(_attrs), do: :ok
    end

    defmodule BillingCore do
      @moduledoc false
      @behaviour SalixWeb.ComputeProviders.Cloudflare.VMAuthorization

      @impl true
      def authorize_vm(attrs) do
        owner = attrs[:billing_owner] || %{}

        account_id = owner["billing_account_id"] || owner[:billing_account_id]
        entrypoint = attrs[:entrypoint] || "cloud_vm_reconcile"
        actor_type = attrs[:actor_type] || "system"

        request =
          Module.concat([:BillingCore, :FeeControl, :Request])
          |> struct(%{
            billing_account_id: owner["billing_account_id"] || owner[:billing_account_id],
            resource_kind: :vm,
            action: attrs[:action] || :resume,
            mode: :enforce,
            estimated_credits: 1,
            balance_snapshot: attrs[:balance_snapshot] || owner["balance_snapshot"] || 0,
            provider: attrs[:provider] || "cloudflare",
            sku: attrs[:sku] || "runtime-minimum",
            typed_sink: attrs[:typed_sink],
            source: "vm_authorization",
            source_key: attrs[:source_key] || "vm:#{account_id}:#{entrypoint}",
            row_context: %{
              "billing_account_id" => account_id,
              "surface" => owner["surface"] || owner[:surface] || "unknown",
              "product_owner_type" =>
                owner["product_owner_type"] || owner[:product_owner_type] || "unknown",
              "product_owner_id" =>
                owner["product_owner_id"] || owner[:product_owner_id] || "unknown",
              "tenant_id" => owner["salix_tenant_id"] || owner[:salix_tenant_id] || "",
              "group_id" => owner["salix_group_id"] || owner[:salix_group_id] || "",
              "entrypoint" => entrypoint,
              "actor_type" => actor_type
            }
          })

        fee_control = Module.concat([:BillingCore, :FeeControl])

        case apply(fee_control, :authorize, [request]) do
          {:ok, %{allowed?: true}} -> :ok
          {:ok, decision} -> {:error, {:billing_unavailable, decision}}
          {:error, _} = err -> err
        end
      end
    end
  end

  @doc "Advance one claimed Group Workload without replaying user operations."
  def reconcile(_allocation, workload, opts) do
    with %GroupCompute.Environment{owner_type: "group", owner_id: group} <-
           SalixStore.Repo.get(GroupCompute.Environment, workload.environment_id),
         {:ok, %{"workload_id" => id, "provider" => provider} = rec} <- get_record(group),
         true <- provider == "cloudflare" || {:error, :unsupported_provider},
         true <- id == workload.id || {:error, :stale_generation} do
      cond do
        workload.desired_state in ["stopped", "draining"] ->
          with :ok <- teardown(rec, opts), do: {:ok, %{outcome: :group_reconciled}}

        rec["status"] == "archived" and is_integer(rec["wake_requested_at"]) ->
          case wake_archived_vm(group, opts) do
            {:ok, _} -> {:ok, %{outcome: :group_reconciled}}
            {:error, _} = error -> error
          end

        rec["status"] == "waking" ->
          case wake_archived_vm(group, opts) do
            {:ok, _} ->
              {:ok, %{outcome: :group_reconciled}}

            {:error, :wake_in_progress} ->
              if now_ms() - (rec["last_wake_at"] || rec["created_at"] || 0) >= 3_300_000 do
                _ = record_last_error(group, :transition_recovery_required)

                {:error,
                 {:gateway_error,
                  %{"code" => "group_transition_recovery_required", "kind" => "action_required"}}}
              else
                {:ok, %{outcome: :pending}}
              end

            {:error, _} = error ->
              error
          end

        rec["status"] == "archiving" ->
          started = rec["archive_started_at"] || rec["last_wake_at"] || rec["created_at"]

          if now_ms() - started >= 900_000 do
            _ = record_last_error(group, :transition_recovery_required)

            {:error,
             {:gateway_error,
              %{"code" => "group_transition_recovery_required", "kind" => "action_required"}}}
          else
            {:ok, %{outcome: :pending}}
          end

        rec["status"] == "creating" ->
          case provision_once(group, opts) do
            {:ok, _} -> {:ok, %{outcome: :group_reconciled}}
            {:error, _} = error -> error
          end

        rec["status"] == "ready" ->
          with {:ok, group_record} <- group_record(group) do
            _ = maybe_meter_ready_interval(rec, group_record, opts)

            if SalixWeb.CloudVM.Runtimes.pending?(rec),
              do: SalixWeb.CloudVM.Runtimes.schedule(group, opts)

            case archive_idle_once(group, opts) do
              {:ok, _} ->
                {:ok, %{outcome: :group_reconciled}}

              {:skipped, _} ->
                case maybe_revive_carrier(rec, group_record, opts) do
                  :error -> {:error, :group_attachment_unavailable}
                  _ -> {:ok, %{outcome: :group_reconciled}}
                end

              {:error, :runtime_not_quiet} ->
                {:ok, %{outcome: :group_reconciled}}

              {:error, _} = error ->
                error
            end
          end

        true ->
          empty = %{
            provisioned: [],
            failed: [],
            orphaned: [],
            revived: [],
            archived: [],
            eligible_for_resume: []
          }

          _ = sweep_one(rec, opts, empty)
          emit_recovery_metrics([rec])
          {:ok, %{outcome: :group_reconciled}}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      _ -> {:error, :unsupported_provider}
    end
  end

  # ---- durable group records ----

  @doc "Fetch the VM record for a group."
  @spec get_record(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_record(group_id), do: GroupCompute.group_workload(group_id)

  @doc """
  Ensure a VM record exists for the agent's group: create-once `creating`;
  an existing `failed` record is restarted. Returns `{:ok, record, outcome}` with
  outcome `:created | :restarted | :existing`.
  """
  @spec ensure_record(map()) :: {:ok, map(), :created | :restarted | :existing} | {:error, term()}
  def ensure_record(agent) do
    case get_in(agent, ["vm", "provider"]) || "cloudflare" do
      "cloudflare" ->
        ensure_cloudflare_record(agent)

      _ ->
        {:error, :unsupported_provider}
    end
  end

  defp ensure_cloudflare_record(%{"group_id" => group_id} = agent) do
    with {:ok, group} <- group_record(group_id),
         {:ok, profile_key} <- authorized_profile_key(group),
         :ok <- check_agent_profile(agent, profile_key) do
      create_cloudflare_record(agent, profile_key)
    else
      :missing -> {:error, :group_not_found}
      {:error, _} = error -> error
    end
  end

  defp create_cloudflare_record(%{"group_id" => group_id} = agent, profile_key) do
    provider = "cloudflare"

    rec =
      %{
        "tenant_id" => agent["tenant_id"],
        "group_id" => group_id,
        "schema_version" => 1,
        "provider" => provider,
        "provider_resource_name" => RuntimeIds.cloud_vm_provider_resource_name(group_id),
        "provider_resource_id" => RuntimeIds.cloud_vm_provider_resource_name(group_id),
        "env_id" => cloudvm_env_id(group_id),
        "device_id" => cloudvm_device_id(group_id),
        "connector_id" => cloudvm_connector_id(group_id),
        "provider_spec" => %{"profile_key" => profile_key},
        "alias" => @env_alias,
        "status" => "creating",
        "node_id" => nil,
        "attempt_at" => nil,
        "created_at" => now_ms(),
        "ready_at" => nil,
        "error" => nil
      }
      |> put_initial_worker_release(provider)
      |> maybe_put("created_by_agent_id", agent["agent_id"])

    case GroupCompute.ensure_group_workload(rec) do
      {:ok, created, :created} ->
        {:ok, created, :created}

      {:ok, _existing, :existing} ->
        restart_if_failed(group_id, rec["provider"])

      {:error, _} = error ->
        error
    end
  end

  defp authorized_profile_key(%{
         "billing_owner" => %{"surface" => "comma", "vm_profile_key" => "cf-standard-1"}
       }),
       do: {:ok, "cf-standard-1"}

  defp authorized_profile_key(%{
         "billing_owner" => %{"surface" => "bridge", "vm_profile_key" => "cf-standard-2"}
       }),
       do: {:ok, "cf-standard-2"}

  defp authorized_profile_key(%{"billing_owner" => %{"surface" => surface} = owner})
       when surface in ["cue", "comma", "bridge"] and not is_map_key(owner, "vm_profile_key"),
       do: {:ok, "cf-standard-2"}

  defp authorized_profile_key(_), do: {:error, :vm_profile_authorization_required}

  defp check_agent_profile(agent, profile_key) do
    case get_in(agent, ["vm", "profile"]) do
      nil -> :ok
      ^profile_key -> :ok
      _ -> {:error, :vm_profile_not_authorized}
    end
  end

  defp restart_if_failed(group_id, requested_provider) do
    case get_record(group_id) do
      {:ok, %{"status" => "failed"} = rec} ->
        with :ok <- ensure_provider_matches(rec, requested_provider) do
          case update_record(group_id, fn current ->
                 if current["status"] == "failed" do
                   current
                   |> Map.merge(%{
                     "status" => "creating",
                     "error" => nil,
                     "node_id" => nil,
                     "attempt_at" => nil,
                     "created_at" => now_ms()
                   })
                 else
                   {:error, :restart_already_won}
                 end
               end) do
            {:ok, restarted} -> {:ok, restarted, :restarted}
            {:error, :restart_already_won} -> restart_if_failed(group_id, requested_provider)
            {:error, _} = error -> error
          end
        end

      {:ok, rec} ->
        with :ok <- ensure_provider_matches(rec, requested_provider) do
          {:ok, rec, :existing}
        end

      {:error, _} = err ->
        err
    end
  end

  defp ensure_provider_matches(rec, requested_provider) do
    existing_provider = rec["provider"]

    if existing_provider == requested_provider do
      :ok
    else
      {:error, {:conflict, "vm provider change requires a data-preserving migration"}}
    end
  end

  @doc "Reject provider changes until the existing data and bindings have been migrated."
  @spec switch_provider(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def switch_provider(%{"group_id" => group_id, "tenant_id" => tenant_id}, provider, _opts \\ []) do
    with :ok <- validate_enabled(tenant_id, provider),
         {:ok, current} <- get_record(group_id) do
      if current["provider"] == provider,
        do: {:ok, current},
        else:
          {:error,
           {:provider_migration_required,
            "Move the existing files, archives, and bindings through the Compute release handoff before changing provider."}}
    end
  end

  defp switch_group_record(group_id) do
    case group_record(group_id) do
      {:ok, group} -> {:ok, group}
      :missing -> {:error, :group_not_found}
      {:error, _} = err -> err
    end
  end

  @doc "One page of Cloudflare versions. An empty page can still have a next cursor."
  def list_outdated_cloudflare_vms(opts \\ []) do
    desired = worker_release()["desired_worker_version_id"]

    with {:ok, page} <- GroupCompute.page_group_workloads(opts) do
      %{
        data:
          Enum.filter(page.records, fn rec ->
            rec["provider"] == "cloudflare" and is_binary(desired) and desired != "" and
              rec["current_worker_version_id"] != desired
          end),
        next_cursor: page.next_cursor
      }
    end
  end

  @doc "One bounded page of lingering lifecycle states."
  def list_stuck_cloudflare_vms(opts \\ []) do
    now = Keyword.get(opts, :now, now_ms())

    with {:ok, page} <- GroupCompute.page_group_workloads(opts) do
      data =
        page.records
        |> Enum.filter(
          &(&1["provider"] == "cloudflare" and
              &1["status"] in ~w(creating reviving archiving waking failed))
        )
        |> Enum.map(&with_ops_age(&1, now))

      %{data: data, next_cursor: page.next_cursor}
    end
  end

  @doc "One bounded page of keepAlive candidates with their attachment projection."
  def list_cloudflare_keepalive_leaks(opts \\ []) do
    now = Keyword.get(opts, :now, now_ms())

    with {:ok, page} <- GroupCompute.page_group_workloads(opts) do
      data =
        page.records
        |> Enum.filter(&cloudflare_keepalive_candidate?/1)
        |> Enum.flat_map(fn rec ->
          case attachment_status(rec) do
            {:connected, _} ->
              []

            status ->
              [
                rec
                |> with_ops_age(now)
                |> Map.put("attachment_status", format_attachment_status(status))
              ]
          end
        end)

      %{data: data, next_cursor: page.next_cursor}
    end
  end

  @doc "Record a desired Worker version for one VM without forcing an active switch."
  @spec set_desired_worker_version(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def set_desired_worker_version(group_id, version, opts \\ [])
      when is_binary(group_id) and is_binary(version) and version != "" do
    release = worker_release()

    with {:ok, kind} <- release_kind(opts[:worker_release_kind] || release["worker_release_kind"]) do
      update_record(group_id, fn rec ->
        rec
        |> Map.put("desired_worker_version_id", version)
        |> Map.put("worker_release_id", opts[:worker_release_id] || release["worker_release_id"])
        |> Map.put("worker_release_kind", kind)
        |> Map.put_new("rollout_state", "pending")
      end)
    end
  end

  @doc "Force one Cloudflare VM to its desired Worker version at an explicit VM boundary."
  @spec force_worker_switch(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def force_worker_switch(group_id, opts \\ []) when is_binary(group_id) do
    with {:ok, rec} <- get_record(group_id),
         :ok <- require_cloudflare_record(rec),
         :ok <- require_no_archive_hold(rec),
         {:ok, rec} <- prepare_worker_switch(rec, opts),
         :ok <- wait_for_operation_drain(group_id, Keyword.get(opts, :grace_ms, 0)) do
      case rec["worker_release_kind"] || "gateway_only" do
        "gateway_only" -> switch_gateway_only(rec, opts)
        _breaking -> switch_breaking_worker(rec, opts)
      end
    else
      {:error, reason} = err ->
        _ = mark_rollout_failed(group_id, reason)
        err
    end
  end

  @doc "Pause new mutating cloud-vm operations across all Salix nodes."
  @spec begin_vm_maintenance(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def begin_vm_maintenance(metadata \\ %{}, opts \\ []) when is_map(metadata) do
    maintenance_id =
      metadata["maintenance_id"] || metadata[:maintenance_id] ||
        random_operation_id("vm-maintenance")

    metadata =
      metadata
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("maintenance_id", maintenance_id)

    with {:ok, record} <-
           GroupCompute.begin_cloudflare_gateway_release(maintenance_id, metadata) do
      summary = drain_vm_operations_for_maintenance(opts)
      {:ok, Map.put(record, "operation_drain_summary", summary)}
    end
  end

  @doc "Clear the global cloud-vm operation pause."
  @spec clear_vm_maintenance(String.t() | nil) :: :ok | {:error, term()}
  def clear_vm_maintenance(maintenance_id \\ nil)

  def clear_vm_maintenance(nil) do
    case vm_maintenance() do
      %{"maintenance_id" => maintenance_id} when is_binary(maintenance_id) ->
        clear_vm_maintenance(maintenance_id)

      _ ->
        {:error, :vm_maintenance_id_required}
    end
  end

  def clear_vm_maintenance(maintenance_id),
    do: GroupCompute.clear_cloudflare_gateway_release(maintenance_id)

  @doc "Fence managed Gateway starts for one image release. A retry uses the same ID."
  def prepare_image_release(maintenance_id) when is_binary(maintenance_id) do
    GroupCompute.begin_cloudflare_gateway_release(maintenance_id, %{
      "reason" => "sandbox_image_release"
    })
  end

  def image_release_status, do: GroupCompute.cloudflare_gateway_release_status()

  def mark_image_release_deploying(maintenance_id) when is_binary(maintenance_id),
    do: GroupCompute.mark_cloudflare_gateway_release_deploying(maintenance_id)

  def cancel_image_release(maintenance_id) when is_binary(maintenance_id),
    do: GroupCompute.clear_cloudflare_gateway_release(maintenance_id, "prepared")

  def finish_image_release(maintenance_id) when is_binary(maintenance_id),
    do: GroupCompute.clear_cloudflare_gateway_release(maintenance_id, "deploying")

  @doc "Read one bounded page of Group facts relevant to the Sandbox image release."
  def image_release_workloads(maintenance_id, opts)
      when is_binary(maintenance_id) and is_list(opts) do
    with :ok <- require_image_release(maintenance_id),
         {:ok, page} <- GroupCompute.page_group_workloads(opts) do
      {:ok,
       %{
         data:
           page.records
           |> Enum.map(fn rec ->
             attempts =
               Enum.count(rec["active_operations"] || %{}, fn {_id, operation} ->
                 is_map(operation) and operation["kind"] == "cloudflare_gateway_attempt"
               end)

             %{
               "group_id" => rec["group_id"],
               "provider" => rec["provider"],
               "resource_name" => rec["provider_resource_name"],
               "profile_key" => get_in(rec, ["provider_spec", "profile_key"]),
               "gateway_base_url" => image_release_gateway_url(rec),
               "status" => rec["status"],
               "archive_recorded" =>
                 (rec["status"] == "archived" or
                    (rec["status"] == "waking" and rec["archive_reason"] == "recovery_rebuild" and
                       get_in(rec, ["archive_last_operation", "operation"]) ==
                         rec["wake_operation_id"] and
                       get_in(rec, ["archive_last_operation", "result"]) == "rebuild")) and
                   matching_recorded_archive?(rec),
               "gateway_attempt_count" => attempts
             }
           end)
           |> Enum.filter(fn rec ->
             rec["provider"] == "cloudflare" or rec["gateway_attempt_count"] > 0
           end),
         next_cursor: page.next_cursor
       }}
    end
  end

  defp image_release_gateway_url(%{"tenant_id" => tenant_id}) when is_binary(tenant_id) do
    case cloudflare_config(tenant_id) do
      {:ok, %{base_url: url}} -> url
      _ -> nil
    end
  end

  defp image_release_gateway_url(_rec), do: nil

  @doc "Start a fenced archive for one named running Container."
  def image_release_archive(maintenance_id, group_id, resource_name, profile_key)
      when is_binary(maintenance_id) and is_binary(group_id) and is_binary(resource_name) and
             profile_key in ["cf-standard-1", "cf-standard-2"] do
    with :ok <- require_image_release(maintenance_id),
         {:ok, %{"provider" => "cloudflare", "provider_resource_name" => ^resource_name} = rec} <-
           get_record(group_id),
         true <-
           get_in(rec, ["provider_spec", "profile_key"]) == profile_key ||
             {:error, :container_profile_changed} do
      case rec["status"] do
        "archived" ->
          if release_archive_recorded?(rec) and rec["active_operation_count"] == 0 and
               not SalixWeb.CloudVM.RuntimeLifecycle.demand?(group_id) do
            with {:ok, cfg} <- cloudflare_config(rec["tenant_id"]),
                 client <- cloudflare_client(cfg, [], group_id),
                 {:ok, _} <- keepalive(rec, false, client: client, archive_release: true),
                 :ok <- destroy(rec, client: client, archive_release: true) do
              {:ok, "archived"}
            end
          else
            {:error, {:archive_not_quiet, :archive_unverified_or_active}}
          end

        "archiving" ->
          start_image_archive_worker(rec,
            archive_operation: rec["archive_operation_id"],
            recovery: rec["archive_reason"] in ["recovery", "recovery_committing"],
            maintenance_id: maintenance_id
          )

        "ready" ->
          with :ok <- seal_release_source(rec),
               {:ok, current} <- get_record(group_id),
               :ok <- idle_archive_eligible?(current, force: true) do
            start_image_archive_worker(current, force: true, maintenance_id: maintenance_id)
          else
            {:skip, reason} -> {:error, {:archive_not_quiet, reason}}
            {:error, reason} -> {:error, {:archive_not_quiet, reason}}
          end

        "waking" ->
          start_image_archive_worker(rec, recovery: true, maintenance_id: maintenance_id)

        status ->
          {:error, {:archive_state_unavailable, status}}
      end
    else
      {:ok, _} -> {:error, :image_release_resource_mismatch}
      {:error, _} = error -> error
    end
  end

  defp start_image_archive_worker(rec, opts) do
    group_id = rec["group_id"]
    key = {:image_archive, group_id}

    case Elixir.Registry.lookup(SalixEnv.VM.Providers.Cloudflare.AttachmentRegistry, key) do
      [{_, _}] ->
        {:ok, "archiving"}

      [] ->
        case Task.Supervisor.start_child(SalixWeb.CloudVM.ImageArchiveSupervisor, fn ->
               case Elixir.Registry.register(
                      SalixEnv.VM.Providers.Cloudflare.AttachmentRegistry,
                      key,
                      nil
                    ) do
                 {:ok, _} ->
                   result =
                     cond do
                       rec["status"] == "waking" -> recover_image_release_wake(rec, opts)
                       rec["status"] == "archiving" -> resume_image_archive(rec, opts)
                       true -> archive_idle_once(group_id, opts)
                     end

                   if match?({:error, _}, result) do
                     Logger.error("image release archive #{group_id}: #{inspect(result)}")
                     record_last_error(group_id, {:image_release_archive_failed, elem(result, 1)})
                   end

                 {:error, {:already_registered, _}} ->
                   :ok
               end
             end) do
          {:ok, _} -> {:ok, "started"}
          {:error, reason} -> {:error, {:archive_worker_unavailable, reason}}
        end
    end
  end

  defp seal_release_source(rec) do
    with {:ok, cfg} <- cloudflare_config(rec["tenant_id"]),
         client <- cloudflare_client(cfg, [], rec["group_id"]),
         {:ok, _} <- CloudflareClient.seal_control(client, sandbox_id(rec)) do
      :ok
    end
  end

  defp resume_image_archive(rec, opts) do
    with true <- rec["archive_reason"] in ["idle_committing", "recovery_committing"],
         true <- matching_recorded_archive?(rec),
         true <- get_in(rec, ["archive", "restore_operation"]) == rec["archive_operation_id"],
         {:ok, cfg} <- cloudflare_config(rec["tenant_id"]),
         client <- cloudflare_client(cfg, [], rec["group_id"]),
         {:ok, observation} <- CloudflareClient.control_observation(client, sandbox_id(rec)),
         %{
           "running" => false,
           "managed_commands_settled" => true,
           "control" =>
             %{
               "sealed" => true,
               "pending" => nil,
               "last_terminal" => %{"action" => "destroy", "outcome" => "completed"} = terminal
             } = control
         } <- observation,
         true <-
           Map.take(control, ~w(owner_id operation_id generation revision)) ==
             Map.take(
               rec["cloudflare_control"] || %{},
               ~w(owner_id operation_id generation revision)
             ),
         true <-
           Map.take(terminal, ~w(owner_id operation_id generation revision)) ==
             Map.take(control, ~w(owner_id operation_id generation revision)),
         :ok <- CloudflareClient.seal_control(client, sandbox_id(rec)) |> control_sealed_result() do
      with :ok <- require_release_worker(opts),
           :ok <-
             DurableArchive.check_chunks(rec["archive"], rec["group_id"], fn ->
               require_release_worker(opts)
             end) do
        finish_archived_source(rec["group_id"], rec["archive_operation_id"])
      end
    else
      _ -> archive_cloudflare_idle(rec, opts)
    end
  end

  defp control_sealed_result({:ok, _}), do: :ok
  defp control_sealed_result({:error, _} = error), do: error

  defp recover_image_release_wake(rec, opts) do
    operation = rec["wake_operation_id"]

    with true <- is_binary(operation) || {:error, :wake_operation_missing},
         {:ok, cfg} <- cloudflare_config(rec["tenant_id"]),
         client <- cloudflare_client(cfg, [], rec["group_id"]),
         :ok <- settle_release_source(rec, client),
         {:ok, sealed} <- get_record(rec["group_id"]),
         {:ok, %{"quiet" => true} = facts} <-
           CloudflareClient.connector_control(client, sandbox_id(sealed), "seal", "full"),
         true <- same_connector_control?(sealed, facts) || {:error, :connector_control_changed} do
      if facts["never_admitted"] == true do
        with true <-
               matching_recorded_archive?(sealed) || {:error, :recovery_source_archive_missing},
             :ok <-
               DurableArchive.check_chunks(sealed["archive"], sealed["group_id"], fn ->
                 require_release_worker(opts)
               end),
             :ok <- require_release_worker(opts),
             :ok <- destroy(sealed, client: client, archive_release: true),
             {:ok, rebuilt} <- record_rebuild_target(sealed, operation) do
          {:ok, rebuilt}
        end
      else
        with {:ok, recovering} <-
               update_record(rec["group_id"], fn current ->
                 if current["status"] == "waking" and current["wake_operation_id"] == operation and
                      current["provider_resource_name"] == rec["provider_resource_name"] do
                   current
                   |> Map.put("status", "archiving")
                   |> Map.put("archive_reason", "recovery")
                   |> Map.put("archive_operation_id", operation)
                   |> Map.put("archive_started_at", now_ms())
                 else
                   {:error, :wake_operation_lost}
                 end
               end) do
          archive_cloudflare_idle(recovering, Keyword.put(opts, :archive_operation, operation))
        end
      end
    else
      {:ok, _} -> {:error, :runtime_not_quiet}
      {:error, _} = error -> error
    end
  end

  defp settle_release_source(rec, client) do
    case seal_release_source(rec) do
      {:error, :cloudflare_control_unsettled} ->
        with operation when is_binary(operation) <- get_in(rec, ["archive", "operation"]),
             {:ok, %{"phase" => "restored"}} <-
               CloudflareClient.archive_import(client, sandbox_id(rec), %{
                 "action" => "status",
                 "operation" => operation
               }),
             :ok <- seal_release_source(rec),
             do: :ok

      result ->
        result
    end
  end

  defp same_connector_control?(rec, facts) do
    keys = ~w(owner_id operation_id generation revision)
    control = facts["control"]

    is_map(control) and control["sealed"] == true and
      Map.take(control, keys) == Map.take(rec["cloudflare_control"] || %{}, keys)
  end

  defp require_release_worker(opts) do
    case opts[:maintenance_id] do
      id when is_binary(id) ->
        case vm_maintenance() do
          %{
            "maintenance_id" => ^id,
            "phase" => "prepared",
            "started_at" => started,
            "enabled" => true
          }
          when is_integer(started) ->
            if now_ms() < started + 75 * 60_000,
              do: :ok,
              else: {:error, :image_release_drain_timeout}

          _ ->
            {:error, :image_release_fence_mismatch}
        end

      _ ->
        :ok
    end
  end

  defp record_rebuild_target(rec, operation) do
    update_record(rec["group_id"], fn current ->
      if current["wake_operation_id"] == operation and
           current["provider_resource_name"] == rec["provider_resource_name"] and
           current["status"] in ["waking", "archiving"] and current["archive"] == rec["archive"] do
        current
        |> Map.put("status", "waking")
        |> Map.put("archive_reason", "recovery_rebuild")
        |> Map.put("wake_requested_at", now_ms())
        |> Map.put("archive_last_operation", %{
          "operation" => operation,
          "result" => "rebuild",
          "at" => now_ms()
        })
        |> Map.delete("archive_operation_id")
        |> Map.delete("archive_progress")
        |> Map.put("node_id", nil)
        |> Map.put("attempt_at", nil)
      else
        {:error, :wake_operation_lost}
      end
    end)
  end

  @doc "Read one Group's current archive operation without scanning other Workloads."
  def archive_operation_status(group_id, operation)
      when is_binary(group_id) and is_binary(operation) do
    with {:ok, %{"provider" => "cloudflare"} = rec} <- get_record(group_id) do
      diagnostics = Enum.filter(rec["archive_diagnostics"] || [], &(&1["operation"] == operation))

      cond do
        rec["archive_operation_id"] == operation ->
          {:ok,
           %{
             "group_id" => group_id,
             "operation" => operation,
             "status" => rec["status"],
             "reason" => rec["archive_reason"],
             "progress" => rec["archive_progress"],
             "cancel_requested" => rec["archive_cancel_requested"] == true,
             "diagnostics" => diagnostics
           }}

        get_in(rec, ["archive_last_operation", "operation"]) == operation ->
          {:ok, Map.put(rec["archive_last_operation"], "diagnostics", diagnostics)}

        diagnostics != [] ->
          {:ok,
           %{
             "group_id" => group_id,
             "operation" => operation,
             "observation" => true,
             "diagnostics" => diagnostics
           }}

        true ->
          {:error, :archive_operation_not_found}
      end
    else
      _ -> {:error, :archive_operation_not_found}
    end
  end

  @doc "Cancel one pre-commit archive after its Connector worker stops and its runtime resumes."
  def cancel_archive_operation(group_id, operation)
      when is_binary(group_id) and is_binary(operation) do
    case archive_operation_status(group_id, operation) do
      {:ok, %{"result" => "cancelled"}} -> {:ok, "cancelled"}
      _ -> do_cancel_archive_operation(group_id, operation)
    end
  end

  defp do_cancel_archive_operation(group_id, operation) do
    with {:ok,
          %{
            "status" => "archiving",
            "archive_reason" => "idle",
            "archive_operation_id" => ^operation,
            "provider" => "cloudflare"
          } = rec} <- get_record(group_id),
         {:ok, _} <-
           update_record(group_id, fn current ->
             if current["provider"] == "cloudflare" and current["status"] == "archiving" and
                  current["archive_reason"] == "idle" and
                  current["archive_operation_id"] == operation do
               Map.put(current, "archive_cancel_requested", true)
             else
               {:error, :archive_commit_recovery_required}
             end
           end),
         {:ok, cfg} <- cloudflare_config(rec["tenant_id"]),
         client <- cloudflare_client(cfg, [], rec["group_id"]),
         :ok <- seal_release_source(rec),
         :ok <- DurableArchive.cancel(client, sandbox_id(rec), operation) do
      finish_cancelled_archive(rec, operation)
    else
      {:ok, _} -> {:error, :archive_commit_recovery_required}
      {:error, _} = error -> error
      _ -> {:error, :archive_cancel_unconfirmed}
    end
  end

  defp finish_cancelled_archive(rec, operation) do
    group_id = rec["group_id"]

    case archive_operation_status(group_id, operation) do
      {:ok, %{"result" => "cancelled"}} ->
        {:ok, "cancelled"}

      {:ok, %{"status" => "archiving", "reason" => "idle"}} ->
        finish_cancelled_archive_runtime(rec, operation)

      _ ->
        {:error, :archive_recovery_changed}
    end
  end

  defp finish_cancelled_archive_runtime(rec, operation) do
    group_id = rec["group_id"]

    with {:ok, _mode} <- quiesce_archive_runtimes(rec, operation),
         {:ok, %{"resumed" => true}} <- resume_archive_source(rec, operation),
         :ok <- stop_archive_repair_attachment(rec),
         {:ok, _} <-
           update_record(group_id, fn current ->
             if current["status"] == "archiving" and
                  current["archive_reason"] == "idle" and
                  current["archive_operation_id"] == operation and
                  current["archive_cancel_requested"] == true do
               current
               |> rollback_failed_archive(operation)
               |> Map.put("status", "ready")
               |> Map.delete("archive_operation_id")
               |> Map.delete("archive_cancel_requested")
               |> Map.delete("archive_progress")
               |> Map.put("archive_last_operation", %{
                 "operation" => operation,
                 "result" => "cancelled",
                 "at" => now_ms()
               })
               |> Map.put("last_error", nil)
             else
               {:error, :archive_recovery_changed}
             end
           end) do
      {:ok, "cancelled"}
    else
      {:error, _} = error -> error
      _ -> {:error, :archive_cancel_unconfirmed}
    end
  end

  defp require_image_release(maintenance_id) do
    case vm_maintenance() do
      %{"maintenance_id" => ^maintenance_id, "enabled" => true, "phase" => phase} = record
      when phase in ["prepared", "deploying"] ->
        case record["active_direct_attempts"] || %{} do
          attempts when is_map(attempts) and map_size(attempts) == 0 -> :ok
          _ -> {:error, :direct_gateway_attempts_pending}
        end

      %{"reason" => "vm_maintenance_unavailable"} ->
        {:error, :vm_maintenance_unavailable}

      _ ->
        {:error, :image_release_fence_mismatch}
    end
  end

  @spec vm_maintenance() :: map() | nil
  def vm_maintenance do
    case S3.get(Keys.ctl_vm_maintenance()) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"enabled" => true} = record} -> record
          {:ok, %{"enabled" => false}} -> SalixCluster.NodeLifecycle.vm_maintenance()
          _ -> %{"enabled" => true, "reason" => "vm_maintenance_invalid"}
        end

      {:error, :not_found} ->
        SalixCluster.NodeLifecycle.vm_maintenance()

      {:error, reason} ->
        %{
          "enabled" => true,
          "reason" => "vm_maintenance_unavailable",
          "detail" => inspect(reason)
        }
    end
  end

  defp require_cloudflare_record(%{"provider" => "cloudflare"}), do: :ok

  defp require_cloudflare_record(_rec),
    do: {:error, {:bad_request, "worker switch requires cloudflare VM"}}

  defp drain_vm_operations_for_maintenance(opts) do
    {:ok, page} = GroupCompute.page_group_workloads(Keyword.take(opts, [:cursor, :limit]))
    grace_ms = Keyword.get(opts, :grace_ms, 0) |> max(0) |> min(30_000)
    deadline = System.monotonic_time(:millisecond) + grace_ms
    records = Enum.filter(page.records, &(&1["provider"] == "cloudflare"))

    results =
      Map.new(records, fn rec ->
        group_id = rec["group_id"]

        result =
          case wait_for_operation_drain(
                 group_id,
                 max(deadline - System.monotonic_time(:millisecond), 0)
               ) do
            :ok -> %{"state" => "completed", "active_operation_count" => 0}
            {:error, reason} -> %{"state" => "timeout", "reason" => inspect(reason)}
          end

        {group_id, result}
      end)

    %{
      "started_at" => now_ms(),
      "vm_count" => map_size(results),
      "next_cursor" => page.next_cursor,
      "completed" =>
        Enum.count(results, fn {_group, result} -> result["state"] == "completed" end),
      "timeout" => Enum.count(results, fn {_group, result} -> result["state"] == "timeout" end),
      "vms" => results
    }
  end

  defp prepare_worker_switch(%{"group_id" => group_id} = rec, opts) do
    release = worker_release()

    desired =
      opts[:desired_worker_version_id] || rec["desired_worker_version_id"] ||
        release["desired_worker_version_id"]

    if is_binary(desired) and desired != "" do
      with {:ok, kind} <-
             release_kind(
               opts[:worker_release_kind] || rec["worker_release_kind"] ||
                 release["worker_release_kind"]
             ) do
        update_record(group_id, fn current ->
          current
          |> Map.put("desired_worker_version_id", desired)
          |> Map.put(
            "worker_release_id",
            opts[:worker_release_id] || release["worker_release_id"]
          )
          |> Map.put("worker_release_kind", kind)
          |> Map.put("rollout_state", "draining")
          |> Map.put("operation_drain_summary", %{
            "started_at" => now_ms(),
            "active_operation_count" => current["active_operation_count"] || 0
          })
        end)
      end
    else
      {:error, {:bad_request, "desired_worker_version_id is required"}}
    end
  end

  defp wait_for_operation_drain(group_id, grace_ms) do
    deadline = System.monotonic_time(:millisecond) + max(grace_ms, 0)
    do_wait_for_operation_drain(group_id, deadline)
  end

  defp do_wait_for_operation_drain(group_id, deadline) do
    case get_record(group_id) do
      {:ok, rec} ->
        cond do
          (rec["active_operation_count"] || 0) == 0 ->
            :ok

          System.monotonic_time(:millisecond) >= deadline ->
            {:error,
             {:active_operations,
              %{
                "active_operation_count" => rec["active_operation_count"] || 0,
                "active_operations" => rec["active_operations"] || %{}
              }}}

          true ->
            Process.sleep(25)
            do_wait_for_operation_drain(group_id, deadline)
        end

      {:error, _} = err ->
        err
    end
  end

  defp switch_gateway_only(%{"group_id" => group_id, "tenant_id" => tenant_id} = rec, opts) do
    if env_id = rec["env_id"], do: SalixEnv.VM.Providers.Cloudflare.Attachments.stop(env_id)

    with {:ok, group} <- switch_group_record(group_id),
         {:ok, cfg} <- cloudflare_config(tenant_id),
         client <-
           cloudflare_client(
             cfg,
             Keyword.put(opts, :worker_version_id, rec["desired_worker_version_id"]),
             group_id
           ),
         {:ok, %{sandbox: sandbox}} <-
           __MODULE__.ensure(rec, group,
             client: client,
             keep_alive: true,
             attach: true,
             archive: nil,
             meta: %{
               "tenant_id" => rec["tenant_id"],
               "group_id" => group_id,
               "alias" => @env_alias,
               "name" => "Cloud Workspace",
               "provider" => "cloudflare",
               "provider_resource_name" => rec["provider_resource_name"]
             }
           ),
         :ok <- verify_worker_version(sandbox, rec["desired_worker_version_id"]),
         {:ok, ready} <- mark_rollout_ready(group_id, sandbox, "gateway_only") do
      {:ok, ready}
    end
  end

  defp switch_breaking_worker(%{"group_id" => group_id} = rec, opts) do
    with {:ok, _archived} <- archive_cloudflare_idle(rec, Keyword.put(opts, :force, true)),
         {:ok, ready} <- wake_archived_vm(group_id, opts),
         sandbox = get_in(ready, ["provider_spec", "cloudflare_worker"]) || %{},
         :ok <- verify_worker_version(sandbox, rec["desired_worker_version_id"]) do
      mark_rollout_ready(group_id, sandbox, rec["worker_release_kind"])
    end
  end

  defp before_archive_persist(opts) do
    case opts[:before_archive_persist] do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  end

  defp verify_worker_version(_sandbox, nil), do: :ok

  defp verify_worker_version(%{"worker_version_id" => version}, version), do: :ok

  defp verify_worker_version(sandbox, desired),
    do: {:error, {:worker_version_mismatch, desired, sandbox["worker_version_id"]}}

  defp mark_rollout_ready(group_id, sandbox, kind) do
    update_record(group_id, fn rec ->
      rec
      |> put_cloudflare_worker_metadata(sandbox)
      |> put_current_worker_version(sandbox)
      |> Map.put("rollout_state", "ready")
      |> Map.put("worker_release_kind", kind)
      |> Map.put("operation_drain_summary", %{
        "completed_at" => now_ms(),
        "state" => "completed",
        "active_operation_count" => 0
      })
    end)
  end

  defp mark_rollout_failed(group_id, reason) do
    update_record(group_id, fn rec ->
      rec
      |> Map.put("rollout_state", "failed")
      |> Map.put("last_error", inspect(reason) |> String.slice(0, 500))
    end)
  end

  @doc "Mark the group cloud VM ready after its stable device is connected."
  @spec mark_ready(String.t()) :: {:ok, map()} | {:error, term()}
  def mark_ready(group_id) do
    update_record(group_id, fn rec ->
      Map.merge(rec, %{
        "status" => "ready",
        "ready_at" => now_ms(),
        "error" => nil,
        "last_error" => nil,
        "node_id" => nil,
        "attempt_at" => nil
      })
    end)
  end

  @doc "Mark a Group VM failed and retain its error for the owner."
  @spec mark_failed(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def mark_failed(group_id, error) do
    update_record(group_id, fn rec ->
      Map.merge(rec, %{
        "status" => "failed",
        "error" => to_string(error),
        "node_id" => nil,
        "attempt_at" => nil
      })
    end)
  end

  @doc "Mark a VM record as blocked by hard billing availability."
  @spec mark_billing_suspended(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def mark_billing_suspended(group_id, decision) do
    update_record(group_id, fn rec ->
      Map.merge(rec, %{
        "status" => "billing_suspended",
        "error" => "billing_unavailable",
        "billing_decision" => decision_snapshot(decision),
        "node_id" => nil,
        "attempt_at" => nil
      })
    end)
  end

  @doc "Start a VM operation, rejecting new mutating calls while rollout drain is active."
  @spec begin_operation(String.t(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def begin_operation(group_id, kind, opts \\ [])

  def begin_operation(group_id, kind, opts)
      when is_binary(group_id) and is_binary(kind) do
    with :ok <- SalixWeb.CloudVM.RuntimeLifecycle.wake(group_id) do
      begin_awake_operation(group_id, kind, opts)
    end
  end

  def begin_operation(_group_id, _kind, _opts), do: {:ok, nil}

  defp begin_awake_operation(group_id, kind, opts) do
    mutating? = Keyword.get(opts, :mutating?, MapSet.member?(@mutating_vm_operations, kind))
    agent_id = Keyword.get(opts, :agent_id)
    operation_id = Keyword.get(opts, :operation_id) || random_operation_id(kind)

    case GroupCompute.begin_group_operation(
           group_id,
           %{
             operation_id: operation_id,
             kind: kind,
             mutating?: mutating?,
             agent_id: agent_id,
             idempotency_class: Keyword.get(opts, :idempotency_class, idempotency_class(kind))
           },
           if(mutating?, do: vm_maintenance())
         ) do
      {:wake, {:error, _} = error} ->
        case SalixWeb.CloudVM.RuntimeLifecycle.wake(group_id) do
          {:error, %{"error_class" => _} = reason} -> {:error, reason}
          _ -> error
        end

      result ->
        result
    end
  end

  defp maybe_call_hook(opts, key, arg) do
    case Keyword.get(opts, key) do
      fun when is_function(fun, 1) ->
        _ = fun.(arg)
        :ok

      fun when is_function(fun, 0) ->
        _ = fun.()
        :ok

      _ ->
        :ok
    end
  end

  @doc "Finish a VM operation started by begin_operation/3."
  @spec finish_operation(String.t(), String.t() | nil, String.t(), term()) ::
          :ok | {:error, term()}
  def finish_operation(_group_id, nil, _state, _result), do: :ok

  def finish_operation(group_id, operation_id, state, result)
      when is_binary(group_id) and is_binary(operation_id) do
    GroupCompute.finish_group_operation(group_id, %{
      operation_id: operation_id,
      state: state,
      result: result
    })
  end

  @doc "Mark an agent settle only when that agent used cloud-vm since its previous settle."
  @spec mark_agent_settled(String.t()) :: :ok
  def mark_agent_settled(agent_id) when is_binary(agent_id) do
    with {:ok, agent} <- SalixAgent.Control.get(agent_id),
         group_id when is_binary(group_id) <- agent["group_id"] || agent["agent_group_id"] do
      _ =
        update_record(group_id, fn rec ->
          if rec["last_vm_operation_agent_id"] == agent_id do
            rec
            |> Map.put("last_agent_settled_after_vm_at", now_ms())
            |> Map.delete("last_vm_operation_agent_id")
          else
            rec
          end
        end)

      :ok
    else
      _ -> :ok
    end
  end

  def mark_agent_settled(_agent_id), do: :ok

  @doc "Repair a missing ready connection or return retryable archive/wake state."
  @spec wake_if_archived(String.t()) :: {:error, term()} | :no_environment
  def wake_if_archived(group_id) when is_binary(group_id) do
    case SalixWeb.CloudVM.RuntimeLifecycle.wake(group_id) do
      {:error, %{"error_class" => _} = error} ->
        {:error, error}

      {:error, reason} when reason != :runtime_waking ->
        {:error, unavailable_error(group_id)}

      _ ->
        wake_if_archived_status(group_id)
    end
  end

  def wake_if_archived(_group_id), do: :no_environment

  defp wake_if_archived_status(group_id) do
    case get_record(group_id) do
      {:ok, %{"provider" => "cloudflare", "status" => "archived"} = rec} ->
        {:error, {:vm_waking, %{"retry_after_ms" => 1_000, "env_id" => rec["env_id"]}}}

      {:ok, %{"provider" => "cloudflare", "status" => "waking"} = rec} ->
        {:error, {:vm_waking, %{"retry_after_ms" => 1_000, "env_id" => rec["env_id"]}}}

      {:ok, %{"provider" => "cloudflare", "status" => "archiving"} = rec} ->
        {:error, {:vm_archiving, %{"retry_after_ms" => 1_000, "env_id" => rec["env_id"]}}}

      {:ok, %{"status" => "ready"} = rec} ->
        case group_record(group_id) do
          {:ok, group} ->
            case targeted_reattach(rec, group) do
              :revived ->
                {:error, {:vm_waking, %{"retry_after_ms" => 1_000, "env_id" => rec["env_id"]}}}

              :error ->
                :no_environment
            end

          _ ->
            :no_environment
        end

      _ ->
        :no_environment
    end
  end

  defp targeted_reattach(%{"provider" => "cloudflare"} = rec, group) do
    resource = rec["provider_resource_name"]
    profile = get_in(rec, ["provider_spec", "profile_key"])

    case attachment_status(rec) do
      {:connected,
       %{
         "meta" => %{
           "provider" => "cloudflare",
           "provider_resource_name" => ^resource,
           "profile_key" => ^profile,
           "archive_repair" => true
         }
       }} ->
        case stop_archive_repair_attachment(rec) do
          :ok -> attach_ready_record(rec, group)
          {:error, _} -> :error
        end

      {:connected,
       %{
         "meta" => %{
           "provider" => "cloudflare",
           "provider_resource_name" => ^resource,
           "profile_key" => ^profile
         }
       }} ->
        :revived

      _ ->
        attach_ready_record(rec, group)
    end
  end

  defp attach_ready_record(rec, group) do
    with {:ok, cfg} <- cloudflare_config(rec["tenant_id"]),
         client =
           cloudflare_client(
             cfg,
             [
               worker_version_id:
                 rec["current_worker_version_id"] || rec["desired_worker_version_id"]
             ],
             rec["group_id"]
           ),
         {:ok, _pid} <- __MODULE__.attach_existing(rec, group, client: client) do
      :revived
    else
      error ->
        _ = record_last_error(rec["group_id"], {:targeted_reattach, error})
        :error
    end
  end

  @doc "Return a structured retryable error for an unavailable cloud-vm alias."
  @spec unavailable_error(String.t()) :: map()
  def unavailable_error(group_id) when is_binary(group_id) do
    base = %{
      "error_class" => "vm_unavailable",
      "retryable" => true,
      "message" => "VM unavailable"
    }

    case get_record(group_id) do
      {:ok, %{"provider" => "cloudflare", "status" => "billing_suspended"} = rec} ->
        SalixAgent.BillingAvailability.error(rec["billing_decision"] || %{})
        |> Map.put("env_id", rec["env_id"])

      {:ok, %{"provider" => "cloudflare"} = rec} ->
        base
        |> Map.put("env_id", rec["env_id"])
        |> maybe_put("sandbox_id", rec["provider_resource_id"])
        |> maybe_put("connection_generation", rec["connection_generation"])
        |> maybe_put("status", rec["status"])

      _ ->
        base
    end
  end

  def unavailable_error(group_id), do: unavailable_error(to_string(group_id || ""))

  @doc "Mark a previously billing-suspended VM as eligible to resume."
  @spec mark_eligible_for_resume(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def mark_eligible_for_resume(group_id, decision) do
    update_record(group_id, fn rec ->
      Map.merge(rec, %{
        "status" => "eligible_for_resume",
        "error" => nil,
        "last_error" => nil,
        "billing_decision" => decision_snapshot(decision),
        "node_id" => nil,
        "attempt_at" => nil
      })
    end)
  end

  @doc "Delete the VM record."
  @spec delete_record(String.t()) :: :ok | {:error, term()}
  def delete_record(group_id), do: GroupCompute.retire_group_workload(group_id)

  @doc "Public projection of the Group VM record, or nil."
  @spec vm_json(String.t()) :: map() | nil
  def vm_json(group_id) do
    case get_record(group_id) do
      {:ok, rec} -> public_json(rec)
      _ -> nil
    end
  end

  @doc false
  def public_json(rec) do
    %{
      "enabled" => true,
      "provider" => rec["provider"] || "cloudflare",
      "status" => rec["status"],
      "env_id" => rec["env_id"],
      "alias" => rec["alias"] || @env_alias,
      "capabilities" => provider_capabilities(rec),
      "error" => rec["error"],
      "last_error" => rec["last_error"],
      "billing_decision" => rec["billing_decision"]
    }
  end

  defp provider_capabilities(_rec),
    do: %{"ws" => true, "http_proxy" => true, "restartable" => true}

  # ---- lifecycle ----

  @doc """
  Ensure the agent group's VM record exists and (when `auto_provision` is
  on and the record is fresh or restarted) kick an async provision. Returns the
  group-owned record.
  """
  @spec ensure_provisioning(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_provisioning(%{"group_id" => group_id} = agent, opts \\ []) do
    with :ok <- reject_router_only_tenant(agent),
         {:ok, rec, outcome} <- ensure_record(agent) do
      case authorize_vm_start(agent, rec, opts) do
        :ok ->
          if outcome in [:created, :restarted] and cfg(:auto_provision, opts) do
            # The shared Compute reconciler discovers the persisted creation intent.
            :ok
          end

          {:ok, rec}

        {:error, {:billing_unavailable, decision}} ->
          if rec["status"] in ~w(creating failed billing_suspended eligible_for_resume) do
            with {:ok, _} <- mark_billing_suspended(group_id, decision),
                 do: {:error, SalixAgent.BillingAvailability.error(decision)}
          else
            {:error, SalixAgent.BillingAvailability.error(decision)}
          end

        {:error, _} = error ->
          error
      end
    end
  end

  # Guest Tenants never own a Cloud VM, whatever an agent record claims.
  defp reject_router_only_tenant(agent) do
    if SalixStore.TenantProfiles.router_only?(agent["tenant_id"]),
      do: {:error, :router_only_tenant},
      else: :ok
  end

  defp authorize_vm_start(agent, rec, opts) do
    billing_owner =
      case group_record(agent["group_id"]) do
        {:ok, group} -> group["billing_owner"] || %{}
        _ -> %{}
      end

    if billing_account_id(billing_owner) do
      vm_authorizer().authorize_vm(%{
        billing_owner: billing_owner,
        group_id: agent["group_id"],
        tenant_id: agent["tenant_id"],
        provider_resource_name: rec["provider_resource_name"],
        action: :resume,
        entrypoint: "cloud_vm_enable",
        actor_type: "user",
        provider: metering_provider(rec, opts),
        sku: metering_sku(rec, opts)
      })
    else
      :ok
    end
  end

  @doc "Authorize a paid Group VM start or resume against current billing facts."
  def authorize_resume(group_id, opts \\ []) do
    with {:ok, rec} <- get_record(group_id),
         {:ok, group} <- group_record(group_id) do
      case authorize_vm_reconcile(group, rec, opts) do
        :ok ->
          :ok

        {:error, {:billing_unavailable, decision}} ->
          {:error, SalixAgent.BillingAvailability.error(decision)}

        {:error, _} = error ->
          error
      end
    end
  end

  defp authorize_vm_reconcile(group, rec, opts) do
    billing_owner = group["billing_owner"] || %{}

    if billing_account_id(billing_owner) do
      vm_authorizer().authorize_vm(%{
        billing_owner: billing_owner,
        group_id: rec["group_id"],
        tenant_id: rec["tenant_id"],
        provider_resource_name: rec["provider_resource_name"],
        action: :resume,
        entrypoint: "cloud_vm_sweeper",
        actor_type: "system",
        provider: metering_provider(rec, opts),
        sku: metering_sku(rec, opts)
      })
    else
      :ok
    end
  end

  defp billing_account_id(owner) when is_map(owner) do
    case owner["billing_account_id"] || owner[:billing_account_id] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp billing_account_id(_owner), do: nil

  defp metering_sku(rec, _opts) do
    case get_in(rec, ["provider_spec", "profile_key"]) do
      "cf-standard-1" -> "runtime-standard-1"
      "cf-standard-2" -> "runtime-minimum"
      _ -> "profile-unresolved"
    end
  end

  defp metering_provider(rec, opts) do
    rec["provider"] || cfg(:metering_provider, opts)
  end

  defp provider_neutral_archive?(%{
         "type" => "connector_tar_gz",
         "encoding" => "base64",
         "data" => data
       })
       when is_binary(data) and data != "",
       do: true

  defp provider_neutral_archive?(%{"type" => type} = archive)
       when type in ["connector_tar_gz_chunks", "connector_tar_zst_chunks"],
       do: DurableArchive.valid_manifest?(archive)

  defp provider_neutral_archive?(_archive), do: false

  defp archive_metadata(archive) when is_map(archive) do
    archive
    |> Map.take(["type", "encoding", "storage", "operation", "byte_size", "chunk_count", "scope"])
    |> Map.put("archived_at", now_ms())
  end

  defp recorded_archive_metadata?(%{
         "type" => "connector_tar_gz",
         "encoding" => "base64",
         "archived_at" => archived_at
       })
       when is_integer(archived_at),
       do: true

  defp recorded_archive_metadata?(%{
         "type" => type,
         "storage" => storage,
         "operation" => operation,
         "byte_size" => bytes,
         "chunk_count" => count,
         "archived_at" => archived_at
       })
       when type in ["connector_tar_gz_chunks", "connector_tar_zst_chunks"] and
              storage in ["salix_s3", "r2"] and is_binary(operation) and operation != "" and
              is_integer(bytes) and bytes > 0 and
              is_integer(count) and count > 0 and is_integer(archived_at),
       do: true

  defp recorded_archive_metadata?(_), do: false

  defp matching_recorded_archive?(rec) do
    archive = rec["archive"] || %{}
    metadata = rec["connector_archive"] || %{}

    DurableArchive.valid_manifest?(archive) and recorded_archive_metadata?(metadata) and
      Map.take(metadata, ~w(type storage operation byte_size chunk_count)) ==
        Map.take(archive, ~w(type storage operation byte_size chunk_count)) and
      (metadata["scope"] || "full") == (archive["scope"] || "full")
  end

  defp release_archive_recorded?(rec) do
    archive = rec["archive"] || %{}
    metadata = rec["connector_archive"] || %{}

    matching_recorded_archive?(rec) or
      (archive["type"] == "connector_tar_gz" and provider_neutral_archive?(archive) and
         recorded_archive_metadata?(metadata) and metadata["encoding"] == archive["encoding"] and
         metadata["type"] == archive["type"])
  end

  defp vm_authorizer,
    do: Application.get_env(:salix_web, :vm_authorization_mod, VMAuthorization.Noop)

  @doc "Run one bounded Cloudflare Group VM provisioning attempt."
  @spec provision_once(String.t(), keyword()) ::
          {:ok, provision_outcome()} | {:error, term()}
  def provision_once(group_id, opts \\ []) do
    with {:ok, rec} <- get_record(group_id),
         :ok <- authorize_provision_once(rec, opts),
         {:ok, rec} <- claim(rec, opts) do
      do_provision_once(rec, opts)
    else
      {:error, {:billing_unavailable, decision}} ->
        _ = mark_billing_suspended(group_id, decision)
        {:ok, :billing_suspended}

      other ->
        other
    end
  end

  defp authorize_provision_once(%{"group_id" => group_id} = rec, opts) do
    case group_record(group_id) do
      {:ok, group} -> authorize_vm_reconcile(group, rec, opts)
      _ -> :ok
    end
  end

  defp do_provision_once(%{"group_id" => group_id} = rec, opts) do
    cond do
      now_ms() - (rec["created_at"] || 0) > cfg(:max_provision_age_ms, opts) ->
        _ = mark_failed(group_id, "cloud-vm provisioning timed out")
        {:ok, :failed}

      true ->
        case do_provision(rec, opts) do
          {:error, reason} = err ->
            _ = record_last_error(group_id, reason)

            Logger.warning(
              "cloud-vm provisioning attempt failed (will retry): group=#{group_id} #{inspect(reason)}"
            )

            err

          other ->
            other
        end
    end
  end

  defp record_last_error(group_id, reason) do
    detail = reason |> inspect() |> String.slice(0, 500)
    update_record(group_id, &Map.put(&1, "last_error", detail))
  end

  defp do_provision(%{"group_id" => group_id} = rec, opts) do
    case group_record(group_id) do
      :missing ->
        # The group was deleted while the sprite record exists — delete the VM
        # and retain the record for retry if provider deletion fails.
        with :ok <- teardown_orphan(rec, opts), do: {:ok, :orphaned}

      {:error, reason} ->
        # Cannot tell — never treat a read error as an orphan.
        {:error, reason}

      {:ok, group} ->
        provision_cloudflare(rec, group, opts)
    end
  end

  defp provision_cloudflare(rec, group, opts) do
    case cloudflare_config(rec["tenant_id"]) do
      {:error, :not_configured} ->
        _ = mark_failed(rec["group_id"], @config_missing_error <> ": cloudflare")
        {:ok, :failed}

      {:error, reason} ->
        {:error, reason}

      {:ok, cfg} ->
        rec = put_record_desired_worker_release(rec)

        provision_cloudflare_vm(
          rec,
          group,
          cloudflare_client(
            cfg,
            Keyword.put(opts, :worker_version_id, rec["desired_worker_version_id"]),
            rec["group_id"]
          ),
          opts
        )
    end
  end

  defp provision_cloudflare_vm(%{"group_id" => group_id} = rec, group, client, opts) do
    with {:ok, %{attachment: _pid, sandbox: sandbox}} <-
           __MODULE__.ensure(rec, group,
             client: client,
             keep_alive: true,
             attach: true,
             archive: rec["archive"],
             restore_deadline_ms:
               if(is_binary(opts[:wake_operation_id]),
                 do: (rec["last_wake_at"] || rec["created_at"]) + 2_700_000
               ),
             wake_operation_id: opts[:wake_operation_id],
             meta: %{
               "tenant_id" => rec["tenant_id"],
               "group_id" => group_id,
               "device_id" => rec["device_id"],
               "connector_id" => rec["connector_id"],
               "alias" => @env_alias,
               "name" => "Cloud Workspace",
               "provider" => "cloudflare",
               "provider_resource_name" => rec["provider_resource_name"],
               "profile_key" => get_in(rec, ["provider_spec", "profile_key"]),
               "wake_operation_id" => opts[:wake_operation_id]
             }
           ),
         {:ok, _connector_run_id} <- verify_device_connected(rec, opts) do
      :ok = maybe_call_hook(opts, :before_cloudflare_ready, group_id)

      case mark_cloudflare_ready(group_id, rec["env_id"], sandbox, opts) do
        {:ok, _} -> {:ok, :ready}
        {:error, _} = err -> err
      end
    else
      {:error, :timeout} ->
        if Keyword.has_key?(opts, :wake_operation_id) do
          {:error, :timeout}
        else
          _ = mark_failed(group_id, "cloud-vm connector did not attach")
          {:ok, :failed}
        end

      # The Gateway cannot start this Container profile until the dual-profile
      # Gateway image is released. Retrying inside the provisioning budget only
      # hides that behind "provisioning timed out"; the next use restarts the VM.
      {:error, {contract, profile}} = error
      when contract in [:gateway_profile_unsupported, :gateway_control_unsupported] ->
        if Keyword.has_key?(opts, :wake_operation_id) do
          error
        else
          message = gateway_profile_unsupported_message(profile)
          Logger.error("cloud-vm provisioning failed: group=#{group_id} #{message}")
          _ = mark_failed(group_id, message)
          {:ok, :failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp gateway_profile_unsupported_message(profile) do
    "cloud-vm Gateway does not serve Container profile #{profile || "unresolved"}: " <>
      "release the dual-profile Gateway image, then retry"
  end

  defp mark_cloudflare_ready(group_id, env_id, sandbox, opts) do
    wake_operation_id = Keyword.get(opts, :wake_operation_id)

    update_record(group_id, fn rec ->
      if rec["archive_reason"] != "recovery_rebuild" and
           (is_nil(wake_operation_id) or rec["wake_operation_id"] == wake_operation_id) do
        rec
        |> Map.merge(%{
          "status" => "ready",
          "ready_at" => now_ms(),
          "error" => nil,
          "last_error" => nil,
          "node_id" => nil,
          "attempt_at" => nil,
          "env_id" => env_id
        })
        |> Map.delete("wake_operation_id")
        |> Map.delete("wake_requested_at")
        |> put_cloudflare_worker_metadata(sandbox)
        |> put_current_worker_version(sandbox)
      else
        {:error, :wake_operation_lost}
      end
    end)
  end

  defp put_cloudflare_worker_metadata(rec, sandbox) when is_map(sandbox) do
    metadata =
      sandbox
      |> Map.take([
        "worker_version_id",
        "worker_version_tag",
        "worker_version_timestamp",
        "gateway_build_id",
        "connector_image_version"
      ])
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()

    if map_size(metadata) == 0 do
      rec
    else
      provider_spec =
        rec
        |> Map.get("provider_spec", %{})
        |> Map.put("cloudflare_worker", metadata)

      Map.put(rec, "provider_spec", provider_spec)
    end
  end

  defp put_cloudflare_worker_metadata(rec, _sandbox), do: rec

  defp put_current_worker_version(rec, %{"worker_version_id" => version})
       when is_binary(version) and version != "" do
    rec
    |> Map.put("current_worker_version_id", version)
    |> Map.put("rollout_state", "ready")
    |> Map.put_new("active_operation_count", 0)
    |> Map.put_new("active_operations", %{})
  end

  defp put_current_worker_version(rec, _sandbox), do: rec

  defp put_record_desired_worker_release(%{"provider" => "cloudflare"} = rec) do
    release = worker_release()

    rec
    |> maybe_put(
      "desired_worker_version_id",
      rec["desired_worker_version_id"] || release["desired_worker_version_id"]
    )
    |> maybe_put("worker_release_id", rec["worker_release_id"] || release["worker_release_id"])
    |> maybe_put(
      "worker_release_kind",
      rec["worker_release_kind"] || release["worker_release_kind"]
    )
  end

  defp put_record_desired_worker_release(rec), do: rec

  @doc "Deterministic env id for a group's cloud VM."
  @spec cloudvm_env_id(String.t()) :: String.t()
  def cloudvm_env_id(group_id), do: RuntimeIds.cloud_vm_env_id(group_id)

  @doc "Stable device id for the group-owned cloud VM connector."
  @spec cloudvm_device_id(String.t()) :: String.t()
  def cloudvm_device_id(group_id), do: RuntimeIds.cloud_vm_device_id(group_id)

  @doc "Stable connector id for the group-owned cloud VM connector."
  @spec cloudvm_connector_id(String.t()) :: String.t()
  def cloudvm_connector_id(group_id), do: RuntimeIds.cloud_vm_connector_id(group_id)

  @doc false
  def reconcile_runtimes(group_id, opts \\ []) do
    with {:ok, %{"status" => "ready"} = rec} <- get_record(group_id),
         true <- SalixWeb.CloudVM.Runtimes.pending?(rec),
         :ok <- authorize_provision_once(rec, opts) do
      SalixWeb.CloudVM.Runtimes.reconcile(rec, opts)
    else
      {:error, {:billing_unavailable, decision}} ->
        if SalixAgent.BillingAvailability.denied?({:billing_unavailable, decision}) do
          SalixWeb.CloudVM.Runtimes.fail_pending(
            group_id,
            SalixAgent.BillingAvailability.error(decision)
          )
        end

      _ ->
        :ok
    end
  end

  @doc false
  def wake_runtime_carrier(rec) do
    with {:ok, group} <- group_record(rec["group_id"]), do: targeted_reattach(rec, group)
  end

  @doc false
  def prepare_runtime_connector(%{"provider" => "cloudflare"} = rec) do
    case current_device(rec) do
      {:ok, %{"status" => "connected"}} ->
        with {:ok, _, _} <-
               GroupCompute.update_group_workload(
                 rec["group_id"],
                 &Map.put(&1, "runtime_connector", true)
               ),
             do: :ok

      _ ->
        {:error, :runtime_connector_unavailable}
    end
  end

  defp verify_device_connected(rec, opts) do
    if cfg(:verify_connector, opts) do
      deadline = now_ms() + cfg(:bootstrap_timeout_ms, opts)
      poll_device_connected(rec, deadline, cfg(:bootstrap_poll_ms, opts))
    else
      {:ok, nil}
    end
  end

  defp poll_device_connected(rec, deadline, interval) do
    case current_device(rec) do
      {:ok, %{"status" => "connected", "connector_run_id" => connector_run_id}} ->
        {:ok, connector_run_id}

      _ ->
        if now_ms() >= deadline do
          {:error, :timeout}
        else
          Process.sleep(min(interval, max(deadline - now_ms(), 1)))
          poll_device_connected(rec, deadline, interval)
        end
    end
  end

  @doc """
  Best-effort teardown of the Group VM. Orphan cleanup uses a separate discard
  path; this checkpoint-preserving path is used for explicit
  group-runtime teardown. Agent deletion must not call this.
  """
  @spec teardown(map() | String.t(), keyword()) :: :ok
  def teardown(group_id, opts \\ [])

  def teardown(group_id, opts) when is_binary(group_id) do
    case get_record(group_id) do
      {:ok, rec} -> teardown(rec, opts)
      _ -> :ok
    end
  end

  def teardown(%{"group_id" => _group_id} = rec, opts), do: teardown_cloudflare(rec, opts)

  # Only callers that observed a missing group may discard its VM without a
  # checkpoint. Reading a checkpoint can start a cold container and fail at the
  # capacity ceiling, preventing the orphan cleanup that would free capacity.
  defp teardown_orphan(%{"provider" => "cloudflare", "group_id" => group_id} = rec, opts) do
    with {:ok, cfg} <- cloudflare_config(rec["tenant_id"]),
         :ok <- __MODULE__.destroy(rec, client: cloudflare_client(cfg, opts, rec["group_id"])),
         :ok <- delete_record(group_id) do
      :ok
    end
  end

  defp teardown_orphan(rec, opts), do: teardown(rec, opts)

  defp teardown_cloudflare(%{"group_id" => group_id, "status" => "archived"}, _opts),
    do: delete_record(group_id)

  defp teardown_cloudflare(%{"status" => "ready"} = rec, opts) do
    with {:ok, _} <- archive_cloudflare_idle(rec, Keyword.put(opts, :force, true)),
         do: delete_record(rec["group_id"])
  end

  defp teardown_cloudflare(_rec, _opts), do: {:error, :group_release_recovery_required}

  @doc "Archive and shut down one idle Cloudflare VM if it meets the idle policy."
  @spec archive_idle_once(String.t(), keyword()) ::
          {:ok, map()} | {:skipped, term()} | {:error, term()}
  def archive_idle_once(group_id, opts \\ []) when is_binary(group_id) do
    with {:ok, rec} <- get_record(group_id),
         :ok <- idle_archive_eligible?(rec, opts),
         {:ok, archived} <- archive_cloudflare_idle(rec, opts) do
      {:ok, archived}
    else
      {:skip, reason} -> {:skipped, reason}
      {:error, _} = err -> err
    end
  end

  defp idle_archive_eligible?(%{"provider" => "cloudflare", "status" => "ready"} = rec, opts) do
    now = opts[:now] || now_ms()
    idle_ms = Keyword.get(opts, :idle_archive_ms, cfg(:idle_archive_ms, opts))
    last_operation = rec["last_operation_at"] || 0
    settled = rec["last_agent_settled_after_vm_at"]
    # A provisioned VM that has never run an operation has no agent settlement
    # to wait for. Start its idle grace at readiness, not at provision start.
    idle_since =
      settled ||
        if(is_nil(rec["last_operation_at"]), do: rec["ready_at"])

    active_count = rec["active_operation_count"] || 0

    cond do
      provider_cutover_archive_hold?(rec) ->
        {:skip, :provider_cutover_archive_pending}

      SalixWeb.CloudVM.RuntimeLifecycle.demand?(rec["group_id"]) ->
        {:skip, :accepted_runtime_work}

      (rec["runtime_selection_until"] || 0) > now ->
        {:skip, :runtime_selection}

      Enum.any?(rec["runtime_targets"] || %{}, fn {_, target} ->
        target["state"] in ~w(pending installing)
      end) ->
        {:skip, :runtime_installing}

      active_count > 0 ->
        {:skip, :active_operations}

      is_nil(idle_since) ->
        {:skip, :not_settled_after_vm}

      Keyword.get(opts, :force, false) ->
        :ok

      now - Enum.max([last_operation, idle_since, rec["ready_at"] || 0]) >= idle_ms ->
        :ok

      true ->
        {:skip, :not_idle}
    end
  end

  defp idle_archive_eligible?(_rec, _opts), do: {:skip, :not_cloudflare_ready}

  defp archive_cloudflare_idle(%{"group_id" => group_id, "tenant_id" => tenant_id} = rec, opts) do
    archive_operation_id = Keyword.get(opts, :archive_operation) || random_operation_id("archive")
    archive_started = System.monotonic_time(:millisecond)

    with {:ok, cfg} <- cloudflare_config(tenant_id),
         client <- cloudflare_client(cfg, opts, rec["group_id"]),
         :ok <- maybe_call_hook(opts, :before_archive_update, group_id),
         {:ok, _} <-
           update_record(group_id, fn current ->
             if current["status"] == "archiving" and
                  current["archive_operation_id"] == archive_operation_id do
               current
             else
               if idle_archive_eligible?(current, opts) == :ok do
                 if length(current["archive_gc_operations"] || []) < 64 do
                   current
                   |> Map.put("status", "archiving")
                   |> Map.put("archive_operation_id", archive_operation_id)
                   |> Map.put("archive_started_at", now_ms())
                   |> Map.put("archive_reason", "idle")
                   |> Map.delete("archive_progress")
                   |> Map.delete("archive_cancel_requested")
                   |> Map.put("last_error", nil)
                 else
                   {:error, :archive_gc_backlog}
                 end
               else
                 {:error, :active_or_not_ready}
               end
             end
           end),
         {:ok,
          %{"status" => "archiving", "archive_operation_id" => ^archive_operation_id} = archiving} <-
           get_record(group_id),
         :ok <- record_idle_archive_start_delay(archiving, opts),
         :ok <- seal_release_source(archiving),
         :ok <- ensure_archive_attachment(archiving),
         {:ok, archive_mode} <- quiesce_archive_runtimes(archiving, archive_operation_id),
         {:ok, result} <-
           export_or_resume_archive(archiving, client, archive_operation_id, archive_mode, opts),
         archive = Map.put(result, "restore_operation", archive_operation_id),
         true <- provider_neutral_archive?(archive),
         :ok <- before_archive_persist(opts),
         {:ok, _} <-
           update_record(group_id, fn current ->
             if current["status"] == "archiving" and
                  current["archive_operation_id"] == archive_operation_id and
                  current["archive_cancel_requested"] != true do
               if current["archive_reason"] in ["idle_committing", "recovery_committing"] do
                 if current["archive"] == archive,
                   do: current,
                   else: {:error, :archive_operation_lost}
               else
                 current
                 |> Map.put("archive_previous", current["archive"])
                 |> Map.put("connector_archive_previous", current["connector_archive"])
                 |> Map.put("archive", archive)
                 |> Map.put("connector_archive", archive_metadata(archive))
               end
             else
               {:error, :archive_operation_lost}
             end
           end),
         {:ok, _} <-
           update_record(group_id, fn current ->
             if current["archive_operation_id"] == archive_operation_id and
                  current["archive_cancel_requested"] != true,
                do:
                  Map.put(
                    current,
                    "archive_reason",
                    if(current["archive_reason"] in ["recovery", "recovery_committing"],
                      do: "recovery_committing",
                      else: "idle_committing"
                    )
                  ),
                else: {:error, :archive_operation_lost}
           end),
         :ok <-
           confirm_archive_quiescence(rec, archive_operation_id, archive_mode, archive_started),
         {:ok, %{"released" => true}} <-
           archive_runtime_rpc(rec, "cloud_runtime_release", %{"token" => archive_operation_id}),
         :ok <- require_release_worker(opts),
         {:ok, _} <- __MODULE__.keepalive(rec, false, client: client, archive_release: true),
         :ok <- __MODULE__.destroy(rec, client: client, archive_release: true),
         {:ok, archived} <- finish_archived_source(group_id, archive_operation_id) do
      {:ok, archived}
    else
      {:ok, _not_owned_archiving} ->
        {:error, :active_or_not_ready}

      false ->
        _ =
          restore_archiving_record(
            group_id,
            :provider_neutral_archive_required,
            archive_operation_id
          )

        {:error, :provider_neutral_archive_required}

      {:error, :runtime_not_quiet} = error ->
        _ = restore_unquiesced_archiving_record(group_id, archive_operation_id)
        error

      {:error, :archive_attachment_unavailable} = error ->
        _ = SalixEnv.VM.Providers.Cloudflare.Attachments.stop(rec["env_id"])

        _ =
          record_last_error(group_id, {:archive_resume_pending, :archive_attachment_unavailable})

        error

      {:error, reason} ->
        _ = restore_archiving_record(group_id, reason, archive_operation_id)
        {:error, reason}
    end
  end

  defp export_or_resume_archive(rec, client, operation, mode, opts) do
    if rec["archive_reason"] in ["idle_committing", "recovery_committing"] do
      if matching_recorded_archive?(rec) and
           get_in(rec, ["archive", "restore_operation"]) == operation,
         do: {:ok, rec["archive"]},
         else: {:error, :committed_archive_missing}
    else
      export_idle_archive(rec, client, operation, mode, opts)
    end
  end

  defp finish_archived_source(group_id, archive_operation_id) do
    with {:ok, rec} <- get_record(group_id) do
      if rec["archive_reason"] == "recovery_committing" do
        record_rebuild_target(rec, archive_operation_id)
      else
        update_record(group_id, fn current ->
          if current["status"] == "archiving" and
               current["archive_operation_id"] == archive_operation_id and
               current["active_operation_count"] == 0 do
            current
            |> enqueue_previous_archive_gc(archive_operation_id)
            |> Map.delete("archive_previous")
            |> Map.delete("connector_archive_previous")
            |> Map.put("status", "archived")
            |> Map.put("archive_last_operation", %{
              "operation" => archive_operation_id,
              "result" => "archived",
              "at" => now_ms()
            })
            |> Map.put("archived_at", now_ms())
            |> Map.put("archive_reason", "idle")
            |> Map.delete("archive_operation_id")
            |> Map.delete("archive_progress")
            |> Map.delete("archive_cancel_requested")
            |> Map.put("active_operation_count", 0)
            |> Map.put("active_operations", %{})
            |> Map.put("node_id", nil)
            |> Map.put("attempt_at", nil)
          else
            {:error, :archive_operation_lost}
          end
        end)
      end
    end
  end

  defp record_idle_archive_start_delay(rec, opts) do
    idle_since =
      rec["last_agent_settled_after_vm_at"] ||
        if(is_nil(rec["last_operation_at"]), do: rec["ready_at"])

    if is_integer(idle_since) and is_integer(rec["archive_started_at"]) do
      due_at =
        Enum.max([rec["last_operation_at"] || 0, idle_since, rec["ready_at"] || 0]) +
          Keyword.get(opts, :idle_archive_ms, cfg(:idle_archive_ms, opts))

      :telemetry.execute(
        [:salix, :vm, :idle_archive, :start],
        %{delay_seconds: max(rec["archive_started_at"] - due_at, 0) / 1_000},
        %{profile: get_in(rec, ["provider_spec", "profile_key"]) || "unknown"}
      )
    end

    :ok
  end

  defp ensure_archive_attachment(rec) do
    if device_connected?(rec) do
      :ok
    else
      with {:ok, group} <- group_record(rec["group_id"]),
           :revived <- targeted_reattach(rec, group),
           :ok <- await_archive_attachment(rec, 100) do
        :ok
      else
        _ -> {:error, :archive_attachment_unavailable}
      end
    end
  end

  defp await_archive_attachment(rec, 0) do
    if device_connected?(rec), do: :ok, else: {:error, :archive_attachment_unavailable}
  end

  defp await_archive_attachment(rec, attempts) do
    if device_connected?(rec) do
      :ok
    else
      Process.sleep(100)
      await_archive_attachment(rec, attempts - 1)
    end
  end

  defp quiesce_archive_runtimes(%{"cloudflare_control" => control} = rec, token)
       when is_map(control) do
    scope =
      if rec["archive_reason"] in ["recovery", "recovery_committing"],
        do: "recovery",
        else: "full"

    with {:ok, cfg} <- cloudflare_config(rec["tenant_id"]),
         client <- cloudflare_client(cfg, [], rec["group_id"]),
         {:ok, %{"quiet" => true}} <-
           CloudflareClient.connector_control(client, sandbox_id(rec), "seal", scope) do
      {:ok, {:managed, scope}}
    else
      {:ok, _} ->
        {:error, :runtime_not_quiet}

      {:error, reason} = error ->
        if scope == "full" and legacy_control_error?(reason),
          do: quiesce_legacy_archive_runtimes(rec, token),
          else: error
    end
  end

  defp quiesce_archive_runtimes(%{"provider" => "cloudflare"} = rec, token) do
    quiesce_legacy_archive_runtimes(rec, token)
  end

  defp quiesce_archive_runtimes(_rec, _token), do: {:ok, :legacy}

  defp legacy_control_error?({:api_error, 404, _}), do: true
  defp legacy_control_error?({:api_error, 404, _, _}), do: true
  defp legacy_control_error?(_), do: false

  defp quiesce_legacy_archive_runtimes(rec, token) do
    case archive_runtime_rpc(rec, "cloud_runtime_quiesce", %{
           "token" => token,
           "timeout_ms" => 4_200_000
         }) do
      {:ok, %{"quiet" => true, "continued" => _}} -> {:ok, :chunked}
      {:ok, %{"quiet" => true}} -> {:ok, :legacy}
      {:ok, %{"quiet" => false}} -> {:error, :runtime_not_quiet}
      {:error, "external runtime still owns work"} -> {:error, :runtime_not_quiet}
      _ -> {:error, :runtime_quiesce_unconfirmed}
    end
  end

  defp export_idle_archive(rec, client, token, :chunked, opts) do
    with :ok <- confirm_archive_quiescence(rec, token, :chunked, nil) do
      DurableArchive.export(client, sandbox_id(rec), rec["group_id"], token, fn progress ->
        with :ok <- require_release_worker(opts),
             do: persist_archive_progress(rec["group_id"], token, progress)
      end)
    end
  end

  defp export_idle_archive(rec, client, token, {:managed, scope} = mode, opts) do
    with :ok <- confirm_archive_quiescence(rec, token, mode, nil) do
      DurableArchive.export(
        client,
        sandbox_id(rec),
        rec["group_id"],
        token,
        fn progress ->
          with :ok <- require_release_worker(opts),
               do: persist_archive_progress(rec["group_id"], token, progress)
        end,
        scope
      )
    end
  end

  defp export_idle_archive(rec, client, _token, :legacy, opts) do
    with :ok <- require_release_worker(opts),
         {:ok, %{checkpoint: result}} <-
           __MODULE__.checkpoint(rec, client: client, provider_neutral_required: true) do
      {:ok, result["archive"] || result}
    end
  end

  defp persist_archive_progress(group_id, operation, progress) do
    with {:ok, %{"status" => "archiving", "archive_operation_id" => ^operation} = rec} <-
           get_record(group_id),
         false <- rec["archive_cancel_requested"] == true do
      previous = rec["archive_progress"] || %{}
      now = now_ms()

      if previous["phase"] != progress["phase"] or
           now - (previous["reported_at"] || 0) >= 5_000 or
           (is_integer(progress["total_bytes"]) and
              progress["uploaded_bytes"] == progress["total_bytes"]) do
        case update_record(group_id, fn current ->
               if current["status"] == "archiving" and
                    current["archive_operation_id"] == operation and
                    current["archive_cancel_requested"] != true do
                 Map.put(current, "archive_progress", Map.put(progress, "reported_at", now))
               else
                 {:error, :archive_cancel_requested}
               end
             end) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end
      else
        :ok
      end
    else
      true -> {:error, :archive_cancel_requested}
      _ -> {:error, :archive_operation_lost}
    end
  end

  defp confirm_archive_quiescence(_rec, _token, :legacy, started) do
    if System.monotonic_time(:millisecond) - started < 13 * 60_000,
      do: :ok,
      else: {:error, :archive_quiescence_expired}
  end

  defp confirm_archive_quiescence(rec, token, {:managed, scope}, _started) do
    case quiesce_archive_runtimes(rec, token) do
      {:ok, {:managed, ^scope}} -> :ok
      {:error, _} = error -> error
      _ -> {:error, :archive_quiescence_expired}
    end
  end

  defp confirm_archive_quiescence(rec, token, :chunked, _started) do
    case archive_runtime_rpc(rec, "cloud_runtime_quiesce", %{
           "token" => token,
           "timeout_ms" => 4_200_000
         }) do
      {:ok, %{"quiet" => true, "continued" => true}} -> :ok
      _ -> {:error, :archive_quiescence_expired}
    end
  end

  defp restore_archiving_record(group_id, reason, archive_operation_id) do
    with {:ok, rec} <- get_record(group_id),
         true <- rec["archive_operation_id"] == archive_operation_id do
      if rec["archive_reason"] in ["idle_committing", "recovery", "recovery_committing"] do
        # Release/destroy may have succeeded without a response. Keep the
        # archived facts and fence until reconciliation reports operator action.
        record_last_error(group_id, reason)
      else
        case resume_archive_source(rec, archive_operation_id) do
          {:ok, %{"resumed" => true}} ->
            with :ok <- stop_archive_repair_attachment(rec) do
              update_record(group_id, fn current ->
                if current["archive_operation_id"] == archive_operation_id do
                  current
                  |> Map.put("status", "ready")
                  |> rollback_failed_archive(archive_operation_id)
                  |> Map.delete("archive_operation_id")
                  |> Map.delete("archive_progress")
                  |> Map.delete("archive_cancel_requested")
                  |> Map.put("last_error", inspect(reason) |> String.slice(0, 500))
                  |> maybe_record_archive_cancel(archive_operation_id, reason)
                else
                  current
                end
              end)
            end

          _ ->
            record_last_error(group_id, {:archive_resume_pending, reason})
        end
      end
    end
  end

  defp restore_unquiesced_archiving_record(group_id, archive_operation_id) do
    with {:ok, rec} <- get_record(group_id),
         :ok <- reopen_unquiesced_source(rec),
         :ok <- stop_archive_repair_attachment(rec) do
      update_record(group_id, fn current ->
        if current["status"] == "archiving" and
             current["archive_reason"] == "idle" and
             current["archive_operation_id"] == archive_operation_id do
          current
          |> Map.put("status", "ready")
          |> rollback_failed_archive(archive_operation_id)
          |> Map.delete("archive_operation_id")
          |> Map.delete("archive_progress")
          |> Map.delete("archive_cancel_requested")
          |> Map.put("last_error", ":runtime_not_quiet")
        else
          {:error, :archive_operation_lost}
        end
      end)
    end
  end

  defp resume_archive_source(rec, operation) do
    with {:ok, cfg} <- cloudflare_config(rec["tenant_id"]),
         client <- cloudflare_client(cfg, [], rec["group_id"]),
         {:ok, mode} <- CloudflareClient.resume_control(client, sandbox_id(rec)) do
      if mode == :managed,
        do: {:ok, %{"resumed" => true}},
        else: archive_runtime_rpc(rec, "cloud_runtime_resume", %{"token" => operation})
    end
  end

  defp reopen_unquiesced_source(rec) do
    with {:ok, cfg} <- cloudflare_config(rec["tenant_id"]),
         client <- cloudflare_client(cfg, [], rec["group_id"]),
         {:ok, _} <- CloudflareClient.resume_control(client, sandbox_id(rec)),
         do: :ok
  end

  defp stop_archive_repair_attachment(rec) do
    case current_device(rec) do
      {:ok,
       %{"meta" => %{"archive_repair" => true}, "node" => owner, "connector_run_id" => run_id}}
      when is_binary(owner) ->
        with :ok <- stop_attachment_on_owner(owner, rec["env_id"]) do
          case current_device(rec) do
            {:error, :not_found} ->
              :ok

            {:ok, device} ->
              if device["connector_run_id"] != run_id or device["status"] != "connected" or
                   get_in(device, ["meta", "archive_repair"]) != true,
                 do: :ok,
                 else: {:error, :archive_repair_attachment_still_connected}

            _ ->
              {:error, :archive_repair_attachment_still_connected}
          end
        end

      {:ok, %{"meta" => %{"archive_repair" => true}}} ->
        {:error, :archive_repair_attachment_owner_unavailable}

      _ ->
        :ok
    end
  end

  defp stop_attachment_on_owner(owner, env_id) when is_binary(env_id) do
    case Enum.find([node() | Node.list()], &(to_string(&1) == owner)) do
      nil ->
        {:error, :archive_repair_attachment_owner_unavailable}

      owner_node ->
        try do
          if owner_node == node() do
            SalixEnv.VM.Providers.Cloudflare.Attachments.stop(env_id)
          else
            :erpc.call(
              owner_node,
              SalixEnv.VM.Providers.Cloudflare.Attachments,
              :stop,
              [env_id],
              5_000
            )
          end
        catch
          _, _ -> {:error, :archive_repair_attachment_owner_unavailable}
        end
    end
  end

  defp maybe_record_archive_cancel(current, operation, reason)
       when reason in [:archive_cancelled, :archive_cancel_requested] do
    Map.put(current, "archive_last_operation", %{
      "operation" => operation,
      "result" => "cancelled",
      "at" => now_ms()
    })
  end

  defp maybe_record_archive_cancel(current, _operation, _reason), do: current

  defp archive_runtime_rpc(rec, method, params) do
    resource = rec["provider_resource_name"]
    profile = get_in(rec, ["provider_spec", "profile_key"])

    with {:ok,
          %{
            "status" => "connected",
            "connector_run_id" => run_id,
            "meta" =>
              %{
                "provider" => "cloudflare",
                "provider_resource_name" => ^resource
              } = meta
          }}
         when is_binary(run_id) <- current_device(rec),
         true <- archive_attachment_profile?(meta, profile) do
      timeout = if method == "cloud_runtime_quiesce", do: 100_000, else: 20_000
      SalixEnv.Connector.Live.request(run_id, method, params, timeout: timeout)
    else
      _ -> {:error, :disconnected}
    end
  end

  defp archive_attachment_profile?(%{"profile_key" => profile}, profile), do: true

  # Pre-profile Cloudflare attachments can remain connected through the first
  # release. Their only Sandbox namespace was the retained standard-2 app.
  defp archive_attachment_profile?(meta, "cf-standard-2"),
    do: not is_map_key(meta, "profile_key")

  defp archive_attachment_profile?(_meta, _profile), do: false

  defp enqueue_previous_archive_gc(current, new_operation) do
    case current["archive_previous"] do
      %{"type" => type, "operation" => old_operation} = old_archive
      when type in ["connector_tar_gz_chunks", "connector_tar_zst_chunks"] and
             is_binary(old_operation) and old_operation != new_operation ->
        queue_archive_gc(current, old_operation, old_archive["storage"] || "salix_s3")

      _ ->
        current
    end
  end

  defp rollback_failed_archive(current, operation) do
    current =
      if get_in(current, ["archive", "operation"]) == operation do
        current
        |> Map.put("archive", current["archive_previous"])
        |> Map.put("connector_archive", current["connector_archive_previous"])
      else
        current
      end

    current
    |> Map.delete("archive_previous")
    |> Map.delete("connector_archive_previous")
    |> queue_archive_gc(operation, "r2")
    |> queue_archive_gc(operation, "salix_s3")
  end

  defp queue_archive_gc(current, operation, storage) do
    pending = current["archive_gc_operations"] || []

    entry =
      if storage == "r2", do: %{"operation" => operation, "storage" => "r2"}, else: operation

    Map.put(current, "archive_gc_operations", Enum.uniq(pending ++ [entry]))
  end

  @doc "Restore an archived Cloudflare VM on demand."
  @spec wake_archived_vm(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def wake_archived_vm(group_id, opts \\ []) when is_binary(group_id) do
    with {:ok, %{"provider" => "cloudflare"} = rec} <- get_record(group_id) do
      case complete_connected_wake(rec) do
        {:ok, ready} -> {:ok, ready}
        :continue -> do_wake_archived_vm(group_id, rec, opts)
        {:error, _} = error -> error
      end
    end
  end

  defp do_wake_archived_vm(group_id, rec, opts) do
    with :ok <- authorize_resume(group_id, opts),
         {:ok, wake_operation_id} <- wake_operation(group_id, rec, opts),
         :ok <- stop_stale_wake_attachment(rec, wake_operation_id),
         {:ok, group} <- switch_group_record(group_id),
         {:ok, cfg} <- cloudflare_config(rec["tenant_id"]),
         {:ok, %{"status" => "waking", "wake_operation_id" => ^wake_operation_id} = waking} <-
           get_record(group_id),
         :ok <-
           wake_cloudflare_record(
             waking,
             group,
             cloudflare_client(
               cfg,
               Keyword.put(opts, :worker_version_id, rec["desired_worker_version_id"]),
               rec["group_id"]
             ),
             Keyword.put(opts, :wake_operation_id, wake_operation_id)
           ),
         {:ok, ready} <- get_record(group_id) do
      {:ok, ready}
    else
      {:ok, %{"status" => status}} ->
        {:error, {:bad_state, status}}

      {:error, _} = err ->
        err
    end
  end

  @doc "Confirm only the exact connected wake without starting a Container."
  def confirm_completed_wake(workload) do
    with %GroupCompute.Environment{owner_type: "group", owner_id: group} <-
           SalixStore.Repo.get(GroupCompute.Environment, workload.environment_id),
         {:ok, %{"workload_id" => id, "provider" => "cloudflare"} = rec} <- get_record(group),
         true <- id == workload.id do
      case complete_connected_wake(rec) do
        {:ok, _} -> {:ok, %{outcome: :group_reconciled}}
        result -> result
      end
    else
      _ -> :continue
    end
  end

  defp complete_connected_wake(%{"archive_reason" => reason})
       when reason in ["recovery_rebuild", "recovery_restoring"],
       do: :continue

  defp complete_connected_wake(
         %{
           "status" => "waking",
           "wake_operation_id" => operation,
           "provider_resource_name" => resource
         } = rec
       )
       when is_binary(operation) and is_binary(resource) do
    profile = get_in(rec, ["provider_spec", "profile_key"])

    case current_device(rec) do
      {:ok,
       %{
         "status" => "connected",
         "meta" => %{
           "provider" => "cloudflare",
           "provider_resource_name" => ^resource,
           "profile_key" => ^profile,
           "wake_operation_id" => ^operation
         }
       }} ->
        mark_cloudflare_ready(rec["group_id"], rec["env_id"], %{}, wake_operation_id: operation)

      _ ->
        :continue
    end
  end

  defp complete_connected_wake(_rec), do: :continue

  defp wake_operation(group_id, %{"status" => "archived"}, opts) do
    wake_operation_id = random_operation_id("wake")

    with :ok <- maybe_call_hook(opts, :before_wake_update, group_id),
         {:ok, _} <-
           update_record(group_id, fn current ->
             if current["status"] == "archived" do
               current
               |> Map.put("status", "waking")
               |> Map.put("wake_operation_id", wake_operation_id)
               |> Map.put("last_wake_at", now_ms())
               |> Map.put("last_error", nil)
             else
               {:error, {:bad_state, current["status"]}}
             end
           end) do
      {:ok, wake_operation_id}
    end
  end

  defp wake_operation(_group_id, %{"status" => "waking", "wake_operation_id" => id}, _opts)
       when is_binary(id) do
    {:ok, id}
  end

  defp wake_operation(_group_id, rec, _opts), do: {:error, {:bad_state, rec["status"]}}

  defp stop_stale_wake_attachment(rec, wake_operation_id) do
    case current_device(rec) do
      {:ok, %{"node" => owner, "connector_run_id" => run_id} = device}
      when is_binary(owner) ->
        meta = device["meta"] || %{}

        if meta["provider_resource_name"] == rec["provider_resource_name"] and
             (meta["profile_key"] != get_in(rec, ["provider_spec", "profile_key"]) or
                meta["wake_operation_id"] != wake_operation_id) do
          with :ok <- stop_attachment_on_owner(owner, rec["env_id"]),
               :ok <- await_stale_wake_attachment_stop(rec, run_id, 20) do
            :ok
          end
        else
          :ok
        end

      _ ->
        # Without an owner there is no Attachment process to address. The
        # import admission still rejects a live old connection.
        :ok
    end
  end

  defp await_stale_wake_attachment_stop(rec, run_id, attempts) do
    case current_device(rec) do
      {:ok, %{"status" => "connected", "connector_run_id" => ^run_id}} when attempts > 0 ->
        Process.sleep(250)
        await_stale_wake_attachment_stop(rec, run_id, attempts - 1)

      {:ok, %{"status" => "connected", "connector_run_id" => ^run_id}} ->
        {:error, :stale_wake_attachment_still_connected}

      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp wake_cloudflare_record(rec, group, client, opts) do
    case provision_cloudflare_vm(rec, group, client, opts) do
      {:ok, :ready} -> :ok
      {:ok, other} -> {:error, other}
      {:error, _} = err -> err
    end
  end

  @doc "Persist Group release intent for the shared Compute reconciler."
  def teardown_async(group_id), do: GroupCompute.request_group_stop(group_id)

  @doc """
  Bounded manual recovery page for retained legacy resources.
  Normal Cloudflare recovery runs through ComputeReconciler claims.
  Returns the page cursor with provisioned, failed, and orphaned results.
  """
  @spec sweep_once(keyword()) :: map()
  def sweep_once(opts \\ []) do
    {:ok, page} = GroupCompute.page_group_workloads(Keyword.take(opts, [:limit, :cursor]))
    records = page.records

    result =
      Enum.reduce(
        records,
        %{
          provisioned: [],
          failed: [],
          orphaned: [],
          revived: [],
          archived: [],
          eligible_for_resume: []
        },
        fn rec, acc -> sweep_one(rec, opts, acc) end
      )

    emit_recovery_metrics(records)
    Map.put(result, :next_cursor, page.next_cursor)
  end

  defp emit_recovery_metrics(records) do
    records
    |> Enum.group_by(fn rec ->
      owner = rec["billing_owner"] || %{}
      {owner["surface"] || "system", rec["provider"] || "other", rec["status"] || "other"}
    end)
    |> Enum.each(fn {{surface, provider, state}, rows} ->
      Salix.Telemetry.emit_vm_recovery(
        %{surface: surface, provider: provider, state: state},
        length(rows)
      )
    end)
  rescue
    _exception -> :ok
  end

  defp sweep_one(%{"group_id" => group_id} = rec, opts, acc) do
    case {group_record(group_id), rec["status"]} do
      {:missing, _status} ->
        case teardown_orphan(rec, opts) do
          :ok ->
            Map.update!(acc, :orphaned, &[group_id | &1])

          {:error, reason} ->
            _ = record_last_error(group_id, {:orphan_teardown, reason})
            acc
        end

      {{:ok, _group}, "creating"} ->
        case provision_once(group_id, opts) do
          {:ok, :ready} -> Map.update!(acc, :provisioned, &[group_id | &1])
          {:ok, :failed} -> Map.update!(acc, :failed, &[group_id | &1])
          {:ok, :orphaned} -> Map.update!(acc, :orphaned, &[group_id | &1])
          _ -> acc
        end

      {{:ok, group}, "ready"} ->
        _ = maybe_meter_ready_interval(rec, group, opts)

        if SalixWeb.CloudVM.Runtimes.pending?(rec) do
          SalixWeb.CloudVM.Runtimes.schedule(group_id, opts)
        end

        case maybe_archive_idle(rec, opts) do
          :archived ->
            Map.update!(acc, :archived, &[group_id | &1])

          :skip ->
            case maybe_revive_carrier(rec, group, opts) do
              :revived -> Map.update!(acc, :revived, &[group_id | &1])
              _ -> acc
            end
        end

      {{:ok, group}, "billing_suspended"} ->
        case authorize_vm_reconcile(group, rec, opts) do
          :ok ->
            _ = mark_eligible_for_resume(group_id, %{"allowed" => true})

            case restart_for_resume(group_id) do
              {:ok, _rec} ->
                case provision_once(group_id, opts) do
                  {:ok, :ready} -> Map.update!(acc, :provisioned, &[group_id | &1])
                  {:ok, :failed} -> Map.update!(acc, :failed, &[group_id | &1])
                  {:ok, :orphaned} -> Map.update!(acc, :orphaned, &[group_id | &1])
                  _ -> Map.update!(acc, :eligible_for_resume, &[group_id | &1])
                end

              _ ->
                Map.update!(acc, :eligible_for_resume, &[group_id | &1])
            end

          {:error, {:billing_unavailable, decision}} ->
            _ = mark_billing_suspended(group_id, decision)
            acc
        end

      {{:ok, _group}, "eligible_for_resume"} ->
        case restart_for_resume(group_id) do
          {:ok, _rec} ->
            case provision_once(group_id, opts) do
              {:ok, :ready} -> Map.update!(acc, :provisioned, &[group_id | &1])
              {:ok, :failed} -> Map.update!(acc, :failed, &[group_id | &1])
              {:ok, :orphaned} -> Map.update!(acc, :orphaned, &[group_id | &1])
              _ -> acc
            end

          _ ->
            acc
        end

      {{:ok, _group}, status} when status in ["archiving", "archived", "waking"] ->
        acc

      _ ->
        acc
    end
  end

  defp maybe_archive_idle(
         %{"provider" => "cloudflare", "status" => "ready", "group_id" => group_id},
         opts
       ) do
    case archive_idle_once(group_id, opts) do
      {:ok, _} ->
        :archived

      {:skipped, _} ->
        :skip

      {:error, reason} ->
        _ = record_last_error(group_id, {:idle_archive, reason})
        :skip
    end
  end

  defp maybe_archive_idle(_rec, _opts), do: :skip

  defp maybe_revive_carrier(rec, group, _opts), do: maybe_revive_cloudflare_attachment(rec, group)

  defp maybe_revive_cloudflare_attachment(rec, group) do
    if device_connected?(rec), do: :ok, else: targeted_reattach(rec, group)
  end

  defp restart_for_resume(group_id) do
    update_record(group_id, fn rec ->
      Map.merge(rec, %{
        "status" => "creating",
        "error" => nil,
        "last_error" => nil,
        "node_id" => nil,
        "attempt_at" => nil,
        "created_at" => now_ms()
      })
    end)
  end

  defp decision_snapshot(%{__struct__: _} = decision) do
    decision
    |> Map.from_struct()
    |> decision_snapshot()
  end

  defp decision_snapshot(decision) when is_map(decision) do
    decision
    |> Map.take([
      :allowed?,
      :reason,
      :decision_id,
      :balance_snapshot,
      "allowed",
      "allowed?",
      "reason",
      "decision_id",
      "balance_snapshot"
    ])
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Map.new()
  end

  defp decision_snapshot(_decision), do: %{}

  defp device_connected?(rec) do
    case current_device(rec) do
      {:ok, %{"status" => "connected", "node" => owner, "transport_id" => transport_id}} ->
        SalixEnv.Bridge.live_on?(owner, transport_id)

      _ ->
        false
    end
  end

  defp maybe_meter_ready_interval(%{"group_id" => group_id} = rec, group, opts) do
    now = opts[:now] || now_ms()
    checkpoint_ms = rec["last_metered_at"] || rec["ready_at"] || rec["created_at"] || now
    start_ms = max(checkpoint_ms, rec["ready_at"] || checkpoint_ms)
    duration_seconds = max(div(now - start_ms, 1_000), 0)

    if duration_seconds > 0 do
      fact = %{
        source: "salix_web.cloud_vm",
        source_key: "vm:cloudflare:#{group_id}:#{start_ms}:#{now}",
        entrypoint: "cloud_vm_sweeper",
        actor_type: "system",
        provider: Keyword.get(opts, :vm_provider, metering_provider(rec, opts)),
        sku: Keyword.get(opts, :vm_sku, metering_sku(rec, opts)),
        duration_seconds: duration_seconds,
        quantity: duration_seconds,
        metered_at: DateTime.from_unix!(now, :millisecond),
        interval_start_ms: start_ms,
        interval_end_ms: now,
        tenant_id: rec["tenant_id"],
        group_id: group_id,
        env_id: rec["env_id"],
        provider_resource_name: rec["provider_resource_name"],
        owner_snapshot: group["billing_owner"] || %{},
        quality: []
      }

      result = call_metering(:meter_vm_interval, [fact], opts)

      if checkpoint_meter_result?(result) do
        case update_record(group_id, &Map.put(&1, "last_metered_at", now)) do
          {:ok, _} -> :ok
          {:error, _} = error -> if(opts[:strict_metering], do: error, else: :ok)
        end
      else
        if(
          opts[:strict_metering] == true and
            (result != :disabled or not is_nil(billing_account_id(group["billing_owner"] || %{}))),
          do: {:error, :provider_migration_metering_failed},
          else: :ok
        )
      end
    else
      :ok
    end
  end

  defp checkpoint_meter_result?(result) do
    case result do
      :ok ->
        true

      {:ok, _} ->
        true

      {:ok, _, _} ->
        true

      {:unattributed, _} ->
        true

      {:unattributed, _, _} ->
        true

      {:pending, _} ->
        true

      {:pending, _, _} ->
        true

      _ ->
        false
    end
  end

  defp call_metering(fun, args, opts) do
    case Application.get_env(:salix_web, :vm_metering_mod) do
      nil ->
        :disabled

      mod ->
        apply(mod, fun, args)
    end
  catch
    kind, reason ->
      Logger.warning("cloud-vm metering failed: #{inspect({kind, reason})}")
      if(opts[:strict_metering], do: {:error, :metering_failed}, else: :ok)
  end

  # ---- claim ----

  defp claim(%{"group_id" => group_id} = rec, opts) do
    now = now_ms()
    attempt = rec["attempt_at"]

    cond do
      rec["status"] != "creating" ->
        {:error, {:not_claimable, rec["status"]}}

      is_integer(attempt) and now - attempt < cfg(:stale_claim_ms, opts) and
          not Keyword.get(opts, :force, false) ->
        {:error, :recently_attempted}

      true ->
        update_record(group_id, fn current ->
          current_attempt = current["attempt_at"]

          cond do
            current["status"] != "creating" ->
              {:error, {:not_claimable, current["status"]}}

            is_integer(current_attempt) and
              now - current_attempt < cfg(:stale_claim_ms, opts) and
                not Keyword.get(opts, :force, false) ->
              {:error, :recently_attempted}

            true ->
              Map.merge(current, %{"attempt_at" => now, "node_id" => local_node_id()})
          end
        end)
    end
  end

  # ---- helpers ----

  defp group_record(group_id) do
    case S3.get(Keys.ctl_group(group_id)) do
      {:ok, %{body: body}} ->
        {:ok, Jason.decode!(body)}

      {:error, :not_found} ->
        :missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cloudflare_client(%{base_url: _} = cfg, opts, group_id) do
    profile_key =
      case get_record(group_id) do
        {:ok, rec} -> get_in(rec, ["provider_spec", "profile_key"])
        _ -> nil
      end

    opts[:cloudflare_client] ||
      SalixEnv.VM.Providers.Cloudflare.Client.new(
        base_url: cfg.base_url,
        secret: cfg.secret,
        profile_key: profile_key,
        worker_name: opts[:worker_name] || Map.get(cfg, :worker_name),
        worker_version_id: opts[:worker_version_id],
        group_id: group_id,
        backoff_ms: 1,
        req_options: opts[:req_options] || []
      )
  end

  defp random_operation_id(kind),
    do: kind <> "-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

  defp idempotency_class(kind)
       when kind in ["read", "read_stream", "process_list", "process_tail"],
       do: "read_only"

  defp idempotency_class("status"), do: "lifecycle_read"
  defp idempotency_class(_kind), do: "non_idempotent"

  defp put_initial_worker_release(rec, "cloudflare") do
    release = worker_release()

    rec
    |> maybe_put("desired_worker_version_id", release["desired_worker_version_id"])
    |> maybe_put("worker_release_id", release["worker_release_id"])
    |> maybe_put("worker_release_kind", release["worker_release_kind"])
    |> Map.put_new("rollout_state", "pending")
    |> Map.put_new("active_operation_count", 0)
    |> Map.put_new("active_operations", %{})
  end

  defp put_initial_worker_release(rec, _provider), do: rec

  defp update_record(group_id, fun) do
    with {:ok, committed, previous} <- GroupCompute.update_group_workload(group_id, fun) do
      billing_owner = committed["billing_owner"] || previous["billing_owner"] || %{}

      Salix.Telemetry.emit_vm_transition(
        %{
          surface: billing_owner["surface"] || "system",
          provider: committed["provider"] || previous["provider"] || "other"
        },
        previous["status"],
        committed["status"]
      )

      {:ok, committed}
    end
  end

  defp cloudflare_keepalive_candidate?(rec) do
    rec["provider"] == "cloudflare" and rec["provider_resource_id"] not in [nil, ""] and
      rec["status"] in ["ready", "creating", "reviving", "waking", "failed"]
  end

  defp attachment_status(rec) do
    case current_device(rec) do
      {:ok, %{"status" => "connected"} = device} ->
        if SalixEnv.Bridge.live_on?(device["node"], device["transport_id"]),
          do: {:connected, device},
          else: {:stale_connected, device}

      {:ok, device} ->
        {:disconnected, device}

      {:error, :not_found} ->
        :missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_device(rec) do
    case {rec["tenant_id"], rec["group_id"], rec["device_id"]} do
      {tenant_id, group_id, device_id}
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and group_id != "" and
             is_binary(device_id) and device_id != "" ->
        Registry.get_device(tenant_id, group_id, device_id)

      _ ->
        {:error, :not_found}
    end
  end

  defp format_attachment_status(:missing), do: "missing"
  defp format_attachment_status({:stale_connected, _env_rec}), do: "stale_connected"
  defp format_attachment_status({:disconnected, _env_rec}), do: "disconnected"
  defp format_attachment_status({:error, reason}), do: "error:#{inspect(reason)}"

  defp with_ops_age(rec, now) do
    rec
    |> Map.delete("archive")
    |> Map.put("ops_age_ms", age_ms(ops_age_basis(rec), now))
  end

  defp ops_age_basis(%{"status" => "waking"} = rec),
    do: rec["last_wake_at"] || rec["attempt_at"] || rec["updated_at"] || rec["created_at"]

  defp ops_age_basis(%{"status" => "archiving"} = rec),
    do: rec["archived_at"] || rec["attempt_at"] || rec["updated_at"] || rec["created_at"]

  defp ops_age_basis(%{"status" => "creating"} = rec),
    do: rec["attempt_at"] || rec["created_at"] || rec["updated_at"]

  defp ops_age_basis(%{"status" => "reviving"} = rec),
    do: rec["attempt_at"] || rec["last_wake_at"] || rec["updated_at"] || rec["created_at"]

  defp ops_age_basis(%{"status" => "failed"} = rec),
    do: rec["updated_at"] || rec["attempt_at"] || rec["created_at"]

  defp ops_age_basis(rec),
    do:
      rec["attempt_at"] || rec["updated_at"] || rec["ready_at"] || rec["created_at"] ||
        rec["archived_at"] || rec["last_wake_at"]

  defp age_ms(value, now) when is_integer(value), do: max(now - value, 0)
  defp age_ms(_value, _now), do: nil

  defp cfg(key, opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(@defaults, key)
    end
  end

  defp local_node_id do
    case System.get_env("SALIX_NODE_ID") do
      id when is_binary(id) and id != "" -> id
      _ -> to_string(node())
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp now_ms, do: System.system_time(:millisecond)

  @behaviour SalixEnv.ComputeProvider

  alias SalixEnv.VM.Providers.Cloudflare.Attachments

  @impl true
  def capabilities, do: [:runtime_exec, :service_public_http]

  @impl true
  def allocate(allocation, _workload, opts) do
    with {:ok, resource} <-
           CloudflareClient.ensure(Keyword.fetch!(opts, :client), sandbox_id(allocation),
             keep_alive: true
           ),
         do: {:ok, %{outcome: :succeeded, resource: resource}}
  end

  @impl true
  def observe(allocation, opts) do
    with {:ok, resource} <- status(allocation, opts),
         do: {:ok, %{outcome: :succeeded, resource: resource}}
  end

  @impl true
  def release(allocation, opts) do
    with :ok <- destroy(allocation, opts), do: {:ok, %{outcome: :succeeded}}
  end

  @impl true
  def bootstrap(allocation, workload, credential, opts) do
    with :ok <- authorize_bootstrap(workload, credential),
         %GroupCompute.Environment{owner_type: "group", owner_id: group} <-
           SalixStore.Repo.get(GroupCompute.Environment, workload.environment_id),
         {:ok, rec} <- GroupCompute.group_workload(group),
         true <- rec["workload_id"] == workload.id and rec["allocation_id"] == allocation.id,
         {:ok, %{attachment: attachment}} <- ensure(rec, rec, Keyword.put(opts, :attach, true)) do
      {:ok, %{outcome: :succeeded, attachment: attachment}}
    else
      nil -> {:error, :connector_identity_required}
      false -> {:error, :connector_identity_required}
      {:error, _} = error -> error
      _ -> {:error, :connector_identity_required}
    end
  end

  @impl true
  def checkpoint(allocation, opts) do
    with {:ok, archive} <-
           CloudflareClient.checkpoint(
             Keyword.fetch!(opts, :client),
             sandbox_id(allocation),
             Keyword.put(opts, :provider_neutral_required, true)
           ),
         do: {:ok, %{outcome: :succeeded, checkpoint: archive}}
  end

  @impl true
  def restore(allocation, archive, opts) do
    client = Keyword.fetch!(opts, :client)

    case archive do
      %{"type" => type} when type in ["connector_tar_gz_chunks", "connector_tar_zst_chunks"] ->
        with :ok <-
               DurableArchive.restore(client, sandbox_id(allocation), client.group_id, archive),
             do: {:ok, %{outcome: :succeeded, restore: %{"restored" => true}}}

      _ ->
        with {:ok, result} <- CloudflareClient.restore(client, sandbox_id(allocation), archive),
             do: {:ok, %{outcome: :succeeded, restore: result}}
    end
  end

  defp authorize_bootstrap(%{id: workload_id}, %{"token" => token, "workload_id" => workload_id}) do
    case SalixStore.Compute.WorkloadCredential.verify(token, workload_id, "runtime") do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_workload_credential}
    end
  end

  defp authorize_bootstrap(_, _), do: {:error, :invalid_workload_credential}

  def ensure(rec, group, opts) do
    client = Keyword.fetch!(opts, :client)
    ensure_once(rec, group, opts, client, sandbox_id(rec))
  end

  defp ensure_once(rec, group, opts, client, id) do
    with {:ok, sandbox} <-
           CloudflareClient.ensure(client, id, keep_alive: Keyword.get(opts, :keep_alive)),
         :ok <- maybe_restore(client, id, rec["group_id"], Keyword.get(opts, :archive), opts),
         :ok <- ready?(client, id),
         :ok <- CloudflareClient.open_connector(client, id),
         {:ok, attachment} <- maybe_attach(rec, group, client, id, opts) do
      {:ok, %{sandbox: sandbox, attachment: attachment}}
    end
  end

  @doc "Attach Salix to an already-ready sandbox without mutating provider state."
  def attach_existing(rec, group, opts) do
    opts = opts |> Keyword.put(:attach, true) |> Keyword.put_new(:async, true)

    maybe_attach(
      rec,
      group,
      Keyword.fetch!(opts, :client),
      sandbox_id(rec),
      opts
    )
  end

  def status(rec, opts) do
    opts |> Keyword.fetch!(:client) |> CloudflareClient.status(sandbox_id(rec))
  end

  def destroy(rec, opts) do
    with :ok <- current_archive_hold_admission(rec["group_id"]) do
      if env_id = rec["env_id"], do: Attachments.stop(env_id)

      opts
      |> Keyword.fetch!(:client)
      |> CloudflareClient.destroy(sandbox_id(rec),
        purpose: if(Keyword.get(opts, :archive_release, false), do: :archive, else: :normal)
      )
    end
  end

  defp current_archive_hold_admission(group_id) do
    case get_record(group_id) do
      {:ok, current} -> require_no_archive_hold(current)
      {:error, reason} when reason in [:not_found, :invalid_group] -> :ok
      {:error, _} -> {:error, :group_workload_unavailable}
    end
  end

  defp provider_cutover_archive_hold?(rec),
    do:
      get_in(rec, ["provider_migration", "archive_hold"]) ==
        "awaiting_durable_archive"

  defp require_no_archive_hold(rec) do
    if provider_cutover_archive_hold?(rec),
      do: {:error, :provider_cutover_archive_pending},
      else: :ok
  end

  def keepalive(rec, keep_alive, opts) when is_boolean(keep_alive) do
    with :ok <-
           if(keep_alive, do: :ok, else: current_archive_hold_admission(rec["group_id"])) do
      opts
      |> Keyword.fetch!(:client)
      |> CloudflareClient.keepalive(sandbox_id(rec), keep_alive,
        purpose: if(Keyword.get(opts, :archive_release, false), do: :archive, else: :normal)
      )
    end
  end

  defp maybe_restore(_client, _id, _group_id, nil, _opts), do: :ok
  defp maybe_restore(_client, _id, _group_id, "", _opts), do: :ok

  defp maybe_restore(client, id, group_id, %{"type" => type} = archive, opts)
       when type in ["connector_tar_gz_chunks", "connector_tar_zst_chunks"],
       do:
         DurableArchive.restore(client, id, group_id, archive,
           deadline_ms: opts[:restore_deadline_ms]
         )

  defp maybe_restore(client, id, _group_id, archive, _opts) do
    case CloudflareClient.restore(client, id, archive) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ready?(client, id) do
    case CloudflareClient.proxy(client, id, "/readyz") do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:connector_not_ready, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_attach(rec, group, client, id, opts) do
    if Keyword.get(opts, :attach, true) do
      attachment_opts =
        [
          env_id: Map.fetch!(rec, "env_id"),
          sandbox_id: id,
          client: client,
          meta:
            attachment_meta(rec, group, id)
            |> Map.merge(Keyword.get(opts, :meta, %{}))
            |> Map.put("managed_compute", true)
        ] ++ Keyword.take(opts, [:async])

      Attachments.ensure(attachment_opts)
    else
      {:ok, nil}
    end
  end

  defp attachment_meta(rec, group, id) do
    %{
      "tenant_id" => rec["tenant_id"] || group["tenant_id"],
      "group_id" => rec["group_id"] || group["id"],
      "device_id" => Map.fetch!(rec, "device_id"),
      "connector_id" => Map.fetch!(rec, "connector_id"),
      "provider_resource_name" => id,
      "profile_key" => get_in(rec, ["provider_spec", "profile_key"]),
      "managed_compute" => true,
      "alias" => rec["alias"] || "cloud-vm",
      "name" => rec["name"] || group["name"] || "Cloud VM"
    }
  end

  defp sandbox_id(%GroupCompute.Allocation{provider_observation: observation}),
    do: sandbox_id(observation)

  defp sandbox_id(%{provider_ref: id}) when is_binary(id) and id != "", do: id
  defp sandbox_id(%{"provider_ref" => id}) when is_binary(id) and id != "", do: id

  defp sandbox_id(%{"provider_resource_id" => id}) when is_binary(id) and id != "", do: id
  defp sandbox_id(%{"provider_resource_name" => id}) when is_binary(id) and id != "", do: id
end
