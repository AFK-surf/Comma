defmodule SalixWeb.CloudVM.Runtimes do
  @moduledoc "Cloud VM-owned, bounded runtime installation intent and recovery."
  alias SalixStore.Compute, as: GroupCompute
  alias SalixWeb.CloudVM.RuntimeInstall
  alias SalixEnv.Control

  @budget_ms 300_000
  @limit 16

  def request(agent, args) do
    id = args["request_id"]
    provider = args["provider"]

    with true <- RuntimeInstall.valid_id?(id) and provider in ~w(codex claude),
         true <- Enum.all?(Map.keys(args), &(&1 in ~w(provider request_id retry))),
         true <- is_boolean(Map.get(args, "retry", false)),
         true <- get_in(agent, ["vm", "enabled"]) == true,
         true <- (get_in(agent, ["vm", "provider"]) || "cloudflare") == "cloudflare",
         {:ok, rec} <- SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent),
         true <- rec["provider"] == "cloudflare",
         :ok <- SalixWeb.CloudVM.RuntimeLifecycle.wake(agent["group_id"]),
         {:ok, record, _} <-
           GroupCompute.update_group_workload(agent["group_id"], fn current ->
             targets = current["runtime_targets"] || %{}

             case targets[id] do
               nil when map_size(targets) < @limit ->
                 Map.put(
                   current,
                   "runtime_targets",
                   Map.put(targets, id, %{
                     "provider" => provider,
                     "state" => "pending",
                     "requested_at" => now_ms()
                   })
                 )

               %{"provider" => ^provider} = existing ->
                 if args["retry"] == true and
                      (existing["state"] == "failed" or expired?(existing)) do
                   put_in(
                     current,
                     ["runtime_targets", id],
                     existing
                     |> Map.merge(%{
                       "state" => "pending",
                       "requested_at" => now_ms(),
                       "issue" => nil,
                       "error" => nil
                     })
                     |> Map.delete("discovery_attempts")
                     |> Map.delete("claim")
                   )
                 else
                   current
                 end

               nil ->
                 {:error, :cloud_vm_runtime_capacity}

               _ ->
                 {:error, :runtime_request_conflict}
             end
           end) do
      if pending?(record), do: schedule(agent["group_id"])
      {:ok, project(record, id)}
    else
      false -> {:error, :cloud_vm_runtime_invalid_request}
      {:error, _} = error -> error
    end
  end

  def fail_pending(group_id, error) do
    GroupCompute.update_group_workload(group_id, fn current ->
      targets =
        Map.new(current["runtime_targets"] || %{}, fn {id, target} ->
          if target["state"] == "pending",
            do:
              {id,
               target
               |> Map.merge(%{
                 "state" => "failed",
                 "issue" => "billing_unavailable",
                 "error" => error
               })},
            else: {id, target}
        end)

      Map.put(current, "runtime_targets", targets)
    end)
  end

  def schedule(group_id, opts \\ []) do
    Task.Supervisor.start_child(SalixWeb.CloudVM.RuntimeInstallSupervisor, fn ->
      SalixWeb.ComputeProviders.Cloudflare.reconcile_runtimes(group_id, opts)
    end)
  end

  def pending?(record),
    do:
      Enum.any?(record["runtime_targets"] || %{}, fn {_, target} ->
        target["state"] in ~w(pending installing) or
          target["state"] == "installed"
      end)

  # The tenant API caller owns account authorization. Agent tools never call this.
  def bind_account(tenant, group, id, account) when is_binary(account) do
    with_account_lock(tenant, group, id, fn ->
      with {:ok, %{"target" => %{"device_runtime_id" => runtime}, "device_id" => device}} <-
             get(tenant, group, id),
           :ok <- manual_account(tenant, group, id) do
        SalixWeb.SubscriptionRuntimeAuth.distribute(tenant, group, device, runtime, account)
      else
        _ -> {:error, :runtime_not_installed}
      end
    end)
  end

  def bind_account(_, _, _, _), do: {:error, :invalid_account}

  def unbind_account(tenant, group, id) do
    with_account_lock(tenant, group, id, fn ->
      with {:ok, %{"target" => %{"device_runtime_id" => runtime}, "device_id" => device}} <-
             get(tenant, group, id),
           :ok <- manual_account(tenant, group, id) do
        SalixWeb.SubscriptionRuntimeAuth.unbind(tenant, group, device, runtime)
      else
        _ -> {:error, :runtime_not_installed}
      end
    end)
  end

  def get(tenant, group, id) do
    with {:ok, %{"tenant_id" => ^tenant} = rec} <- GroupCompute.group_workload(group),
         true <- is_map(get_in(rec, ["runtime_targets", id])) do
      {:ok, project(rec, id)}
    else
      _ -> {:error, :not_found}
    end
  end

  # The existing VM sweep invokes this once per Group. One claim covers one
  # installation; a crashed owner expires without granting an unbounded retry.
  def reconcile(rec, opts) do
    token = Ecto.UUID.generate()
    now = now_ms()

    case GroupCompute.update_group_workload(rec["group_id"], fn current ->
           targets = current["runtime_targets"] || %{}

           expired =
             Map.new(targets, fn {id, value} ->
               if value["state"] in ~w(pending installing) and
                    now - value["requested_at"] >= @budget_ms,
                  do:
                    {id,
                     Map.merge(value, %{
                       "state" => "failed",
                       "issue" => "runtime_install_timeout"
                     })},
                  else: {id, value}
             end)

           next =
             if Enum.any?(expired, fn {_, v} -> v["state"] == "installing" end),
               do: nil,
               else: Enum.find(Enum.sort(expired), fn {_, v} -> v["state"] == "pending" end)

           claimed =
             case next do
               {id, value} ->
                 Map.put(
                   expired,
                   id,
                   Map.merge(value, %{"state" => "installing", "claim" => token})
                 )

               nil ->
                 expired
             end

           Map.put(current, "runtime_targets", claimed)
         end) do
      {:ok, current, _} ->
        case Enum.find(current["runtime_targets"] || %{}, fn {_, v} -> v["claim"] == token end) do
          {id, value} ->
            result =
              with :ok <-
                     SalixWeb.ComputeProviders.Cloudflare.authorize_resume(
                       current["group_id"],
                       opts
                     ),
                   :ok <-
                     SalixWeb.ComputeProviders.Cloudflare.prepare_runtime_connector(current),
                   remaining when remaining > 0 <- @budget_ms - (now_ms() - value["requested_at"]) do
                install_opts =
                  Keyword.put(opts, :runtime_install_timeout_ms, min(remaining, 240_000))

                RuntimeInstall.install(current, id, value["provider"], install_opts)
              else
                {:error, _} = error -> error
                _ -> {:error, :runtime_install_timeout}
              end

            GroupCompute.update_group_workload(rec["group_id"], fn latest ->
              case get_in(latest, ["runtime_targets", id]) do
                %{"state" => "installing", "claim" => ^token} = target ->
                  patch =
                    case result do
                      :ok ->
                        %{"state" => "installed", "issue" => nil}

                      {:error, %{"error_class" => "billing_unavailable"} = error} ->
                        %{"state" => "failed", "issue" => "billing_unavailable", "error" => error}

                      {:error, issue} ->
                        %{"state" => "failed", "issue" => to_string(issue)}
                    end

                  put_in(
                    latest,
                    ["runtime_targets", id],
                    Map.merge(target, patch) |> Map.delete("claim")
                  )

                _ ->
                  latest
              end
            end)

          nil ->
            current |> discover_installed() |> auto_bind()
        end

      error ->
        error
    end
  end

  # One full probe per sweep discovers all newly installed wrappers. Persist
  # the attempt before the RPC so a failed caller cannot retry without a bound.
  defp discover_installed(rec) do
    missing =
      for {id, target} <- rec["runtime_targets"] || %{},
          target["state"] == "installed",
          is_nil(runtime(rec, id, target["provider"])),
          do: id

    if missing == [] do
      rec
    else
      claim =
        GroupCompute.update_group_workload(rec["group_id"], fn current ->
          Enum.reduce(missing, current, fn id, acc ->
            update_in(acc, ["runtime_targets", id], fn target ->
              cond do
                target["state"] != "installed" ->
                  target

                (target["discovery_attempts"] || 0) >= 3 ->
                  Map.merge(target, %{"state" => "failed", "issue" => "runtime_discovery_failed"})

                true ->
                  attempts = (target["discovery_attempts"] || 0) + 1

                  Map.merge(target, %{
                    "discovery_attempts" => attempts,
                    "issue" => "runtime_discovery_pending"
                  })
              end
            end)
          end)
        end)

      case claim do
        {:ok, claimed, _} ->
          pending =
            Enum.filter(missing, &(claimed["runtime_targets"][&1]["state"] == "installed"))

          if pending == [], do: claimed, else: finish_discovery(claimed, pending)

        _ ->
          rec
      end
    end
  end

  defp finish_discovery(rec, missing) do
    Control.discover_runtimes(rec["device_id"], rec["group_id"], rec["tenant_id"])

    found =
      Map.new(missing, fn id ->
        {id, not is_nil(runtime(rec, id, rec["runtime_targets"][id]["provider"]))}
      end)

    case GroupCompute.update_group_workload(rec["group_id"], fn current ->
           Enum.reduce(missing, current, fn id, acc ->
             update_in(acc, ["runtime_targets", id], fn target ->
               cond do
                 target["state"] != "installed" or
                   target["requested_at"] != rec["runtime_targets"][id]["requested_at"] or
                     target["discovery_attempts"] !=
                       rec["runtime_targets"][id]["discovery_attempts"] ->
                   target

                 found[id] ->
                   Map.put(target, "issue", nil)

                 target["discovery_attempts"] >= 3 ->
                   Map.merge(target, %{
                     "state" => "failed",
                     "issue" => "runtime_discovery_failed"
                   })

                 true ->
                   target
               end
             end)
           end)
         end) do
      {:ok, current, _} -> current
      _ -> rec
    end
  end

  defp manual_account(tenant, group, id) do
    case GroupCompute.update_group_workload(group, fn rec ->
           if rec["tenant_id"] == tenant and is_map(get_in(rec, ["runtime_targets", id])),
             do: put_in(rec, ["runtime_targets", id, "account_mode"], "manual"),
             else: {:error, :not_found}
         end) do
      {:ok, _, _} -> :ok
      error -> error
    end
  end

  # At most sixteen installed targets and three eligible accounts per target.
  # Manual bindings remain authoritative. Automatic exhausted bindings can rotate
  # only after the Connector acknowledges idle-only revocation.
  defp auto_bind(rec) do
    Enum.each(rec["runtime_targets"] || %{}, fn {id, target} ->
      if target["state"] == "installed" and target["account_mode"] != "manual" do
        with_account_lock(rec["tenant_id"], rec["group_id"], id, fn ->
          with {:ok, current} <- GroupCompute.group_workload(rec["group_id"]),
               true <- get_in(current, ["runtime_targets", id, "account_mode"]) != "manual" do
            auto_bind_target(current, id, target["provider"])
          else
            _ -> :ok
          end
        end)
      end
    end)
  end

  defp auto_bind_target(rec, id, provider) do
    with %{"device_runtime_id" => runtime_id} = runtime <- runtime(rec, id, provider),
         :ok <- release_exhausted_binding(rec, runtime, provider),
         nil <- account_binding(rec, runtime),
         {:ok, accounts} <-
           SalixAgent.SubscriptionStore.runtime_candidates(
             rec["tenant_id"],
             provider,
             get_in(rec, ["runtime_targets", id, "account_cursor"]) || ""
           ) do
      if runtime["issue"] == "connector_runtime_unavailable" and accounts != [] do
        SalixWeb.CloudVM.RuntimeLifecycle.wake(rec["group_id"])
      else
        Enum.reduce_while(accounts, nil, fn account, _ ->
          result =
            SalixWeb.SubscriptionRuntimeAuth.distribute(
              rec["tenant_id"],
              rec["group_id"],
              rec["device_id"],
              runtime_id,
              account
            )

          if account_binding(rec, runtime), do: {:halt, result}, else: {:cont, result}
        end)

        binding = account_binding(rec, runtime)

        GroupCompute.update_group_workload(rec["group_id"], fn current ->
          current
          |> put_in(
            ["runtime_targets", id, "account_cursor"],
            if(binding, do: "", else: List.last(accounts) || "")
          )
          |> put_in(
            ["runtime_targets", id, "account_issue"],
            if(binding, do: nil, else: "account_required")
          )
        end)
      end
    else
      _ -> :ok
    end
  end

  defp release_exhausted_binding(rec, runtime, provider) do
    case account_binding(rec, runtime) do
      %{account_id: account, status: "ready"} ->
        if SalixAgent.SubscriptionStore.runtime_quota_exhausted?(rec["tenant_id"], account) do
          # Do not revoke the current account when there is no replacement.
          # Probe from the start: the installation cursor is not a quota cursor.
          with {:ok, [_ | _]} <-
                 SalixAgent.SubscriptionStore.runtime_candidates(rec["tenant_id"], provider) do
            SalixWeb.SubscriptionRuntimeAuth.release_exhausted_idle(
              rec["tenant_id"],
              rec["group_id"],
              rec["device_id"],
              runtime["device_runtime_id"],
              account
            )
          else
            _ -> :ok
          end
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  # Serialize automatic selection and explicit revocation across server nodes.
  # The hash is only a PostgreSQL lock key. Collisions delay unrelated targets
  # and grant no account authority. Scope and account checks remain unchanged.
  defp with_account_lock(tenant, group, id, fun) do
    case SalixStore.Repo.transaction(fn ->
           with {:ok, _} <-
                  SalixAgent.SubscriptionStore.query("SET LOCAL lock_timeout = '5s'", []),
                {:ok, _} <-
                  SalixAgent.SubscriptionStore.query(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    ["cloud-runtime-account:" <> tenant <> ":" <> group <> ":" <> id]
                  ) do
             fun.()
           else
             _ -> {:error, :account_binding_busy}
           end
         end) do
      {:ok, result} -> result
      _ -> {:error, :account_binding_busy}
    end
  end

  defp project(rec, id) do
    value = rec["runtime_targets"][id]
    runtime = runtime(rec, id, value["provider"])

    {state, issue} =
      if expired?(value),
        do: {"failed", "runtime_install_timeout"},
        else: {value["state"], value["issue"]}

    %{
      "request_id" => id,
      "provider" => value["provider"],
      "state" => state,
      "issue" => issue,
      "error" => value["error"],
      "device_id" => rec["device_id"],
      "ready" =>
        rec["status"] == "ready" and state == "installed" and is_map(runtime) and
          runtime["status"] == "ready",
      "account_binding" => account_binding(rec, runtime),
      "account_issue" => value["account_issue"],
      "auth" => runtime && runtime["auth"],
      "readiness_issue" =>
        if(rec["runtime_idle"] == true, do: "runtime_idle", else: runtime && runtime["issue"]),
      "target" =>
        if(runtime,
          do: %{"kind" => "connected", "device_runtime_id" => runtime["device_runtime_id"]}
        )
    }
  end

  defp account_binding(rec, %{"device_runtime_id" => runtime_id}) do
    case SalixWeb.SubscriptionRuntimeAuth.status(
           rec["tenant_id"],
           rec["group_id"],
           rec["device_id"],
           runtime_id
         ) do
      {:ok, binding} -> binding
      _ -> nil
    end
  end

  defp account_binding(_, _), do: nil

  defp runtime(rec, id, provider) do
    case SalixEnv.Registry.get_device(rec["tenant_id"], rec["group_id"], rec["device_id"]) do
      {:ok, device} ->
        found =
          Enum.find(get_in(device, ["meta", "agent_runtimes"]) || [], fn runtime ->
            runtime["provider"] == provider and
              String.ends_with?(
                runtime["identity_material"] || "",
                "/salix/runtimes/#{id}/bin/#{provider}"
              )
          end)

        with %{"device_runtime_id" => runtime_id} <- found,
             {:ok, current} <-
               Control.subscription_runtime_target(
                 rec["device_id"],
                 runtime_id,
                 rec["group_id"],
                 rec["tenant_id"]
               ),
             do: current,
             else: (_ ->
                      if(is_map(found),
                        do:
                          Map.merge(found, %{
                            "ready" => false,
                            "status" => "unavailable",
                            "issue" => "connector_runtime_unavailable",
                            "auth" => nil
                          })
                      ))

      _ ->
        nil
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp expired?(value),
    do:
      value["state"] in ~w(pending installing) and now_ms() - value["requested_at"] >= @budget_ms
end
