defmodule Comma.Billing.RouterModels do
  @moduledoc "Comma-owned policy for free Router main-model calls."

  alias Comma.{Repo, Data.Workspace}

  @limit 100

  def get do
    case Ecto.Adapters.SQL.query(
           Repo,
           "SELECT models, revision FROM comma_billing_policy WHERE id = 1",
           [],
           timeout: 5_000
         ) do
      {:ok, %{rows: [[models, revision]]}} -> {:ok, %{models: models, revision: revision}}
      {:ok, _} -> {:error, :billing_policy_missing}
      {:error, _} -> {:error, :billing_policy_unavailable}
    end
  end

  def update(attrs) do
    with {:ok, models} <- normalize_models(attrs["models"]),
         revision when is_integer(revision) and revision >= 0 <- attrs["revision"] do
      Repo.transaction(fn ->
        %{rows: [[previous, current]]} =
          Ecto.Adapters.SQL.query!(
            Repo,
            "SELECT models, revision FROM comma_billing_policy WHERE id = 1 FOR UPDATE",
            []
          )

        if revision != current, do: Repo.rollback(:billing_policy_conflict)

        Ecto.Adapters.SQL.query!(
          Repo,
          "UPDATE comma_billing_policy SET models = $1, revision = revision + 1 WHERE id = 1",
          [models]
        )

        if command_id = attrs["admin_command_id"] do
          Ecto.Adapters.SQL.query!(
            Repo,
            "UPDATE comma_admin_audit_events SET evidence = $2 WHERE id = $1::uuid",
            [Ecto.UUID.dump!(command_id), %{"before" => previous, "after" => models}]
          )
        end

        %{models: models, revision: current + 1}
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_billing_policy}
    end
  end

  def normalize_models(models) when is_list(models) and length(models) <= @limit do
    if Enum.all?(models, fn
         %{"provider" => provider, "sku" => sku} -> bounded?(provider) and bounded?(sku)
         _ -> false
       end) do
      normalized =
        Enum.map(models, fn model ->
          {provider, sku} = BillingCore.LLMMetering.model_key(model["provider"], model["sku"])
          %{"provider" => provider, "sku" => sku}
        end)

      {:ok, normalized |> Enum.uniq() |> Enum.sort_by(&{&1["provider"], &1["sku"]})}
    else
      {:error, :invalid_billing_policy}
    end
  end

  def normalize_models(_), do: {:error, :invalid_billing_policy}

  def free_call?(%{model_purpose: :agent_main, surface: "comma"} = fact) do
    workspace_id = fact[:product_owner_id]
    agent_id = fact[:salix_agent_id]

    if fact[:product_owner_type] == "workspace" and is_binary(workspace_id) and
         is_binary(agent_id) do
      workspace = Repo.get(Workspace, workspace_id)

      case workspace do
        %Workspace{status: "active"} ->
          if workspace.salix_router_agent_id == agent_id and
               workspace.salix_tenant_id == fact[:tenant_id] and
               workspace.billing_owner_id == fact[:billing_account_id] do
            listed?(fact.provider, fact.sku)
          else
            {:ok, false}
          end

        _ ->
          {:ok, false}
      end
    else
      {:ok, false}
    end
  end

  def free_call?(_), do: {:ok, false}

  def free_conversation?(workspace, conversation) do
    agent_id = get_in(conversation, ["internal", "billing_context", "salix_agent_id"])

    if is_binary(agent_id) and agent_id == workspace["router_agent_id"] do
      with {:ok, %{models: [_ | _] = models}} <- get(),
           {:ok, config} when is_map(config) <-
             SalixAgent.Templates.resolve_llm_for_agent(agent_id) do
        {provider, sku} =
          BillingCore.LLMMetering.model_key(
            SalixAgent.LLMProvider.provider(config),
            config["model"]
          )

        {:ok, Enum.member?(models, %{"provider" => provider, "sku" => sku})}
      else
        {:ok, %{models: []}} -> {:ok, false}
        {:ok, nil} -> {:ok, false}
        {:error, _} = error -> error
        _ -> {:ok, false}
      end
    else
      {:ok, false}
    end
  end

  defp listed?(provider, sku) do
    {provider, sku} = BillingCore.LLMMetering.model_key(provider, sku)

    with {:ok, policy} <- get() do
      {:ok, Enum.member?(policy.models, %{"provider" => provider, "sku" => sku})}
    end
  end

  defp bounded?(value),
    do: is_binary(value) and byte_size(value) <= 200 and String.trim(value) != ""
end
