defmodule BridgeForTeamsWeb.RunnerController do
  @moduledoc """
  Org-scoped product API for BFT runners.

  The terminal CLI calls this same product surface instead of a CLI-only runner
  lifecycle. The host-side `bft-runner` still uses the runner process API under
  `/v1/orgs/:org_id/runners/...` with runner API-key auth.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  import BridgeForTeamsWeb.ProjectAPIResponse

  alias BridgeForTeams.{Environments, MacMiniOnboarding}
  alias BridgeForTeams.Schema.{MacMiniProvisioner, Organization}
  alias BridgeForTeamsWeb.{MacMiniRelease, ProjectScope}

  def index(conn, %{"org" => org_ref}) do
    with {:ok, org} <- require_org(org_ref),
         :ok <- authorize_org(conn, org, "member") do
      runners =
        org.id
        |> Environments.list_mac_mini_provisioners()
        |> Enum.map(&public_runner/1)

      send_ok(conn, %{
        "mode" => "runners_list",
        "org" => public_org(org),
        "release" => public_server_release(),
        "runners" => runners,
        "summary" => runner_summary(runners),
        "next_action" => runners_next_action(org, runners)
      })
    else
      error -> send_project_error(conn, error, "Could not list runners.")
    end
  end

  def install_command(conn, %{"org" => org_ref} = params) do
    with {:ok, org} <- require_org(org_ref),
         :ok <- authorize_org(conn, org, "admin"),
         :ok <- reject_runner_install_action(params["action"]),
         {:ok, runner_stable_id} <- resolve_runner_stable_id(org, params["runner"]),
         {:ok, server_build_id} <- MacMiniRelease.server_build_id(),
         {:ok, %{command: command, install_code: install_code}} <-
           MacMiniOnboarding.create_install_code(org.id,
             created_by_id: current_user(conn).id,
             wrapper_url: mac_mini_wrapper_url(conn, org),
             server_build_id: server_build_id,
             runner_stable_id: runner_stable_id
           ) do
      send_ok(conn, %{
        "mode" => "runner_install_command",
        "org" => public_org(org),
        "command" => command,
        "expires_at" => DateTime.to_iso8601(install_code.expires_at),
        "server_build_id" => install_code.server_build_id,
        "next_action" => runner_install_command_next_action(org),
        "redaction" => %{
          "bearer_token_printed" => false,
          "runner_api_key_printed" => false,
          "one_time_install_code_printed" => true
        }
      })
    else
      {:error, reason} ->
        send_backend_error(conn, reason, "Could not create runner install command.")

      error ->
        send_project_error(conn, error, "Could not create runner install command.")
    end
  end

  defp require_org(org_ref) do
    ProjectScope.require_org(org_ref, missing_message: "Pass --org <org-id-or-slug>.")
  end

  defp resolve_runner_stable_id(_org, nil), do: {:ok, nil}
  defp resolve_runner_stable_id(_org, ""), do: {:ok, nil}

  defp resolve_runner_stable_id(org, ref) when is_binary(ref) do
    ref = String.trim(ref)

    if ref == "" do
      {:ok, nil}
    else
      org.id
      |> Environments.list_mac_mini_provisioners()
      |> Enum.find(&(&1.id == ref or &1.stable_id == ref))
      |> case do
        %MacMiniProvisioner{stable_id: stable_id} -> {:ok, stable_id}
        nil -> {:error, 404, "runner_not_found", "Runner not found in this organization.", %{}}
      end
    end
  end

  defp resolve_runner_stable_id(_org, _ref),
    do: {:error, 400, "invalid_runner", "Runner must be an id or stable id.", %{}}

  defp authorize_org(conn, %Organization{} = org, min_role) do
    ProjectScope.authorize_org(current_user(conn), org, min_role)
  end

  defp current_user(conn), do: Map.fetch!(conn.assigns, :current_user)

  defp public_runner(%MacMiniProvisioner{} = provisioner) do
    target = MacMiniRelease.updates(nil, provisioner)["salix-connect"]

    update_available =
      MacMiniRelease.component_update_available?(
        provisioner.capabilities,
        "salix-connect",
        target
      )

    %{
      "id" => provisioner.id,
      "stable_id" => provisioner.stable_id,
      "name" => provisioner.name,
      "status" => provisioner.status,
      "effective_status" => provisioner.effective_status || provisioner.status,
      "last_seen_at" => iso8601_or_nil(provisioner.last_seen_at),
      "last_seen_age_seconds" => provisioner.last_seen_age_seconds,
      "host_identity" => provisioner.host_identity,
      "os_summary" => provisioner.os_summary,
      "version" => provisioner.version,
      "component_versions" => MacMiniRelease.component_versions_label(provisioner.capabilities),
      "component_digests" => Map.get(provisioner.capabilities || %{}, "component_digests", %{}),
      "update_available" => update_available,
      "capacity" => provisioner.capacity,
      "current_connector_count" => provisioner.current_connector_count,
      "capabilities" => provisioner.capabilities || %{}
    }
  end

  defp runner_summary(runners) do
    online = Enum.count(runners, &runner_ready?/1)
    update_available = Enum.count(runners, &Map.get(&1, "update_available"))

    %{
      "total" => length(runners),
      "online" => online,
      "ready" => online > 0,
      "update_available" => update_available > 0,
      "update_available_count" => update_available
    }
  end

  defp runner_install_command_next_action(org),
    do:
      "Run this one-time command on the target runner machine. Use `bft-runner` there for foreground smoke or `bft-runner service start` for launchd, then run `bft runners list --org #{org.slug}` to verify a recent heartbeat."

  defp runners_next_action(org, runners) do
    cond do
      Enum.any?(runners, &Map.get(&1, "update_available")) ->
        "A runner has not reached its exact target release. Keep bft-runner online and rerun `bft runners list --org #{org.slug}` to verify the reported version."

      Enum.any?(runners, &runner_ready?/1) ->
        "A runner has a recent heartbeat; continue to project device creation or group onboarding."

      true ->
        "After operator approval, run `bft runners install-command --org <org> --confirm-mutating` on the target machine, then run `bft-runner` or start the runner service there before rerunning this list."
    end
  end

  defp reject_runner_install_action(nil), do: :ok
  defp reject_runner_install_action(""), do: :ok

  defp reject_runner_install_action(_action),
    do:
      {:error, 400, "runner_install_action_removed",
       "BFT only generates runner install commands. Use bft-runner on the target machine for local runner operations.",
       %{}}

  defp runner_ready?(%{"effective_status" => "online"}), do: true
  defp runner_ready?(_runner), do: false

  defp mac_mini_wrapper_url(conn, org) do
    conn
    |> MacMiniRelease.api_base_url()
    |> then(&(&1 <> "/v1/orgs/#{org.id}/runners/install.sh"))
  end

  defp public_server_release do
    case MacMiniRelease.server_build_id() do
      {:ok, server_build_id} -> %{"server_build_id" => server_build_id}
      {:error, _reason} -> %{"error" => "server_release_unavailable"}
    end
  end

  defp iso8601_or_nil(nil), do: nil

  defp iso8601_or_nil(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601_or_nil(_value), do: nil
end
