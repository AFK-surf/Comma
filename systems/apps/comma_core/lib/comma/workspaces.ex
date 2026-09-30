defmodule Comma.Workspaces do
  @moduledoc "Comma-owned account context and authorization for admitted Salix Groups."

  import Ecto.Query

  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Comma.Operations
  alias Comma.Repo
  alias Comma.WorkspaceGroupBinding
  alias Ecto.Multi
  alias SalixStore.Ids

  @workspace_list_limit 100
  @membership_limit 100

  def create_for_user(user_id, attrs \\ %{}) do
    id = attrs["workspace_id"] || attrs[:workspace_id] || new_id("wsp")
    vm = Map.get(attrs, "vm", Map.get(attrs, :vm))

    vm =
      if is_nil(vm),
        do: %{"enabled" => not Application.get_env(:comma_core, :selfhost, false)},
        else: vm

    with :ok <- reject_salix_identity(attrs),
         {:ok, vm} <- normalize_vm(vm, allow_recreate?: false) do
      tenant_id = Ids.new_tenant_id()
      group_id = Ids.new_group_id(tenant_id)
      router_agent_id = Ids.new_agent_id(group_id)
      default_worker_agent_id = Ids.new_agent_id(group_id)

      workspace =
        %{
          "id" => id,
          "name" => attrs["name"] || attrs[:name] || "Default workspace",
          "owner_user_id" => user_id,
          "billing_account_id" =>
            attr(attrs, :billing_account_id) || billing_account_prefix() <> id,
          "salix_tenant_id" => tenant_id,
          "members" => [%{"user_id" => user_id, "role" => "owner"}],
          "default_group_id" => group_id,
          "router_agent_id" => router_agent_id,
          "default_worker_agent_id" => default_worker_agent_id,
          "created_at" => unix_time(DateTime.utc_now()),
          "updated_at" => unix_time(DateTime.utc_now())
        }
        |> put_optional("vm", vm)

      with {:ok, stored, _operation_id} <- insert_workspace_with_owner(workspace) do
        get(stored.id)
      end
    end
  end

  def list_for_user(user_id, session \\ %{}) do
    with {:ok, scoped_workspace_id} <- scoped_workspace_id(session) do
      query =
        from(workspace in Workspace,
          join: membership in WorkspaceMembership,
          on: membership.workspace_id == workspace.id,
          where:
            workspace.owner_user_id == ^user_id and membership.user_id == ^user_id and
              membership.role == "owner" and membership.status == "active" and
              workspace.status == "active",
          order_by: [desc: workspace.inserted_at, desc: workspace.id],
          limit: ^(@workspace_list_limit + 1)
        )
        |> maybe_scope_workspace(scoped_workspace_id)

      rows = Repo.all(query) |> Enum.take(@workspace_list_limit)
      {:ok, workspace_maps(rows)}
    end
  end

  def create_for_session(_user_id, %{"restricted" => true}, _attrs), do: {:error, :forbidden}

  def create_for_session(_user_id, _session, _attrs),
    do: {:error, :workspace_creation_managed}

  defp billing_account_prefix do
    Application.get_env(:comma_core, :billing_account_prefix, "comma-ba-")
  end

  def get(id) when is_binary(id) do
    case Repo.get(Workspace, id) do
      nil -> {:error, :not_found}
      workspace -> {:ok, workspace_map(workspace, memberships_for([id])[id] || [])}
    end
  end

  def get(_id), do: {:error, :not_found}

  @doc "The Workspace that owns an exact Salix Group. Grants no authority."
  def get_by_group(group_id) when is_binary(group_id) do
    with true <- Ids.valid_group_id?(group_id),
         %Workspace{id: id} = workspace <- Repo.get_by(Workspace, salix_group_id: group_id) do
      {:ok, workspace_map(workspace, memberships_for([id])[id] || [])}
    else
      _ -> {:error, :not_found}
    end
  end

  def get_by_group(_group_id), do: {:error, :not_found}

  @doc false
  def group_binding_revision(workspace) when is_map(workspace) do
    WorkspaceGroupBinding.revision(workspace)
  end

  @doc "Return the Comma product Workspace with its canonical admitted Salix Group id."
  def public(workspace) when is_map(workspace) do
    workspace
    |> Map.put("group_id", workspace["default_group_id"])
    |> Map.drop([
      "salix_tenant_id",
      "default_group_id",
      "router_agent_id",
      "default_worker_agent_id"
    ])
    |> Map.update("members", [], fn members ->
      Enum.filter(
        members,
        &(&1["user_id"] == workspace["owner_user_id"] and &1["role"] == "owner")
      )
    end)
    |> Map.update("status", nil, &public_status/1)
  end

  def update(user, session, workspace_id, attrs) do
    with {:ok, _workspace} <- authorize(user, session, workspace_id),
         {:ok, updates, command_vm} <- normalize_updates(attrs),
         {:ok, stored, _operation_id} <-
           update_workspace(user, session, workspace_id, updates, command_vm) do
      get(stored.id)
    end
  end

  def authorize(user, session, workspace_id) do
    with %Workspace{} = workspace <- Repo.get(Workspace, workspace_id),
         :ok <- session_scope(session, workspace_id, nil),
         true <- active_owner?(workspace, user["id"]),
         :ok <- workspace_ready(workspace) do
      {:ok, workspace_map(workspace, memberships_for([workspace_id])[workspace_id] || [])}
    else
      nil -> {:error, :not_found}
      false -> {:error, :forbidden}
      {:error, _} = error -> error
    end
  end

  @doc "Authorize an exact Group without making the Workspace its resource owner."
  def authorize_group(user, session, group_id) when is_binary(group_id) do
    with true <- Ids.valid_group_id?(group_id),
         %Workspace{} = workspace <- Repo.get_by(Workspace, salix_group_id: group_id),
         :ok <- group_session_scope(session, group_id, nil),
         true <- active_owner?(workspace, user["id"]),
         :ok <- workspace_ready(workspace) do
      {:ok, workspace_map(workspace, memberships_for([workspace.id])[workspace.id] || [])}
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def authorize_group(_user, _session, _group_id), do: {:error, :not_found}

  @doc """
  Re-checks, without a session, that `user_id` still owns the ready Workspace
  of an exact Group. A Task Share uses this to read as its creator.
  """
  def authorize_group_owner(workspace_id, group_id, user_id)
      when is_binary(workspace_id) and is_binary(group_id) and is_binary(user_id) do
    with true <- Ids.valid_group_id?(group_id),
         %Workspace{id: ^workspace_id} = workspace <-
           Repo.get_by(Workspace, salix_group_id: group_id),
         true <- active_owner?(workspace, user_id),
         :ok <- workspace_ready(workspace) do
      {:ok, workspace_map(workspace, memberships_for([workspace.id])[workspace.id] || [])}
    else
      _ -> {:error, :not_found}
    end
  end

  def authorize_group_owner(_workspace_id, _group_id, _user_id), do: {:error, :not_found}

  @doc false
  def active_owner?(
        %Workspace{id: workspace_id, owner_user_id: user_id},
        user_id
      )
      when is_binary(user_id) do
    Repo.exists?(
      from(membership in WorkspaceMembership,
        where:
          membership.workspace_id == ^workspace_id and membership.user_id == ^user_id and
            membership.role == "owner" and membership.status == "active"
      )
    )
  end

  def active_owner?(_workspace, _user_id), do: false

  defp workspace_ready(%Workspace{status: "active"}), do: :ok

  defp workspace_ready(%Workspace{status: "provisioning"}),
    do: {:error, :workspace_provisioning}

  defp workspace_ready(%Workspace{status: "provisioning_failed"}),
    do: {:error, :workspace_provisioning_failed}

  defp workspace_ready(%Workspace{}), do: {:error, :workspace_unavailable}

  defp public_status("active"), do: "ready"
  defp public_status("provisioning_failed"), do: "failed"
  defp public_status(status), do: status

  def session_scope(%{"restricted" => true} = session, workspace_id, conversation_id) do
    scoped_workspace_id = session["workspace_id"]
    scoped_conversation_id = session["conversation_id"]

    cond do
      not is_binary(scoped_workspace_id) or scoped_workspace_id == "" ->
        {:error, :forbidden}

      scoped_workspace_id != workspace_id ->
        {:error, :forbidden}

      is_nil(scoped_conversation_id) ->
        :ok

      not is_binary(scoped_conversation_id) or scoped_conversation_id == "" ->
        {:error, :forbidden}

      is_nil(conversation_id) or scoped_conversation_id == conversation_id ->
        :ok

      true ->
        {:error, :forbidden}
    end
  end

  def session_scope(_session, _workspace_id, _conversation_id), do: :ok

  @doc false
  def group_session_scope(%{"restricted" => true} = session, group_id, conversation_id) do
    scoped_group_id = session["group_id"]
    scoped_conversation_id = session["conversation_id"]

    if is_nil(scoped_group_id) do
      legacy_group_session_scope(session, group_id, conversation_id)
    else
      exact_group_session_scope(
        scoped_group_id,
        scoped_conversation_id,
        group_id,
        conversation_id
      )
    end
  end

  def group_session_scope(_session, _group_id, _conversation_id), do: :ok

  defp exact_group_session_scope(
         scoped_group_id,
         scoped_conversation_id,
         group_id,
         conversation_id
       ) do
    cond do
      not is_binary(scoped_group_id) or scoped_group_id == "" ->
        {:error, :forbidden}

      scoped_group_id != group_id ->
        {:error, :forbidden}

      is_nil(scoped_conversation_id) ->
        :ok

      not is_binary(scoped_conversation_id) or scoped_conversation_id == "" ->
        {:error, :forbidden}

      is_nil(conversation_id) or scoped_conversation_id == conversation_id ->
        :ok

      true ->
        {:error, :forbidden}
    end
  end

  defp legacy_group_session_scope(session, group_id, conversation_id) do
    workspace_id = session["workspace_id"]
    scoped_conversation_id = session["conversation_id"]

    cond do
      not is_binary(group_id) or group_id == "" ->
        {:error, :forbidden}

      not is_binary(workspace_id) or workspace_id == "" ->
        {:error, :forbidden}

      not is_binary(scoped_conversation_id) or scoped_conversation_id == "" ->
        {:error, :forbidden}

      not workspace_bound_to_group?(workspace_id, group_id) ->
        {:error, :forbidden}

      is_nil(conversation_id) or scoped_conversation_id == conversation_id ->
        :ok

      true ->
        {:error, :forbidden}
    end
  end

  defp workspace_bound_to_group?(workspace_id, group_id) do
    Repo.exists?(
      from(workspace in Workspace,
        where: workspace.id == ^workspace_id and workspace.salix_group_id == ^group_id
      )
    )
  end

  defp insert_workspace_with_owner(workspace) do
    attrs = workspace_attrs(workspace)
    operation_id = convergence_operation_id(workspace["id"], 1)

    multi =
      Multi.new()
      |> Multi.insert(:workspace, Workspace.changeset(%Workspace{}, attrs))
      |> Multi.insert(:owner_membership, fn %{workspace: stored} ->
        WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
          workspace_id: stored.id,
          user_id: workspace["owner_user_id"],
          role: "owner",
          status: "active"
        })
      end)
      |> Operations.create_with_job(
        convergence_operation_attrs(workspace["id"], 1),
        Comma.Workers.WorkspaceConvergence.new(%{"operation_id" => operation_id})
      )

    case Repo.transaction(multi) do
      {:ok, %{workspace: stored}} ->
        {:ok, stored, operation_id}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp update_workspace(user, session, workspace_id, updates, command_vm) do
    multi =
      Multi.new()
      |> Multi.run(:locked_workspace, fn repo, _changes ->
        workspace =
          repo.one(from(row in Workspace, where: row.id == ^workspace_id, lock: "FOR UPDATE"))

        cond do
          is_nil(workspace) ->
            {:error, :not_found}

          session_scope(session, workspace_id, nil) != :ok ->
            {:error, :forbidden}

          not active_owner?(workspace, user["id"]) ->
            {:error, :forbidden}

          true ->
            {:ok, workspace}
        end
      end)
      |> Multi.update(:workspace, fn %{locked_workspace: workspace} ->
        next_generation = workspace.lock_version + 1

        changes =
          %{}
          |> maybe_copy_update(updates, "name", :name)
          |> maybe_copy_update(updates, "vm", :vm)
          |> put_vm_recreate_generation(command_vm, next_generation)

        workspace
        |> Workspace.changeset(changes)
        |> Ecto.Changeset.optimistic_lock(:lock_version)
      end)
      |> Multi.merge(fn %{workspace: stored} ->
        if is_nil(command_vm) do
          Multi.new()
        else
          operation_id = convergence_operation_id(stored.id, stored.lock_version)

          Operations.create_with_job(
            Multi.new(),
            convergence_operation_attrs(stored.id, stored.lock_version),
            Comma.Workers.WorkspaceConvergence.new(%{"operation_id" => operation_id})
          )
        end
      end)

    case Repo.transaction(multi) do
      {:ok, %{workspace: stored}} ->
        operation_id =
          if is_nil(command_vm),
            do: nil,
            else: convergence_operation_id(stored.id, stored.lock_version)

        {:ok, stored, operation_id}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp scoped_workspace_id(%{"restricted" => true, "workspace_id" => workspace_id})
       when is_binary(workspace_id) and workspace_id != "",
       do: {:ok, workspace_id}

  defp scoped_workspace_id(%{"restricted" => true}), do: {:error, :forbidden}

  defp scoped_workspace_id(_session), do: {:ok, nil}

  defp maybe_scope_workspace(query, nil), do: query

  defp maybe_scope_workspace(query, workspace_id),
    do: from(workspace in query, where: workspace.id == ^workspace_id)

  defp workspace_maps([]), do: []

  defp workspace_maps(workspaces) do
    memberships = memberships_for(Enum.map(workspaces, & &1.id))
    Enum.map(workspaces, &workspace_map(&1, memberships[&1.id] || []))
  end

  defp memberships_for([]), do: %{}

  defp memberships_for(workspace_ids) do
    from(membership in WorkspaceMembership,
      where: membership.workspace_id in ^workspace_ids and membership.status == "active",
      order_by: [asc: membership.workspace_id, asc: membership.inserted_at, asc: membership.id],
      limit: ^(length(workspace_ids) * @membership_limit)
    )
    |> Repo.all()
    |> Enum.group_by(& &1.workspace_id)
    |> Map.new(fn {workspace_id, memberships} ->
      {workspace_id, Enum.take(memberships, @membership_limit)}
    end)
  end

  defp workspace_map(%Workspace{} = workspace, memberships) do
    %{
      "id" => workspace.id,
      "name" => workspace.name,
      "owner_user_id" => workspace.owner_user_id,
      "billing_account_id" => workspace.billing_owner_id,
      "salix_tenant_id" => workspace.salix_tenant_id,
      "members" => Enum.map(memberships, &%{"user_id" => &1.user_id, "role" => &1.role}),
      "default_group_id" => workspace.salix_group_id,
      "router_agent_id" => workspace.salix_router_agent_id,
      "default_worker_agent_id" => workspace.salix_worker_agent_id,
      "status" => workspace.status,
      "created_at" => unix_time(workspace.inserted_at),
      "updated_at" => unix_time(workspace.updated_at)
    }
    |> put_optional("vm", workspace.vm)
  end

  defp workspace_attrs(workspace) do
    %{
      id: workspace["id"],
      owner_user_id: workspace["owner_user_id"],
      salix_tenant_id: workspace["salix_tenant_id"],
      salix_group_id: workspace["default_group_id"],
      group_generation: group_binding_revision(workspace),
      salix_router_agent_id: workspace["router_agent_id"],
      salix_worker_agent_id: workspace["default_worker_agent_id"],
      billing_owner_id: workspace["billing_account_id"],
      name: workspace["name"],
      vm: workspace["vm"],
      status: "provisioning"
    }
  end

  defp maybe_copy_update(changes, updates, source, target) do
    if Map.has_key?(updates, source), do: Map.put(changes, target, updates[source]), else: changes
  end

  defp normalize_updates(attrs) when is_map(attrs) do
    attrs = stringify(attrs)

    with {:ok, vm} <- normalize_vm(attrs["vm"], allow_recreate?: true) do
      updates =
        %{}
        |> maybe_put_name(attrs)
        |> maybe_put_vm(vm)

      command_vm = if Map.has_key?(attrs, "vm"), do: attrs["vm"], else: nil
      {:ok, updates, command_vm}
    end
  end

  defp normalize_updates(_attrs), do: {:error, {:bad_request, "invalid request body"}}

  defp maybe_put_name(updates, %{"name" => name}) when is_binary(name) do
    case String.trim(name) do
      "" -> updates
      trimmed -> Map.put(updates, "name", trimmed)
    end
  end

  defp maybe_put_name(updates, _attrs), do: updates
  defp maybe_put_vm(updates, nil), do: updates
  defp maybe_put_vm(updates, vm), do: Map.put(updates, "vm", strip_vm_command_flags(vm))

  defp put_vm_recreate_generation(changes, nil, _generation), do: changes

  defp put_vm_recreate_generation(changes, vm, generation) do
    Map.put(changes, :vm_recreate_generation, if(vm["recreate"] == true, do: generation))
  end

  defp normalize_vm(nil, _opts), do: {:ok, nil}

  defp normalize_vm(vm, opts) when is_map(vm) do
    vm = stringify(vm)

    cond do
      Map.has_key?(vm, "enabled") and not is_boolean(vm["enabled"]) ->
        {:error, {:bad_request, "vm.enabled must be boolean"}}

      vm["provider"] not in [nil, "", "cloudflare"] ->
        {:error, {:bad_request, "vm.provider must be cloudflare"}}

      Map.has_key?(vm, "recreate") and not Keyword.get(opts, :allow_recreate?, false) ->
        {:error, {:bad_request, "vm.recreate is only supported when updating a workspace"}}

      Map.has_key?(vm, "recreate") and not is_boolean(vm["recreate"]) ->
        {:error, {:bad_request, "vm.recreate must be boolean"}}

      true ->
        normalized =
          %{}
          |> put_optional("enabled", vm["enabled"])
          |> put_optional("provider", blank_to_nil(vm["provider"]))
          |> put_optional("recreate", vm["recreate"])

        {:ok, normalized}
    end
  end

  defp normalize_vm(_vm, _opts), do: {:error, {:bad_request, "vm must be an object"}}
  defp strip_vm_command_flags(vm) when is_map(vm), do: Map.delete(vm, "recreate")
  defp strip_vm_command_flags(vm), do: vm

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      value = if is_map(value), do: stringify(value), else: value
      {to_string(key), value}
    end)
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp attr(attrs, key) do
    value = attrs[to_string(key)] || attrs[key]

    if is_binary(value) do
      value = String.trim(value)
      if value == "", do: nil, else: value
    else
      value
    end
  end

  defp reject_salix_identity(attrs) do
    fields = ~w(salix_tenant_id default_group_id router_agent_id default_worker_agent_id)

    case Enum.find(fields, &(Map.has_key?(attrs, &1) or Map.has_key?(attrs, String.to_atom(&1)))) do
      nil -> :ok
      field -> {:error, {:bad_request, "#{field} is generated by the workspace owner"}}
    end
  end

  defp new_id(prefix),
    do: prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp convergence_operation_attrs(workspace_id, generation) do
    %{
      operation_id: convergence_operation_id(workspace_id, generation),
      operation_type: "workspace_convergence",
      owner_type: "workspace",
      owner_id: workspace_id,
      generation: generation,
      status: "pending",
      attempt: 0,
      external_idempotency_key: "comma.workspace.convergence/v1/#{workspace_id}/#{generation}",
      metadata: %{}
    }
  end

  defp convergence_operation_id(workspace_id, generation) do
    digest =
      :crypto.hash(:sha256, "#{workspace_id}:#{generation}")
      |> Base.url_encode64(padding: false)

    "wsp_converge_" <> digest
  end

  defp unix_time(nil), do: nil
  defp unix_time(%DateTime{} = value), do: DateTime.to_unix(value, :second)
end
