defmodule Comma.Synchronicity do
  @moduledoc """
  Provisioning of Comma Workspaces into the Synchronicity control plane.

  Each Comma Workspace maps to one Synchronicity org + one default network. The
  Workspace's owner authenticates over Comma OIDC (their identity anchors to a
  single shared hub provider), so a later dashboard sign-in lands on the
  pre-created account inside the Workspace's org.

  This module is driven by `Comma.Workers.WorkspaceConvergence`: alongside Salix
  and Billing, a converging Workspace calls `provision_workspace/1`, which the
  worker uses to fill in the Workspace's `sync_org_id`/`sync_network_id`, and
  then `ensure_agent_key/1`, which mints the member org key the Salix agent
  reaches the Workspace's Drive with and stores it as the Workspace group's
  Salix Drive binding (`Salix.Control.DriveBindings`, through
  `Comma.Salix.Client`). Salix owns the binding from then on: its dashboard
  shows it beside bindings operators entered by hand, and its agent mount
  (`SalixAgent.DriveMount`) is what reads it. Comma reads the row as stored
  (`drive_binding/1`), not the enabled handle the mount uses, so a row an
  operator disabled or took over is a row that exists and is left alone.

  The remote-present/local-missing retry boundary is modeled in
  `tla/comma_synchronicity/WorkspaceProvisioning.tla`.
  """

  import Ecto.Query

  require Logger

  alias Comma.Accounts
  alias Comma.Data.Workspace
  alias Comma.Repo
  alias Comma.Salix.Client, as: Salix

  @max_provision_limit 1_000

  # The name the minted key carries in the org's key list, beside keys people
  # minted in the dashboard.
  @agent_key_name "comma-agent"

  # The space the Comma desktop app publishes as the install's Drive
  # (`clients/apps/electron/src/main/modules/electron-main.module.ts`,
  # `defaultSpace.id`), and the one network a Workspace org holds.
  @default_space "comma-drive"
  @default_network "default"
  # The binding source Comma writes; an operator's row says `manual`.
  @binding_source "comma"

  @spec provision_workspace(Workspace.t()) ::
          Comma.Synchronicity.Client.ok()
          | Comma.Synchronicity.Client.error()
          | {:error, :owner_not_found}
          | {:error, :workspace_not_found}
  def provision_workspace(%Workspace{} = workspace) do
    case owner(workspace.owner_user_id) do
      {:ok, owner} ->
        measured(:synchronicity_provision, fn ->
          with {:ok, %{sync_org_id: org_id, sync_network_id: network_id} = result} <-
                 client().provision_workspace(
                   workspace.id,
                   workspace.name || "Workspace",
                   owner
                 ),
               :ok <- persist_sync_ids(workspace.id, org_id, network_id) do
            {:ok, result}
          end
        end)

      {:error, :not_found} ->
        {:error, :owner_not_found}
    end
  end

  @doc """
  Guarantees the Workspace's group holds a Drive binding Comma minted: a
  member org key for the Workspace's Synchronicity org, minted through the
  provisioning secret and stored as the group's `Salix.Control.DriveBindings`
  row with `source: "comma"`. Idempotent: a Comma-minted binding is left alone,
  and so is any row an operator owns (`source: "manual"`), enabled or not:
  a binding an operator disabled stays disabled. Only a group with no row at
  all gets a key.

  Minting is not itself idempotent on the control plane, so a key that
  cannot be stored is revoked again rather than left as an orphan. A
  Comma-minted binding may also carry `retired_key_ids`, keys of earlier
  rotations whose revocation the control plane has not confirmed; this call
  retries those and answers `{:error, {:retryable, {:revoke_pending, ...}}}`
  while any remains, so convergence keeps retrying.
  """
  @spec ensure_agent_key(Workspace.t()) ::
          {:ok, :present | :minted | :manual}
          | Comma.Synchronicity.Client.key_error()
          | {:error, :owner_not_found}
          | {:error, :workspace_not_found}
          | {:error, :not_configured}
          | {:error, {:retryable, {:revoke_pending, %{key_ids: [String.t()], reason: term()}}}}
          | {:error, term()}
  def ensure_agent_key(%Workspace{id: workspace_id}) do
    with true <- configured?() || {:error, :not_configured},
         {:ok, workspace} <- fetch_workspace(workspace_id) do
      case Salix.drive_binding(workspace_scope(workspace)) do
        {:ok, %{"source" => @binding_source} = binding} ->
          settle_retired_keys(workspace, retired_key_ids(binding), :present)

        {:ok, _operator_owned} ->
          {:ok, :manual}

        {:error, :not_found} ->
          mint_agent_key(workspace, nil, [])

        {:error, reason} ->
          {:error, {:retryable, {:drive_binding, reason}}}
      end
    end
  end

  @doc """
  Replaces the Workspace's Comma-minted agent key with a fresh one and revokes
  the old one. An operator action, for a key believed leaked:
  `bin/comma rpc 'Comma.Synchronicity.rotate_agent_key("wsp_...")'`. A binding
  an operator owns is not touched.

  `{:ok, :minted}` means both halves happened: the new key is stored and
  the old one is revoked. When the control plane does not confirm the
  revocation, the new key is still stored (the agent is already on it) and
  the old key's id is kept in the binding's `retired_key_ids`; the answer is
  `{:error, {:retryable, {:revoke_pending, %{key_ids: [...], reason: ...}}}}`
  and the old key must be treated as still valid. Run this again, or let
  the next convergence run, to retry the revocation; or revoke the listed
  key in the Synchronicity dashboard.
  """
  @spec rotate_agent_key(String.t()) ::
          {:ok, :minted | :manual}
          | Comma.Synchronicity.Client.key_error()
          | {:error, :owner_not_found}
          | {:error, :workspace_not_found}
          | {:error, :not_configured}
          | {:error, {:retryable, {:revoke_pending, %{key_ids: [String.t()], reason: term()}}}}
          | {:error, term()}
  def rotate_agent_key(workspace_id) when is_binary(workspace_id) do
    with true <- configured?() || {:error, :not_configured},
         {:ok, workspace} <- fetch_workspace(workspace_id) do
      case Salix.drive_binding(workspace_scope(workspace)) do
        {:ok, %{"source" => @binding_source} = binding} ->
          mint_agent_key(workspace, binding["api_key_id"], retired_key_ids(binding))

        {:ok, _operator_owned} ->
          {:ok, :manual}

        {:error, :not_found} ->
          mint_agent_key(workspace, nil, [])

        {:error, reason} ->
          {:error, {:retryable, {:drive_binding, reason}}}
      end
    end
  end

  @doc "Provision one Workspace by its Comma-owned id."
  @spec provision_workspace_by_id(String.t()) ::
          Comma.Synchronicity.Client.ok()
          | Comma.Synchronicity.Client.error()
          | {:error, :owner_not_found}
          | {:error, :workspace_not_found}
  def provision_workspace_by_id(workspace_id) when is_binary(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %Workspace{} = workspace -> provision_workspace(workspace)
      nil -> {:error, :workspace_not_found}
    end
  end

  @doc """
  Provision a bounded batch of non-deleted Workspaces whose local
  Synchronicity org or network id is missing.

  Successful rows are persisted before the next row is attempted, so a batch
  with failures is resumable. The returned summary is bounded by `limit` and
  contains only failed Workspace ids and classified reasons.
  """
  @spec provision_missing(pos_integer()) :: {:ok, map()} | {:error, map() | :invalid_limit}
  def provision_missing(limit) when is_integer(limit) and limit in 1..@max_provision_limit do
    query =
      from(w in Workspace,
        where: w.status != "deleted" and (is_nil(w.sync_org_id) or is_nil(w.sync_network_id)),
        order_by: [asc: w.id],
        limit: ^limit
      )

    provision_batch(Repo.all(query))
  end

  def provision_missing(_limit), do: {:error, :invalid_limit}

  @doc """
  Refresh a bounded page of all non-deleted Workspaces, including mapped rows.
  Repeat with the returned last_workspace_id as after_id. Retry failed ids
  before advancing. An empty page ends the scan.
  """
  def refresh_all(limit, after_id \\ nil)

  def refresh_all(limit, after_id)
      when is_integer(limit) and limit in 1..@max_provision_limit and
             (is_nil(after_id) or (is_binary(after_id) and byte_size(after_id) > 0)) do
    query =
      from(w in Workspace,
        where: w.status != "deleted",
        order_by: [asc: w.id],
        limit: ^limit
      )

    query = if is_nil(after_id), do: query, else: where(query, [w], w.id > ^after_id)
    workspaces = Repo.all(query)
    {outcome, summary} = provision_batch(workspaces)

    last_id =
      case List.last(workspaces) do
        nil -> nil
        workspace -> workspace.id
      end

    {outcome, Map.put(summary, :last_workspace_id, last_id)}
  end

  def refresh_all(_limit, _after_id), do: {:error, :invalid_refresh_options}

  defp provision_batch(workspaces) do
    {succeeded, failures} =
      Enum.reduce(workspaces, {0, []}, fn workspace, {succeeded, failures} ->
        case provision_workspace(workspace) do
          {:ok, _result} ->
            {succeeded + 1, failures}

          {:error, reason} ->
            {succeeded, [%{workspace_id: workspace.id, reason: reason} | failures]}
        end
      end)

    failures = Enum.reverse(failures)

    summary = %{
      processed: length(workspaces),
      succeeded: succeeded,
      failed: length(failures),
      failures: failures
    }

    if failures == [], do: {:ok, summary}, else: {:error, summary}
  end

  @doc """
  Enrolls the current user's device (its public node key `nk`) into their
  Workspace's assigned Synchronicity network, resolved server-side. Backs the
  session endpoint `PUT /v1/comma/me/synchronicity/devices/current`. The Workspace
  must already be provisioned (its `sync_network_id` filled by convergence).
  """
  @spec enroll_device(String.t(), String.t() | nil, String.t() | nil) ::
          Comma.Synchronicity.Client.device_ok()
          | Comma.Synchronicity.Client.device_error()
          | {:error, :not_configured}
          | {:error, :workspace_not_found}
          | {:error, :owner_not_found}
  def enroll_device(user_id, nk, label) when is_binary(user_id) do
    if configured?() do
      with {:ok, nk} <- present(nk, :nk),
           {:ok, label} <- present(label, :label),
           {:ok, workspace} <- workspace_for_owner(user_id),
           :ok <- provisioned(workspace),
           {:ok, owner} <- owner_or_error(user_id) do
        measured(:synchronicity_enroll, fn ->
          client().enroll_device(workspace.id, nk, label, owner)
        end)
      end
    else
      {:error, :not_configured}
    end
  end

  @doc """
  Reports this user's Synchronicity provisioning state for the client's runtime
  supervisor: whether the integration is configured, whether their Workspace is
  provisioned (its network assigned), and that network id. A local read with no
  S2S call. Backs `GET /v1/comma/me/synchronicity/status`.
  """
  @spec status(String.t()) ::
          {:ok,
           %{
             configured: boolean(),
             provisioned: boolean(),
             status: String.t(),
             network_id: String.t() | nil,
             agent_access: boolean()
           }}
          | {:error, :workspace_not_found}
  def status(user_id) when is_binary(user_id) do
    if configured?() do
      case workspace_for_owner(user_id) do
        {:ok, %Workspace{sync_network_id: network_id} = workspace} when is_binary(network_id) ->
          {:ok,
           %{
             configured: true,
             provisioned: true,
             status: "ready",
             network_id: network_id,
             agent_access: agent_access?(workspace)
           }}

        {:ok, %Workspace{}} ->
          {:ok,
           %{
             configured: true,
             provisioned: false,
             status: "provisioning",
             network_id: nil,
             agent_access: false
           }}

        {:error, :workspace_not_found} = error ->
          error
      end
    else
      {:ok,
       %{
         configured: false,
         provisioned: false,
         status: "unconfigured",
         network_id: nil,
         agent_access: false
       }}
    end
  end

  @doc "Whether provisioning is configured on this deployment."
  @spec configured?() :: boolean()
  def configured?, do: Application.get_env(:comma_core, :synchronicity) != nil

  @doc false
  def config! do
    case Application.get_env(:comma_core, :synchronicity) do
      nil ->
        raise "Synchronicity provisioning is not configured (set comma.synchronicity in config.json)"

      config ->
        %{
          base_url: Keyword.fetch!(config, :base_url),
          provisioning_secret: Keyword.fetch!(config, :provisioning_secret),
          req_options: Keyword.get(config, :req_options, [])
        }
    end
  end

  defp owner(user_id) do
    case Accounts.get_user(user_id) do
      {:ok, user} ->
        {:ok, %{subject: user["id"], email: user["email"], name: user["name"]}}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  defp owner_or_error(user_id) do
    case owner(user_id) do
      {:ok, owner} -> {:ok, owner}
      {:error, :not_found} -> {:error, :owner_not_found}
    end
  end

  defp present(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp present(_value, field), do: {:error, {:invalid, field}}

  defp workspace_for_owner(user_id) do
    query =
      from(workspace in Workspace,
        where: workspace.owner_user_id == ^user_id and workspace.status != "deleted",
        order_by: [asc: workspace.inserted_at, asc: workspace.id],
        limit: 1
      )

    case Repo.one(query) do
      %Workspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :workspace_not_found}
    end
  end

  defp provisioned(%Workspace{sync_network_id: id}) when is_binary(id), do: :ok
  defp provisioned(_workspace), do: {:error, :not_provisioned}

  defp persist_sync_ids(workspace_id, org_id, network_id)
       when is_binary(org_id) and is_binary(network_id) do
    case Repo.update_all(
           from(w in Workspace, where: w.id == ^workspace_id and w.status != "deleted"),
           set: [
             sync_org_id: org_id,
             sync_network_id: network_id,
             updated_at: DateTime.utc_now()
           ]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :workspace_not_found}
    end
  end

  # ---- agent key ----

  defp fetch_workspace(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %Workspace{status: "deleted"} -> {:error, :workspace_not_found}
      %Workspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :workspace_not_found}
    end
  end

  # The shape `Comma.Salix.Client` takes: the binding lives under the
  # Workspace's default group.
  defp workspace_scope(%Workspace{} = workspace) do
    %{
      "id" => workspace.id,
      "salix_tenant_id" => workspace.salix_tenant_id,
      "default_group_id" => workspace.salix_group_id
    }
  end

  # The agent can reach the Drive: a stored binding that is enabled and
  # carries a key, whoever wrote it.
  defp agent_access?(workspace) do
    case Salix.drive_binding(workspace_scope(workspace)) do
      {:ok, %{"enabled" => enabled, "api_key" => api_key}} ->
        enabled != false and is_binary(api_key) and api_key != ""

      _ ->
        false
    end
  end

  defp retired_key_ids(binding) do
    binding["retired_key_ids"]
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  # Mints a key for the Workspace's org and stores it as the group's Drive
  # binding. `replaced_key_id` (nil for a first key) joins `retired` in the
  # stored row before any revocation is attempted, so a revocation the
  # control plane does not confirm is never forgotten. A key the binding
  # store refuses is revoked again rather than orphaned.
  defp mint_agent_key(%Workspace{} = workspace, replaced_key_id, retired) do
    with {:ok, owner} <- owner_or_error(workspace.owner_user_id),
         {:ok, key} <-
           measured(:synchronicity_agent_key, fn ->
             client().mint_api_key(workspace.id, owner, @agent_key_name)
           end) do
      retired =
        (retired ++ List.wrap(replaced_key_id))
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.uniq()

      binding = %{
        "base_url" => config!().base_url,
        "org_slug" => key.org_slug,
        "network" =>
          if(is_binary(key.network) and key.network != "",
            do: key.network,
            else: @default_network
          ),
        "space" => @default_space,
        "api_key" => key.token,
        "api_key_id" => key.key_id,
        "retired_key_ids" => retired,
        "source" => @binding_source,
        "enabled" => true
      }

      case Salix.put_drive_binding(workspace_scope(workspace), binding) do
        {:ok, _stored} ->
          settle_retired_keys(workspace, retired, :minted)

        {:error, reason} ->
          revoke_orphan(workspace.id, key.key_id)
          {:error, {:retryable, {:drive_binding, reason}}}
      end
    end
  end

  # Revokes every retired key and records the ones the control plane did
  # not confirm gone. `:not_found` is gone. The outcome is `{:ok, outcome}`
  # only when nothing remains: a rotation whose old key may still work is
  # not a success, and the retained ids make the next call retry it.
  defp settle_retired_keys(_workspace, [], outcome), do: {:ok, outcome}

  defp settle_retired_keys(%Workspace{} = workspace, retired, outcome) do
    {remaining, reasons} =
      Enum.reduce(retired, {[], []}, fn key_id, {remaining, reasons} ->
        case client().revoke_api_key(workspace.id, key_id) do
          :ok -> {remaining, reasons}
          {:error, :not_found} -> {remaining, reasons}
          {:error, reason} -> {[key_id | remaining], [reason | reasons]}
        end
      end)

    remaining = Enum.reverse(remaining)

    if remaining != retired do
      case Salix.put_drive_binding(workspace_scope(workspace), %{"retired_key_ids" => remaining}) do
        {:ok, _stored} ->
          :ok

        {:error, reason} ->
          # The row keeps the longer list; a revoked key answers
          # `:not_found` on the retry, so nothing is lost.
          Logger.warning(
            "synchronicity agent key retirement not recorded workspace=#{workspace.id} reason=#{inspect(reason)}"
          )
      end
    end

    case remaining do
      [] ->
        {:ok, outcome}

      key_ids ->
        reason = List.last(reasons)

        Logger.warning(
          "synchronicity agent key revoke pending workspace=#{workspace.id} keys=#{inspect(key_ids)} reason=#{inspect(reason)}"
        )

        {:error, {:retryable, {:revoke_pending, %{key_ids: key_ids, reason: reason}}}}
    end
  end

  # A key minted but never stored: revoke it; failing that, name it, since
  # no row will ever retry it.
  defp revoke_orphan(workspace_id, key_id) do
    case client().revoke_api_key(workspace_id, key_id) do
      :ok ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "synchronicity agent key orphaned workspace=#{workspace_id} key=#{key_id} reason=#{inspect(reason)}: revoke it in the Synchronicity dashboard"
        )

        :ok
    end
  end

  @doc false
  def measured(operation, fun) do
    started_at = System.monotonic_time()

    try do
      result = fun.()
      emit_operation(operation, outcome(result), started_at)
      result
    catch
      kind, reason ->
        emit_operation(operation, :error, started_at)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp emit_operation(operation, outcome, started_at) do
    CommaProduct.Telemetry.emit_operation(
      operation,
      outcome,
      System.monotonic_time() - started_at
    )
  end

  defp outcome({:ok, _result}), do: :ok
  defp outcome({:error, :explicit_link_required}), do: :conflict
  defp outcome({:error, {:invalid, {:conflict, _code}}}), do: :conflict
  defp outcome({:error, {:retryable, {:status, 429}}}), do: :rate_limited
  defp outcome({:error, {:retryable, _reason}}), do: :unavailable

  defp outcome({:error, reason}) when reason in [:owner_not_found, :workspace_not_found],
    do: :not_found

  defp outcome({:error, :auth}), do: :rejected
  defp outcome({:error, :not_provisioned}), do: :rejected
  defp outcome({:error, {:invalid, _reason}}), do: :rejected

  defp outcome({:error, reason})
       when reason in [
              :hosting_disabled,
              :browse_disabled,
              :no_cloud_attached,
              :no_device_attached
            ],
       do: :unavailable

  defp outcome({:error, :precondition}), do: :conflict
  defp outcome({:error, reason}) when reason in [:too_large, :over_budget], do: :rejected
  defp outcome(:ok), do: :ok
  defp outcome(_result), do: :other

  defp client, do: Application.get_env(:comma_core, :synchronicity_client, Comma.Synchronicity.HTTP)
end
