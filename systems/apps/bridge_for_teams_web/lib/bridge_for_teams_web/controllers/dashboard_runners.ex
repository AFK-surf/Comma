defmodule BridgeForTeamsWeb.DashboardRunners do
  @moduledoc """
  Builds the Runners page payloads and applies runner writes for
  `DashboardAPIController`.

  Every org member sees the fleet. Connector assignments are limited to the
  Agent Swarms the caller can see. Owners and admins also see each runner's
  credential state, the onboarding guide, and may create install commands,
  revoke or rotate runner keys and remove runners.

  The list is one bounded page of 25 runners read in a fixed number of queries;
  credentials are read only for the active keys of the runners on that page.
  The page polls it every 5 seconds, so the cost is one page read per open tab
  and interval, independent of the fleet size and of key history.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{Auth, Environments, MacMiniOnboarding}
  alias BridgeForTeamsWeb.MacMiniRelease

  @page_limit 25
  @poll_interval_ms 5_000
  @install_code_ttl_seconds 15 * 60
  @runner_key_scopes ~w(* runners:* runners:write)
  @bft_agent_skill_path Path.expand("../../../priv/bft-operator/SKILL.md", __DIR__)
  @external_resource @bft_agent_skill_path
  @bft_agent_skill File.read!(@bft_agent_skill_path)

  @doc "One page of the org's runners with connector summaries."
  def page(org, user, can_manage?, cursor) do
    page = page_runners(org.id, cursor)
    runner_ids = Enum.map(page.entries, & &1.id)

    connector_counts =
      Environments.runner_connector_assignment_status_counts(org.id, runner_ids, user.id)

    credentials =
      if can_manage?,
        do: credentials_by_stable_id(org.id, Enum.map(page.entries, & &1.stable_id)),
        else: %{}

    %{
      "viewer" => %{"can_manage" => can_manage?},
      "runners" =>
        Enum.map(page.entries, fn runner ->
          public_runner(
            runner,
            Map.get(connector_counts, runner.id, []),
            can_manage?,
            credentials
          )
        end),
      "total_count" => page.total_count,
      "cursor" => page.cursor,
      "next_cursor" => page.next_cursor,
      "poll_interval_ms" => @poll_interval_ms
    }
  end

  @doc "One page of a runner's connector assignments visible to `user`."
  def connectors(org, user, runner_id, cursor) do
    with {:ok, runner_id} <- cast_id(runner_id, &runner_not_found/0) do
      cursor =
        case Ecto.UUID.cast(cursor) do
          {:ok, cursor} -> cursor
          :error -> nil
        end

      page =
        Environments.page_runner_connector_assignments(org.id, runner_id, user.id, after: cursor)

      {:ok,
       %{
         "entries" =>
           Enum.map(page.entries, fn connector ->
             %{
               "id" => connector.id,
               "name" => connector.env_alias || connector.name,
               "provisioning_status" => connector.provisioning_status,
               "project_id" => connector.project_id,
               "project_name" => connector.project_name
             }
           end),
         "cursor" => page.cursor,
         "next_cursor" => page.next_cursor
       }}
    end
  end

  @doc "What an owner or admin needs to onboard a runner. Creates nothing."
  def onboarding(org) do
    api_base_url = MacMiniRelease.api_base_url()
    runner = ~s("$HOME/.bridge-for-teams/bin/bft-runner")

    %{
      "org_id" => org.id,
      "api_base_url" => api_base_url,
      "install_code_ttl_seconds" => @install_code_ttl_seconds,
      "local_steps" => [
        step(
          "doctor",
          "primary",
          gettext("Check local posture"),
          gettext("Run a no-secret preflight before starting a long-running worker."),
          "#{runner} doctor"
        ),
        step(
          "foreground",
          "primary",
          gettext("Smoke in the foreground"),
          gettext("Start the worker and confirm that this page receives a fresh heartbeat."),
          runner
        ),
        step(
          "launchd",
          "primary",
          gettext("Make the runner persistent"),
          gettext("After the smoke succeeds, start the managed login service."),
          "#{runner} service start"
        ),
        step(
          "status-logs",
          "advanced",
          gettext("Inspect status and logs"),
          gettext("Read the local worker state and redacted logs for diagnostics."),
          "#{runner} status\n#{runner} logs"
        )
      ],
      "paths" => %{
        "config" => "~/.bridge-for-teams/runner.json",
        "install_status" => "~/.bridge-for-teams/runner-install-status.json",
        "worker_status" => "~/.bridge-for-teams/state/runner-status.json",
        "logs" => "~/.bridge-for-teams/state/logs"
      },
      "agent_handoff" => agent_handoff(api_base_url, org.id),
      "agent_skill" => @bft_agent_skill
    }
  end

  @doc "Create a one-time install command for a new runner."
  def create_install_command(org, user) do
    with {:ok, server_build_id} <- server_build_id() do
      org
      |> install_code(user, server_build_id, [])
      |> install_command_result()
    end
  end

  @doc "Revoke one runner API key."
  def revoke_key(org, user, key_id) do
    with {:ok, key_id} <- cast_id(key_id, &key_not_found/0),
         {:ok, _credential} <- runner_credential(org.id, key_id) do
      case Auth.revoke_api_key(org.id, key_id, audit_opts(user)) do
        {:ok, api_key} -> {:ok, %{"id" => api_key.id, "revoked_at" => api_key.revoked_at}}
        {:error, :not_found} -> key_not_found()
        {:error, reason} -> backend_error(reason, &revoke_failed_message/1)
      end
    end
  end

  @doc """
  Revoke a runner's key and create an install command bound to the same runner
  identity. Nothing is revoked when the Server release is unavailable.
  """
  def rotate_key(org, user, key_id) do
    with {:ok, key_id} <- cast_id(key_id, &key_not_found/0),
         {:ok, server_build_id} <- server_build_id(),
         {:ok, %{stable_id: stable_id}} <- runner_credential(org.id, key_id) do
      opts = audit_opts(user)

      case Auth.revoke_api_key(org.id, key_id, opts) do
        {:ok, _api_key} ->
          org
          |> install_code(user, server_build_id,
            runner_stable_id: stable_id,
            audit_metadata: %{"rotated_key_id" => key_id},
            audit: opts
          )
          |> install_command_result()

        {:error, :not_found} ->
          key_not_found()

        {:error, reason} ->
          backend_error(reason, &rotate_failed_message/1)
      end
    end
  end

  @doc "Remove a runner and revoke every key bound to it."
  def remove(org, user, runner_id) do
    with {:ok, runner_id} <- cast_id(runner_id, &runner_not_found/0) do
      case MacMiniOnboarding.remove_runner(org.id, runner_id, audit_opts(user)) do
        {:ok, runner} -> {:ok, %{"id" => runner.id}}
        {:error, :runner_not_found} -> runner_not_found()
        {:error, reason} -> backend_error(reason, &remove_failed_message/1)
      end
    end
  end

  # FinLive behaviour: a cursor past the end (runners removed meanwhile) falls
  # back to the first page.
  defp page_runners(org_id, cursor) do
    cursor = if is_binary(cursor) and cursor != "", do: cursor
    page = Environments.page_mac_mini_provisioners(org_id, limit: @page_limit, after: cursor)

    if page.entries == [] and page.total_count > 0 and cursor do
      org_id
      |> Environments.page_mac_mini_provisioners(
        limit: @page_limit,
        total_count: page.total_count
      )
      |> Map.put(:cursor, nil)
    else
      Map.put(page, :cursor, cursor)
    end
  end

  defp public_runner(runner, connector_counts, can_manage?, credentials) do
    target = MacMiniRelease.updates(nil, runner)["salix-connect"]

    %{
      "id" => runner.id,
      "stable_id" => runner.stable_id,
      "name" => runner.name,
      "status" => runner.status,
      "effective_status" => runner.effective_status || runner.status || "unknown",
      "host_identity" => runner.host_identity,
      "os_summary" => runner.os_summary,
      "version" => runner.version,
      "component_versions" => component_versions(runner.capabilities),
      "update_available" =>
        MacMiniRelease.component_update_available?(runner.capabilities, "salix-connect", target),
      "capacity" => runner.capacity || 0,
      "current_connector_count" => runner.current_connector_count || 0,
      "last_seen_at" => runner.last_seen_at,
      "last_seen_age_seconds" => runner.last_seen_age_seconds,
      "connectors" => %{
        "total" => connector_counts |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
        "by_status" =>
          Enum.map(connector_counts, fn {status, count} ->
            %{"status" => status, "count" => count}
          end)
      },
      "credential" => if(can_manage?, do: public_credential(credentials, runner.stable_id))
    }
  end

  defp component_versions(%{"component_versions" => versions}) when is_map(versions) do
    for {component, version} <- versions, is_binary(version) and version != "", into: %{} do
      {component, version}
    end
  end

  defp component_versions(_capabilities), do: %{}

  defp public_credential(credentials, stable_id) do
    case credentials |> Map.get(stable_id, []) |> Enum.find(&is_nil(&1.revoked_at)) do
      nil -> %{"active" => false, "key_id" => nil, "created_at" => nil}
      key -> %{"active" => true, "key_id" => key.id, "created_at" => key.created_at}
    end
  end

  defp credentials_by_stable_id(_org_id, []), do: %{}

  defp credentials_by_stable_id(org_id, stable_ids) do
    org_id
    |> MacMiniOnboarding.list_runner_credentials(stable_ids: stable_ids, active_only: true)
    |> Enum.group_by(& &1.stable_id, & &1.api_key)
  end

  # Only keys that a runner consumed through an install code can be revoked or
  # rotated here; other org API keys are out of this page's scope.
  defp runner_credential(org_id, key_id) do
    org_id
    |> MacMiniOnboarding.list_runner_credentials(key_id: key_id)
    |> Enum.find(&runner_key?(&1.api_key))
    |> case do
      nil -> key_not_found()
      credential -> {:ok, credential}
    end
  end

  defp runner_key?(api_key), do: Enum.any?(api_key.scopes || [], &(&1 in @runner_key_scopes))

  defp install_code(org, user, server_build_id, opts) do
    {audit, opts} = Keyword.pop(opts, :audit, audit_opts(user))

    MacMiniOnboarding.create_install_code(
      org.id,
      audit ++
        [
          created_by_id: user.id,
          wrapper_url: MacMiniRelease.api_base_url() <> "/v1/orgs/#{org.id}/runners/install.sh",
          server_build_id: server_build_id
        ] ++ opts
    )
  end

  defp install_command_result({:ok, %{command: command, install_code: install_code}}) do
    {:ok,
     %{
       "command" => command,
       "expires_at" => install_code.expires_at,
       "runner_stable_id" => install_code.runner_stable_id
     }}
  end

  defp install_command_result({:error, reason}),
    do: backend_error(reason, &install_failed_message/1)

  defp server_build_id do
    case MacMiniRelease.server_build_id() do
      {:ok, server_build_id} ->
        {:ok, server_build_id}

      {:error, _reason} ->
        {:error, 503, "server_release_unavailable", gettext("Server release is unavailable."),
         %{}}
    end
  end

  defp agent_handoff(api_base_url, org_id) do
    """
    Help me connect and operate a BFT runner from this Mac.

    Target API base: #{api_base_url}
    Target organization: #{org_id}

    Use the installed bft CLI as the source of truth. Start by running:
    bft commands --json
    bft agent help overview --json
    bft agent help auth --json
    bft agent help runners --json
    bft agent help output --json

    If bft is missing, explain that first and ask before running:
    curl -fsSL #{shell_quote(api_base_url <> "/v1/cli/install.sh")} | sh

    Check auth status. If login is needed, run:
    bft auth login --url #{shell_quote(api_base_url)} --output text
    Then wait for me to approve the browser device flow.

    Inspect the target organization and existing runners before changing anything. Before every command marked mutating, tell me the exact target and effect and wait for explicit approval. Use --confirm-mutating when the command metadata or help requires it, and only after I approve. After approval, create exactly one runner install command and execute it immediately; do not generate a second one just to inspect the response.

    Ask whether I want a temporary foreground runner or the persistent login service. Do not run both. Verify local status and a recent online heartbeat with bft runners list before reporting success.
    """
    |> String.trim()
  end

  defp step(id, group, title, description, command),
    do: %{
      "id" => id,
      "group" => group,
      "title" => title,
      "description" => description,
      "command" => command
    }

  defp shell_quote(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    ~s("#{escaped}")
  end

  defp audit_opts(user) do
    label =
      cond do
        is_binary(user.email) and user.email != "" -> user.email
        is_binary(user.name) and user.name != "" -> user.name
        true -> user.id
      end

    [actor_user_id: user.id, actor_label: label, request_id: Ecto.UUID.generate()]
  end

  defp cast_id(value, not_found) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> not_found.()
    end
  end

  defp backend_error(reason, message) do
    {:error, 500, "runner_write_failed", message.(describe_error(reason)), %{}}
  end

  defp install_failed_message(reason),
    do: gettext("Couldn't create the runner install command (%{reason}).", reason: reason)

  defp revoke_failed_message(reason),
    do: gettext("Couldn't revoke the runner API key (%{reason}).", reason: reason)

  defp rotate_failed_message(reason),
    do: gettext("Couldn't rotate the runner API key (%{reason}).", reason: reason)

  defp remove_failed_message(reason),
    do: gettext("Couldn't remove the runner (%{reason}).", reason: reason)

  defp describe_error(:unavailable), do: gettext("runtime unavailable")
  defp describe_error(:timeout), do: gettext("runtime timed out")
  defp describe_error(%Ecto.Changeset{}), do: "validation_failed"
  defp describe_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe_error(_reason), do: "backend_error"

  defp runner_not_found,
    do: {:error, 404, "runner_not_found", gettext("Runner not found."), %{}}

  defp key_not_found,
    do: {:error, 404, "runner_key_not_found", gettext("Runner API key not found."), %{}}
end
