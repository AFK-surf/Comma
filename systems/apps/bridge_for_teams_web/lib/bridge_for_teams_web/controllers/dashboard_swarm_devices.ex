defmodule BridgeForTeamsWeb.DashboardSwarmDevices do
  @moduledoc """
  Builds the Agent Swarm Devices page payloads and applies its writes for
  `DashboardAPIController`: the fixed cloud computer and the swarm's devices,
  adding a device on an organization runner, disconnecting and deleting a
  device, the runtime authentication targets, Android setup and the Compute
  environments with their Shell workload, drain and revoke.

  The page reads PostgreSQL projections and never the live device registry:
  at most 100 devices (`Environments.list_projected_environments/1`), one
  Compute page of 50 environments and 50 workloads, the Android admission
  record and whether a device request is still being provisioned. Its cost
  does not grow with the number of devices. Runtime authentication goes
  through the browser-owned `/dashboard/orgs/:org/projects/:project/runtime-auth`
  and `managed-auth` endpoints; this page lists the targets (at most 50).

  While a device request is active the browser polls `provisioning/1`, one
  indexed EXISTS query, and reads the page again when it is done.

  Every swarm member reads the page; the runner list and every write are for
  swarm admins. A refused device write records a denied audit entry, as the
  LiveView page did.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{Compute, Environments, Observability, Projects, RuntimeAuth}
  alias BridgeForTeamsWeb.Dashboard.CoreComponents
  alias SalixStore.RuntimeIds

  @runner_page 100
  @runtime_auth_targets 50
  @external_providers ~w(codex pi claude)
  @managed_providers ~w(codex claude)
  @android_profiles 8

  # ---- Reads ----

  @doc """
  The page. `runtime_auth_request` (with `runtime_auth_target`) names a Router
  request a management link opens; it is read for swarm admins only.
  """
  def page(org, user, project, role, params) do
    {:ok, environments} = Environments.list_projected_environments(project.id)
    compute = compute(org, project)

    {:ok,
     %{
       "project" => public_project(project, role),
       "cloud" => %{
         "enabled" => project.vm_enabled == true,
         "manageable" => role == "admin" and project.status != "archived"
       },
       "devices" => Enum.map(environments, &device/1),
       "provisioning" => Environments.device_provisioning_active?(project.id),
       "android" => android(project, environments),
       "compute" => Map.delete(compute, "rows"),
       "runtime_auth" => %{
         "targets" => runtime_auth_targets(compute["rows"], environments),
         "request" => linked_request(user, project, role, params)
       }
     }}
  end

  @doc "Whether a device request is still being provisioned; the page polls it."
  def provisioning(project),
    do: {:ok, %{"active" => Environments.device_provisioning_active?(project.id)}}

  @doc "The organization runners a device can be created on: online ones of the first 100."
  def runners(org, role) do
    with :ok <- admin(role) do
      %{entries: runners} = Environments.page_mac_mini_provisioners(org.id, limit: @runner_page)

      {:ok,
       %{
         "runners" =>
           for runner <- runners, runner.effective_status == "online" do
             %{"id" => runner.id, "label" => runner.name || runner.stable_id || runner.id}
           end,
         "runners_href" => "/orgs/#{org.slug}/fin"
       }}
    end
  end

  # ---- Writes ----

  @doc "Ask an online runner to create a device for this swarm."
  def create(org, user, project, role, params) do
    runner = text(params["runner_id"])

    with :ok <-
           authorize(role, fn ->
             device_denied(org, user, project, "device.provision_requested",
               resource_type: "device_provision_request",
               metadata: %{"provisioner_id_configured" => not is_nil(runner)}
             )
           end),
         {:ok, runner} <- runner_id(runner) do
      attrs = %{
        "name" => text(params["name"]),
        "alias" => text(params["alias"]),
        "provisioner_id" => runner
      }

      case Environments.create_device_provision_request(project.id, attrs, audit_opts(user)) do
        {:ok, _request} ->
          {:ok, %{"notice" => gettext("Device connection request created.")}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, 422, "invalid_device", gettext("Could not create the device connection."),
           %{
             "fields" =>
               Ecto.Changeset.traverse_errors(changeset, &CoreComponents.translate_error/1)
           }}

        {:error, reason} when reason in [:provisioner_offline, :provisioner_not_found] ->
          {:error, 409, "runner_offline", gettext("Runner is offline."), %{}}

        {:error, _reason} ->
          write_failed(gettext("Could not create the device connection."))
      end
    end
  end

  @doc "Turn the managed cloud computer on or off; the request names the wanted state."
  def set_cloud(_org, user, project, role, params) do
    with :ok <-
           authorize(role, fn ->
             Projects.record_project_write_attempt(
               project,
               "project.vm_enabled_changed",
               "denied",
               :forbidden,
               audit_opts(user)
             )
           end),
         true <-
           project.status != "archived" ||
             {:error, 409, "project_archived", gettext("This Agent Swarm is archived."), %{}},
         {:ok, enabled} <- cloud_enabled(params["enabled"]) do
      case Projects.set_vm_enabled(project, enabled, audit_opts(user)) do
        {:ok, updated} ->
          {:ok,
           %{
             "enabled" => updated.vm_enabled,
             "notice" =>
               if(updated.vm_enabled,
                 do: gettext("Cloud computer enabled for this Agent Swarm."),
                 else: gettext("Cloud computer disabled for this Agent Swarm.")
               )
           }}

        {:error, _reason} ->
          write_failed(gettext("Couldn't update the cloud computer setting."))
      end
    end
  end

  defp cloud_enabled(enabled) when is_boolean(enabled), do: {:ok, enabled}

  defp cloud_enabled(_enabled),
    do:
      {:error, 422, "invalid_cloud", gettext("Couldn't update the cloud computer setting."), %{}}

  @doc "Disconnect the device's current connector run."
  def disconnect(org, user, project, role, device_id) do
    device_write(org, user, project, role, device_id, "device.disconnected", fn opts ->
      case Environments.disconnect_environment(project.id, device_id, opts) do
        {:ok, _record} -> {:ok, %{"notice" => gettext("Device disconnected.")}}
        {:error, :not_found} -> device_not_found()
        {:error, _reason} -> write_failed(gettext("Could not disconnect the device."))
      end
    end)
  end

  @doc "Delete the device from this swarm and revoke its connector credential."
  def delete(org, user, project, role, device_id) do
    device_write(org, user, project, role, device_id, "device.deleted", fn opts ->
      case Environments.delete_environment(project.id, device_id, opts) do
        {:ok, _record} -> {:ok, %{"notice" => gettext("Device deleted.")}}
        {:error, :not_found} -> device_not_found()
        {:error, _reason} -> write_failed(gettext("Could not delete the device."))
      end
    end)
  end

  defp device_write(org, user, project, role, device_id, action, write) do
    with :ok <-
           authorize(role, fn ->
             device_denied(org, user, project, action,
               resource_type: "device",
               metadata: %{"device_id_configured" => not is_nil(text(device_id))}
             )
           end) do
      write.(
        audit_opts(user) ++
          [org_id: org.id, project_id: project.id, resource_label: device_id]
      )
    end
  end

  @doc "Create a Shell workload in one of this swarm's Compute environments."
  def create_shell(org, _user, project, role, environment_id) do
    with :ok <- compute_admin(role) do
      case Compute.create_workload(org, project, %{
             "environment_id" => environment_id,
             "kind" => "shell"
           }) do
        {:ok, _result} ->
          {:ok,
           %{"notice" => gettext("Shell workload accepted. Refresh to check its runtime status.")}}

        {:error, :not_found} ->
          environment_not_found()

        {:error, _reason} ->
          {:error, 422, "workload_failed", gettext("Could not create the Shell workload."), %{}}
      end
    end
  end

  @doc "Drain or revoke a Compute environment at the revision the page showed."
  def environment_intent(org, _user, project, role, environment_id, intent, params)
      when intent in [:drain, :revoke] do
    with :ok <- compute_admin(role) do
      attrs = %{"expected_revision" => params["expected_revision"]}

      result =
        case intent do
          :drain -> Compute.drain(org, project, environment_id, attrs)
          :revoke -> Compute.revoke(org, project, environment_id, attrs)
        end

      case result do
        {:ok, _environment} ->
          {:ok, %{"notice" => gettext("Compute environment updated.")}}

        {:error, :not_found} ->
          environment_not_found()

        {:error, reason} when reason in [:revision_conflict, :invalid_revision] ->
          {:error, 409, "environment_changed",
           gettext("This Compute environment changed. Refresh and try again."), %{}}

        {:error, _reason} ->
          write_failed(gettext("Could not update Compute environment."))
      end
    end
  end

  # ---- Devices ----

  defp device(env) do
    info = if is_map(env["system_info"]), do: env["system_info"], else: %{}

    %{
      "id" => env["device_id"],
      "name" => text(env["name"]),
      "status" => text(env["status"]) || "unknown",
      "disconnectable" => env["status"] != "disconnected" and is_binary(env["connector_run_id"]),
      "runtimes" =>
        for runtime <- external_runtimes(env) do
          %{
            "id" => runtime["device_runtime_id"],
            "provider" => runtime["provider"],
            "version" => text(runtime["version"])
          }
        end,
      "host" => text(info["hostname"]),
      "os" =>
        [info["os_type"], info["os_release"] || info["os_version"]]
        |> Enum.map(&text/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
        |> text(),
      "cpu_model" => text(info["cpu_model"]),
      "cpu_count" => positive(info["cpu_count"]),
      "memory_bytes" => positive(info["memory_total"]),
      "last_seen_at" => iso_timestamp(env["updated_at"]),
      "info_updated_at" => iso_timestamp(env["system_info_updated_at"]),
      "android" => android_device(env)
    }
  end

  defp external_runtimes(env) do
    for runtime <- List.wrap(env["device_runtimes"]),
        is_map(runtime),
        runtime <- [stringify(runtime)],
        RuntimeIds.external_runtime_provider?(runtime["provider"]),
        text(runtime["device_runtime_id"]),
        do: runtime
  end

  # ---- Android ----

  defp android(project, environments) do
    android = Enum.filter(environments, &android?/1)

    setup =
      cond do
        Enum.any?(android, &(&1["status"] in ["online", "connected", "ready"])) -> "connected"
        android != [] -> "needs_attention"
        true -> "not_connected"
      end

    case Environments.android_control_status(project.id) do
      {:ok, %{entitled: true} = status} ->
        %{
          "status" => "ok",
          "entitled" => true,
          "profiles" => status.profiles,
          "setup" => setup,
          "registered" => android != []
        }

      {:ok, _not_entitled} ->
        %{
          "status" => "ok",
          "entitled" => false,
          "profiles" => [],
          "setup" => setup,
          "registered" => android != []
        }

      {:error, _reason} ->
        %{
          "status" => "unavailable",
          "entitled" => false,
          "profiles" => [],
          "setup" => setup,
          "registered" => android != []
        }
    end
  end

  defp android?(env) do
    capabilities = env["capabilities"]

    is_map(capabilities) and
      (capabilities["android_device_tool"] == true or is_map(capabilities["android"]))
  end

  defp android_device(env) do
    if android?(env) do
      android =
        if is_map(env["capabilities"]["android"]), do: env["capabilities"]["android"], else: %{}

      %{
        "profiles" =>
          android["profiles"]
          |> List.wrap()
          |> Enum.filter(&is_binary/1)
          |> Enum.take(@android_profiles),
        "default_profile" => text(android["default_profile"]),
        "active_profile" => text(android["active_profile"]),
        "target_profile" => text(android["target_profile"]),
        "phase" => text(android["phase"]),
        "state" => text(android["state"]),
        "available_slots" => non_negative(android["available_slots"]),
        "capacity" => non_negative(android["capacity"])
      }
    end
  end

  # ---- Compute ----

  defp compute(org, project) do
    case Compute.project(org, project) do
      {:ok, projection} ->
        %{
          "status" => "ok",
          "environments" =>
            for row <- projection["environments"] || [] do
              %{
                "id" => row.id,
                "desired_state" => row.desired_state,
                "observed_state" => row.observed_state,
                "revision" => row.revision
              }
            end,
          "workloads" =>
            for row <- projection["workloads"] || [] do
              %{"id" => row.id, "kind" => row.kind, "observed_state" => row.observed_state}
            end,
          "rows" => projection["workloads"] || []
        }

      {:error, _reason} ->
        %{"status" => "unavailable", "environments" => [], "workloads" => [], "rows" => []}
    end
  end

  # ---- Runtime authentication ----

  # The bounded Compute and device projections name the targets; the panel
  # reads live status only for the target it opens.
  defp runtime_auth_targets(workloads, environments) do
    compute =
      for row <- workloads,
          "external." <> provider <- [Map.get(row, :template_key)],
          provider in @external_providers do
        target(row.id, provider, row.observed_state, %{
          "kind" => "compute_workload",
          "workload_id" => row.id
        })
      end

    connected =
      Stream.flat_map(environments, fn env ->
        for runtime <- external_runtimes(env), runtime["provider"] in @external_providers do
          target(runtime["device_runtime_id"], runtime["provider"], env["status"], %{
            "kind" => "connected_runtime",
            "device_id" => env["device_id"],
            "runtime_id" => runtime["device_runtime_id"]
          })
        end
      end)

    compute |> Stream.concat(connected) |> Enum.take(@runtime_auth_targets)
  end

  defp target(id, provider, status, target) do
    %{
      "id" => id,
      "provider" => provider,
      "status" => status,
      "target" => target,
      "managed" => target["kind"] == "compute_workload" or provider in @managed_providers
    }
  end

  defp linked_request(user, project, "admin", %{"runtime_auth_request" => request_id} = params)
       when is_binary(request_id) do
    target = params["runtime_auth_target"]

    case RuntimeAuth.get_request(user.id, project.id, request_id) do
      {:ok, %{"target" => %{"workload_id" => ^target}} = request} when is_binary(target) ->
        %{
          "request_id" => request["request_id"],
          "action" => request["action"],
          "target" => request["target"]
        }

      _other ->
        nil
    end
  end

  defp linked_request(_user, _project, _role, _params), do: nil

  # ---- Authorization and envelopes ----

  defp admin("admin"), do: :ok

  defp admin(_role),
    do: {:error, 403, "forbidden", gettext("Only Agent Swarm admins can manage devices."), %{}}

  defp authorize("admin", _record), do: :ok

  defp authorize(role, record) do
    _ = record.()
    admin(role)
  end

  defp compute_admin("admin"), do: :ok

  defp compute_admin(_role),
    do: {:error, 403, "forbidden", gettext("Only Agent Swarm admins can manage Compute."), %{}}

  defp device_denied(org, user, project, action, opts) do
    Observability.record_write_attempt(%{
      org_id: org.id,
      actor_user_id: user.id,
      actor_label: actor_label(user),
      action: action,
      resource_type: Keyword.fetch!(opts, :resource_type),
      resource_label: project.name,
      result: "denied",
      reason: :forbidden,
      request_id: Ecto.UUID.generate(),
      surface: "device",
      metadata:
        Map.merge(
          %{
            "project_id" => project.id,
            "salix_group_id" => project.salix_group_id,
            "surface" => "device"
          },
          Keyword.fetch!(opts, :metadata)
        )
    })
  end

  defp runner_id(nil),
    do: {:error, 422, "runner_required", gettext("Select an online runner."), %{}}

  defp runner_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, 409, "runner_offline", gettext("Runner is offline."), %{}}
    end
  end

  defp device_not_found,
    do: {:error, 404, "device_not_found", gettext("Device not found."), %{}}

  defp environment_not_found,
    do: {:error, 404, "environment_not_found", gettext("Compute environment not found."), %{}}

  defp write_failed(message), do: {:error, 503, "write_failed", message, %{}}

  defp public_project(project, role),
    do: %{"id" => project.id, "name" => project.name, "role" => role}

  defp audit_opts(user),
    do: [actor_user_id: user.id, actor_label: actor_label(user), request_id: Ecto.UUID.generate()]

  defp actor_label(user), do: text(user.email) || text(user.name) || user.id

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_value), do: nil

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: nil

  # Devices report times in unix seconds or milliseconds.
  defp iso_timestamp(value) when is_integer(value) do
    unit = if value > 99_999_999_999, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _invalid -> nil
    end
  end

  defp iso_timestamp(_value), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil
end
