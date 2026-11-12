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

  A product may also give a role to a person who has no account in it but
  whom the Group's chat app is available to (`app_member_role/2`): a
  BridgeForTeams Project's Feishu or Lark users. The caller asks the chat
  app whether that is so for the person who asked; a product that needs an
  account answers `:none`.
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

  @doc """
  Whether the Group's agents may issue a station enrollment for someone who is
  no known member. A product that does not implement it never allows that.
  """
  @callback open_enrollment?(tenant_id :: String.t(), group_id :: String.t()) :: boolean()
  @optional_callbacks open_enrollment?: 2

  @doc """
  A member of the Group as people know them, `%{"name", "email"}`, or `:none`
  for no member. A product that does not implement it names no one.
  """
  @callback member(tenant_id :: String.t(), group_id :: String.t(), user_id :: String.t()) ::
              {:ok, map()} | :none
  @optional_callbacks member: 3

  @doc """
  The role in the Group of a person who has no account in the product and
  whom the Group's chat app (its Feishu or Lark app) is available to, or
  `:none` where the product needs an account. The caller checks that the app
  is available to the person; the product only says what role that gives.
  """
  @callback app_member_role(tenant_id :: String.t(), group_id :: String.t()) ::
              {:ok, String.t()} | :none
  @optional_callbacks app_member_role: 2

  @group_enroller "group"

  @doc "The enroller of an enrollment issued for no member: its device has no owner."
  def group_enroller, do: @group_enroller

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

  @doc "A member of the Group as people know them (`name`, `email`), or `:none`."
  @spec member(String.t(), String.t(), String.t()) :: {:ok, map()} | :none
  def member(tenant_id, group_id, user_id)
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(user_id) do
    Enum.find_value(implementations(), :none, fn module ->
      SystemsRuntime.Proc.ensure_loaded?(module)

      if function_exported?(module, :member, 3) do
        case module.member(tenant_id, group_id, user_id) do
          {:ok, person} -> {:ok, person}
          :none -> nil
        end
      end
    end)
  end

  def member(_tenant_id, _group_id, _user_id), do: :none

  @doc """
  The role of a person whom the Group's chat app is available to and who has
  no account in the product (`c:app_member_role/2`), or `:none`: the answer
  of the first product that gives one. A product that does not implement it
  gives none.
  """
  @spec app_member_role(String.t(), String.t()) :: {:ok, String.t()} | :none
  def app_member_role(tenant_id, group_id) when is_binary(tenant_id) and is_binary(group_id) do
    Enum.find_value(implementations(), :none, fn module ->
      SystemsRuntime.Proc.ensure_loaded?(module)

      if function_exported?(module, :app_member_role, 2) do
        case module.app_member_role(tenant_id, group_id) do
          {:ok, role} when is_binary(role) -> {:ok, role}
          :none -> nil
        end
      end
    end)
  end

  def app_member_role(_tenant_id, _group_id), do: :none

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
  lent the workspace's accounts (`SalixWeb.StationProfiles`). `group_enroller/0`
  may where the product allows open enrollment (`c:open_enrollment?/2`).
  """
  @spec enroller?(String.t(), String.t(), String.t()) :: boolean()
  def enroller?(tenant_id, group_id, @group_enroller)
      when is_binary(tenant_id) and is_binary(group_id) do
    Enum.any?(implementations(), fn module ->
      function_exported?(module, :open_enrollment?, 2) and
        module.open_enrollment?(tenant_id, group_id)
    end)
  end

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
