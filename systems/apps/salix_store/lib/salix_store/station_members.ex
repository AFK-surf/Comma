defmodule SalixStore.StationMembers do
  @moduledoc """
  Who belongs to a Group's stations, as the product that owns the Group
  decides (`SalixStore.Stations` keeps the roster, not the membership).

  Each product registers an implementation at start
  (`config :salix_store, :station_members`, a list; `register/1`). An
  implementation answers for the Groups its product owns and `:none` for any
  other, so a user's role in a Group is the one answer that is not `:none`.
  Groups of different products never overlap.

  A role is the product's own role name. `manager?/3` is whether the role may
  rename and remove the Group's stations, and `enroller?/3` whether it may
  enroll one (any role but a read-only one). The product also names the
  Group as its stations show it (`workspace_name/2`): a Comma Workspace's
  name, a BridgeForTeams Project's name.

  Whether a Group's stations are served is the product's answer too
  (`workspace_active?/2`): an active Comma Workspace, a BridgeForTeams Project
  that is not archived. A Group no registered product owns is refused by no
  one: it has no members, and only the control plane places a station there.
  """

  @doc "The user's active role in the active Group, or `:none`."
  @callback role(tenant_id :: String.t(), group_id :: String.t(), user_id :: String.t()) ::
              {:ok, String.t()} | :none

  @doc "Whether `role` manages the Group's stations."
  @callback manager_role?(role :: String.t()) :: boolean()

  @doc "Whether `role` is read-only: it may not enroll a station or be lent the Group's accounts."
  @callback read_only_role?(role :: String.t()) :: boolean()

  @doc "The name of the product's workspace that is this Group, or `:none`."
  @callback workspace_name(tenant_id :: String.t(), group_id :: String.t()) ::
              {:ok, String.t()} | :none

  @doc """
  Whether the product's workspace that is this Group is in use (not
  suspended, deleted or archived), or `:none` for a Group of another product.
  """
  @callback workspace_active?(tenant_id :: String.t(), group_id :: String.t()) ::
              boolean() | :none

  @doc "Map a sealed provider principal through the product's existing identity binding."
  @callback requester(String.t(), String.t(), map(), String.t()) :: {:ok, String.t()} | :none
  @optional_callbacks requester: 4

  def requester(tenant, group, connect, subject) do
    Enum.find_value(implementations(), {:error, :requester_required}, fn module ->
      if function_exported?(module, :requester, 4) do
        case module.requester(tenant, group, connect, subject) do
          {:ok, user} -> if enroller?(tenant, group, user), do: {:ok, user}
          :none -> nil
        end
      end
    end)
  end

  @doc "Adds `module` to the registered implementations."
  def register(module) when is_atom(module) do
    modules = Enum.uniq(implementations() ++ [module])
    SystemsRuntime.put_env(:salix_store, :station_members, modules)
  end

  @doc "The user's role in the Group, from the product that owns it."
  @spec role(String.t(), String.t(), String.t()) :: {:ok, String.t()} | :none
  def role(tenant_id, group_id, user_id)
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(user_id) do
    case answer(tenant_id, group_id, user_id) do
      {_module, role} -> {:ok, role}
      nil -> :none
    end
  end

  def role(_tenant_id, _group_id, _user_id), do: :none

  @doc "Whether the user manages the Group's stations."
  @spec manager?(String.t(), String.t(), String.t()) :: boolean()
  def manager?(tenant_id, group_id, user_id)
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(user_id) do
    case answer(tenant_id, group_id, user_id) do
      {module, role} -> module.manager_role?(role)
      nil -> false
    end
  end

  def manager?(_tenant_id, _group_id, _user_id), do: false

  @doc """
  Whether the user may enroll a station in the Group: any role but a
  read-only one. The same rule says whether the user's device station is
  lent the workspace's accounts (`SalixWeb.StationProfiles`).
  """
  @spec enroller?(String.t(), String.t(), String.t()) :: boolean()
  def enroller?(tenant_id, group_id, user_id)
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(user_id) do
    case answer(tenant_id, group_id, user_id) do
      {module, role} -> not module.read_only_role?(role)
      nil -> false
    end
  end

  def enroller?(_tenant_id, _group_id, _user_id), do: false

  @doc "The Group's name as its stations show it; empty when no product names it."
  @spec workspace_name(String.t(), String.t()) :: String.t()
  def workspace_name(tenant_id, group_id) when is_binary(tenant_id) and is_binary(group_id) do
    Enum.find_value(implementations(), "", fn module ->
      case module.workspace_name(tenant_id, group_id) do
        {:ok, name} when is_binary(name) -> name
        :none -> nil
      end
    end)
  end

  @doc """
  Whether the Group's stations are served: the answer of the product that
  owns the Group, and true when no registered product owns it.
  """
  @spec workspace_active?(String.t(), String.t()) :: boolean()
  def workspace_active?(tenant_id, group_id) when is_binary(tenant_id) and is_binary(group_id) do
    implementations()
    |> Enum.map(& &1.workspace_active?(tenant_id, group_id))
    |> Enum.find(true, &is_boolean/1)
  end

  defp answer(tenant_id, group_id, user_id) do
    Enum.find_value(implementations(), fn module ->
      case module.role(tenant_id, group_id, user_id) do
        {:ok, role} when is_binary(role) -> {module, role}
        :none -> nil
      end
    end)
  end

  defp implementations,
    do: :salix_store |> SystemsRuntime.get_env(:station_members, []) |> List.wrap()
end
