defmodule SalixWeb.Dashboard.RoutingModels do
  @moduledoc "Model Choices for the Group's route editor."
  alias SalixAgent.{AccountPool, AgentManagement.Ports}
  alias SalixWeb.Dashboard.RoutingForm

  # At most 100 Profiles and 500 catalog models, with their allowed choices.
  # Read on page entry, explicit refresh, and save. No polling or per-model RPC.
  def load(group, tenant) do
    policy = group["task_model_selection"] || %{}

    scope = %{
      tenant_id: tenant,
      group_id: group["group_id"],
      model_profile_id: policy["profile_id"]
    }

    with {:ok, filter} <- Ports.model_filter(scope),
         {:ok, page} <-
           AccountPool.servable_models(tenant,
             limit: 500,
             profile_id: policy["profile_id"],
             filter: filter
           ) do
      options = selectable(page["models"], policy)
      platform = %{"kind" => "platform", "tier" => "worker"}

      options =
        if policy["profile_id"],
          do: options,
          else: [
            %{
              "key" => RoutingForm.model_key(platform),
              "name" => "Platform model",
              "routing_efforts" => [nil]
            }
            | options
          ]

      {:ok, Map.put(page, "models", options)}
    end
  end

  @doc """
  The platform route table's choices: each catalog model (or platform Custom
  endpoint model) that an enabled platform API key serves, as a model of the
  `worker` tier. At most 100 Profiles and 500 models, read on page entry,
  refresh, save and learning.
  """
  def platform_models do
    keys_serve = &Enum.filter(&1, fn model -> model["api_key_sources"] != [] end)

    with {:ok, page} <-
           AccountPool.servable_models(AccountPool.platform_tenant(),
             limit: 500,
             filter: keys_serve
           ) do
      {:ok,
       for model <- page["models"] do
         choice = %{"kind" => "platform", "tier" => "worker", "model" => model["id"]}

         %{
           "key" => RoutingForm.model_key(choice),
           "name" => model["name"],
           "routing_efforts" => Enum.uniq([nil | List.wrap(model["efforts"])])
         }
       end}
    end
  end

  # Use normal Task Model Choices, including payment and Profile
  # restrictions. Each choice keeps its own allowed reasoning efforts.
  def selectable(models, policy) do
    Enum.flat_map(models, fn model ->
      choices = model["choices"] || default_choices(model, policy["profile_id"])
      efforts = Enum.uniq([nil | List.wrap(model["efforts"])])

      choices
      |> Enum.filter(&(is_nil(policy["profile_id"]) or &1["profile_id"] == policy["profile_id"]))
      |> Enum.group_by(fn choice ->
        choice = if policy["profile_id"], do: Map.delete(choice, "profile_id"), else: choice
        RoutingForm.model_key(choice)
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {key, allowed} ->
        offered =
          Enum.filter(efforts, fn effort ->
            Enum.any?(allowed, &(&1["reasoning_effort"] in [nil, effort]))
          end)

        choice = hd(allowed)
        choice = if policy["profile_id"], do: Map.delete(choice, "profile_id"), else: choice

        choice =
          if model["served_by"] == "api_key" and is_binary(policy["profile_id"]),
            do: Map.put(choice, "allow_paid", true),
            else: choice

        label = RoutingForm.model_label(choice, model["name"])

        if offered == [],
          do: [],
          else: [Map.merge(model, %{"key" => key, "name" => label, "routing_efforts" => offered})]
      end)
    end)
  end

  defp default_choices(model, pin) when is_binary(pin),
    do: [%{"kind" => "catalog", "model" => model["id"], "profile_id" => pin}]

  defp default_choices(model, _pin) do
    choice = %{"kind" => "catalog", "model" => model["id"]}

    plain =
      if model["served_by"] == "subscription",
        do: [choice],
        else: []

    if model["served_by"] == "api_key" or model["api_key_sources"] not in [nil, []],
      do: plain ++ [Map.put(choice, "allow_paid", true)],
      else: plain
  end
end
