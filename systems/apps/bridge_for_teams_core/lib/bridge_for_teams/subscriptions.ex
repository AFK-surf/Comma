defmodule BridgeForTeams.Subscriptions do
  @moduledoc "Organization-authorized access to Salix subscription accounts and templates."
  import Ecto.Query

  alias BridgeForTeams.{Memberships, Orgs, Repo}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.Project

  def authorize({org_id, user_id}) do
    with {:ok, org} <- Orgs.get_org(org_id),
         {:ok, role} when role in ["owner", "admin"] <- Memberships.org_role(org_id, user_id) do
      {:ok, org}
    else
      _ -> {:error, :forbidden}
    end
  end

  def list(scope, cursor), do: account(scope, :list, [cursor])

  @doc """
  One page of the workloads bound to an account. Only owners and admins get
  here, and they administer every Agent Swarm of the organization, so a binding
  is visible when its project belongs to the organization; the rest are
  counted in `hidden_count`. The projects of a page load in one query.
  """
  def list_bindings({org_id, _user_id} = scope, account_id, cursor \\ 0) do
    with {:ok, org} <- authorize(scope),
         {:ok, page} <-
           Client.impl().subscription_operation(
             org.salix_tenant_id,
             :list_bindings,
             [account_id, cursor]
           ) do
      projects = org_projects(org_id, page["bindings"])

      {visible, hidden} =
        Enum.split_with(page["bindings"], &Map.has_key?(projects, &1["project_id"]))

      {:ok,
       %{
         "bindings" => Enum.map(visible, &public_binding(&1, projects[&1["project_id"]])),
         "hidden_count" => length(hidden),
         "next" => page["next"]
       }}
    end
  end

  def create(scope, %{"credential_kind" => "provider_api_key"} = attrs),
    do:
      account(scope, :create, [
        Map.take(attrs, ~w(credential_kind name connection credentials))
      ])

  def create(scope, attrs),
    do:
      account(scope, :create, [
        attrs
        |> Map.take(~w(provider credentials))
        |> Map.put("credential_kind", "subscription_oauth")
      ])

  def update(scope, id, attrs) do
    allowed =
      if Map.has_key?(attrs, "connection") or Map.has_key?(attrs, "name"),
        do: ~w(version name connection credentials),
        else: ~w(version disabled credentials)

    account(scope, :update, [id, Map.take(attrs, allowed)])
  end

  def delete(scope, id, version), do: account(scope, :delete, [id, version])
  def quota(scope, id), do: account(scope, :quota, [id])

  def reset_quota(scope, id, attrs),
    do: account(scope, :reset_quota, [id, Map.take(attrs, ~w(version request_id))])

  def begin_oauth(scope, attrs),
    do: account(scope, :begin_oauth, [Map.take(attrs, ~w(provider account_id version mode))])

  def complete_oauth(scope, id, attrs),
    do: account(scope, :complete_oauth, [id, Map.take(attrs, ~w(code))])

  defp account(scope, action, args) do
    with {:ok, org} <- authorize(scope) do
      Client.impl().subscription_operation(org.salix_tenant_id, action, args)
    end
  end

  defp org_projects(org_id, bindings) do
    ids =
      for %{"project_id" => id} <- bindings,
          match?({:ok, _}, Ecto.UUID.cast(id)),
          uniq: true,
          do: id

    from(p in Project, where: p.org_id == ^org_id and p.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp public_binding(binding, project) do
    binding
    |> Map.drop(["project_id", "group_id", "device_id", "device_runtime_id"])
    |> Map.put("project", %{"id" => project.id, "name" => project.name, "slug" => project.slug})
  end

  def templates(scope) do
    with {:ok, org} <- authorize(scope) do
      Client.impl().private_template_operation(org.salix_tenant_id, :list, [])
    end
  end

  def discover_models(scope, pool) when pool in ["codex", "claude"] do
    with {:ok, org} <- authorize(scope) do
      Client.impl().private_template_operation(org.salix_tenant_id, :discover, [pool])
    end
  end

  def save_template(scope, id, attrs) do
    with {:ok, org} <- authorize(scope) do
      Client.impl().private_template_operation(org.salix_tenant_id, :save, [
        id,
        Map.take(
          attrs,
          ~w(name model model_display_name model_vendor subscription_provider max_tokens)
        )
      ])
    end
  end

  def delete_template(scope, id) do
    with {:ok, org} <- authorize(scope) do
      if id in [org.default_template_id, org.default_router_template_id] or
           id in (org.allowed_template_ids || []) do
        {:error,
         {:conflict,
          "Remove this template from the organization's default and allowed models first."}}
      else
        Client.impl().private_template_operation(org.salix_tenant_id, :delete, [id])
      end
    end
  end
end
