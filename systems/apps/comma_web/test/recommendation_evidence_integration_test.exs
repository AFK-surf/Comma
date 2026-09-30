defmodule CommaWeb.RecommendationEvidenceIntegrationTest do
  use Comma.DataCase, async: false

  alias Comma.Data.{RecommendationRun, Workspace, WorkspaceMembership}
  alias Comma.{Recommendations, Repo}
  alias CommaWeb.RecommendationSourceCollector
  alias SalixStore.Ids

  defmodule Settings do
    def settings(_tenant_id), do: {:ok, %{"api_key" => "test"}}
  end

  defmodule Client do
    def execute_tool(_settings, _tool_slug, _group_id, _arguments, _opts) do
      {:ok,
       %{
         "successful" => true,
         "data" => Application.fetch_env!(:comma_web, :recommendation_evidence_provider_data)
       }}
    end
  end

  setup do
    keys = [
      :recommendation_composio_client_mod,
      :recommendation_composio_settings_mod,
      :recommendation_evidence_provider_data
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:comma_web, &1)})
    Application.put_env(:comma_web, :recommendation_composio_client_mod, Client)
    Application.put_env(:comma_web, :recommendation_composio_settings_mod, Settings)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:comma_web, key)
        {key, value} -> Application.put_env(:comma_web, key, value)
      end)
    end)

    :ok
  end

  test "a renderer-visible URL beyond index 256 remains publishable" do
    urls = for index <- 0..279, do: "https://linear.app/cm/CM-#{pad(index)}"
    target_url = List.last(urls)

    Application.put_env(:comma_web, :recommendation_evidence_provider_data, %{
      "issues" => %{
        "nodes" => Enum.map(urls, &%{"url" => &1})
      },
      "zzPadding" => String.duplicate("x", 30_000)
    })

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "recommendation-evidence-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_active_workspace!(user)
    assert {:ok, _envelope} = Recommendations.get(user, %{}, workspace["id"], "Etc/UTC")

    assert {:ok, profile} =
             Recommendations.set_relevance_mode(user, %{}, workspace["id"], "generic")

    discovered = %{
      "appId" => "linear",
      "appName" => "Linear",
      "connectionId" => "ca-linear",
      "kind" => "composio",
      "label" => "Linear",
      "toolkit" => "linear"
    }

    assert {:ok, profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [discovered])

    [source] = profile.sources
    assert source["enabled"] == true

    assert {:ok, %{facts: [fact], failures: []}} =
             RecommendationSourceCollector.collect(workspace, [source])

    assert fact["data"]["_comma"]["truncated"] == true
    assert fact["data"]["_comma"]["originalBytes"] > 12_000
    assert Jason.encode!(fact["data"]) =~ target_url
    assert byte_size(Jason.encode!(fact["data"])) <= 12_000

    assert {:ok, %{run: run}} =
             Recommendations.request_refresh(user, %{}, workspace["id"], "manual")

    assert {:ok, recorded} = Recommendations.record_source_evidence(run["id"], [fact])
    assert target_url in recorded.source_evidence[source["connectionId"]]
    assert recorded.source_evidence_recorded == true

    assert {:ok, {:published, _envelope}} =
             Recommendations.publish(run["id"], snapshot(run, source, target_url))

    settled = Repo.get!(RecommendationRun, run["id"])
    assert settled.status == "published"
    assert settled.source_evidence == %{}
    assert settled.source_evidence_recorded == false
  end

  defp snapshot(run, source, target_url) do
    %{
      "cards" => [
        %{
          "fallbackText" => "Review #{target_url}",
          "id" => "linear",
          "items" => [
            %{
              "action" => %{
                "label" => "Review issue",
                "prompt" => "Review the Linear issue",
                "requiresConfirmation" => false,
                "type" => "open_task_form"
              },
              "id" => "linear-279",
              "parts" => [
                %{
                  "kind" => "inline-link",
                  "link" => %{
                    "href" => target_url,
                    "label" => "COMMA-279",
                    "sourceId" => source["connectionId"]
                  }
                }
              ]
            }
          ],
          "sourceIds" => [source["connectionId"]],
          "template" => "text-list@1",
          "title" => "Linear"
        }
      ],
      "generatedAt" => System.system_time(:millisecond),
      "generation" => run["generation"],
      "protocolVersion" => 1,
      "sourceRevision" => run["sourceRevision"],
      "summary" => [
        %{"kind" => "markdown", "text" => "Review "},
        %{
          "kind" => "inline-link",
          "link" => %{
            "href" => target_url,
            "label" => "COMMA-279",
            "sourceId" => source["connectionId"]
          }
        }
      ],
      "templateCatalogVersion" => 1,
      "warnings" => []
    }
  end

  defp create_active_workspace!(user) do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        id: "wsp-recommendation-evidence-#{System.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant_id,
        salix_group_id: group_id,
        group_generation: "generation-1",
        salix_router_agent_id: Ids.new_agent_id(group_id),
        salix_worker_agent_id: Ids.new_agent_id(group_id),
        billing_owner_id: "billing-#{user["id"]}",
        name: "Recommendation evidence",
        status: "active"
      })
      |> Repo.insert!()

    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: "owner",
      status: "active"
    })
    |> Repo.insert!()

    assert {:ok, public_workspace} = Comma.Workspaces.get(workspace.id)
    public_workspace
  end

  defp pad(index), do: index |> Integer.to_string() |> String.pad_leading(3, "0")
end
