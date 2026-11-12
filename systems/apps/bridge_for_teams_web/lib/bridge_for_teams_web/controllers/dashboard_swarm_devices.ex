defmodule BridgeForTeamsWeb.DashboardSwarmDevices do
  @moduledoc """
  Builds the Agent Swarm Devices page payloads and applies its writes for
  `DashboardAPIController`: the swarm's Cloud VM (where it runs, its status
  and the org Runner it uses), the swarm's devices, disconnecting and
  deleting a device, Android setup and
  the Compute environments with their Shell workload, drain and revoke,
  and setting up a Comma hardware board (its credentials and whether it may
  run operations).
  A device that cannot take tasks carries a `station_notice`
  (`BridgeForTeamsWeb.StationNotice`) saying how to upgrade it.

  The page reads PostgreSQL projections and never the live device registry:
  at most 100 devices (`Environments.list_projected_environments/1`), one
  Compute page of 50 environments and 50 workloads, the Group's Cloud VM
  record and Runner binding (`Compute.cloud_vm/2`, indexed reads) and the
  Android admission record. Its cost does not grow with the number of devices.

  Every swarm member reads the page; every write is for swarm admins. A refused device write records a denied audit entry, as the
  LiveView page did.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{Agents, Compute, Environments, Observability, Projects}
  alias BridgeForTeamsWeb.StationNotice
  alias SalixStore.RuntimeIds

  @runner_page 100
  @android_profiles 8

  # ---- Reads ----

  @doc "The page."
  def page(org, _user, project, role) do
    {:ok, environments} = Environments.list_projected_environments(project.id)

    {:ok,
     %{
       "project" => public_project(project, role),
       "cloud_vm" => cloud_vm(org, project, role),
       "devices" => Enum.map(environments, &device/1),
       "android" => android(project, environments),
       "compute" => compute(org, project)
     }}
  end

  @doc "The online organization runners the Cloud VM can run on: of the first 100."
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

  @doc """
  Choose the org Runner that prepares the swarm's VMM Station.
  A swarm has at most one Runner. Its existing Cloudflare VM keeps its identity.
  """
  def choose_runner(org, user, project, role, params) do
    with :ok <- cloud_vm_admin(project, user, role) do
      case Compute.choose_cloud_vm_runner(
             org,
             project,
             text(params["runner_id"]),
             text(params["request_id"])
           ) do
        {:ok, _operation} ->
          {:ok, %{"notice" => gettext("The runner was asked to prepare the VMM Station.")}}

        {:error, reason} ->
          runner_error(reason)
      end
    end
  end

  @doc "Remove the swarm's Runner choice while no Cloud VM runs on it."
  def remove_runner(org, user, project, role) do
    with :ok <- cloud_vm_admin(project, user, role) do
      case Compute.remove_cloud_vm_runner(org, project) do
        {:ok, _operation} ->
          {:ok, %{"notice" => gettext("Runner removed from this Agent Swarm.")}}

        {:error, reason} ->
          runner_error(reason)
      end
    end
  end

  defp cloud_vm_admin(project, user, role) do
    with :ok <-
           authorize(role, fn ->
             Projects.record_project_write_attempt(
               project,
               "project.cloud_vm_runner_changed",
               "denied",
               :forbidden,
               audit_opts(user)
             )
           end) do
      if project.status == "archived",
        do: {:error, 409, "project_archived", gettext("This Agent Swarm is archived."), %{}},
        else: :ok
    end
  end

  defp runner_error(:project_runner_bound),
    do:
      {:error, 409, "runner_already_chosen",
       gettext(
         "This Agent Swarm already has a runner. Remove it before you choose another runner."
       ), %{}}

  defp runner_error(:cloud_vm_on_runner),
    do:
      {:error, 409, "cloud_vm_on_runner",
       gettext("The Cloud VM runs on this runner. You cannot remove the runner."), %{}}

  defp runner_error(reason) when reason in [:runner_offline, :runner_not_found],
    do: {:error, 409, "runner_offline", gettext("Runner is offline."), %{}}

  defp runner_error(:not_found),
    do: {:error, 404, "runner_not_chosen", gettext("This Agent Swarm has no runner."), %{}}

  defp runner_error(:invalid_id),
    do: {:error, 422, "runner_required", gettext("Select an online runner."), %{}}

  defp runner_error(_reason), do: write_failed(gettext("Couldn't update the runner."))

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

  @doc "Read the swarm's devices from Salix now, for the page's Refresh."
  def refresh(_org, _user, project, _role) do
    case Environments.refresh_project_devices(project.id) do
      :ok -> {:ok, %{}}
      {:error, _reason} -> write_failed(gettext("Couldn't refresh the devices."))
    end
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

  @doc """
  Mint the credentials a Comma hardware board stores when an admin sets it
  up from this page over Web Bluetooth. Answers them once; they are never
  read again.
  """
  def provision_hardware(org, user, project, role, params) do
    with :ok <-
           authorize(role, fn ->
             device_denied(org, user, project, "device.provisioned",
               resource_type: "device",
               metadata: %{}
             )
           end) do
      opts = audit_opts(user) ++ [org_id: org.id, project_id: project.id]

      case Environments.provision_hardware_device(project.id, params["name"], opts) do
        {:ok, credentials} ->
          {:ok, %{"credentials" => credentials}}

        {:error, :invalid_name} ->
          {:error, 422, "invalid_name", gettext("Enter a device name of at most 63 bytes."), %{}}

        {:error, _reason} ->
          write_failed(gettext("Couldn't create the device credentials."))
      end
    end
  end

  @doc """
  The command that installs the station on a computer and connects it to this
  swarm. Shown once: it works once and expires after an hour.
  """
  def create_station_install(org, user, project, role, params) do
    with :ok <-
           authorize(role, fn ->
             device_denied(org, user, project, "device.station_install_created",
               resource_type: "device",
               metadata: %{}
             )
           end) do
      opts = audit_opts(user) ++ [org_id: org.id, project_id: project.id]

      case Environments.create_station_install(project.id, params["name"], user.id, opts) do
        {:ok, %{"command" => command, "expires_at" => expires_at}} ->
          {:ok, %{"command" => command, "expires_at" => iso_timestamp(expires_at)}}

        {:error, :invalid_name} ->
          {:error, 422, "invalid_name", gettext("Enter a device name of at most 63 bytes."), %{}}

        {:error, _reason} ->
          write_failed(gettext("Couldn't create the install command."))
      end
    end
  end

  @doc "Let a hardware device run operations on its network, or make it read-only."
  def set_operations(org, user, project, role, device_id, params) do
    device_write(org, user, project, role, device_id, "device.operations", fn opts ->
      case params["allow"] do
        allow when is_boolean(allow) ->
          case Environments.set_device_operations(project.id, device_id, allow, opts) do
            {:ok, true} ->
              {:ok, %{"notice" => gettext("The device can now run operations.")}}

            {:ok, false} ->
              {:ok, %{"notice" => gettext("The device is now read-only.")}}

            {:error, :not_found} ->
              device_not_found()

            {:error, :device_offline} ->
              {:error, 409, "device_offline",
               gettext("The device is offline. Turn it on and try again."), %{}}

            {:error, _reason} ->
              write_failed(gettext("Couldn't change the device's access."))
          end

        _ ->
          {:error, 422, "invalid_allow", gettext("Choose whether to allow operations."), %{}}
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

  # ---- Cloud VM ----

  # Where the Cloud VM is retired the page keeps its section only while the
  # swarm has a Cloud VM that is not archived (`Agents.sandbox_places/1`):
  # admins stop it or remove its runner there.
  defp cloud_vm(org, project, role) do
    places = Agents.sandbox_places(project)

    if places["cloud_vm_shown"] == true,
      do: cloud_vm_section(org, project, role, places),
      else: nil
  end

  defp cloud_vm_section(org, project, role, places) do
    manageable = role == "admin" and project.status != "archived"

    {:ok, state} = Compute.cloud_vm(org, project)

    vm =
      case state["vm"] do
        "unavailable" -> %{"status" => "unavailable", "location" => nil}
        vm -> vm
      end

    %{
      "enabled" => places["cloud_vm_retired"] != true and places["cloud_vm_available"] == true,
      "manageable" => manageable,
      "vm" => vm,
      "runner" => state["runner"] && Map.take(state["runner"], ~w(name status)),
      "next_location" => state["next_location"],
      "runner_choosable" => manageable and is_nil(state["runner"]),
      "runner_removable" =>
        manageable and not is_nil(state["runner"]) and
          not match?(%{"location" => %{"kind" => "runner"}}, vm)
    }
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
      "android" => android_device(env),
      # A Comma hardware board forwards LAN requests only while it allows
      # operations; the page offers the switch for those devices.
      "hardware" => hardware?(env),
      "allows_operations" => env["allows_operations"] == true,
      "station_notice" => station_notice(env)
    }
  end

  # A board set up from this page carries the kind it was minted with, from
  # before it first connects.
  defp hardware?(env), do: env["device_kind"] == "hardware"

  # Nil for a hardware board, which never runs tasks, and for a device that
  # has not reported what it runs yet; else why it cannot take tasks and how
  # its user upgrades it.
  defp station_notice(env) do
    capabilities = env["capabilities"]

    if hardware?(env) or not is_map(capabilities) or capabilities == %{},
      do: nil,
      else: StationNotice.for_capabilities(capabilities)
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
          # A revoked environment that never came up has nothing left to show or do.
          "environments" =>
            for row <- projection["environments"] || [],
                {row.desired_state, row.observed_state} != {"revoked", "pending"} do
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
            end
        }

      {:error, _reason} ->
        %{"status" => "unavailable", "environments" => [], "workloads" => []}
    end
  end

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
      request_id: SystemsRuntime.Proc.uuid(),
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

  defp device_not_found,
    do: {:error, 404, "device_not_found", gettext("Device not found."), %{}}

  defp environment_not_found,
    do: {:error, 404, "environment_not_found", gettext("Compute environment not found."), %{}}

  defp write_failed(message), do: {:error, 503, "write_failed", message, %{}}

  defp public_project(project, role),
    do: %{"id" => project.id, "name" => project.name, "role" => role}

  defp audit_opts(user),
    do: [
      actor_user_id: user.id,
      actor_label: actor_label(user),
      request_id: SystemsRuntime.Proc.uuid()
    ]

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
