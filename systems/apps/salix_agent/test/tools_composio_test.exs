defmodule SalixAgent.Tools.ComposioTest do
  @moduledoc """
  Composio integration tools: tenant gating through the
  `SalixAgent.ComposioStore` seam, group-id scoping (Composio user_id =
  group id, foreign accounts read as not_found), the connect → poll →
  active/pending/failed lifecycle, catalog listing/schema fetch, direct
  execution incl. provider-level failure passthrough and output bounding.
  The HTTP client is stubbed via `:composio_client_mod`; agent context via
  `:oauth_store_mod` (shared with the oauth tools).
  """
  use ExUnit.Case, async: false

  alias SalixAgent.Tools.Composio, as: ComposioTools

  @group_id "group-composio-1"
  @tenant "tenant-composio"
  @settings %{"api_key" => "ck_test", "base_url" => ""}
  @ctx %{agent_id: "agent-1", session_id: "sess-1"}

  defmodule StubOAuthStore do
    @moduledoc false
    @behaviour SalixAgent.OAuthStore

    @impl true
    def agent_oauth_context(_agent_id) do
      case Application.get_env(:salix_agent, :composio_test_context) do
        nil -> {:error, :agent_not_found}
        ctx -> {:ok, ctx}
      end
    end

    @impl true
    def provider_app(_tenant, _provider), do: {:error, :not_configured}
    @impl true
    def bindings_for_group(_group_id), do: {:ok, []}
    @impl true
    def public_base_url, do: nil
    @impl true
    def delete_binding(_tenant, _group_id, _binding_id), do: :ok
  end

  defmodule StubComposioStore do
    @moduledoc false
    @behaviour SalixAgent.ComposioStore

    @impl true
    def settings(tenant) do
      case Application.get_env(:salix_agent, :composio_test_settings) do
        %{} = by_tenant -> Map.get(by_tenant, tenant) || {:error, :not_configured}
        nil -> {:error, :not_configured}
      end
    end
  end

  defmodule StubClient do
    @moduledoc "Canned Composio client; records calls, replays :composio_test_responses."

    def list_connected_accounts_all(settings, user_id, opts),
      do: replay(:list_connected_accounts_all, [settings, user_id, opts])

    def ensure_auth_config(settings, toolkit),
      do: replay(:ensure_auth_config, [settings, toolkit])

    def create_connect_link(settings, auth_config_id, user_id, opts \\ []),
      do: replay(:create_connect_link, [settings, auth_config_id, user_id, opts])

    def get_connected_account(settings, id), do: replay(:get_connected_account, [settings, id])

    def delete_connected_account(settings, id),
      do: replay(:delete_connected_account, [settings, id])

    def list_tools(settings, opts), do: replay(:list_tools, [settings, opts])

    def list_toolkits(settings, opts), do: replay(:list_toolkits, [settings, opts])

    def execute_tool(settings, tool_slug, user_id, arguments, opts \\ []),
      do: replay(:execute_tool, [settings, tool_slug, user_id, arguments, opts])

    defp replay(fun, args) do
      pid = Application.get_env(:salix_agent, :composio_test_pid)
      if pid, do: send(pid, {:composio_call, fun, args})

      responses = Application.get_env(:salix_agent, :composio_test_responses, %{})

      case Map.fetch(responses, fun) do
        {:ok, response} when is_function(response) -> apply(response, args)
        {:ok, response} -> response
        :error -> raise "no stubbed response for #{fun}"
      end
    end
  end

  @seam_keys [
    :oauth_store_mod,
    :composio_store_mod,
    :composio_client_mod,
    :composio_test_context,
    :composio_test_settings,
    :composio_test_responses,
    :composio_test_pid
  ]

  setup do
    prev = Map.new(@seam_keys, &{&1, Application.get_env(:salix_agent, &1)})

    Application.put_env(:salix_agent, :oauth_store_mod, StubOAuthStore)
    Application.put_env(:salix_agent, :composio_store_mod, StubComposioStore)
    Application.put_env(:salix_agent, :composio_client_mod, StubClient)

    Application.put_env(:salix_agent, :composio_test_context, %{
      tenant: @tenant,
      group_id: @group_id
    })

    Application.put_env(:salix_agent, :composio_test_settings, %{@tenant => {:ok, @settings}})
    Application.put_env(:salix_agent, :composio_test_pid, self())

    on_exit(fn ->
      Enum.each(prev, fn
        {key, nil} -> Application.delete_env(:salix_agent, key)
        {key, value} -> Application.put_env(:salix_agent, key, value)
      end)
    end)

    :ok
  end

  defp stub_responses(map), do: Application.put_env(:salix_agent, :composio_test_responses, map)

  # ---- gating ----

  test "every tool reports an unconfigured tenant with the oauth fallback hint" do
    Application.put_env(:salix_agent, :composio_test_settings, %{})

    for fun <- [
          &ComposioTools.list_connections/2,
          &ComposioTools.request_connection/2,
          &ComposioTools.execute/2
        ] do
      err =
        assert_raise RuntimeError, fn ->
          fun.(%{"toolkit" => "gmail", "tool_slug" => "X"}, @ctx)
        end

      assert err.message =~ "composio is not configured for this tenant"
      assert err.message =~ "oauth.*"
    end
  end

  test "a runtime without a composio store seam reports not configured" do
    Application.put_env(:salix_agent, :composio_store_mod, nil)

    err = assert_raise RuntimeError, fn -> ComposioTools.list_connections(%{}, @ctx) end
    assert err.message =~ "composio is not configured"
  end

  # ---- list_connections ----

  test "list_connections lists the group's accounts sorted by toolkit" do
    stub_responses(%{
      list_connected_accounts_all:
        {:ok,
         [
           %{
             "id" => "ca_2",
             "toolkit" => %{"slug" => "notion"},
             "status" => "INITIATED",
             "status_reason" => nil
           },
           %{"id" => "ca_1", "toolkit" => %{"slug" => "gmail"}, "status" => "ACTIVE"}
         ]}
    })

    out = ComposioTools.list_connections(%{}, @ctx) |> Jason.decode!()

    assert [
             %{"connected_account_id" => "ca_1", "toolkit" => "gmail", "status" => "ACTIVE"},
             %{"connected_account_id" => "ca_2", "toolkit" => "notion", "status" => "INITIATED"}
           ] = out["connections"]

    assert_received {:composio_call, :list_connected_accounts_all,
                     [@settings, @group_id, [page_limit: 100, max_pages: 10]]}
  end

  test "list_connections fails closed instead of returning an incomplete account set" do
    stub_responses(%{
      list_connected_accounts_all: {:error, :connected_accounts_page_limit_exceeded}
    })

    error =
      assert_raise RuntimeError, fn ->
        ComposioTools.list_connections(%{}, @ctx)
      end

    assert error.message =~ "connected_accounts_page_limit_exceeded"

    assert_received {:composio_call, :list_connected_accounts_all,
                     [@settings, @group_id, [page_limit: 100, max_pages: 10]]}
  end

  # ---- request_connection ----

  test "request_connection resolves an auth config, returns the connect link, and sets a wait" do
    stub_responses(%{
      ensure_auth_config: {:ok, "ac_1"},
      create_connect_link:
        {:ok,
         %{
           "redirect_url" => "https://connect.composio.dev/link/ln_1",
           "connected_account_id" => "ca_new",
           "expires_at" => "2026-07-05T12:00:00Z"
         }}
    })

    {content, events} = ComposioTools.request_connection(%{"toolkit" => "Gmail"}, @ctx)
    out = Jason.decode!(content)

    assert out["status"] == "pending"
    assert out["toolkit"] == "gmail"
    assert out["connected_account_id"] == "ca_new"
    assert out["redirect_url"] == "https://connect.composio.dev/link/ln_1"

    # The session waits for the user to complete the browser flow; the wait's
    # source is NOT auto_wait, so the dispatcher does not drop/re-batch it.
    assert [%{"type" => "wait_set", "session_id" => "sess-1", "wait" => wait}] = events
    assert wait["source"] == "composio_connection"
    assert wait["reason"] == "composio connection: gmail"
    assert wait["connected_account_id"] == "ca_new"
    assert is_integer(wait["deadline_ms"])

    assert_received {:composio_call, :ensure_auth_config, [@settings, "gmail"]}
    assert_received {:composio_call, :create_connect_link, [@settings, "ac_1", @group_id, []]}
  end

  # ---- check_connection ----

  test "check_connection maps ACTIVE / INITIATED / FAILED statuses" do
    for {provider_status, expected} <- [
          {"ACTIVE", "active"},
          {"INITIATED", "pending"},
          {"INITIALIZING", "pending"},
          {"FAILED", "failed"}
        ] do
      stub_responses(%{
        get_connected_account:
          {:ok,
           %{
             "id" => "ca_1",
             "user_id" => @group_id,
             "status" => provider_status,
             "toolkit" => %{"slug" => "gmail"}
           }}
      })

      out =
        ComposioTools.check_connection(%{"connected_account_id" => "ca_1"}, @ctx)
        |> Jason.decode!()

      assert out["status"] == expected, "#{provider_status} should map to #{expected}"
    end
  end

  test "check_connection hides other groups' accounts as not_found" do
    stub_responses(%{
      get_connected_account:
        {:ok, %{"id" => "ca_foreign", "user_id" => "other-group", "status" => "ACTIVE"}}
    })

    out =
      ComposioTools.check_connection(%{"connected_account_id" => "ca_foreign"}, @ctx)
      |> Jason.decode!()

    assert out["status"] == "not_found"
  end

  # ---- delete_connection ----

  test "delete_connection verifies ownership before deleting" do
    stub_responses(%{
      get_connected_account:
        {:ok, %{"id" => "ca_1", "user_id" => @group_id, "status" => "ACTIVE"}},
      delete_connected_account: :ok
    })

    out =
      ComposioTools.delete_connection(%{"connected_account_id" => "ca_1"}, @ctx)
      |> Jason.decode!()

    assert out["status"] == "deleted"
    assert_received {:composio_call, :delete_connected_account, [@settings, "ca_1"]}
  end

  test "delete_connection of a foreign or missing account is not_found and does not delete" do
    stub_responses(%{
      get_connected_account: {:ok, %{"id" => "ca_x", "user_id" => "other-group"}},
      delete_connected_account: :ok
    })

    out =
      ComposioTools.delete_connection(%{"connected_account_id" => "ca_x"}, @ctx)
      |> Jason.decode!()

    assert out["status"] == "not_found"
    refute_received {:composio_call, :delete_connected_account, _}
  end

  # ---- list_tools / get_tool ----

  test "list_tools requires a toolkit or query and trims long descriptions" do
    assert_raise RuntimeError, ~r/at least one of 'toolkit' or 'query'/, fn ->
      ComposioTools.list_tools(%{}, @ctx)
    end

    stub_responses(%{
      list_tools:
        {:ok,
         [
           %{
             "slug" => "GMAIL_FETCH_EMAILS",
             "name" => "Fetch emails",
             "description" => String.duplicate("d", 400)
           }
         ]}
    })

    out = ComposioTools.list_tools(%{"toolkit" => "gmail"}, @ctx) |> Jason.decode!()

    assert [%{"tool_slug" => "GMAIL_FETCH_EMAILS", "description" => desc}] = out["tools"]
    assert String.length(desc) == 301

    assert_received {:composio_call, :list_tools, [@settings, opts]}
    assert opts[:toolkit] == "gmail"
    assert opts[:limit] == 20
  end

  test "get_tool returns the full input schema" do
    stub_responses(%{
      list_tools:
        {:ok,
         [
           %{
             "slug" => "GMAIL_FETCH_EMAILS",
             "name" => "Fetch emails",
             "description" => "Fetch emails from Gmail",
             "toolkit" => %{"slug" => "gmail"},
             "input_parameters" => %{
               "type" => "object",
               "properties" => %{"max_results" => %{"type" => "integer"}}
             }
           }
         ]}
    })

    out = ComposioTools.get_tool(%{"tool_slug" => "gmail_fetch_emails"}, @ctx) |> Jason.decode!()

    assert out["tool_slug"] == "GMAIL_FETCH_EMAILS"
    assert out["input_parameters"]["properties"]["max_results"]

    assert_received {:composio_call, :list_tools, [@settings, opts]}
    assert opts[:tool_slugs] == "GMAIL_FETCH_EMAILS"
  end

  # ---- list_toolkits ----

  test "list_toolkits searches the catalog and returns slim entries" do
    stub_responses(%{
      list_toolkits:
        {:ok,
         [
           %{
             "slug" => "googlecalendar",
             "name" => "Google Calendar",
             "meta" => %{"description" => String.duplicate("d", 400), "tools_count" => 24}
           }
         ]}
    })

    out =
      ComposioTools.list_toolkits_catalog(%{"query" => "calendar"}, @ctx) |> Jason.decode!()

    assert [entry] = out["toolkits"]
    assert entry["toolkit"] == "googlecalendar"
    assert entry["tools_count"] == 24
    assert String.length(entry["description"]) == 301
    assert out["usage"] =~ "composio.request_connection"

    assert_received {:composio_call, :list_toolkits, [@settings, opts]}
    assert opts[:search] == "calendar"
    assert opts[:limit] == 20
  end

  # ---- execute ----

  test "execute posts the group id and returns the provider data inline" do
    stub_responses(%{
      execute_tool:
        {:ok,
         %{
           "data" => %{"messages" => [%{"subject" => "hello"}]},
           "successful" => true,
           "error" => nil,
           "log_id" => "log_1"
         }}
    })

    out =
      ComposioTools.execute(
        %{"tool_slug" => "GMAIL_FETCH_EMAILS", "arguments" => %{"max_results" => 1}},
        @ctx
      )
      |> Jason.decode!()

    assert out["successful"] == true
    assert out["data"]["messages"] == [%{"subject" => "hello"}]
    assert out["log_id"] == "log_1"

    assert_received {:composio_call, :execute_tool,
                     [@settings, "GMAIL_FETCH_EMAILS", @group_id, %{"max_results" => 1}, []]}
  end

  test "execute passes provider-level failure through instead of raising" do
    stub_responses(%{
      execute_tool: {:ok, %{"data" => %{}, "successful" => false, "error" => "missing scopes"}}
    })

    out = ComposioTools.execute(%{"tool_slug" => "GMAIL_FETCH_EMAILS"}, @ctx) |> Jason.decode!()

    assert out["successful"] == false
    assert out["error"] == "missing scopes"
  end

  test "execute preserves oversized provider payloads for the session projection layer" do
    big = String.duplicate("x", 150_000)

    stub_responses(%{
      execute_tool:
        {:ok,
         %{
           "data" => %{"blob" => big},
           "successful" => true,
           "log_id" => "log_large"
         }}
    })

    encoded = ComposioTools.execute(%{"tool_slug" => "GMAIL_FETCH_EMAILS"}, @ctx)
    out = Jason.decode!(encoded)

    assert byte_size(encoded) > 150_000
    assert out["data"]["blob"] == big
    assert out["log_id"] == "log_large"
    refute Map.has_key?(out, "truncated")
  end

  test "execute rejects non-object arguments" do
    assert_raise RuntimeError, ~r/'arguments' must be a JSON object/, fn ->
      ComposioTools.execute(%{"tool_slug" => "X", "arguments" => "nope"}, @ctx)
    end
  end

  test "execute refuses a pinned account owned by another group before provider execution" do
    stub_responses(%{
      get_connected_account: {:ok, %{"user_id" => "foreign", "status" => "ACTIVE"}}
    })

    assert_raise RuntimeError, ~r/not found in this group/, fn ->
      ComposioTools.execute(
        %{"tool_slug" => "GMAIL_FETCH_EMAILS", "connected_account_id" => "ca_foreign"},
        @ctx
      )
    end

    refute_received {:composio_call, :execute_tool, _}
  end

  # ---- registry ----

  test "Inspector dispatch permits the pinned read and refuses mutations and alternate accounts" do
    stub_responses(%{
      get_connected_account: {:ok, %{"user_id" => @group_id, "status" => "ACTIVE"}},
      execute_tool: {:ok, %{"data" => %{"id" => "issue-1"}, "successful" => true}}
    })

    ctx =
      @ctx
      |> Map.merge(%{
        role: "worker",
        runtime_kind: :internal,
        llm_tool_envelope: true,
        ifc_mode: :off
      })
      |> SalixAgent.TestSupport.with_plugin_projection()

    # An old or overly broad catalog is not authority to bypass dispatch.
    disclosure = SalixAgent.ToolDisclosure.materialize_static("worker", :internal, ctx)

    ctx =
      ctx
      |> Map.put(:tool_disclosure, disclosure)
      |> Map.put(:inspector_policy, SalixAgent.TestSupport.inspector_policy())

    read = %{
      "tool_slug" => "LINEAR_GET_LINEAR_ISSUE",
      "connected_account_id" => "ca-inspection-linear",
      "arguments" => %{"issue_id" => "issue-1"}
    }

    run = fn args ->
      [result] =
        SalixAgent.SessionToolDispatch.execute(
          [
            %{
              id: "inspect",
              name: "call",
              args: %{"tool" => "composio.execute", "params" => args}
            }
          ],
          ctx
        )

      result
    end

    read_result = run.(read)
    refute read_result.error, inspect(read_result)

    assert_received {:composio_call, :execute_tool,
                     [
                       @settings,
                       "LINEAR_GET_LINEAR_ISSUE",
                       @group_id,
                       %{"issue_id" => "issue-1"},
                       [connected_account_id: "ca-inspection-linear"]
                     ]}

    query = SalixAgent.InspectorPolicy.linear_queries()["project"]
    query_args = %{"query_or_mutation" => query, "variables" => %{"id" => "project-1"}}

    project_read = %{
      read
      | "tool_slug" => "LINEAR_RUN_QUERY_OR_MUTATION",
        "arguments" => query_args
    }

    refute run.(project_read).error

    assert_received {:composio_call, :execute_tool,
                     [
                       @settings,
                       "LINEAR_RUN_QUERY_OR_MUTATION",
                       @group_id,
                       ^query_args,
                       [connected_account_id: "ca-inspection-linear"]
                     ]}

    for forbidden <- [
          Map.put(read, "tool_slug", "LINEAR_UPDATE_ISSUE"),
          Map.put(read, "tool_slug", "LINEAR_RUN_QUERY_OR_MUTATION"),
          Map.put(read, "tool_slug", "LINEAR_LIST_LINEAR_PROJECTS"),
          Map.put(read, "connected_account_id", "ca-somebody-else"),
          Map.delete(read, "connected_account_id"),
          %{
            project_read
            | "arguments" => %{
                query_args
                | "query_or_mutation" =>
                    query <> " mutation { issueDelete(id: \"x\") { success } }"
              }
          },
          %{project_read | "arguments" => Map.put(query_args, "override", "mutation")},
          %{read | "tool_slug" => "LINEAR_LIST_LINEAR_ISSUES", "arguments" => %{"first" => 20}},
          %{
            read
            | "tool_slug" => "LINEAR_LIST_LINEAR_ISSUES",
              "arguments" => %{"project_id" => "p", "first" => 101}
          }
        ] do
      assert %{error: true, error_class: "forbidden", events: []} = run.(forbidden)
      refute_received {:composio_call, :execute_tool, _}
    end

    [ordinary] =
      SalixAgent.SessionToolDispatch.execute(
        [
          %{
            id: "ordinary",
            name: "call",
            args: %{
              "tool" => "composio.execute",
              "params" => Map.put(read, "tool_slug", "LINEAR_UPDATE_ISSUE")
            }
          }
        ],
        Map.delete(ctx, :inspector_policy)
      )

    refute ordinary.error

    assert_received {:composio_call, :execute_tool,
                     [@settings, "LINEAR_UPDATE_ISSUE", @group_id, _, _]}
  end

  test "composio tools are registered with schemas" do
    specs = SalixAgent.Tools.specs()
    by_name = Map.new(specs, &{&1["name"], &1})

    for name <- [
          "composio.list_connections",
          "composio.request_connection",
          "composio.check_connection",
          "composio.delete_connection",
          "composio.list_tools",
          "composio.get_tool",
          "composio.execute",
          "composio.list_toolkits"
        ] do
      assert %{"input_schema" => %{"type" => "object"}} = by_name[name], "#{name} missing"
    end
  end
end
