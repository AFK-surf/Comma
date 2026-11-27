defmodule BridgeForTeams.ModelsOfferedTest do
  @moduledoc """
  What a swarm model picker offers (`BridgeForTeams.Models.offered/4`): only
  choices the org admins allow that an enabled account of the org serves. A
  plain choice no account serves stops every round it runs
  (`model_unavailable`); a model only API keys serve runs only pay-per-use,
  and only where the admins allow pay-per-use. Each offered choice saves
  (`BridgeForTeams.Models.allowed?/3`).
  """
  use ExUnit.Case, async: true

  alias BridgeForTeams.Models
  alias BridgeForTeams.Schema.Organization

  defp choice(model, paid \\ false),
    do: %{"kind" => "catalog", "model" => model, "allow_paid" => paid}

  defp option(model, label) do
    %{"key" => Models.key(choice(model)), "choice" => choice(model), "label" => label}
    |> Map.put("vendor", nil)
  end

  defp catalog do
    {:ok,
     [
       option("gpt-5.5", "GPT-5.5"),
       option("glm-5", "GLM-5"),
       option("claude-sonnet-5-5", "Claude Sonnet 5.5"),
       option("claude-opus-5-5", "Claude Opus 5.5")
     ]}
  end

  @served {:ok,
           %{
             "gpt-5.5" => %{"served_by" => "subscription", "key_sources" => []},
             "glm-5" => %{"served_by" => "api_key", "key_sources" => ["OpenRouter"]},
             "claude-sonnet-5-5" => %{
               "served_by" => "subscription",
               "key_sources" => ["OpenRouter"]
             },
             "team-model" => %{
               "served_by" => "api_key",
               "key_sources" => ["Team gateway"],
               "label" => "Team model"
             }
           }}

  defp paid_label(option), do: option["label"] <> " (pay-per-use)"
  defp offered(org, served \\ @served), do: Models.offered(org, catalog(), served, &paid_label/1)
  defp keys(options), do: Enum.map(options, & &1["key"])

  test "without an allowed list, offers each served model in the form that runs" do
    org = %Organization{allowed_models: []}
    offered = offered(org)

    assert keys(offered) == [
             "catalog:gpt-5.5",
             "catalog:glm-5+paid",
             "catalog:claude-sonnet-5-5",
             "catalog:claude-sonnet-5-5+paid",
             "catalog:team-model+paid"
           ]

    assert Enum.map(offered, & &1["label"]) == [
             "GPT-5.5",
             "GLM-5 (pay-per-use)",
             "Claude Sonnet 5.5",
             "Claude Sonnet 5.5 (pay-per-use)",
             "Team model (pay-per-use)"
           ]

    # Each catalog choice offered saves: pay-per-use too, at any effort.
    for option <- offered, option["choice"]["model"] != "team-model" do
      assert Models.allowed?(org, option["choice"], catalog()), option["key"]
    end

    assert Models.allowed?(
             org,
             Map.put(choice("glm-5", true), "reasoning_effort", "high"),
             catalog()
           )

    refute Models.allowed?(org, Map.put(choice("glm-5"), "platform", true), catalog())
    refute Models.allowed?(org, choice("glm-5"), {:error, :unavailable})
  end

  test "with an allowed list, offers only its served choices as the admins stored them" do
    org = %Organization{
      allowed_models: [
        choice("gpt-5.5"),
        choice("glm-5"),
        choice("claude-sonnet-5-5", true),
        choice("claude-opus-5-5")
      ]
    }

    # glm-5 only a key serves, and the admins allow it only plain: left out,
    # never turned pay-per-use.
    assert [
             %{"key" => "catalog:gpt-5.5", "label" => "GPT-5.5"},
             %{"key" => "catalog:claude-sonnet-5-5+paid", "label" => sonnet}
           ] = offered(org)

    assert sonnet == "Claude Sonnet 5.5 (pay-per-use)"
    refute Models.allowed?(org, choice("glm-5", true), catalog())
  end

  test "offers every allowed choice when what serves each model is unknown" do
    org = %Organization{allowed_models: []}
    {:ok, options} = catalog()
    assert offered(org, {:error, :truncated}) == options
    assert Models.served?(choice("claude-opus-5-5"), {:error, :unavailable})
    refute Models.served?(choice("claude-opus-5-5"), @served)
    refute Models.served?(choice("gpt-5.5", true), @served)
  end
end
