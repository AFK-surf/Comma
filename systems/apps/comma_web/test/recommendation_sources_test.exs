defmodule CommaWeb.RecommendationSourcesTest do
  use ExUnit.Case, async: false

  alias CommaWeb.RecommendationSourceCatalog
  alias Salix.Control.{Groups, Tenants}

  defmodule StubComposio do
    def get(_tenant), do: {:ok, %{}}

    def list_connected_accounts_all(settings, group_id),
      do: list_connected_accounts(settings, group_id)

    def list_connected_accounts(_settings, _group),
      do:
        Application.get_env(
          :comma_web,
          :recommendation_source_result,
          {:ok, Application.get_env(:comma_web, :recommendation_source_accounts, [])}
        )
  end

  setup do
    previous_store = Application.get_env(:salix_store, :s3_backend)
    previous_composio_settings = Application.get_env(:salix_web, :composio_settings_mod)
    previous_composio_client = Application.get_env(:salix_web, :composio_client_mod)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_web, :composio_settings_mod, StubComposio)
    Application.put_env(:salix_web, :composio_client_mod, StubComposio)
    Application.put_env(:comma_web, :recommendation_source_accounts, [])

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      if previous_store,
        do: Application.put_env(:salix_store, :s3_backend, previous_store),
        else: Application.delete_env(:salix_store, :s3_backend)

      restore_env(:salix_web, :composio_settings_mod, previous_composio_settings)
      restore_env(:salix_web, :composio_client_mod, previous_composio_client)
      Application.delete_env(:comma_web, :recommendation_source_accounts)
      Application.delete_env(:comma_web, :recommendation_source_result)
    end)

    assert {:ok, _} = SalixMCP.Builtins.seed_builtin_definitions()
    assert {:ok, tenant} = Tenants.create(%{"name" => "Recommendation source test"})

    assert {:ok, group} =
             Groups.create(%{"name" => "Recommendation source test"}, tenant["tenant_id"])

    %{tenant_id: tenant["tenant_id"], group_id: group["group_id"]}
  end

  test "native OAuth discovery does not require Composio configuration", context do
    Application.put_env(:comma_web, :recommendation_source_result, {:error, :not_configured})

    assert {:ok, []} =
             CommaWeb.RecommendationSources.discover(%{
               "salix_tenant_id" => context.tenant_id,
               "default_group_id" => context.group_id
             })
  end

  test "native sources collect through scoped credentials without Composio", context do
    Application.put_env(:comma_web, :recommendation_source_result, {:error, :not_configured})
    previous = Application.get_env(:comma_web, :recommendation_oauth_http_options)

    Application.put_env(:comma_web, :recommendation_oauth_http_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn -> restore_env(:comma_web, :recommendation_oauth_http_options, previous) end)
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.host do
        "api.github.com" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer github-test"]
          assert conn.query_string =~ "per_page=12"

          Req.Test.json(conn, [
            %{
              "subject" => %{
                "title" => "Review",
                "url" => "https://api.github.com/repos/comma/app/pulls/1"
              }
            }
          ])

        "api.linear.app" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer linear-test"]

          Req.Test.json(conn, %{
            "data" => %{
              "issues" => %{
                "nodes" => [
                  %{"title" => "Issue", "url" => "https://linear.app/comma/issue/COMMA-1"}
                ]
              }
            }
          })

        "api.notion.com" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer notion-test"]

          Req.Test.json(conn, %{
            "results" => [
              %{"id" => "4b8e7d0d-9f1a-4ed8-9d6b-a8d11080a812", "url" => "https://notion.so/page"}
            ]
          })
      end
    end)

    for provider <- ~w(github linear notion) do
      connection = "#{context.group_id}-#{provider}"

      :ok =
        SalixStore.OAuth.put(connection, %{
          "connection_id" => connection,
          "tenant" => context.tenant_id,
          "provider" => provider,
          "access_token" => "#{provider}-test",
          "scopes" => ~w(repo read:org read write),
          "status" => "active"
        })

      assert {:ok, _, nil} =
               Salix.Control.OAuthBindings.put(
                 context.tenant_id,
                 context.group_id,
                 provider,
                 provider,
                 connection
               )
    end

    workspace = %{"salix_tenant_id" => context.tenant_id, "default_group_id" => context.group_id}
    assert {:ok, sources} = CommaWeb.RecommendationSources.discover(workspace)
    assert Enum.map(sources, & &1["appId"]) == ~w(github linear notion)
    assert Enum.all?(sources, &(&1["kind"] == "managed_oauth" and is_binary(&1["label"])))

    assert {:ok, %{facts: facts, failures: []}} =
             CommaWeb.RecommendationSourceCollector.collect(
               workspace,
               Enum.map(sources, &Map.put(&1, "enabled", true))
             )

    assert length(facts) == 3

    [source | _] = sources

    assert {:error, :oauth_source_unavailable} =
             CommaWeb.RecommendationOAuthSource.read(
               Map.put(workspace, "default_group_id", "another-group"),
               source
             )

    assert {:error, :oauth_source_unavailable} =
             CommaWeb.RecommendationOAuthSource.read(
               Map.put(workspace, "salix_tenant_id", "another-tenant"),
               source
             )

    assert {:ok, _} =
             Salix.Control.OAuthBindings.update(context.group_id, source["connectionId"], %{
               "enabled" => false
             })

    assert {:error, :oauth_source_unavailable} =
             CommaWeb.RecommendationOAuthSource.read(workspace, source)

    assert {:ok, remaining} = CommaWeb.RecommendationSources.discover(workspace)
    assert length(remaining) == 2
  end

  test "Slack discovery selects the managed binding while retaining the old Composio account",
       context do
    old = %{
      "id" => "ca_slack",
      "user_id" => context.group_id,
      "toolkit" => %{"slug" => "slack"},
      "status" => "ACTIVE"
    }

    Application.put_env(:comma_web, :recommendation_source_accounts, [old])
    connection = "#{context.group_id}-slack"

    :ok =
      SalixStore.OAuth.put(connection, %{
        "connection_id" => connection,
        "tenant" => context.tenant_id,
        "provider" => "slack",
        "access_token" => "slack-test",
        "status" => "active"
      })

    assert {:ok, binding, nil} =
             Salix.Control.OAuthBindings.put(
               context.tenant_id,
               context.group_id,
               "slack",
               "slack",
               connection
             )

    workspace = %{"salix_tenant_id" => context.tenant_id, "default_group_id" => context.group_id}

    assert {:ok, [%{"kind" => "managed_oauth", "appId" => "slack"} = source]} =
             CommaWeb.RecommendationSources.discover(workspace)

    assert source["connectionId"] == binding["binding_id"]
    assert Application.get_env(:comma_web, :recommendation_source_accounts) == [old]
  end

  test "an active Composio account with the real nested toolkit shape is exposed", context do
    Application.put_env(:comma_web, :recommendation_source_accounts, [
      %{
        "id" => "ca_slack",
        "user_id" => context.group_id,
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      }
    ])

    assert {:ok, [source]} =
             CommaWeb.RecommendationSources.discover(%{
               "salix_tenant_id" => context.tenant_id,
               "default_group_id" => context.group_id
             })

    assert source["connectionId"] == "ca_slack"
    assert source["kind"] == "composio"
    assert source["toolkit"] == "slack"
  end

  test "re-authorized toolkits expose only their newest active account", context do
    Application.put_env(:comma_web, :recommendation_source_accounts, [
      %{
        "id" => "ca_googledrive_old",
        "user_id" => context.group_id,
        "toolkit" => %{"slug" => "googledrive"},
        "status" => "ACTIVE",
        "created_at" => "2026-09-01T08:00:00.000Z",
        "updated_at" => "2026-09-11T06:00:00.000Z"
      },
      %{
        "id" => "ca_googledrive_new",
        "user_id" => context.group_id,
        "toolkit" => %{"slug" => "googledrive"},
        "status" => "ACTIVE",
        "created_at" => "2026-09-10T08:00:00.000Z",
        "updated_at" => "2026-09-10T08:00:00.000Z"
      },
      %{
        "id" => "ca_gmail_pending",
        "user_id" => context.group_id,
        "toolkit" => %{"slug" => "gmail"},
        "status" => "INITIATED",
        "created_at" => "2026-09-11T07:00:00.000Z"
      },
      %{
        "id" => "ca_gmail",
        "user_id" => context.group_id,
        "toolkit" => %{"slug" => "gmail"},
        "status" => "ACTIVE",
        "created_at" => "2026-09-09T08:00:00.000Z"
      }
    ])

    assert {:ok, sources} =
             CommaWeb.RecommendationSources.discover(%{
               "salix_tenant_id" => context.tenant_id,
               "default_group_id" => context.group_id
             })

    # Authorization time decides; a later token refresh on the old account does not.
    assert Enum.map(sources, &{&1["toolkit"], &1["connectionId"]}) == [
             {"gmail", "ca_gmail"},
             {"googledrive", "ca_googledrive_new"}
           ]

    # Settings rows show the product name, not the toolkit slug.
    assert Enum.map(sources, & &1["appName"]) == ["Gmail", "Google Drive"]
  end

  test "without timestamps the first listed account of a toolkit is the newest", context do
    Application.put_env(:comma_web, :recommendation_source_accounts, [
      %{
        "id" => "ca_slack_first",
        "user_id" => context.group_id,
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      },
      %{
        "id" => "ca_slack_second",
        "user_id" => context.group_id,
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      }
    ])

    assert {:ok, [source]} =
             CommaWeb.RecommendationSources.discover(%{
               "salix_tenant_id" => context.tenant_id,
               "default_group_id" => context.group_id
             })

    assert source["connectionId"] == "ca_slack_first"
  end

  test "an active Composio account without an executable recipe is not exposed", context do
    Application.put_env(:comma_web, :recommendation_source_accounts, [
      %{
        "id" => "ca-jira",
        "user_id" => context.group_id,
        "toolkit" => %{"slug" => "jira"},
        "status" => "ACTIVE"
      }
    ])

    assert {:ok, []} =
             CommaWeb.RecommendationSources.discover(%{
               "salix_tenant_id" => context.tenant_id,
               "default_group_id" => context.group_id
             })
  end

  test "every supported Composio toolkit has an executable recipe" do
    assert Enum.all?(RecommendationSourceCatalog.supported_composio_toolkits(), fn toolkit ->
             match?(
               {:ok, {tool_slug, arguments}}
               when is_binary(tool_slug) and is_map(arguments),
               RecommendationSourceCatalog.recipe(toolkit, ~U[2026-08-18 01:00:00Z])
             )
           end)
  end

  test "a Composio registry outage is explicit instead of looking disconnected", context do
    Application.put_env(
      :comma_web,
      :recommendation_source_result,
      {:error, :registry_unavailable}
    )

    assert {:error, {:composio_source_discovery_failed, :registry_unavailable}} =
             CommaWeb.RecommendationSources.discover(%{
               "salix_tenant_id" => context.tenant_id,
               "default_group_id" => context.group_id
             })
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
