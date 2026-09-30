defmodule SalixWeb.RouterTest do
  @moduledoc """
  End-to-end HTTP test: POST a message over HTTP,
  the inbox protocol stages + wakes the runtime, the round runs (mock LLM +
  tools), and GET returns the committed transcript. Also auth + 404.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.LLM.Mock
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State, as: InternalSessionState
  alias SalixAgent.InternalSessionStore
  alias Salix.Control.{OAuthBindings, Plugins}
  alias SalixMCP.Store, as: MCPStore
  alias SalixStore.RuntimeIds
  alias SalixIM.ProviderConnects
  alias SalixStore.{AgentVMM, Compute, Ids, Keys, Repo, S3}
  alias SalixWeb.TestSupport.ProtectedMCP

  @host {127, 0, 0, 1}

  defmodule MockTrajectoryEvalQueries do
    @moduledoc false
    use Agent

    def start_link(_opts),
      do: Agent.start_link(fn -> %{rows: [], requests: []} end, name: __MODULE__)

    def set_rows(rows), do: Agent.update(__MODULE__, &%{&1 | rows: rows})
    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

    def confirmed_windows(tenant_id, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        {{:ok, state.rows}, %{state | requests: [{tenant_id, opts} | state.requests]}}
      end)
    end
  end

  defmodule MockSlackOAuth do
    @moduledoc "Recording mock of Slack OAuth's form-encoded Web API."
    use Agent
    import Plug.Conn

    def start_link(_ \\ []),
      do:
        Agent.start_link(fn -> %{response: default_response(), requests: []} end,
          name: __MODULE__
        )

    def respond(body), do: Agent.update(__MODULE__, &%{&1 | response: body})
    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      ["api", method] = conn.path_info

      req = %{
        method: method,
        params: URI.decode_query(raw),
        auth: conn |> get_req_header("authorization") |> List.first()
      }

      Agent.update(__MODULE__, fn s -> %{s | requests: [req | s.requests]} end)

      body =
        if method == "auth.test" do
          %{
            "ok" => true,
            "bot_id" => "B-BOT",
            "user_id" => "B-SLACK",
            "user" => "comma_slack_bot",
            "team_id" => "T-SLACK"
          }
        else
          Agent.get(__MODULE__, & &1.response)
        end

      body = if is_function(body, 1), do: body.(req), else: body
      body = if is_function(body, 0), do: body.(), else: body

      conn
      |> put_resp_header("date", "Thu, 16 Jul 2026 04:00:00 GMT")
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end

    defp default_response do
      %{
        "ok" => true,
        "access_token" => "xoxb-oauth-token",
        "scope" => "canvases:write,chat:write,chat:write",
        "bot_user_id" => "B-SLACK",
        "team" => %{"id" => "T-SLACK", "name" => "Slack Test"},
        "authed_user" => %{"id" => "U-OWNER"}
      }
    end
  end

  defmodule MockIMProviderAPI do
    @moduledoc "Mock Telegram getMe and Feishu tenant-token validation APIs."
    use Agent
    import Plug.Conn

    def start_link(_ \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)

    def requests, do: Agent.get(__MODULE__, &Enum.reverse/1)

    def init(opts), do: opts

    def call(%{method: "GET", path_info: ["telegram", "bot" <> token, "getMe"]} = conn, _opts) do
      record(%{provider: "telegram", token: token})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(telegram_get_me(token)))
    end

    def call(
          %{
            method: "POST",
            path_info: ["open-apis", "auth", "v3", "tenant_access_token", "internal"]
          } =
            conn,
          _opts
        ) do
      {:ok, raw, conn} = read_body(conn)
      params = Jason.decode!(raw)
      record(%{provider: "feishu", params: params})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "code" => 0,
          "msg" => "ok",
          "tenant_access_token" => "tenant-token-" <> params["app_id"]
        })
      )
    end

    def call(conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, Jason.encode!(%{"error" => "not found"}))
    end

    defp telegram_get_me("123456:updated-token") do
      %{
        "ok" => true,
        "result" => %{
          "id" => 1002,
          "is_bot" => true,
          "first_name" => "Bridge Updated",
          "username" => "bridge_updated_bot"
        }
      }
    end

    defp telegram_get_me(_token) do
      %{
        "ok" => true,
        "result" => %{
          "id" => 1001,
          "is_bot" => true,
          "first_name" => "Bridge",
          "username" => "bridge_bot"
        }
      }
    end

    defp record(req), do: Agent.update(__MODULE__, &[req | &1])
  end

  defmodule HangingMCPProvider do
    @moduledoc false

    def set_owner(owner), do: :persistent_term.put({__MODULE__, :owner}, owner)
    def clear_owner, do: :persistent_term.erase({__MODULE__, :owner})
    def provider_state(_agent_id), do: {:ok, %{}}

    def dynamic_disclosure_entries(_agent_id) do
      {:ok,
       [
         %{
           "name" => "mcp.router_liveness.hang",
           "summary" => "Blocking user dependency for the HTTP timeout regression.",
           "manual" => "Blocking user dependency for the HTTP timeout regression.",
           "input_schema" => %{"type" => "object", "properties" => %{}}
         }
       ]}
    end

    def call_tool(_agent_id, "router_liveness", "hang", _args, _ctx) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:router_hanging_mcp_started, self()})

      receive do
        :release_router_hanging_mcp -> {:ok, %{"content" => "released"}}
      end
    end
  end

  defmodule PendingLLM do
    @behaviour SalixAgent.LLM
    @impl true
    def complete(_messages, _tools), do: await_release()
    @impl true
    def complete_stream(_messages, _tools, _on_delta), do: await_release()
    @impl true
    def complete_stream(_messages, _tools, _on_delta, _opts), do: await_release()

    defp await_release do
      receive do
        :release -> {:final, "released"}
      end
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_slack_api_base = Application.get_env(:salix_im, :slack_api_base_url)
    prev_telegram_api_base = Application.get_env(:salix_im, :telegram_api_base_url)
    prev_feishu_api_base = Application.get_env(:salix_im, :feishu_api_base_url)
    prev_api_token = Application.get_env(:salix_web, :api_token)
    prev_eval_query = Application.get_env(:salix_web, :trajectory_eval_query_module)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_web, :api_token, "test-token")

    Application.put_env(
      :salix_web,
      :trajectory_eval_query_module,
      MockTrajectoryEvalQueries
    )

    Comma.PodLifecycle.reset_for_test()
    SalixCluster.NodeLifecycle.reset()
    start_fake_store()

    case start_supervised(Mock) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    start_supervised!(MockTrajectoryEvalQueries)

    Application.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
      Application.put_env(:salix_agent, :llm, prev_llm)
      restore_env(:salix_im, :slack_api_base_url, prev_slack_api_base)
      restore_env(:salix_im, :telegram_api_base_url, prev_telegram_api_base)
      restore_env(:salix_im, :feishu_api_base_url, prev_feishu_api_base)
      restore_env(:salix_web, :trajectory_eval_query_module, prev_eval_query)
      restore_env(:salix_web, :api_token, prev_api_token)
      Comma.PodLifecycle.reset_for_test()
      SalixCluster.NodeLifecycle.reset()
      SalixAgent.SkillProjection.invalidate_cache()
    end)

    tenant_resp = req(:post, "/v1/admin/tenants", json: %{name: "Test Tenant"})
    tenant_id = tenant_resp.body["tenant_id"]

    key_resp = req(:post, "/v1/admin/tenants/#{tenant_id}/api-keys", json: %{name: "test"})
    tenant_key = key_resp.body["key"]

    Process.put(:test_tenant_id, tenant_id)
    Process.put(:test_tenant_key, tenant_key)

    {:ok,
     agent: "agent-#{System.unique_integer([:positive])}",
     tenant_id: tenant_id,
     tenant_key: tenant_key}
  end

  defmodule PrivateMediaCapture do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    match _ do
      send(
        Application.fetch_env!(:salix_web, :private_media_capture_pid),
        {:private_media_auth, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")}
      )

      body = %{
        "data" => [%{"b64_json" => "aGVsbG8="}],
        "choices" => [%{"message" => %{"content" => "described"}}]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end
  end

  @tag :private_template
  test "tenant CRUD rejects server credential references on every provider surface" do
    %{status: 201, body: private} =
      treq(:post, "/v1/templates", json: %{name: "Safe", model: "mock"})

    for field <-
          ~w(provider_config image_config video_config vision_describer_config analyze_config),
        env_field <- ~w(api_key_env auth_token_env) do
      attrs = %{
        "name" => "Untrusted config",
        "model" => "mock",
        field => %{env_field => "SALIX_SYNTHETIC_SERVER_SECRET"}
      }

      assert treq(:post, "/v1/templates", json: attrs).status == 400

      nested =
        Map.put(attrs, field, %{
          "provider_config" => %{env_field => "SALIX_SYNTHETIC_SERVER_SECRET"}
        })

      assert treq(:post, "/v1/templates", json: nested).status == 400
      assert treq(:patch, "/v1/templates/#{private["template_id"]}", json: attrs).status == 400
      assert treq(:patch, "/v1/templates/#{private["template_id"]}", json: nested).status == 400
    end

    assert treq(:patch, "/v1/templates/#{private["template_id"]}",
             json: %{provider_config: %{auth_token_env: "SALIX_SYNTHETIC_SERVER_SECRET"}}
           ).status == 400

    assert treq(:get, "/v1/templates/#{private["template_id"]}").body["provider_config"] == %{}

    # A stored/imported record must also fail closed at canonical runtime resolution.
    key = SalixStore.Keys.ctl_private_template(tenant_id(), private["template_id"])

    unsafe =
      Map.put(private, "analyze_config", %{"auth_token_env" => "SALIX_SYNTHETIC_SERVER_SECRET"})

    assert {:ok, _} = SalixStore.S3.put(key, Jason.encode!(unsafe))

    assert {:error, {:bad_request, _}} =
             SalixAgent.Templates.resolve_llm_for_template(private["template_id"], tenant_id())

    assert {:error, {:bad_request, _}} =
             SalixAgent.Templates.resolve_media_for_template(private["template_id"], tenant_id())

    # Platform operators retain their existing env-reference configuration.
    %{status: 201, body: global} =
      req(:post, "/v1/admin/templates",
        json: %{
          name: "Operator env",
          model: "mock",
          provider_config: %{api_key_env: "SALIX_SYNTHETIC_SERVER_SECRET"}
        }
      )

    assert {:ok, resolved} =
             SalixAgent.Templates.resolve_llm_for_template(global["template_id"], tenant_id())

    assert resolved["api_key_env"] == "SALIX_SYNTHETIC_SERVER_SECRET"
  end

  @tag :private_template
  test "private legacy media and missing endpoints fail before platform dispatch" do
    previous = Application.get_env(:salix_media, :base_url)
    Application.put_env(:salix_web, :private_media_capture_pid, self())
    port = start_bandit_retry!(fn p -> {Bandit, plug: PrivateMediaCapture, port: p} end)
    Application.put_env(:salix_media, :base_url, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      restore_env(:salix_media, :base_url, previous)
      Application.delete_env(:salix_web, :private_media_capture_pid)
    end)

    for provider <- ["legacy", "unknown", ""] do
      config = %{
        provider: provider,
        model: "media",
        provider_config: %{base_url: "http://127.0.0.1:1", api_key: "tenant-key"}
      }

      %{status: 201, body: template} =
        treq(:post, "/v1/templates",
          json: %{
            name: "Private legacy",
            model: "mock",
            image_config: config,
            video_config: config
          }
        )

      {:ok, media} =
        SalixAgent.Templates.resolve_media_for_template(template["template_id"], tenant_id())

      assert {:error, :unsupported_private_media_provider} =
               SalixMedia.ImageGen.generate("private", config: media["image_config"])

      assert {:error, :unsupported_private_media_provider} =
               SalixMedia.VideoGen.generate("private", config: media["video_config"])

      refute_received {:private_media_auth, _, _}
    end

    %{status: 201, body: template} =
      treq(:post, "/v1/templates",
        json: %{
          name: "Missing endpoint",
          model: "mock",
          vision_describer_config: %{model: "vision", api_key: "tenant-key"}
        }
      )

    {:ok, media} =
      SalixAgent.Templates.resolve_media_for_template(template["template_id"], tenant_id())

    assert {:error, :private_media_endpoint_required} =
             SalixMedia.Vision.describe("data:image/png;base64,aGVsbG8=",
               config: media["vision_describer_config"]
             )

    refute_received {:private_media_auth, _, _}
  end

  @tag :private_template
  test "private media cannot inherit platform credentials for a tenant endpoint" do
    previous = Application.get_env(:salix_media, :api_key)
    Application.put_env(:salix_web, :private_media_capture_pid, self())
    on_exit(fn -> Application.delete_env(:salix_web, :private_media_capture_pid) end)
    port = start_bandit_retry!(fn p -> {Bandit, plug: PrivateMediaCapture, port: p} end)
    endpoint = "http://127.0.0.1:#{port}"
    Application.put_env(:salix_media, :api_key, "synthetic-platform-secret")
    on_exit(fn -> restore_env(:salix_media, :api_key, previous) end)

    %{status: 201, body: private} =
      treq(:post, "/v1/templates",
        json: %{
          name: "Own endpoint",
          model: "mock",
          image_config: %{
            provider: "openai",
            model: "image",
            provider_config: %{base_url: endpoint}
          },
          vision_describer_config: %{endpoint: endpoint, model: "vision"}
        }
      )

    assert {:ok, media} =
             SalixAgent.Templates.resolve_media_for_template(private["template_id"], tenant_id())

    assert SalixMedia.HTTP.provider_config(media["image_config"]).api_key == ""
    assert {:ok, _} = SalixMedia.ImageGen.generate("test", config: media["image_config"])
    assert_receive {:private_media_auth, "/images/generations", []}

    assert {:ok, _} =
             SalixMedia.Vision.describe("data:image/png;base64,aGVsbG8=",
               config: media["vision_describer_config"]
             )

    assert_receive {:private_media_auth, "/chat/completions", []}

    assert SalixMedia.HTTP.provider_config(%{}).api_key == "synthetic-platform-secret"
  end

  @tag :private_template
  test "tenant templates support CRUD, agent selection and live runtime config without cross-tenant access" do
    other =
      req(:post, "/v1/admin/tenants", json: %{name: "Other template tenant"}).body["tenant_id"]

    other_key =
      req(:post, "/v1/admin/tenants/#{other}/api-keys", json: %{name: "other"}).body["key"]

    %{status: 201, body: global} =
      req(:post, "/v1/admin/templates",
        json: %{
          name: "Shared model",
          model: "gpt-shared",
          provider_config: %{api_key: "global-secret"}
        }
      )

    %{status: 201, body: private} =
      treq(:post, "/v1/templates",
        json: %{
          name: "Shared model",
          model: "gpt-private",
          tenant_id: other,
          provider_config: %{api_key: "tenant-secret", base_url: "https://api.openai.com/v1"},
          request_headers: %{"X-Private" => "private-header"},
          analyze_config: %{api_key: "analyze-secret", model: "gpt-analyze"},
          image_config: %{api_key: "image-secret", model: "image-private"}
        }
      )

    id = private["template_id"]
    assert private["tenant_id"] == tenant_id()
    assert SalixStore.Ids.valid_private_template_id?(id)
    assert treq(:get, "/v1/templates/#{id}").body["provider_config"]["api_key"] == "tenant-secret"
    assert req(:get, "/v1/admin/templates/#{id}").status == 404
    assert req(:post, "/v1/templates", json: %{name: "Admin", model: "mock"}).status == 401

    %{status: 200, body: catalog} = treq(:get, "/v1/templates/catalog")
    assert Enum.any?(catalog, &(&1["template_id"] == global["template_id"]))
    assert Enum.any?(catalog, &(&1["template_id"] == id and &1["scope"] == "tenant"))
    refute Jason.encode!(catalog) =~ "secret"
    refute Jason.encode!(catalog) =~ "private-header"
    assert Enum.any?(treq(:get, "/v1/templates").body, &(&1["template_id"] == id))
    refute Enum.any?(req(:get, "/v1/admin/templates/catalog").body, &(&1["template_id"] == id))

    refute Enum.any?(
             req_as(other_key, :get, "/v1/templates/catalog").body,
             &(&1["template_id"] == id)
           )

    refute Enum.any?(req_as(other_key, :get, "/v1/templates").body, &(&1["template_id"] == id))

    for method <- [:get, :patch, :delete] do
      opts = if method == :patch, do: [json: %{model: "stolen"}], else: []
      assert req_as(other_key, method, "/v1/templates/#{id}", opts).status == 404
      assert treq(method, "/v1/templates/#{global["template_id"]}", opts).status == 404
    end

    assert treq(:patch, "/v1/templates/#{id}", json: %{tenant_id: other}).status == 400

    assert treq(:patch, "/v1/templates/#{id}", json: %{template_id: global["template_id"]}).status ==
             400

    assert treq(:patch, "/v1/templates/#{id}", json: %{image_config: "invalid"}).status == 400

    group = create_test_group("Private template group")

    %{status: 201, body: agent} =
      treq(:post, "/v1/runtime/agents",
        json: %{
          name: "Private worker",
          group_id: group["group_id"],
          template_id: id
        }
      )

    agent_id = agent["agent_id"]
    assert {:ok, llm} = SalixAgent.Templates.resolve_llm_for_agent(agent_id)
    assert llm["api_key"] == "tenant-secret"
    assert llm["model"] == "gpt-private"
    assert llm["default_headers"]["X-Private"] == "private-header"
    assert {:ok, media} = SalixAgent.Templates.resolve_media_for_agent(agent_id)
    assert media["image_config"]["api_key"] == "image-secret"
    assert media["analyze_config"]["api_key"] == "analyze-secret"
    assert {:ok, record} = SalixAgent.Control.get(agent_id, tenant_id())
    assert {:ok, ^llm} = Salix.Bindings.AgentLlmResolver.resolve_record(record)

    assert {:error, {:template_not_found, ^id}} =
             Salix.Bindings.AgentLlmResolver.resolve_record(Map.put(record, "tenant_id", other))

    assert {:error, {:template_not_found, ^id}} =
             SalixAgent.Templates.resolve_media_for_template(id, other)

    assert {:error, {:template_not_found, ^id}} =
             SalixAgent.Templates.resolve_llm_for_template(id)

    %{status: 201, body: other_group} =
      req_as(other_key, :post, "/v1/runtime/agent-groups", json: %{name: "Other"})

    assert req_as(other_key, :post, "/v1/runtime/agents",
             json: %{group_id: other_group["group_id"], template_id: id}
           ).status == 400

    %{status: 201, body: other_agent} =
      req_as(other_key, :post, "/v1/runtime/agents",
        json: %{
          group_id: other_group["group_id"],
          template_id: global["template_id"]
        }
      )

    assert req_as(other_key, :patch, "/v1/runtime/agents/#{other_agent["agent_id"]}",
             json: %{template_id: id}
           ).status == 400

    assert treq(:delete, "/v1/templates/#{id}").status == 409

    SalixStore.S3.Fake.reset_read_log()

    assert treq(:patch, "/v1/templates/#{id}",
             json: %{model: "gpt-private-updated", provider_config: %{api_key: "rotated-secret"}}
           ).status == 200

    # One editing request reads the validated record once and conditionally writes
    # against that same read; avoid a second object-store round trip per edit.
    key = SalixStore.Keys.ctl_private_template(tenant_id(), id)
    assert Enum.count(SalixStore.S3.Fake.read_log(), &(&1 == {:get, key})) == 1

    assert {:ok, updated} = SalixAgent.Templates.resolve_llm_for_agent(agent_id)
    assert updated["model"] == "gpt-private-updated"
    assert updated["api_key"] == "rotated-secret"

    assert treq(:patch, "/v1/runtime/agents/#{agent_id}",
             json: %{template_id: global["template_id"]}
           ).status == 200

    assert {:ok, shared} = SalixAgent.Templates.resolve_llm_for_agent(agent_id)
    assert shared["api_key"] == "global-secret"
    assert treq(:patch, "/v1/runtime/agents/#{agent_id}", json: %{template_id: id}).status == 200
    assert {:ok, ^updated} = SalixAgent.Templates.resolve_llm_for_agent(agent_id)

    assert treq(:patch, "/v1/runtime/agents/#{agent_id}",
             json: %{template_id: global["template_id"]}
           ).status == 200

    assert treq(:delete, "/v1/templates/#{id}").status == 200
    assert treq(:get, "/v1/templates/#{id}").status == 404

    assert {:error, {:template_not_found, ^id}} =
             SalixAgent.Templates.resolve_llm_for_template(id, tenant_id())

    assert req(:get, "/v1/admin/templates/#{global["template_id"]}").status == 200
  end

  @tag :private_template
  test "private template hidden and archived-reference behavior matches the global template" do
    %{status: 201, body: private} =
      treq(:post, "/v1/templates", json: %{name: "Hidden later", model: "mock"})

    id = private["template_id"]
    group = create_test_group("Archived template references")

    %{status: 201, body: agent} =
      treq(:post, "/v1/runtime/agents", json: %{group_id: group["group_id"], template_id: id})

    assert treq(:patch, "/v1/templates/#{id}", json: %{hidden: true}).status == 200
    refute Enum.any?(treq(:get, "/v1/templates/catalog").body, &(&1["template_id"] == id))
    assert {:ok, _} = SalixAgent.Templates.resolve_llm_for_agent(agent["agent_id"])

    assert treq(:post, "/v1/runtime/agents",
             json: %{group_id: group["group_id"], template_id: id}
           ).status == 400

    # Existing global-template updates accept a known hidden ID; private follows the same rule.
    assert treq(:patch, "/v1/runtime/agents/#{agent["agent_id"]}", json: %{template_id: id}).status ==
             200

    assert {:ok, _} = SalixAgent.Control.archive_permanently(agent["agent_id"], tenant_id())
    assert treq(:delete, "/v1/templates/#{id}").status == 200
  end

  defp tenant_id, do: Process.get(:test_tenant_id)
  defp tenant_key, do: Process.get(:test_tenant_key)

  defp req(method, path, opts \\ []) do
    req_as("test-token", method, path, opts)
  end

  # Tenant-scoped request: authorizes with the tenant API key (created in setup).
  defp treq(method, path, opts \\ []) do
    req_as(tenant_key(), method, path, opts)
  end

  defp req_as(token, method, path, opts \\ []) do
    headers = [{"authorization", "Bearer " <> token}]
    Req.request!([method: method, url: base() <> path, headers: headers] ++ opts)
  end

  test "runtime eval results use a tenant-scoped bounded cursor", %{tenant_id: tenant_id} do
    MockTrajectoryEvalQueries.set_rows([])

    missing_boundary = treq(:get, "/v1/runtime/eval/trajectory-results")
    assert missing_boundary.status == 400
    assert missing_boundary.body == %{"error" => "initial_cursor_required"}

    first =
      treq(
        :get,
        "/v1/runtime/eval/trajectory-results?evaluated_from=2026-08-01T00:00:00Z&limit=1"
      )

    assert first.status == 200
    assert first.body["items"] == []
    assert first.body["has_more"] == false
    assert first.body["consistency"]["mode"] == "eventual_with_overlap"
    assert is_binary(first.body["next_cursor"])

    cursor = URI.encode_www_form(first.body["next_cursor"])
    resumed = treq(:get, "/v1/runtime/eval/trajectory-results?cursor=#{cursor}")
    assert resumed.status == 200
    assert resumed.body["items"] == []

    other_tenant = req(:post, "/v1/admin/tenants", json: %{name: "Other Eval Tenant"})

    other_key =
      req(
        :post,
        "/v1/admin/tenants/#{other_tenant.body["tenant_id"]}/api-keys",
        json: %{name: "other-eval"}
      ).body["key"]

    assert req_as(
             other_key,
             :get,
             "/v1/runtime/eval/trajectory-results?cursor=#{cursor}"
           ).status == 400

    [{^tenant_id, first_opts}, {^tenant_id, resumed_opts}] =
      MockTrajectoryEvalQueries.requests()

    assert first_opts[:limit] == 2
    assert resumed_opts[:limit] == 21
    assert DateTime.diff(resumed_opts[:snapshot_to], resumed_opts[:after_at], :second) >= 3_600

    conflict =
      treq(
        :get,
        "/v1/runtime/eval/trajectory-results?cursor=#{cursor}&min_severity=0.9"
      )

    assert conflict.status == 400
    assert conflict.body == %{"error" => "cursor_filter_conflict"}

    assert treq(
             :get,
             "/v1/runtime/eval/trajectory-results?evaluated_from=2026-08-01T00:00:00Z&limit=101"
           ).status == 400

    assert treq(
             :get,
             "/v1/runtime/eval/trajectory-results?evaluated_from=2026-08-01T00:00:00Z&bootstrap=now"
           ).status == 400

    assert req(:get, "/v1/runtime/eval/trajectory-results?bootstrap=now").status == 401
  end

  test "runtime eval results expose bounded raw records without creating candidates", %{
    tenant_id: tenant_id
  } do
    group_id = Ids.new_group_id(tenant_id)

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "role" => "router"
      })

    agent_id = agent["agent_id"]
    session_id = "ses1_0000000000000000891"

    base = InternalSession.new(agent_id, session_id, %{"created_at" => "2026-08-12T00:00:00Z"})

    state = %InternalSessionState{
      InternalSession.export(base)
      | messages: [
          %{id: 1, role: "user", content: "fix the bug", created_at: 1},
          %{
            id: 2,
            role: "assistant",
            content: "Wait. Authorization: Bearer secret-token-value",
            created_at: 2,
            tool_calls: []
          }
        ],
        next_message_id: 3
    }

    assert :ok = InternalSessionStore.prepare_seed(agent_id, InternalSession.open(state))

    MockTrajectoryEvalQueries.set_rows([
      %{
        "window_key" => "#{agent_id}:#{session_id}:2",
        "salix_agent_id" => agent_id,
        "session_id" => session_id,
        "group_id" => group_id,
        "outcome" => "final",
        "round_id" => "round-1",
        "window_from" => 2,
        "window_to" => 2,
        "window_messages" => 1,
        "max_confirmed_severity" => 0.8,
        "evaluator_version" => "1",
        "evaluated_at" => "2026-08-12T00:00:01.000000Z",
        "findings" => [
          %{
            "metric" => "confusion",
            "score" => 0.8,
            "verdict" => "confirmed",
            "reason" => "backtracking",
            "evidence" => []
          }
        ]
      }
    ])

    response =
      treq(
        :get,
        "/v1/runtime/eval/trajectory-results?evaluated_from=2026-08-01T00:00:00Z"
      )

    assert response.status == 200
    assert [item] = response.body["items"]
    refute Map.has_key?(item, "candidate_id")
    refute Map.has_key?(item, "export_digest")
    refute Map.has_key?(item, "replay")
    assert item["session_records_status"] == "available"
    assert item["target"] == %{"agent_role" => "router", "runtime_kind" => "internal"}

    assert [%{"role" => "user"}, %{"role" => "assistant", "content" => content}] =
             item["session_records"]

    assert content =~ "secret-token-value"
  end

  defp put_vm_record(group_id, record) do
    defaults = %{
      "device_id" => SalixStore.Ids.new_device_id(),
      "connector_id" => "connector-" <> group_id,
      "env_id" => "env-" <> group_id,
      "provider_resource_name" => record["provider_resource_id"]
    }

    {:ok, _, :created} = SalixStore.Compute.ensure_group_workload(Map.merge(defaults, record))
  end

  defp site_req("http" <> _ = url) do
    uri = URI.parse(url)
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
    Req.request!(method: :get, url: base() <> path, headers: [{"host", uri.host}])
  end

  defp site_req(path), do: Req.request!(method: :get, url: base() <> path)

  # Explicitly create an agent under the test tenant (lazy creation is gone).
  # Creates a template (admin), a group (tenant), and an agent (tenant);
  # returns the generated agent_id.
  defp create_test_agent do
    tmpl =
      req(:post, "/v1/admin/templates",
        json: %{
          template_id: "tmpl-#{System.unique_integer([:positive])}",
          name: "Test Template",
          model: "gpt-test",
          provider: "openai",
          provider_config: %{protocol: "responses", model: "gpt-test"}
        }
      )

    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Test Group"})

    agent =
      treq(:post, "/v1/runtime/agents",
        json: %{
          group_id: group.body["group_id"],
          template_id: tmpl.body["template_id"],
          name: "Test Agent"
        }
      )

    agent.body["agent_id"]
  end

  defp create_test_group(name) do
    response = treq(:post, "/v1/runtime/agent-groups", json: %{name: name})
    assert response.status == 201
    response.body
  end

  defp start_fake_store do
    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end
  end

  defp base, do: SalixWeb.Application.base_url()

  defp read_sse_frames(path, count, token \\ nil) do
    token = token || tenant_key()
    port = SalixWeb.Application.http_port()
    {:ok, sock} = :gen_tcp.connect(@host, port, [:binary, active: false, packet: :raw], 2_000)

    request =
      "GET #{path} HTTP/1.1\r\n" <>
        "host: 127.0.0.1:#{port}\r\n" <>
        "authorization: Bearer #{token}\r\n" <>
        "accept: text/event-stream\r\n" <>
        "\r\n"

    :ok = :gen_tcp.send(sock, request)

    try do
      read_sse_frames_loop(sock, %{phase: :headers, buf: "", sse: "", frames: []}, count)
    after
      :gen_tcp.close(sock)
    end
  end

  defp open_sse_stream(path, token \\ nil) do
    token = token || tenant_key()
    parent = self()

    spawn(fn ->
      port = SalixWeb.Application.http_port()
      {:ok, sock} = :gen_tcp.connect(@host, port, [:binary, active: false, packet: :raw], 2_000)

      request =
        "GET #{path} HTTP/1.1\r\n" <>
          "host: 127.0.0.1:#{port}\r\n" <>
          "authorization: Bearer #{token}\r\n" <>
          "accept: text/event-stream\r\n" <>
          "\r\n"

      :ok = :gen_tcp.send(sock, request)
      recv_sse_stream(sock, parent, %{phase: :headers, buf: "", sse: ""})
      :gen_tcp.close(sock)
    end)
  end

  defp recv_sse_stream(sock, parent, state) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, bytes} ->
        recv_sse_stream(sock, parent, ingest_sse_stream(bytes, parent, state))

      {:error, reason} ->
        send(parent, {:sse_closed, reason})
    end
  end

  defp ingest_sse_stream(bytes, parent, %{phase: :headers, buf: buf} = state) do
    case :binary.split(buf <> bytes, "\r\n\r\n") do
      [_incomplete] ->
        %{state | buf: buf <> bytes}

      [head, rest] ->
        send(parent, {:sse_headers, head})
        ingest_sse_stream(rest, parent, %{state | phase: :body, buf: ""})
    end
  end

  defp ingest_sse_stream(bytes, parent, %{phase: :body, buf: buf, sse: sse} = state) do
    case dechunk_sse(buf <> bytes, "") do
      {:more, data, rest} ->
        emit_sse_stream_frames(parent, %{state | buf: rest, sse: sse <> data})

      {:done, data, _rest} ->
        emit_sse_stream_frames(parent, %{state | buf: "", sse: sse <> data})
    end
  end

  defp read_sse_frames_loop(_sock, %{frames: frames}, count) when length(frames) >= count,
    do: Enum.take(frames, count)

  defp read_sse_frames_loop(sock, state, count) do
    {:ok, bytes} = :gen_tcp.recv(sock, 0, 5_000)
    read_sse_frames_loop(sock, ingest_sse(bytes, state), count)
  end

  defp ingest_sse(bytes, %{phase: :headers, buf: buf} = state) do
    case :binary.split(buf <> bytes, "\r\n\r\n") do
      [_incomplete] ->
        %{state | buf: buf <> bytes}

      [_head, rest] ->
        ingest_sse(rest, %{state | phase: :body, buf: ""})
    end
  end

  defp ingest_sse(bytes, %{phase: :body, buf: buf, sse: sse} = state) do
    case dechunk_sse(buf <> bytes, "") do
      {:more, data, rest} ->
        emit_sse_frames(%{state | buf: rest, sse: sse <> data})

      {:done, data, _rest} ->
        emit_sse_frames(%{state | buf: "", sse: sse <> data})
    end
  end

  defp dechunk_sse(buf, acc) do
    case :binary.split(buf, "\r\n") do
      [size_line, rest] ->
        size = size_line |> String.split(";") |> hd() |> String.trim() |> String.to_integer(16)

        cond do
          size == 0 ->
            {:done, acc, rest}

          byte_size(rest) >= size + 2 ->
            <<data::binary-size(^size), "\r\n", rest2::binary>> = rest
            dechunk_sse(rest2, acc <> data)

          true ->
            {:more, acc, buf}
        end

      [_incomplete] ->
        {:more, acc, buf}
    end
  end

  defp emit_sse_frames(%{sse: sse, frames: frames} = state) do
    parts = String.split(sse, "\n\n")
    {complete, [remainder]} = Enum.split(parts, length(parts) - 1)

    parsed =
      complete
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn frame ->
        event =
          frame
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, acc ->
            case line do
              "event: " <> event -> Map.put(acc, "event", event)
              "data: " <> data -> Map.put(acc, "data", Jason.decode!(data))
              _ -> acc
            end
          end)

        if Map.has_key?(event, "event"), do: [event], else: []
      end)

    %{state | sse: remainder, frames: frames ++ parsed}
  end

  defp emit_sse_stream_frames(parent, %{sse: sse} = state) do
    parts = String.split(sse, "\n\n")
    {complete, [remainder]} = Enum.split(parts, length(parts) - 1)

    for frame <- complete, frame != "" do
      parsed =
        frame
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case line do
            "event: " <> event -> Map.put(acc, "event", event)
            "data: " <> data -> Map.put(acc, "data", Jason.decode!(data))
            _ -> acc
          end
        end)

      if Map.has_key?(parsed, "event"), do: send(parent, {:sse_frame, parsed})
    end

    %{state | sse: remainder}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp start_bandit_retry!(spec_fun) do
    Enum.find_value(1..10, fn _ ->
      p = 40_000 + :erlang.phash2(make_ref(), 20_000)

      case ExUnit.Callbacks.start_supervised(spec_fun.(p), id: {:bandit_retry, p}) do
        {:ok, _pid} -> p
        {:error, _} -> nil
      end
    end) || raise "could not bind a test port after 10 attempts"
  end

  defp slack_sig(secret, timestamp, raw_body) do
    mac =
      :crypto.mac(:hmac, :sha256, secret, "v0:" <> timestamp <> ":" <> raw_body)
      |> Base.encode16(case: :lower)

    "v0=" <> mac
  end

  defp post_slack_event(raw_body, timestamp, signature) do
    Req.request!(
      method: :post,
      url: base() <> "/v1/im/slack/events",
      headers: [
        {"content-type", "application/json"},
        {"x-slack-request-timestamp", timestamp},
        {"x-slack-signature", signature}
      ],
      body: raw_body
    )
  end

  defp slack_event(raw_body, secret, timestamp \\ System.system_time(:second)) do
    timestamp = Integer.to_string(timestamp)

    post_slack_event(raw_body, timestamp, slack_sig(secret, timestamp, raw_body))
  end

  defp feishu_message_event(event_id, message_id, text) do
    %{
      "schema" => "2.0",
      "header" => %{
        "event_id" => event_id,
        "event_type" => "im.message.receive_v1",
        "token" => "verify-hook",
        "app_id" => "cli_hook",
        "tenant_key" => "tenant-feishu"
      },
      "event" => %{
        "sender" => %{
          "sender_type" => "user",
          "sender_id" => %{"open_id" => "ou_feishu", "user_id" => "u_feishu"},
          "sender_name" => "Feishu User"
        },
        "message" => %{
          "message_id" => message_id,
          "chat_id" => "oc_feishu",
          "chat_type" => "p2p",
          "message_type" => "text",
          "content" => Jason.encode!(%{"text" => text}),
          "create_time" => "1700000000000"
        }
      }
    }
  end

  defp encrypt_feishu_envelope(envelope, encrypt_key) do
    iv = :binary.copy(<<7>>, 16)
    key = :crypto.hash(:sha256, encrypt_key)
    plaintext = Jason.encode!(envelope)
    padding_size = 16 - rem(byte_size(plaintext), 16)
    padded = plaintext <> :binary.copy(<<padding_size>>, padding_size)
    ciphertext = :crypto.crypto_one_time(:aes_256_cbc, key, iv, padded, true)

    Base.encode64(iv <> ciphertext)
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, retries - 1)
    end
  end

  defp assert_router_session_message(agent_id, group_id, source_id, text) do
    assert {:ok, messages} =
             SalixIM.RouterConversationProjection.list_group_router_messages(group_id)

    assert Enum.count(messages, &(&1["source_message_id"] == source_id)) == 1

    {:ok, session_id} = ProviderConnects.agent_group_router_session_id(agent_id, group_id)

    assert eventually(fn ->
             case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
               {:ok, session} ->
                 Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn msg ->
                   to_string(
                     Map.get(msg, :source_message_id) || Map.get(msg, "source_message_id") || ""
                   ) == source_id and
                     msg.role == "user" and String.contains?(to_string(msg.content || ""), text)
                 end)

               _ ->
                 false
             end
           end)

    {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, session_id)
    session
  end

  defp assert_router_session_pending_input(agent_id, group_id, source_id, text) do
    {:ok, conversation} = SalixIM.RouterConversationInput.ensure(group_id)

    source = %{
      group_id: group_id,
      conversation_id: conversation["conversation_id"],
      participant_id: conversation["router_participant_id"]
    }

    assert {:ok, binding} = SalixIM.ConversationSource.binding(agent_id, source)
    assert {:ok, binding, messages} = SalixIM.ConversationSource.batch(binding, nil)
    message = Enum.find(messages, &(&1["source_message_id"] == source_id))
    assert is_map(message)
    assert {:ok, entry} = SalixIM.ConversationSource.entry(binding, message)
    assert entry.payload.content =~ text

    {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, binding.session_id)
    progress = SalixAgent.InternalSession.conversation_sources(session)[source.participant_id]

    if (progress["seq"] || 0) >= message["seq"] do
      assert Enum.any?(SalixAgent.InternalSession.get(session, :input_queue), fn item ->
               payload = item[:payload] || item["payload"] || %{}
               (payload[:source_message_id] || payload["source_message_id"]) == source_id
             end)
    end

    refute Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
             to_string(
               Map.get(message, :source_message_id) ||
                 Map.get(message, "source_message_id") || ""
             ) == source_id
           end)

    session
  end

  test "tenant Workload projection exposes bounded compute-node activity", %{
    tenant_id: tenant_id
  } do
    suffix = System.unique_integer([:positive])
    pool_id = "activity-pool-#{suffix}"
    environment_id = "activity-environment-#{suffix}"
    binding_id = "activity-binding-#{suffix}"
    allocation_id = "activity-allocation-#{suffix}"
    workload_id = "activity-workload-#{suffix}"
    registration_id = "activity-registration-#{suffix}"

    assert {:ok, _registration} =
             AgentVMM.create_registration(%{
               id: registration_id,
               tenant_id: tenant_id,
               group_id: "activity-group-#{suffix}",
               device_id: "activity-device-#{suffix}",
               enrollment_token: String.duplicate("a", 32)
             })

    assert {:ok, pool} =
             Compute.create_pool(%{
               id: pool_id,
               tenant_id: tenant_id,
               name: "Activity",
               region: "local",
               capabilities: ["runtime_exec"],
               provider_policy: %{"providers" => ["agent_vmm"]}
             })

    assert {:ok, environment} =
             Compute.create_environment(%{
               id: environment_id,
               tenant_id: tenant_id,
               owner_type: "project",
               owner_id: "activity-project-#{suffix}",
               pool_id: pool.id
             })

    assert {:ok, binding} =
             Compute.create_provider_binding(%{
               id: binding_id,
               pool_id: pool.id,
               environment_id: environment.id,
               provider: "agent_vmm",
               provider_ref: registration_id
             })

    registration = SalixStore.Repo.get!(AgentVMM.Registration, registration_id)

    SalixStore.Repo.update!(
      Ecto.Changeset.change(registration, status: "ready", desired_enabled: true)
    )

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration_id, "activity-gateway-#{suffix}", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    assert {:ok, allocation} =
             Compute.allocate(%{
               id: allocation_id,
               environment_id: environment.id,
               provider_binding_id: binding.id,
               generation: environment.generation
             })

    assert {:ok, allocation} =
             Compute.observe_allocation(
               allocation.id,
               allocation.revision,
               environment.generation,
               "ready",
               "succeeded"
             )

    assert {:ok, workload} =
             Compute.create_workload(%{
               id: workload_id,
               environment_id: environment.id,
               allocation_id: allocation.id,
               kind: "external_worker",
               generation: environment.generation
             })

    SalixStore.Repo.update!(Ecto.Changeset.change(workload, observed_state: "ready"))

    assert %{status: 200, body: body} =
             treq(:get, "/v1/compute-node/work-activity/#{registration_id}")

    assert body == %{
             "activity" => "idle",
             "active_operation_count" => 0,
             "workload_count" => 1
           }

    assert workload.id == workload_id
  end

  test "remote dependency configuration does not flap local readiness" do
    Application.put_env(:salix_web, :usage_readiness_mod, :remote_dependency_unavailable)
    assert %{status: 200, body: %{"status" => "ok"}} = req(:get, "/ready")
    assert %{status: 200, body: %{"status" => "ok"}} = req(:get, "/live")
  end

  test "readiness is unavailable while draining but liveness remains healthy" do
    SalixCluster.NodeLifecycle.mark_draining()

    assert %{status: 200, body: %{"status" => "ok"}} = req(:get, "/live")

    assert %{status: 503, body: %{"status" => "unavailable", "reason" => "draining"}} =
             req(:get, "/ready")
  end

  test "agent connector token API is not exposed" do
    agent_id = create_test_agent()

    get_resp = treq(:get, "/v1/runtime/agents/#{agent_id}/connector-tokens")
    post_resp = treq(:post, "/v1/runtime/agents/#{agent_id}/connector-tokens", json: %{})
    delete_resp = treq(:delete, "/v1/runtime/agents/#{agent_id}/connector-tokens/token_hash")

    assert get_resp.status == 404
    assert post_resp.status == 404
    assert delete_resp.status == 404
  end

  test "compute external-worker auth is tenant-writer scoped and rejects a stale target" do
    group = create_test_group("Compute Auth Group")
    agent_id = SalixStore.Ids.new_agent_id(group["group_id"])

    SalixAgent.TestSupport.create_legacy_control_agent!(agent_id, %{
      "tenant_id" => tenant_id(),
      "group_id" => group["group_id"],
      "role" => "worker",
      "runtime_config" => %{
        "kind" => "compute_workload",
        "workload_id" => "workload-auth-stale",
        "runtime_spec" => %{"provider" => "codex"}
      }
    })

    path =
      "/v1/runtime/agent-groups/#{group["group_id"]}/agents/#{agent_id}/external-worker/auth?" <>
        URI.encode_query(%{
          workload_id: "workload-auth-stale",
          generation: "1",
          provider: "codex"
        })

    assert %{status: 409, body: %{"error" => "runtime_auth_target_changed"}} =
             treq(:get, path)

    login_path =
      "/v1/runtime/agent-groups/#{group["group_id"]}/agents/#{agent_id}/external-worker/auth/login"

    exact_target = %{
      workload_id: "workload-auth-stale",
      generation: 1,
      provider: "codex"
    }

    assert %{status: 409, body: %{"error" => "runtime_auth_target_changed"}} =
             treq(:post, login_path, json: Map.put(exact_target, :flow, "device_code"))

    assert %{status: 409, body: %{"error" => "runtime_auth_target_changed"}} =
             treq(:delete, login_path, json: Map.put(exact_target, :attempt_id, "rta_stale"))

    assert %{status: 401, body: %{"error" => "unauthorized"}} = req(:get, path)
  end

  test "group connector token API creates a group-scoped connect token" do
    group_id = create_test_group("Connector Token Group")["group_id"]

    resp =
      treq(:post, "/v1/runtime/agent-groups/#{group_id}/connector-tokens",
        json: %{name: "Mac Studio", alias: "studio"}
      )

    assert resp.status == 201
    assert %{"token" => "salix_conn_" <> _, "token_hash" => token_hash} = resp.body
    assert resp.body["tenant_id"] == tenant_id()
    assert resp.body["group_id"] == group_id
    assert resp.body["name"] == "Mac Studio"
    assert resp.body["alias"] == "studio"
    assert resp.body["connect_url"] == resp.body["server"] <> "/v1/connect"
    assert resp.body["env"]["SALIX_CONNECTOR_TOKEN"] == resp.body["token"]
    refute Map.has_key?(resp.body, "agent_id")
    refute Map.has_key?(resp.body["env"], "SALIX_AGENT_ID")

    tenant_id = tenant_id()

    assert {:ok, ^tenant_id, record} =
             SalixEnv.ConnectorTokens.validate_connector_token(resp.body["token"])

    assert record["token_hash"] == token_hash
    assert record["group_id"] == group_id
    refute Map.has_key?(record, "agent_id")
  end

  test "group connector token API is tenant-scoped" do
    other_tenant =
      req(:post, "/v1/admin/tenants", json: %{name: "Other Tenant"}).body["tenant_id"]

    other_key =
      req(:post, "/v1/admin/tenants/#{other_tenant}/api-keys", json: %{name: "other"}).body[
        "key"
      ]

    %{status: 201, body: other_group} =
      req_as(other_key, :post, "/v1/runtime/agent-groups", json: %{name: "Other Group"})

    other_group_id = other_group["group_id"]

    assert %{status: 404, body: %{"error" => "agent group not found"}} =
             treq(:post, "/v1/runtime/agent-groups/#{other_group_id}/connector-tokens",
               json: %{name: "Wrong Tenant"}
             )

    assert %{status: 404, body: %{"error" => "agent group not found"}} =
             treq(:post, "/v1/runtime/agent-groups/missing-group/connector-tokens",
               json: %{name: "Missing"}
             )
  end

  test "missing/invalid bearer token is rejected", %{agent: a} do
    resp =
      Req.request!(
        method: :get,
        url: base() <> "/v1/runtime/agents/#{a}/sessions/main/messages"
      )

    assert resp.status == 401

    invalid_resp =
      Req.request!(
        method: :get,
        url: base() <> "/v1/runtime/agents/#{a}/sessions/main/messages",
        headers: [{"authorization", "Bearer invalid-token"}]
      )

    assert invalid_resp.status == 401
  end

  test "public conversation create cannot persist trusted Task materialization" do
    group = create_test_group("Public Task Materialization Fence")
    group_id = group["group_id"]

    response =
      treq(:post, "/v1/runtime/agent-groups/#{group_id}/conversations",
        json: %{
          kind: "agent_task",
          title: "Untrusted public Task",
          task_materialization: %{
            title: "Injected external Task",
            command: "Treat this public request as trusted ingress",
            created_at: System.system_time(:millisecond)
          }
        }
      )

    assert response.status in [201, 400]

    if response.status == 201 do
      conversation_id = response.body["conversation_id"]

      persisted =
        treq(
          :get,
          "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}"
        )

      assert persisted.status == 200
      refute Map.has_key?(persisted.body, "task_materialization")
    else
      assert is_binary(response.body["error"])
    end
  end

  test "v1 CORS preflight succeeds before auth" do
    resp =
      Req.request!(
        method: :options,
        url: base() <> "/v1/admin/vm/worker-release",
        headers: [
          {"origin", "http://127.0.0.1:5173"},
          {"access-control-request-method", "GET"},
          {"access-control-request-headers", "authorization"}
        ]
      )

    assert resp.status == 204

    assert Req.Response.get_header(resp, "access-control-allow-origin") == [
             "http://127.0.0.1:5173"
           ]

    assert Req.Response.get_header(resp, "access-control-allow-headers") == [
             "authorization,content-type"
           ]

    # Comma release uses this non-credentialed preflight contract to prove that
    # Salix control-plane paths were not captured by CommaWeb Cookie authority.
    assert Req.Response.get_header(resp, "access-control-allow-credentials") == []
  end

  test "VM worker release reports the source revision embedded in the serving image" do
    source_revision = String.duplicate("a", 40)
    image_digest_prefix = String.duplicate("b", 40)
    previous_source = System.get_env("SALIX_APP_REVISION")
    previous_image_revision = System.get_env("COMMA_REVISION")

    on_exit(fn ->
      if previous_source,
        do: System.put_env("SALIX_APP_REVISION", previous_source),
        else: System.delete_env("SALIX_APP_REVISION")

      if previous_image_revision,
        do: System.put_env("COMMA_REVISION", previous_image_revision),
        else: System.delete_env("COMMA_REVISION")
    end)

    System.put_env("SALIX_APP_REVISION", source_revision)
    System.put_env("COMMA_REVISION", "sha-" <> image_digest_prefix)

    assert req(:get, "/v1/admin/vm/worker-release").body["comma_source_revision"] ==
             source_revision
  end

  test "materializes one pre-authorized Slack installation through the unified integration route" do
    start_supervised!(MockSlackOAuth)
    port = start_bandit_retry!(fn p -> {Bandit, plug: MockSlackOAuth, port: p} end)
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

    group = treq(:post, "/v1/runtime/agent-groups", json: %{name: "Slack Eval"})
    group_id = group.body["group_id"]

    agent =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group_id, name: "Slack Eval Router", is_router: true}
      )

    agent_id = agent.body["agent_id"]

    assert treq(:patch, "/v1/runtime/agent-groups/#{group_id}",
             json: %{router_agent_id: agent_id}
           ).status == 200

    body = %{
      integration_id: "slack",
      provider: "slack",
      inbound_agent_id: agent_id,
      credentials: %{
        type: "app",
        app_name: "evalens",
        app_id: "A-MATERIALIZE",
        client_id: "client-materialize",
        client_secret: "client-secret-materialize",
        signing_secret: "signing-materialize",
        bot_token: "xoxb-materialize"
      }
    }

    created =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/eval/integration-materializations",
        json: body
      )

    assert created.status == 200, inspect(created.body)
    assert created.body["materialization_kind"] == "im_connect"
    assert created.body["provider"] == "slack"
    connect = created.body["resources"]["im_connect"]
    assert connect["workspace_id"] == "T-SLACK"
    assert connect["bot_id"] == "B-BOT"
    assert connect["bot_user_id"] == "B-SLACK"
    assert connect["bot_username"] == "comma_slack_bot"
    assert connect["inbound_agent_id"] == agent_id
    refute inspect(created.body) =~ "xoxb-materialize"

    assert {:ok, stored_connect} =
             SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, connect["connect_id"]))

    assert String.to_integer(stored_connect["inbound_event_not_before_ms"]) ==
             DateTime.to_unix(~U[2026-07-16 04:00:00Z], :millisecond)

    retried =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/eval/integration-materializations",
        json: body
      )

    assert retried.status == 200
    assert retried.body["materialization_id"] == created.body["materialization_id"]

    other_group = treq(:post, "/v1/runtime/agent-groups", json: %{name: "Other"})
    other_group_id = other_group.body["group_id"]

    other_agent =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: other_group_id, name: "Other Router", is_router: true}
      )

    other_agent_id = other_agent.body["agent_id"]

    assert treq(:patch, "/v1/runtime/agent-groups/#{other_group_id}",
             json: %{router_agent_id: other_agent_id}
           ).status == 200

    conflict =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{other_group_id}/eval/integration-materializations",
        json: %{body | inbound_agent_id: other_agent_id}
      )

    assert conflict.status == 409
  end

  test "materializes managed OAuth and its MCP binding through the unified integration route" do
    assert {:ok, _counts} = SalixMCP.Builtins.seed_builtin_definitions()
    group = treq(:post, "/v1/runtime/agent-groups", json: %{name: "GitHub Eval"})
    group_id = group.body["group_id"]

    body = %{
      integration_id: "github",
      provider: "github",
      alias: "github",
      credentials: %{type: "oauth", access_token: "github-eval-token"},
      scopes: ["repo", "read:org", "read:user", "user:email"],
      account: %{
        provider_account_id: "github-account",
        provider_account_name: "Evalens GitHub"
      },
      plugin: %{plugin_id: "github", connection_id: "github-managed"}
    }

    created =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/eval/integration-materializations",
        json: body
      )

    assert created.status == 200, inspect(created.body)
    assert created.body["materialization_kind"] == "managed_oauth"
    assert created.body["provider"] == "github"
    refute inspect(created.body) =~ "github-eval-token"

    oauth = created.body["resources"]["oauth_binding"]
    assert oauth["alias"] == "github"

    assert {:ok, connection} = SalixStore.OAuth.get(oauth["connection_id"])
    assert connection["access_token"] == "github-eval-token"
    assert connection["metadata"]["integration_materialized"] == true
    assert connection["metadata"]["integration_id"] == "github"

    assert {:ok, mcp_binding} =
             SalixMCP.Store.find_binding_by_alias(tenant_id(), group_id, "github")

    assert get_in(mcp_binding, ["oauth_binding_refs", "GITHUB_ACCESS_TOKEN", "provider"]) ==
             "github"

    assert Salix.Bindings.MCPCredentials.resolve(mcp_binding) ==
             {:ok, %{"GITHUB_ACCESS_TOKEN" => "github-eval-token"}}

    retried =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/eval/integration-materializations",
        json: body
      )

    assert retried.status == 200
    assert retried.body["materialization_id"] == created.body["materialization_id"]

    assert retried.body["resources"]["oauth_binding"]["connection_id"] ==
             oauth["connection_id"]
  end

  test "refuses to replace an ordinary OAuth binding during eval materialization" do
    group = treq(:post, "/v1/runtime/agent-groups", json: %{name: "OAuth collision"})
    group_id = group.body["group_id"]
    connection_id = "conn-user-owned"

    assert :ok =
             SalixStore.OAuth.put(connection_id, %{
               "connection_id" => connection_id,
               "tenant" => tenant_id(),
               "provider" => "github",
               "access_token" => "user-owned-token",
               "scopes" => ["repo"],
               "status" => "active"
             })

    assert {:ok, binding, nil} =
             OAuthBindings.put(
               tenant_id(),
               group_id,
               "github",
               "github",
               connection_id
             )

    before =
      SalixStore.S3.Fake.dump()
      |> Map.new(fn {key, object} -> {key, object.body} end)

    response =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/eval/integration-materializations",
        json: %{
          integration_id: "github-eval",
          provider: "github",
          alias: "github",
          credentials: %{type: "oauth", access_token: "eval-token"},
          scopes: ["repo"]
        }
      )

    assert response.status == 409
    assert response.body["error"] =~ "already owned"

    assert SalixStore.S3.Fake.dump()
           |> Map.reject(fn {key, _object} ->
             String.starts_with?(key, "ctl/integration_materializations/")
           end)
           |> Map.new(fn {key, object} -> {key, object.body} end) == before

    assert {:ok, unchanged} = OAuthBindings.get(group_id, binding["binding_id"])
    assert unchanged["connection_id"] == connection_id
  end

  test "serializes the OAuth alias claim across concurrent eval materializations" do
    assert {:ok, _counts} = SalixMCP.Builtins.seed_builtin_definitions()
    group = treq(:post, "/v1/runtime/agent-groups", json: %{name: "OAuth idempotency"})
    group_id = group.body["group_id"]

    body = %{
      integration_id: "github",
      provider: "github",
      alias: "github",
      credentials: %{type: "oauth", access_token: "github-eval-token"},
      scopes: ["repo", "read:org", "read:user", "user:email"],
      plugin: %{plugin_id: "github", connection_id: "github-managed"}
    }

    key = tenant_key()

    responses =
      1..2
      |> Task.async_stream(
        fn _index ->
          req_as(
            key,
            :post,
            "/v1/runtime/agent-groups/#{group_id}/eval/integration-materializations",
            json: body
          )
        end,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, response} -> response end)

    assert Enum.map(responses, & &1.status) == [200, 200]
    assert responses |> Enum.map(& &1.body["materialization_id"]) |> Enum.uniq() |> length() == 1
    assert OAuthBindings.list_records(group_id) |> length() == 1
    assert MCPStore.list_group_bindings(tenant_id(), group_id) |> length() == 1

    other_group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "OAuth ownership race"})

    competing_bodies = [
      Map.put(body, :integration_id, "github-a"),
      body
      |> Map.put(:integration_id, "github-b")
      |> put_in([:credentials, :access_token], "other-token")
    ]

    competing =
      competing_bodies
      |> Task.async_stream(
        fn request_body ->
          req_as(
            key,
            :post,
            "/v1/runtime/agent-groups/#{other_group.body["group_id"]}/eval/integration-materializations",
            json: request_body
          )
        end,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, response} -> response end)

    assert competing |> Enum.map(& &1.status) |> Enum.sort() == [200, 409]
    assert OAuthBindings.list_records(other_group.body["group_id"]) |> length() == 1
  end

  test "reconciles an ambiguous OAuth binding PUT before committing materialization" do
    group = treq(:post, "/v1/runtime/agent-groups", json: %{name: "OAuth ambiguity"})
    group_id = group.body["group_id"]
    alias_name = "github"

    binding_id =
      "oauth-" <>
        String.slice(
          SalixStore.Crypto.hex(Jason.encode!(["fixed", "github", alias_name])),
          0,
          32
        )

    binding_key = Keys.ctl_oauth_group_binding(group_id, binding_id)
    :ok = SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, binding_key})

    body = %{
      integration_id: "github",
      provider: "github",
      alias: alias_name,
      credentials: %{type: "oauth", access_token: "github-eval-token"},
      scopes: ["repo"]
    }

    created =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/eval/integration-materializations",
        json: body
      )

    assert created.status == 200, inspect(created.body)
    oauth = created.body["resources"]["oauth_binding"]
    assert oauth["binding_id"] == binding_id
    assert {:ok, connection} = SalixStore.OAuth.get(oauth["connection_id"])
    assert connection["access_token"] == "github-eval-token"

    retried =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/eval/integration-materializations",
        json: body
      )

    assert retried.status == 200
    assert retried.body["materialization_id"] == created.body["materialization_id"]
    assert OAuthBindings.list_records(group_id) |> length() == 1
  end

  test "materialized OAuth identifiers preserve structured tuple boundaries" do
    group = treq(:post, "/v1/runtime/agent-groups", json: %{name: "OAuth tuple identity"})
    group_id = group.body["group_id"]

    assert {:ok, first, true} =
             OAuthBindings.put_materialized(
               tenant_id(),
               group_id,
               "github:enterprise",
               "work",
               "conn-first",
               "integration-first"
             )

    assert {:ok, second, true} =
             OAuthBindings.put_materialized(
               tenant_id(),
               group_id,
               "github",
               "enterprise:work",
               "conn-second",
               "integration-second"
             )

    refute first["binding_id"] == second["binding_id"]
    assert OAuthBindings.list_records(group_id) |> length() == 2
  end

  test "rolls back OAuth, MCP, and plugin state when plugin preparation fails" do
    assert {:ok, _counts} = SalixMCP.Builtins.seed_builtin_definitions()
    group = treq(:post, "/v1/runtime/agent-groups", json: %{name: "OAuth rollback"})
    group_id = group.body["group_id"]

    assert {:ok, _conflicting_binding} =
             MCPStore.create_binding(tenant_id(), group_id, %{
               "mcp_id" => "mcp1_0000000000000000007",
               "alias" => "github",
               "target_ref" => "remote:notion",
               "placement" => "server"
             })

    before =
      SalixStore.S3.Fake.dump()
      |> Map.new(fn {key, object} -> {key, object.body} end)

    response =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/eval/integration-materializations",
        json: %{
          integration_id: "github",
          provider: "github",
          alias: "github",
          credentials: %{type: "oauth", access_token: "github-eval-token"},
          scopes: ["repo", "read:org", "read:user", "user:email"],
          plugin: %{plugin_id: "github", connection_id: "github-managed"}
        }
      )

    assert response.status == 409, inspect(response.body)
    assert response.body["error"] =~ "MCP alias github is already in use"

    assert SalixStore.S3.Fake.dump()
           |> Map.reject(fn {key, _object} ->
             String.starts_with?(key, "ctl/integration_materializations/")
           end)
           |> Map.new(fn {key, object} -> {key, object.body} end) == before

    assert OAuthBindings.list_records(group_id) == []
  end

  test "materializes native remote MCP OAuth through the same integration route" do
    assert {:ok, _counts} = SalixMCP.Builtins.seed_builtin_definitions()
    previous_private_targets = Application.get_env(:salix_mcp, :allow_private_http_targets)
    Application.put_env(:salix_mcp, :allow_private_http_targets, true)

    on_exit(fn ->
      if is_nil(previous_private_targets) do
        Application.delete_env(:salix_mcp, :allow_private_http_targets)
      else
        Application.put_env(:salix_mcp, :allow_private_http_targets, previous_private_targets)
      end
    end)

    mcp_server =
      start_supervised!(
        {ProtectedMCP,
         expected_authorization: "Bearer notion-eval-token",
         pause_authorized_method: "initialize",
         pause_notify: self()}
      )

    assert {:ok, _definition, :updated} =
             MCPStore.upsert_system_definition(%{
               "mcp_id" => "mcp1_0000000000000000007",
               "tenant_id" => "",
               "name" => "Notion",
               "description" => "Notion materialization test MCP.",
               "server_metadata" => %{
                 "name" => "Notion",
                 "remotes" => [
                   %{
                     "target_ref" => "remote:notion",
                     "transport" => "streamable-http",
                     "url" => ProtectedMCP.base_url(mcp_server) <> "/mcp",
                     "headers_schema" => %{
                       "Authorization" => %{
                         "isRequired" => true,
                         "isSecret" => true,
                         "value" => "Bearer ${NOTION_ACCESS_TOKEN}"
                       }
                     }
                   }
                 ]
               },
               "supports_server" => true,
               "recommended_placement" => "server",
               "supported_placements" => ["server"],
               "auth_requirements" => %{"notion" => ["oauth"]},
               "declared_capabilities" => %{"tools" => true},
               "environment_requirements" => %{"server" => ["public_network"]},
               "trust" => %{"source" => "system_builtin"},
               "created_by" => "system"
             })

    failed_group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Notion Eval Refresh Failure"})

    failed_group_id = failed_group.body["group_id"]

    before_failed_materialization =
      SalixStore.S3.Fake.dump()
      |> Map.reject(fn {key, _object} -> String.starts_with?(key, "meet/") end)
      |> Map.new(fn {key, object} -> {key, object.body} end)

    assert {:ok, projection_before_failure} =
             Plugins.runtime_projection(%{
               "tenant_id" => tenant_id(),
               "group_id" => failed_group_id
             })

    failed_materialization =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{failed_group_id}/eval/integration-materializations",
        json: %{
          integration_id: "notion-failed-refresh",
          provider: "notion",
          alias: "notion",
          provider_key: "evalens:notion:failed-refresh",
          credentials: %{type: "oauth", access_token: "wrong-notion-token"},
          scopes: ["read_content"],
          plugin: %{plugin_id: "notion", connection_id: "notion-native"}
        }
      )

    assert failed_materialization.status == 502
    assert failed_materialization.body["error"] =~ "did not become runnable"

    assert SalixStore.S3.Fake.dump()
           |> Map.reject(fn {key, _object} ->
             String.starts_with?(key, "ctl/integration_materializations/") or
               String.starts_with?(key, "meet/")
           end)
           |> Map.new(fn {key, object} -> {key, object.body} end) ==
             before_failed_materialization

    assert OAuthBindings.list_records(failed_group_id) == []
    assert MCPStore.list_group_bindings(tenant_id(), failed_group_id) == []

    assert Plugins.runtime_projection(%{
             "tenant_id" => tenant_id(),
             "group_id" => failed_group_id
           }) == {:ok, projection_before_failure}

    group = treq(:post, "/v1/runtime/agent-groups", json: %{name: "Notion Eval"})
    group_id = group.body["group_id"]

    key = tenant_key()

    notion_task =
      Task.async(fn ->
        req_as(
          key,
          :post,
          "/v1/runtime/agent-groups/#{group_id}/eval/integration-materializations",
          json: %{
            integration_id: "notion",
            provider: "notion",
            provider_key: "mcp_notion_eval",
            alias: "notion",
            credentials: %{type: "oauth", access_token: "notion-eval-token"},
            scopes: [],
            plugin: %{plugin_id: "notion", connection_id: "notion-native"}
          }
        )
      end)

    assert_receive {:protected_mcp_paused, ^mcp_server, "initialize"}, 5_000

    github_task =
      Task.async(fn ->
        req_as(
          key,
          :post,
          "/v1/runtime/agent-groups/#{group_id}/eval/integration-materializations",
          json: %{
            integration_id: "github",
            provider: "github",
            alias: "github",
            credentials: %{type: "oauth", access_token: "github-eval-token"},
            scopes: ["repo", "read:org", "read:user", "user:email"],
            plugin: %{plugin_id: "github", connection_id: "github-managed"}
          }
        )
      end)

    assert Task.yield(github_task, 150) == nil
    assert OAuthBindings.list_records(group_id) |> Enum.all?(&(&1["alias"] != "github"))

    ProtectedMCP.release(mcp_server)

    created = Task.await(notion_task, 10_000)
    github_created = Task.await(github_task, 10_000)

    assert github_created.status == 200, inspect(github_created.body)

    assert {:ok, github_binding} =
             SalixMCP.Store.find_binding_by_alias(tenant_id(), group_id, "github")

    assert github_binding["alias"] == "github"

    assert created.status == 200, inspect(created.body)
    assert created.body["materialization_kind"] == "remote_mcp_oauth"
    refute inspect(created.body) =~ "notion-eval-token"

    [mcp] = created.body["resources"]["mcp_bindings"]

    assert {:ok, mcp_binding} =
             SalixMCP.Store.get_binding(
               tenant_id(),
               group_id,
               mcp["binding_id"]
             )

    assert is_binary(mcp_binding["remote_oauth_binding_id"])

    assert {:ok, connection} =
             MCPStore.read_connection(tenant_id(), group_id, mcp["binding_id"])

    assert connection["status"] == "running"
    assert Enum.any?(get_in(connection, ["discovered", "tools"]), &(&1["name"] == "echo"))

    assert Salix.Control.RemoteMCPOAuth.resolve_headers(mcp_binding) ==
             {:ok, %{"authorization" => "Bearer notion-eval-token"}}

    assert {:ok, result} =
             SalixMCP.Gateway.call_tool(
               tenant_id(),
               group_id,
               mcp["binding_id"],
               "echo",
               %{"marker" => "ready"}
             )

    assert result["content"] == "MATERIALIZATION_E2E ready"
    calls = ProtectedMCP.calls(mcp_server)
    assert Enum.any?(calls, &(&1.method == "initialize" and not &1.authorized))
    assert Enum.any?(calls, &(&1.method == "tools/call" and &1.authorized))
  end

  test "Slack Connect OAuth and Events verify exact raw body before routing" do
    start_supervised!(MockSlackOAuth)
    port = start_bandit_retry!(fn p -> {Bandit, plug: MockSlackOAuth, port: p} end)
    api_base = "http://127.0.0.1:#{port}/api"
    secret = "slack-signing-secret"
    Application.put_env(:salix_im, :slack_api_base_url, api_base)

    group = treq(:post, "/v1/runtime/agent-groups", json: %{name: "Slack Connect"})

    assert group.status == 201
    group_id = group.body["group_id"]

    agent =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group_id, name: "Slack Router", is_router: true}
      )

    assert agent.status == 201
    agent_id = agent.body["agent_id"]

    assert treq(:patch, "/v1/runtime/agent-groups/#{group_id}",
             json: %{router_agent_id: agent_id}
           ).status ==
             200

    connect =
      treq(:post, "/v1/runtime/agent-groups/#{group_id}/im/providers/slack/connects",
        json: %{
          app_name: "Comma Slack Test",
          app_id: "A-SLACK",
          client_id: "client-1",
          client_secret: "client-secret-1",
          signing_secret: secret
        }
      )

    assert connect.status == 201
    connect_id = connect.body["connect_id"]
    refute Map.has_key?(connect.body, "client_secret")
    refute Map.has_key?(connect.body, "signing_secret")
    assert connect.body["client_secret_configured"] == true
    assert connect.body["signing_secret_configured"] == true

    state =
      URI.parse(connect.body["oauth_url"]).query |> URI.decode_query() |> Map.fetch!("state")

    callback =
      Req.request!(
        method: :get,
        url:
          base() <>
            "/v1/im/slack/oauth/callback?" <> URI.encode_query(%{state: state, code: "code-1"})
      )

    assert callback.status == 200
    assert callback.body =~ "Successfully connected to Slack"

    [oauth_req, auth_req] = MockSlackOAuth.requests()
    assert oauth_req.method == "oauth.v2.access"
    assert oauth_req.params["client_id"] == "client-1"
    assert oauth_req.params["client_secret"] == "client-secret-1"
    assert oauth_req.params["code"] == "code-1"
    assert oauth_req.params["redirect_uri"] =~ "/v1/im/slack/oauth/callback"
    assert auth_req.method == "auth.test"
    assert auth_req.params == %{}
    assert auth_req.auth == "Bearer xoxb-oauth-token"

    [completed] =
      treq(:get, "/v1/runtime/agent-groups/#{group_id}/im/connects?provider=slack").body

    assert completed["connect_id"] == connect_id
    assert completed["workspace_id"] == "T-SLACK"
    assert completed["workspace_name"] == "Slack Test"
    assert completed["bot_id"] == "B-BOT"
    assert completed["bot_user_id"] == "B-SLACK"
    assert completed["bot_username"] == "comma_slack_bot"
    refute Map.has_key?(completed, "bot_token")

    assert {:ok, stored_connect} =
             SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, connect_id))

    assert stored_connect["granted_bot_scopes"] == ["canvases:write", "chat:write"]

    # Hold the first source's round so the second source must remain queued.
    Application.put_env(:salix_agent, :llm, PendingLLM)

    raw =
      ~s({"team_id":"T-SLACK","api_app_id":"A-SLACK","event_id":"Ev-raw-1","type":"event_callback","event":{"type":"app_mention","user":"U1","text":"<@B-SLACK> hello","channel":"C1","ts":"111.200","event_ts":"111.200"}})

    accepted = slack_event(raw, secret)
    assert accepted.status == 200
    assert accepted.body == %{"ok" => true}

    assert_router_session_message(
      agent_id,
      group_id,
      "im_provider:slack:#{connect_id}:Ev-raw-1",
      "<@B-SLACK> hello"
    )

    channel_join =
      ~s({"team_id":"T-SLACK","api_app_id":"A-SLACK","event_id":"Ev-join-1","type":"event_callback","event":{"type":"member_joined_channel","user":"B-SLACK","channel":"C-intro","channel_type":"C","team":"T-SLACK","inviter":"U1"}})

    joined = slack_event(channel_join, secret)
    assert joined.status == 200
    assert joined.body == %{"ok" => true}

    # The first Slack source still owns an unresolved reply obligation in this
    # ingestion-only fixture. A second source was routed successfully, but it
    # remains in the durable source log until the active source can admit it.
    assert_router_session_pending_input(
      agent_id,
      group_id,
      "im_provider:slack:#{connect_id}:channel_joined:C-intro:Ev-join-1",
      "post one short intro message in this channel"
    )

    assert fake_records_with_prefix("ctl/bridge_conversations/#{tenant_id()}/") == %{}

    duplicate = slack_event(raw, secret)
    assert duplicate.status == 200
    assert duplicate.body == %{"duplicate" => true}

    compact =
      ~s({"team_id":"T-SLACK","api_app_id":"A-SLACK","event_id":"Ev-raw-2","type":"event_callback","event":{"type":"app_mention","user":"U2","text":"same json, different bytes","channel":"C1","ts":"222.200","event_ts":"222.200"}})

    pretty = """
    {
      "team_id": "T-SLACK",
      "api_app_id": "A-SLACK",
      "event_id": "Ev-raw-2",
      "type": "event_callback",
      "event": {
        "type": "app_mention",
        "user": "U2",
        "text": "same json, different bytes",
        "channel": "C1",
        "ts": "222.200",
        "event_ts": "222.200"
      }
    }
    """

    timestamp = Integer.to_string(System.system_time(:second))
    rejected = post_slack_event(pretty, timestamp, slack_sig(secret, timestamp, compact))
    assert rejected.status == 401
    assert rejected.body == %{"error" => "invalid Slack signature"}
  end

  test "Telegram and Feishu provider connects support Commaboard installation lifecycle" do
    start_supervised!(MockIMProviderAPI)
    port = start_bandit_retry!(fn p -> {Bandit, plug: MockIMProviderAPI, port: p} end)
    Application.put_env(:salix_im, :telegram_api_base_url, "http://127.0.0.1:#{port}/telegram")
    Application.put_env(:salix_im, :feishu_api_base_url, "http://127.0.0.1:#{port}/open-apis")

    group_id = create_test_group("IM Connects")["group_id"]

    bad_telegram =
      treq(:post, "/v1/runtime/agent-groups/#{group_id}/im/providers/telegram/connects",
        json: %{}
      )

    assert bad_telegram.status == 400
    assert bad_telegram.body["error"] == "bot_token is required"

    telegram =
      treq(:post, "/v1/runtime/agent-groups/#{group_id}/im/providers/telegram/connects",
        json: %{bot_token: "123456:secret-token"}
      )

    assert telegram.status == 201
    telegram_id = telegram.body["connect_id"]
    assert telegram.body["provider"] == "telegram"
    assert telegram.body["status"] == "connected"
    assert telegram.body["bot_user_id"] == "1001"
    assert telegram.body["bot_username"] == "bridge_bot"
    assert telegram.body["bot_token_configured"] == true
    refute Map.has_key?(telegram.body, "bot_token")
    refute Map.has_key?(telegram.body, "api_base_url")

    assert {:ok, stored_telegram} =
             ProviderConnects.get_active_connect_by_id(group_id, telegram_id, "telegram")

    assert stored_telegram["bot_display_name"] == "Bridge"

    patched_telegram =
      treq(
        :patch,
        "/v1/runtime/agent-groups/#{group_id}/im/providers/telegram/connects/#{telegram_id}",
        json: %{bot_token: "123456:updated-token"}
      )

    assert patched_telegram.status == 200
    assert patched_telegram.body["status"] == "connected"
    assert patched_telegram.body["bot_user_id"] == "1002"
    assert patched_telegram.body["bot_username"] == "bridge_updated_bot"
    assert patched_telegram.body["bot_token_configured"] == true
    refute Map.has_key?(patched_telegram.body, "bot_token")
    refute Map.has_key?(patched_telegram.body, "api_base_url")

    assert {:ok, stored_patched_telegram} =
             ProviderConnects.get_active_connect_by_id(group_id, telegram_id, "telegram")

    assert stored_patched_telegram["bot_display_name"] == "Bridge Updated"

    assert treq(
             :post,
             "/v1/runtime/agent-groups/#{group_id}/im/connects/#{telegram_id}/disable"
           ).body ==
             %{"disabled" => true}

    [disabled_telegram] =
      treq(:get, "/v1/runtime/agent-groups/#{group_id}/im/connects?provider=telegram").body

    assert disabled_telegram["connect_id"] == telegram_id
    assert is_integer(disabled_telegram["disabled_at"])

    assert treq(
             :post,
             "/v1/runtime/agent-groups/#{group_id}/im/connects/#{telegram_id}/enable"
           ).body ==
             %{"enabled" => true}

    [enabled_telegram] =
      treq(:get, "/v1/runtime/agent-groups/#{group_id}/im/connects?provider=telegram").body

    assert enabled_telegram["connect_id"] == telegram_id
    refute Map.has_key?(enabled_telegram, "disabled_at")

    assert {:ok, _} =
             Salix.Control.Tenants.put_feishu_tenant_app(tenant_id(), %{
               "app_id" => "cli_a",
               "app_secret" => "secret-a",
               "verification_token" => "verify-a",
               "encrypt_key" => "encrypt-a"
             })

    feishu =
      treq(:post, "/v1/runtime/agent-groups/#{group_id}/im/providers/feishu/connects",
        json: %{
          app_name: "Feishu Smoke",
          app_id: "cli_a"
        }
      )

    assert feishu.status == 201
    feishu_id = feishu.body["connect_id"]
    assert feishu.body["provider"] == "feishu"
    assert feishu.body["app_secret_configured"] == true
    assert feishu.body["verification_token_configured"] == true
    assert feishu.body["encrypt_key_configured"] == true
    assert feishu.body["webhook_url"] =~ "/v1/im/feishu/events"
    refute feishu.body["webhook_url"] =~ feishu_id
    refute Map.has_key?(feishu.body, "app_secret")
    refute Map.has_key?(feishu.body, "verification_token")
    refute Map.has_key?(feishu.body, "api_base_url")

    assert {:ok, _} =
             Salix.Control.Tenants.put_feishu_tenant_app(tenant_id(), %{
               "app_id" => "cli_b",
               "app_secret" => "secret-b",
               "verification_token" => "verify-b",
               "encrypt_key" => "encrypt-b"
             })

    patched_feishu =
      treq(
        :patch,
        "/v1/runtime/agent-groups/#{group_id}/im/providers/feishu/connects/#{feishu_id}",
        json: %{
          app_name: "Feishu Updated",
          app_id: "cli_b"
        }
      )

    assert patched_feishu.status == 200
    assert patched_feishu.body["app_name"] == "Feishu Updated"
    assert patched_feishu.body["app_id"] == "cli_b"
    assert patched_feishu.body["status"] == "connected"
    refute Map.has_key?(patched_feishu.body, "api_base_url")

    assert treq(
             :post,
             "/v1/runtime/agent-groups/#{group_id}/im/connects/#{feishu_id}/disable"
           ).body ==
             %{"disabled" => true}

    [disabled_feishu] =
      treq(:get, "/v1/runtime/agent-groups/#{group_id}/im/connects?provider=feishu").body

    assert disabled_feishu["connect_id"] == feishu_id
    assert is_integer(disabled_feishu["disabled_at"])

    assert treq(
             :post,
             "/v1/runtime/agent-groups/#{group_id}/im/connects/#{feishu_id}/enable"
           ).body ==
             %{"enabled" => true}

    assert treq(:delete, "/v1/runtime/agent-groups/#{group_id}/im/connects/#{telegram_id}").body ==
             %{"deleted" => true}

    assert treq(:delete, "/v1/runtime/agent-groups/#{group_id}/im/connects/#{feishu_id}").body ==
             %{"deleted" => true}

    assert treq(:get, "/v1/runtime/agent-groups/#{group_id}/im/connects").body == []
  end

  test "public IM webhook routes reject structurally malformed callback fields" do
    for envelope <- [
          %{"header" => 42},
          %{"header" => %{"app_id" => %{"nested" => "value"}}}
        ] do
      response =
        Req.request!(
          method: :post,
          url: base() <> "/v1/im/feishu/events",
          headers: [{"content-type", "application/json"}],
          json: envelope,
          retry: false
        )

      assert response.status == 400
      assert response.body == %{"error" => "malformed Feishu envelope"}
    end

    response =
      Req.request!(
        method: :post,
        url: base() <> "/v1/im/slack/events",
        headers: [{"content-type", "application/json"}],
        json: %{
          "type" => "url_verification",
          "challenge" => %{"nested" => "value"}
        },
        retry: false
      )

    assert response.status == 400
    assert response.body == %{"error" => "malformed Slack url_verification challenge"}
  end

  test "Feishu provider webhook verifies, routes, and dedupes into the group router session" do
    start_supervised!(MockIMProviderAPI)
    port = start_bandit_retry!(fn p -> {Bandit, plug: MockIMProviderAPI, port: p} end)
    Application.put_env(:salix_im, :feishu_api_base_url, "http://127.0.0.1:#{port}/open-apis")

    suffix = System.unique_integer([:positive])
    group_id = create_test_group("Feishu Webhook #{suffix}")["group_id"]

    router_agent =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group_id, name: "Feishu Router", role: "router"}
      )

    assert router_agent.status == 201
    router_agent_id = router_agent.body["agent_id"]

    assert treq(:patch, "/v1/runtime/agent-groups/#{group_id}",
             json: %{router_agent_id: router_agent_id}
           ).status ==
             200

    assert {:ok, _} =
             Salix.Control.Tenants.put_feishu_tenant_app(tenant_id(), %{
               "app_id" => "cli_hook",
               "app_secret" => "secret-hook",
               "verification_token" => "verify-hook",
               "encrypt_key" => "encrypt-hook"
             })

    connect =
      treq(:post, "/v1/runtime/agent-groups/#{group_id}/im/providers/feishu/connects",
        json: %{
          app_name: "Feishu Webhook",
          app_id: "cli_hook"
        }
      )

    assert connect.status == 201
    connect_id = connect.body["connect_id"]

    challenge =
      Req.request!(
        method: :post,
        url: base() <> "/v1/im/feishu/events",
        headers: [{"content-type", "application/json"}],
        json: %{
          "type" => "url_verification",
          "app_id" => "cli_hook",
          "token" => "verify-hook",
          "challenge" => "chal-1"
        }
      )

    assert challenge.status == 200
    assert challenge.body == %{"challenge" => "chal-1"}

    v2_challenge =
      Req.request!(
        method: :post,
        url: base() <> "/v1/im/feishu/events",
        headers: [{"content-type", "application/json"}],
        json: %{
          "schema" => "2.0",
          "header" => %{
            "event_type" => "url_verification",
            "app_id" => "cli_hook",
            "token" => "verify-hook"
          },
          "event" => %{"challenge" => "chal-v2"}
        }
      )

    assert v2_challenge.status == 200
    assert v2_challenge.body == %{"challenge" => "chal-v2"}

    encrypted_challenge =
      Req.request!(
        method: :post,
        url: base() <> "/v1/im/feishu/events?app_id=cli_hook",
        headers: [{"content-type", "application/json"}],
        json: %{
          "encrypt" =>
            encrypt_feishu_envelope(
              %{
                "schema" => "2.0",
                "header" => %{
                  "event_type" => "url_verification",
                  "app_id" => "cli_hook",
                  "token" => "verify-hook"
                },
                "event" => %{"challenge" => "chal-encrypted"}
              },
              "encrypt-hook"
            )
        }
      )

    assert encrypted_challenge.status == 200
    assert encrypted_challenge.body == %{"challenge" => "chal-encrypted"}

    malformed_challenges = [
      %{
        "type" => "url_verification",
        "app_id" => "cli_hook",
        "token" => "verify-hook",
        "challenge" => %{"nested" => "value"}
      },
      %{
        "schema" => "2.0",
        "header" => %{
          "event_type" => "url_verification",
          "app_id" => "cli_hook",
          "token" => "verify-hook"
        },
        "event" => %{"challenge" => ["not", "a", "string"]}
      },
      %{
        "type" => "url_verification",
        "app_id" => "cli_hook",
        "token" => "verify-hook"
      },
      %{
        "type" => "url_verification",
        "app_id" => "cli_hook",
        "token" => "verify-hook",
        "challenge" => nil
      },
      %{
        "type" => "url_verification",
        "app_id" => "cli_hook",
        "token" => "verify-hook",
        "challenge" => "valid-challenge",
        "request_id" => %{"nested" => "value"}
      }
    ]

    malformed_challenge_responses =
      Enum.map(malformed_challenges, fn envelope ->
        Req.request!(
          method: :post,
          url: base() <> "/v1/im/feishu/events",
          headers: [{"content-type", "application/json"}],
          json: envelope,
          retry: false
        )
      end)

    assert Enum.map(malformed_challenge_responses, & &1.status) == [400, 400, 400, 400, 400]

    assert Enum.all?(malformed_challenge_responses, fn response ->
             response.body == %{"error" => "malformed Feishu envelope"}
           end)

    malformed_request_id_with_header =
      Req.request!(
        method: :post,
        url: base() <> "/v1/im/feishu/events",
        headers: [
          {"content-type", "application/json"},
          {"x-request-id", "request-id-from-header"}
        ],
        json: %{
          "type" => "url_verification",
          "app_id" => "cli_hook",
          "token" => "verify-hook",
          "challenge" => "valid-challenge",
          "request_id" => %{"nested" => "value"}
        },
        retry: false
      )

    assert malformed_request_id_with_header.status == 400
    assert malformed_request_id_with_header.body == %{"error" => "malformed Feishu envelope"}

    malformed_message_responses =
      [
        put_in(
          feishu_message_event("evt-bad-sender", "om-bad-sender", "bad sender"),
          [
            "event",
            "sender"
          ],
          42
        ),
        put_in(
          feishu_message_event("evt-bad-chat-type", "om-bad-chat-type", "bad chat type"),
          ["event", "message", "chat_type"],
          %{"nested" => "value"}
        ),
        put_in(
          feishu_message_event("evt-bad-body", "om-bad-body", "body retry delivered"),
          ["event", "message", "body"],
          42
        )
      ]
      |> Enum.map(fn envelope ->
        Req.request!(
          method: :post,
          url: base() <> "/v1/im/feishu/events",
          headers: [{"content-type", "application/json"}],
          json: envelope,
          retry: false
        )
      end)

    assert Enum.map(malformed_message_responses, & &1.status) == [400, 400, 400]

    assert Enum.all?(malformed_message_responses, fn response ->
             response.body == %{"error" => "malformed Feishu envelope"}
           end)

    body_retry =
      Req.request!(
        method: :post,
        url: base() <> "/v1/im/feishu/events",
        headers: [{"content-type", "application/json"}],
        json: feishu_message_event("evt-bad-body", "om-bad-body", "body retry delivered"),
        retry: false
      )

    assert body_retry.status == 200
    assert body_retry.body == %{"ok" => true, "status" => "queued"}

    assert_router_session_message(
      router_agent_id,
      group_id,
      "im_provider:feishu:#{connect_id}:om-bad-body",
      "body retry delivered"
    )

    bad_token =
      Req.request!(
        method: :post,
        url: base() <> "/v1/im/feishu/events",
        headers: [{"content-type", "application/json"}],
        json: %{
          "type" => "url_verification",
          "app_id" => "cli_hook",
          "token" => "wrong",
          "challenge" => "chal-2"
        }
      )

    assert bad_token.status == 401

    missing_identity_event =
      feishu_message_event(
        "evt-feishu-missing-identity",
        "om_feishu_missing_identity",
        "@_user_1 group hello"
      )
      |> put_in(["event", "message", "chat_type"], "group")
      |> put_in(["event", "message", "mentions"], [
        %{"key" => "@_user_1", "id" => %{"open_id" => "ou_other"}, "name" => "Feishu Webhook"}
      ])

    ignored =
      Req.request!(
        method: :post,
        url: base() <> "/v1/im/feishu/events",
        headers: [{"content-type", "application/json"}],
        json: missing_identity_event
      )

    assert ignored.status == 200
    assert ignored.body == %{"ignored" => true, "ignored_reason" => "bot_identity_missing"}

    assert {:ok, _} =
             SalixStore.CasRecord.update(Keys.ctl_im_connect(group_id, connect_id), fn current ->
               Map.put(current, "bot_open_id", "ou_feishu_bot")
             end)

    # Real Feishu callbacks can include null user IDs for both the sender and bot mention.
    event =
      feishu_message_event("evt-feishu-1", "om_feishu_1", "@_user_1 hello from feishu")
      |> put_in(["event", "sender", "sender_id"], %{
        "open_id" => "ou_feishu",
        "union_id" => "on_feishu",
        "user_id" => nil
      })
      |> put_in(["event", "message", "chat_type"], "group")
      |> put_in(["event", "message", "mentions"], [
        %{
          "key" => "@_user_1",
          "id" => %{
            "open_id" => "ou_feishu_bot",
            "union_id" => "on_feishu_bot",
            "user_id" => nil
          },
          "name" => "Feishu Webhook",
          "tenant_key" => "tenant-feishu"
        }
      ])

    accepted =
      Req.request!(
        method: :post,
        url: base() <> "/v1/im/feishu/events",
        headers: [{"content-type", "application/json"}],
        json: event
      )

    assert accepted.status == 200
    assert accepted.body == %{"ok" => true, "status" => "queued"}

    assert_router_session_message(
      router_agent_id,
      group_id,
      "im_provider:feishu:#{connect_id}:om_feishu_1",
      "hello from feishu"
    )

    assert fake_records_with_prefix("ctl/bridge_conversations/#{tenant_id()}/") == %{}

    duplicate =
      Req.request!(
        method: :post,
        url: base() <> "/v1/im/feishu/events",
        headers: [{"content-type", "application/json"}],
        json: event
      )

    assert duplicate.status == 200
    assert duplicate.body == %{"ok" => true, "status" => "duplicate"}
  end

  test "POST message → round runs → GET returns transcript" do
    a = create_test_agent()
    session_id = SalixStore.Ids.new_session_id()

    Mock.script([
      {:assistant, "using a tool",
       [
         %{
           id: "t1",
           name: "call",
           args: %{"tool" => "help", "params" => %{"tool" => "fs.read_file"}}
         }
       ]},
      {:final, "final answer"}
    ])

    resp =
      treq(:post, "/v1/runtime/agents/#{a}/sessions/#{session_id}/messages",
        json: %{content: "hello", source_message_id: "test-msg-1"}
      )

    assert resp.status == 202
    assert resp.body["accepted"] == true
    assert resp.body["dedupe"] == "created"

    # Round runs async. The final assistant reply proves the actor has started.
    # A zero-wait tool may either finish before the actor observes its job or
    # publish a running row followed by an independently committed terminal.
    _messages =
      poll_until(a, session_id, fn msgs ->
        Enum.any?(msgs, &(&1["content"] == "final answer"))
      end)

    assert :ok = SalixAgent.TestSupport.await_session_quiet(a, session_id)

    messages =
      poll_until(
        a,
        session_id,
        fn msgs ->
          tool_message =
            Enum.find(msgs, &(&1["role"] == "tool" and &1["tool_call_id"] == "t1"))

          tool_payload = decoded_message_content(tool_message)

          tool_payload["name"] == "fs.read_file" or
            (tool_payload["status"] == "running" and
               Enum.any?(msgs, fn message ->
                 payload = decoded_message_content(message)

                 message["role"] == "runtime" and payload["type"] == "tool_call_completed" and
                   payload["tool_call_id"] == "t1"
               end))
        end,
        500
      )

    roles = Enum.map(messages, & &1["role"])
    assert "user" in roles
    assert "assistant" in roles
    assert "tool" in roles

    tool_msg = Enum.find(messages, &(&1["role"] == "tool" and &1["tool_call_id"] == "t1"))
    tool_payload = decoded_message_content(tool_msg)

    case tool_payload do
      %{"status" => "running", "tool_name" => "help"} ->
        assert "runtime" in roles

        terminal =
          Enum.find(messages, fn message ->
            payload = decoded_message_content(message)
            message["role"] == "runtime" and payload["tool_call_id"] == "t1"
          end)

        terminal_payload = decoded_message_content(terminal)
        assert terminal_payload["type"] == "tool_call_completed"
        assert Jason.decode!(terminal_payload["result"]["content"])["name"] == "fs.read_file"

      %{"name" => "fs.read_file"} ->
        refute Enum.any?(messages, fn message ->
                 payload = decoded_message_content(message)
                 message["role"] == "runtime" and payload["tool_call_id"] == "t1"
               end)

      unexpected ->
        flunk("unexpected tool completion shape: #{inspect(unexpected)}")
    end
  end

  test "external pending input stays separate from idle session status" do
    env_id = "env-external-http-#{System.unique_integer([:positive])}"
    session_id = SalixStore.Ids.new_session_id()

    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Ext"}, tenant_id())
    group_id = group["group_id"]

    {:ok, tmpl} = SalixAgent.Templates.create(%{"name" => "Ext Template", "model" => "mock"})

    device_id = "device-" <> env_id
    runtime_id = "runtime-codex"
    device_runtime_id = RuntimeIds.device_runtime_id(device_id, "codex", runtime_id)

    {:ok, ^env_id, device} =
      SalixEnv.Registry.connect(
        "test-node",
        %{
          "tenant_id" => tenant_id(),
          "group_id" => group_id,
          "device_id" => device_id,
          "connector_id" => "connector-" <> env_id,
          "name" => "Codex Device"
        },
        transport_id: env_id
      )

    connector_run_id = device["connector_run_id"]

    {:ok, _record} =
      SalixEnv.Registry.update_meta(connector_run_id, fn meta ->
        Map.put(meta, "agent_runtimes", [
          %{
            "kind" => "external",
            "provider" => "codex",
            "runtime_id" => runtime_id,
            "device_runtime_id" => device_runtime_id,
            "command" => "/usr/local/bin/codex",
            "version_detected" => true,
            "auth_ready" => true,
            "native_server_startable" => true,
            "ready" => true,
            "readiness_checked_at" => System.system_time(:millisecond),
            "readiness_valid_until" => System.system_time(:millisecond) + 600_000
          }
        ])
      end)

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "External HTTP Worker",
          "group_id" => group_id,
          "template_id" => tmpl["template_id"],
          "role" => "worker",
          "runtime_config" => %{
            "kind" => "external",
            "provider" => "codex",
            "device_id" => device_id,
            "runtime_id" => runtime_id,
            "device_runtime_id" => device_runtime_id
          }
        },
        tenant_id()
      )

    agent_id = agent["agent_id"]

    assert {:ok, :external} =
             SalixAgent.ExternalAgentRuntime.stage_delivery(agent_id, %{
               source_message_id: "external-http-message",
               payload: %{
                 "session_id" => session_id,
                 "content" => "external http input",
                 "role" => "user",
                 "created_at" => System.system_time(:second)
               }
             })

    resp = treq(:get, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/messages")

    assert resp.status == 200
    assert resp.body["session_id"] == session_id
    assert resp.body["status"] == "idle"
    assert resp.body["messages"] == []

    status = treq(:get, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/status")
    assert status.status == 200
    assert status.body["status"] == "idle"
    assert status.body["runtime_availability"]["status"] == "ready"

    assert {:ok, %{"input_message_queue" => [%{"content" => "external http input"}]}} =
             SalixAgent.ExternalSessionStore.get_session_record(agent_id, session_id)
  end

  test "transcript seed route appends internal transcript and compact route sees the watermark" do
    agent_id = create_test_agent()
    session_id = SalixStore.Ids.new_session_id()

    assert {:ok, _created} =
             SalixAgent.InternalSessionStore.prepare_create(agent_id, session_id, %{})

    seed =
      treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/transcript/seed",
        json: %{
          source_id: "evalens:http-seed",
          entries: [
            %{role: "user", content: "seed user"},
            %{
              role: "assistant",
              content: "",
              tool_calls: [
                %{id: "call-http-seed", name: "read_file", args: %{path: "/tmp/seed"}}
              ]
            },
            %{
              role: "tool",
              content: "seed tool result",
              tool_call_id: "call-http-seed",
              tool_name: "read_file"
            },
            %{role: "runtime", content: "seed runtime", type: "eval_runtime_note"},
            %{role: "summary", content: "seed summary"}
          ]
        }
      )

    assert seed.status == 200
    assert seed.body["runtime_kind"] == "internal"
    assert seed.body["appended_count"] == 5
    assert seed.body["message_count"] == 5

    replay =
      treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/transcript/seed",
        json: %{
          source_id: "evalens:http-seed",
          entries: [
            %{role: "user", content: "seed user"},
            %{
              role: "assistant",
              content: "",
              tool_calls: [
                %{id: "call-http-seed", name: "read_file", args: %{path: "/tmp/seed"}}
              ]
            },
            %{
              role: "tool",
              content: "seed tool result",
              tool_call_id: "call-http-seed",
              tool_name: "read_file"
            },
            %{role: "runtime", content: "seed runtime", type: "eval_runtime_note"},
            %{role: "summary", content: "seed summary"}
          ]
        }
      )

    assert replay.body["appended_count"] == 0
    assert replay.body["message_count"] == 5

    Mock.script([{:final, "<compaction-summary>seeded transcript</compaction-summary>"}])

    compact = treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/compact")
    assert compact.status == 200
    assert compact.body["status"] == "compacted"

    detail = treq(:get, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}").body
    assert detail["message_count"] == 5
    assert detail["compacted_through"] == 5
    assert detail["summary_sequence"] == 1

    # Receipts count the complete transcript, including archived messages.
    # Seed deduplication uses the permanent ledger, not the hot window.
    {:ok, archived} = SalixAgent.InternalSessionStore.read(agent_id, session_id)
    assert SalixAgent.InternalSession.get(archived, :messages) == []
    assert SalixAgent.InternalSession.get(archived, :archived_through) > 0

    post_seed =
      treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/transcript/seed",
        json: %{
          source_id: "evalens:http-seed-2",
          entries: [
            %{role: "user", content: "after archive"},
            %{role: "assistant", content: "ack after archive"}
          ]
        }
      )

    assert post_seed.status == 200
    assert post_seed.body["appended_count"] == 2
    assert post_seed.body["skipped_count"] == 0
    assert post_seed.body["message_count"] == 7
    assert post_seed.body["last_message_id"] == 7

    post_replay =
      treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/transcript/seed",
        json: %{
          source_id: "evalens:http-seed-2",
          entries: [
            %{role: "user", content: "after archive"},
            %{role: "assistant", content: "ack after archive"}
          ]
        }
      )

    assert post_replay.body["appended_count"] == 0
    assert post_replay.body["skipped_count"] == 2
    assert post_replay.body["message_count"] == 7
    assert post_replay.body["last_message_id"] == 7
  end

  test "conversation transcript seed route materializes router history without dispatch" do
    group = create_test_group("Seed")
    group_id = group["group_id"]

    router =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group_id, name: "Seed Router", role: "router"}
      ).body

    router_id = router["agent_id"]

    worker =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group_id, name: "Seed Worker", role: "worker"}
      ).body

    worker_id = worker["agent_id"]

    assert treq(:patch, "/v1/runtime/agent-groups/#{group_id}",
             json: %{router_agent_id: router_id}
           ).body["router_agent_id"] == router_id

    conversation_id = group["router_conversation_id"]
    session_id = router["router_session_id"]

    seed_body = %{
      created_at: "2026-07-01T00:00:00Z",
      mark_participants_delivered: true,
      conversation: %{
        kind: "user_chat",
        title: "Bridge chat",
        participants: [
          %{
            actor_type: "user",
            user_id: "current",
            role_label: "user"
          },
          %{
            actor_type: "agent",
            agent_id: router_id,
            role_label: "router"
          },
          %{
            actor_type: "agent",
            agent_id: worker_id,
            role_label: "worker"
          }
        ]
      },
      messages: [
        %{
          client_request_id: "seed-user-1",
          actor_type: "user",
          user_id: "current",
          content: [%{type: "text", text: "remember Lyra"}],
          created_at: "2026-07-01T00:00:01Z"
        },
        %{
          client_request_id: "seed-agent-1",
          actor_type: "agent",
          agent_id: router_id,
          role_label: "router",
          content: [%{type: "text", text: "noted"}],
          created_at: "2026-07-01T00:00:02Z"
        }
      ]
    }

    seed =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/transcript/seed",
        json: seed_body
      )

    assert seed.status == 200
    assert seed.body["appended_count"] == 2
    assert seed.body["message_count"] == 2

    assert participant_delivery_records(group_id, conversation_id) == []
    assert treq(:get, "/v1/runtime/agents/#{router_id}/sessions/#{session_id}").status == 404

    router_conversation =
      treq(:get, "/v1/runtime/agent-groups/#{group_id}/router/conversation").body

    assert router_conversation["conversation_id"] == conversation_id
    assert router_conversation["message_count"] == 2

    participants =
      treq(
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/participants"
      ).body["participants"]

    router_participant = Enum.find(participants, &(&1["agent_id"] == router_id))
    worker_participant = Enum.find(participants, &(&1["agent_id"] == worker_id))
    user_participant = Enum.find(participants, &(&1["actor_type"] == "user"))
    worker_session_id = get_in(worker_participant, ["payload", "session_id"])

    assert SalixStore.Ids.valid_participant_id?(router_participant["participant_id"])
    assert SalixStore.Ids.valid_participant_id?(worker_participant["participant_id"])
    assert SalixStore.Ids.valid_participant_id?(user_participant["participant_id"])
    assert SalixStore.Ids.valid_session_id?(worker_session_id)
    assert router_participant["delivery_cursor_seq"] == 2
    assert worker_participant["state"] == "active"

    assert worker_participant["notification_filter"] == %{
             "messages" => "all",
             "statuses" => "none"
           }

    participant_ids =
      Map.new(participants, fn participant ->
        {{participant["actor_type"], participant["agent_id"] || participant["user_id"]},
         participant["participant_id"]}
      end)

    seeded_messages =
      treq(
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages"
      ).body

    assert Enum.all?(seeded_messages, &SalixStore.Ids.valid_message_id?(&1["message_id"]))

    conversation_ids =
      treq(:get, "/v1/runtime/agent-groups/#{group_id}/conversations").body["data"]
      |> Enum.map(& &1["conversation_id"])

    assert conversation_id in conversation_ids

    replay =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/transcript/seed",
        json: seed_body
      )

    assert replay.status == 200
    assert replay.body["appended_count"] == 0
    assert replay.body["skipped_count"] == 2
    assert participant_delivery_records(group_id, conversation_id) == []

    replayed_participants =
      treq(
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/participants"
      ).body["participants"]

    assert Map.new(replayed_participants, fn participant ->
             {{participant["actor_type"], participant["agent_id"] || participant["user_id"]},
              participant["participant_id"]}
           end) == participant_ids

    assert get_in(
             Enum.find(replayed_participants, &(&1["agent_id"] == worker_id)),
             ["payload", "session_id"]
           ) == worker_session_id

    assert treq(
             :get,
             "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages"
           ).body == seeded_messages
  end

  test "session trace returns persisted tool calls usage stages and skill reads" do
    a = create_test_agent()
    session_id = SalixStore.Ids.new_session_id()

    Mock.script([
      {:assistant, "reading a skill",
       [
         %{
           id: "read-1",
           name: "call",
           args: %{
             "tool" => "fs.read_file",
             "params" => %{"path" => "/.runtime/skills/code-review/SKILL.md"}
           }
         }
       ], nil,
       %{
         "model" => "gpt-test",
         "usage" => %{
           "prompt_tokens" => 11,
           "completion_tokens" => 7,
           "total_tokens" => 18,
           "cache_read_input_tokens" => 5,
           "cache_write_input_tokens" => 2
         }
       }},
      {:final, "done",
       %{
         "model" => "gpt-test",
         "usage" => %{
           "prompt_tokens" => 2,
           "completion_tokens" => 3,
           "total_tokens" => 5,
           "cache_read_input_tokens" => 0,
           "cache_write_input_tokens" => 0
         }
       }}
    ])

    assert treq(:post, "/v1/runtime/agents/#{a}/sessions/#{session_id}/messages",
             json: %{content: "inspect", source_message_id: "test-msg-2"}
           ).status ==
             202

    _messages =
      poll_until(
        a,
        session_id,
        fn msgs ->
          Enum.any?(msgs, fn message ->
            payload = decoded_message_content(message)

            (message["role"] == "tool" and message["tool_call_id"] == "read-1" and
               String.starts_with?(message["content"] || "", "error:")) or
              (message["role"] == "runtime" and payload["type"] == "tool_call_failed" and
                 payload["tool_call_id"] == "read-1")
          end) and
            Enum.any?(msgs, &(&1["content"] == "done"))
        end,
        250
      )

    resp = treq(:get, "/v1/runtime/agents/#{a}/sessions/#{session_id}/trace")
    assert resp.status == 200

    trace = resp.body
    assert trace["usage"]["prompt_tokens"] == 13
    assert trace["usage"]["completion_tokens"] == 10
    assert trace["usage"]["total_tokens"] == 23
    assert trace["usage"]["cache_read_input_tokens"] == 5
    assert trace["usage"]["cache_write_input_tokens"] == 2

    assert [%{"call_id" => "read-1", "name" => "fs.read_file", "status" => "error"} = call] =
             trace["tool_calls"]

    assert call["input"] == ~s({"path":"/.runtime/skills/code-review/SKILL.md"})
    assert call["input_truncated"] == false
    assert call["output_truncated"] == false
    assert call["error_class"] == "tool_error"
    assert call["error_message"] =~ "no such file"

    {:ok, tool_started_at, 0} = DateTime.from_iso8601(call["timestamp"])
    assert abs(DateTime.diff(tool_started_at, DateTime.utc_now(), :second)) < 60

    tool_stage = Enum.find(trace["stages"], &(&1["name"] == "salix.tool.execute"))
    assert tool_stage["start_time"] == call["timestamp"]

    assert [%{"path" => "/.runtime/skills/code-review/SKILL.md"}] =
             trace["skill_reads"]

    assert Enum.any?(trace["stages"], &(&1["name"] == "salix.session.round"))

    assert Enum.any?(
             trace["stages"],
             &(&1["name"] == "salix.tool.execute" and
                 &1["attributes"]["tool.name"] == "fs.read_file")
           )

    assert trace["critical_path"]["name"] == "salix.tool.execute"
    assert trace["has_more"] == false
  end

  test "session trace preserves legacy seconds and explicit execution milliseconds" do
    agent_id = create_test_agent()
    session_id = SalixStore.Ids.new_session_id()
    {:ok, _} = InternalSessionStore.prepare_create(agent_id, session_id, %{})

    cases = [
      {%{"started_at" => 1_720_000_000}, "2024-07-03T09:46:40Z"},
      {%{"started_at" => 1_720_000_000_123}, "2024-07-03T09:46:40.123Z"},
      {%{
         "started_at" => 1_720_000_000,
         "execution_timing" => %{"started_at_ms" => 1_720_000_000_456}
       }, "2024-07-03T09:46:40.456Z"}
    ]

    events =
      cases
      |> Enum.with_index(1)
      |> Enum.map(fn {{timing, _expected}, id} ->
        Map.merge(timing, %{
          "type" => "tool_result",
          "session_id" => session_id,
          "message_id" => id,
          "tool_call_id" => "time-#{id}",
          "tool_name" => "fs.read_file",
          "content" => "file contents",
          "created_at" => 1_720_000_001
        })
      end)

    {:ok, _} = InternalSessionStore.prepare_commit(agent_id, session_id, events, hwm: 3)
    response = treq(:get, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/trace")
    assert response.status == 200

    for {{_timing, expected}, id} <- Enum.with_index(cases, 1) do
      call = Enum.find(response.body["tool_calls"], &(&1["call_id"] == "time-#{id}"))
      assert call["timestamp"] == expected
    end
  end

  test "duplicate source_message_id dedupes over HTTP" do
    a = create_test_agent()
    session_id = SalixStore.Ids.new_session_id()

    Mock.script([{:final, "ok"}, {:final, "ok again"}])

    r1 =
      treq(:post, "/v1/runtime/agents/#{a}/sessions/#{session_id}/messages",
        json: %{content: "x", source_message_id: "fixed-1"}
      )

    assert r1.body["dedupe"] == "created"

    _ =
      poll_until(a, session_id, fn msgs ->
        Enum.any?(msgs, &(&1["role"] == "assistant"))
      end)

    r2 =
      treq(:post, "/v1/runtime/agents/#{a}/sessions/#{session_id}/messages",
        json: %{content: "x", source_message_id: "fixed-1"}
      )

    # The session ledger is the single, permanent dedupe authority (A2): the
    # second delivery of the same source id is DETERMINISTICALLY a duplicate —
    # the staged-era two-layer window ("created" until the object was
    # absorbed-and-deleted) no longer exists, so no timing tolerance and no
    # settling sleep.
    assert r2.body["dedupe"] == "duplicate"

    {:ok, session} = SalixAgent.InternalSessionStore.read(a, session_id)

    user_msgs =
      Enum.filter(SalixAgent.InternalSession.get(session, :messages), &(&1.role == "user"))

    assert length(user_msgs) == 1
  end

  test "frontend control models: templates, groups, agents, and sessions" do
    tmpl =
      req(:post, "/v1/admin/templates",
        json: %{
          template_id: "tmpl-#{System.unique_integer([:positive])}",
          name: "Research",
          model: "gpt-test",
          provider: "openai",
          provider_config: %{protocol: "responses", model: "gpt-test"}
        }
      )

    assert tmpl.status == 201
    template_id = tmpl.body["template_id"]
    assert tmpl.body["provider_config"]["model"] == "gpt-test"
    assert tmpl.body["max_tokens"] == 65_536
    assert tmpl.body["context_tokens"] == 0

    public_template =
      Enum.find(
        req(:get, "/v1/admin/templates/catalog").body,
        &(&1["template_id"] == template_id)
      )

    assert public_template["provider_type"] == "openai"
    refute Map.has_key?(public_template, "provider_config")
    refute Map.has_key?(public_template, "image_config")

    admin_template =
      Enum.find(req(:get, "/v1/admin/templates").body, &(&1["template_id"] == template_id))

    assert admin_template["provider_config"]["model"] == "gpt-test"

    assert req(:post, "/v1/admin/templates",
             json: %{
               template_id: "tmpl-missing-model-#{System.unique_integer([:positive])}",
               name: "Missing Model"
             }
           ).status == 400

    assert req(:post, "/v1/admin/templates",
             json: %{
               template_id: "tmpl-bad-image-#{System.unique_integer([:positive])}",
               name: "Bad Image Config",
               model: "gpt-bad",
               image_config: ["not", "an", "object"]
             }
           ).status == 400

    assert req(:patch, "/v1/admin/templates/#{template_id}",
             json: %{video_config: "not an object"}
           ).status == 400

    assert req(
             :delete,
             "/v1/admin/templates/missing-template-#{System.unique_integer([:positive])}"
           ).status == 404

    hidden_template =
      req(:post, "/v1/admin/templates",
        json: %{
          template_id: "tmpl-hidden-#{System.unique_integer([:positive])}",
          name: "Hidden",
          model: "gpt-hidden",
          provider_config: %{base_url: "https://api.groq.com/openai/v1"},
          hidden: true
        }
      ).body

    refute Enum.any?(
             req(:get, "/v1/admin/templates/catalog").body,
             &(&1["template_id"] == hidden_template["template_id"])
           )

    assert Enum.find(
             req(:get, "/v1/admin/templates").body,
             &(&1["template_id"] == hidden_template["template_id"])
           )["provider_type"] == "groq"

    assert req(:delete, "/v1/admin/templates/#{hidden_template["template_id"]}").body[
             "status"
           ] == "deleted"

    assert req(:get, "/v1/admin/templates/#{hidden_template["template_id"]}").status == 404

    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Lab"})

    assert group.status == 201
    group_id = group.body["group_id"]

    assert treq(:post, "/v1/runtime/agents",
             json: %{
               group_id: group_id,
               template_id: "missing-template-#{System.unique_integer([:positive])}",
               name: "Missing Template Agent"
             }
           ).status == 400

    hidden_agent_template =
      req(:post, "/v1/admin/templates",
        json: %{
          template_id: "tmpl-hidden-agent-#{System.unique_integer([:positive])}",
          name: "Hidden Agent Template",
          model: "gpt-hidden-agent",
          hidden: true
        }
      ).body

    assert treq(:post, "/v1/runtime/agents",
             json: %{
               group_id: group_id,
               template_id: hidden_agent_template["template_id"],
               name: "Hidden Template Agent"
             }
           ).status == 400

    agent =
      treq(:post, "/v1/runtime/agents",
        json: %{
          group_id: group_id,
          template_id: template_id,
          name: "Frontend Agent",
          system_prompt: "Be concise"
        }
      )

    assert agent.status == 201
    agent_id = agent.body["agent_id"]
    session_id = SalixStore.Ids.new_session_id()
    assert agent.body["tool_router_enabled"] == false
    refute Map.has_key?(agent.body, "default_session_id")

    bad_router =
      treq(:patch, "/v1/runtime/agent-groups/#{group_id}", json: %{router_agent_id: agent_id})

    assert bad_router.status == 400
    assert bad_router.body["error"] == "router_agent_id must reference a router agent"

    router_agent =
      treq(:post, "/v1/runtime/agents",
        json: %{
          group_id: group_id,
          name: "Frontend Router",
          role: "router"
        }
      )

    assert router_agent.status == 201
    router_agent_id = router_agent.body["agent_id"]

    initial_agent = treq(:get, "/v1/runtime/agents/#{agent_id}").body
    assert initial_agent["name"] == "Frontend Agent"
    assert initial_agent["status"] == "idle"
    refute Map.has_key?(initial_agent, "activity_status")

    assert Enum.any?(
             treq(:get, "/v1/runtime/agents?status=idle").body,
             &(&1["agent_id"] == agent_id and not Map.has_key?(&1, "activity_status"))
           )

    blocked_delete = req(:delete, "/v1/admin/templates/#{template_id}")
    assert blocked_delete.status == 409
    assert blocked_delete.body["error"] =~ "referenced by 1 agent(s)"

    assert Enum.any?(
             treq(:get, "/v1/runtime/agents?group_id=#{group_id}").body,
             &(&1["agent_id"] == agent_id)
           )

    deleted_agent =
      treq(:post, "/v1/runtime/agents",
        json: %{
          group_id: group_id,
          template_id: template_id,
          name: "Deleted Frontend Agent"
        }
      ).body

    assert treq(:delete, "/v1/runtime/agents/#{deleted_agent["agent_id"]}").body["status"] ==
             "cancelled"

    assert treq(:get, "/v1/runtime/agents/#{deleted_agent["agent_id"]}").status == 404

    refute Enum.any?(
             treq(:get, "/v1/runtime/agents?group_id=#{group_id}").body,
             &(&1["agent_id"] == deleted_agent["agent_id"])
           )

    fork_source =
      treq(:post, "/v1/runtime/agents",
        json: %{
          group_id: group_id,
          template_id: template_id,
          name: "Fork Source"
        }
      ).body

    fork_source_id = fork_source["agent_id"]
    fork_source_session_id = SalixStore.Ids.new_session_id()

    {:ok, fork_vfs_event} =
      SalixAgent.AgentWorkspace.prepare_write(fork_source_id, "/memory/fork.txt", "forked memory")

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(
               fork_source_id,
               "router-test-fork-source",
               %{},
               [fork_vfs_event]
             )

    {:ok, _created_source_session} =
      SalixAgent.InternalSessionStore.prepare_create(
        fork_source_id,
        fork_source_session_id,
        %{}
      )

    {:ok, _source_session} =
      SalixAgent.InternalSessionStore.prepare_commit(
        fork_source_id,
        fork_source_session_id,
        [
          %{
            "type" => "delivery",
            "from_queue" => true,
            "session_id" => fork_source_session_id,
            "message_id" => 1,
            "role" => "user",
            "content" => "source message",
            "source_message_id" => "fork-source-message",
            "created_at" => 1_700_000_005,
            "no_wake" => true
          }
        ],
        hwm: 1
      )

    forked_agent =
      treq(:post, "/v1/runtime/agents",
        json: %{
          group_id: group_id,
          template_id: template_id,
          fork_from: fork_source_id,
          name: "Forked Frontend Agent"
        }
      ).body

    assert forked_agent["forked_from"] == fork_source_id

    [forked_session] =
      treq(:get, "/v1/runtime/agents/#{forked_agent["agent_id"]}/sessions").body

    forked_session_id = forked_session["session_id"]
    assert SalixStore.Ids.valid_session_id?(forked_session_id)
    refute forked_session_id == fork_source_session_id
    assert forked_session["source_agent_id"] == fork_source_id
    assert forked_session["source_session_id"] == fork_source_session_id

    fork_messages =
      treq(
        :get,
        "/v1/runtime/agents/#{forked_agent["agent_id"]}/sessions/#{forked_session_id}/messages"
      ).body["messages"]

    assert Enum.any?(fork_messages, &(&1["content"] == "source message"))

    fork_file =
      Req.request!(
        method: :get,
        url: base() <> "/v1/runtime/agents/#{forked_agent["agent_id"]}/files/memory/fork.txt",
        headers: [{"authorization", "Bearer " <> tenant_key()}]
      )

    assert fork_file.status == 200
    assert fork_file.body == "forked memory"

    tmpl2 =
      req(:post, "/v1/admin/templates",
        json: %{
          template_id: "tmpl-#{System.unique_integer([:positive])}",
          name: "Research next",
          model: "gpt-next",
          provider: "openai",
          provider_config: %{protocol: "responses", model: "gpt-next"}
        }
      )

    assert treq(:patch, "/v1/runtime/agents/#{agent_id}",
             json: %{template_id: "missing-template"}
           ).status ==
             400

    assert treq(:patch, "/v1/runtime/agents/#{agent_id}", json: %{system_prompt: ""}).status ==
             400

    assert treq(:patch, "/v1/runtime/agents/#{agent_id}", json: %{tool_router_enabled: "yes"}).status ==
             400

    updated_agent =
      treq(:patch, "/v1/runtime/agents/#{agent_id}",
        json: %{
          template_id: tmpl2.body["template_id"],
          system_prompt: "Updated prompt",
          router_system_prompt: "Router prompt"
        }
      ).body

    assert updated_agent["template_id"] == tmpl2.body["template_id"]
    assert updated_agent["provider"] == "openai"

    assert treq(:patch, "/v1/runtime/agents/#{agent_id}", json: %{tool_router_enabled: true}).body[
             "tool_router_enabled"
           ] == false

    {:ok, control_agent} = SalixAgent.Control.get(agent_id, tenant_id())
    assert control_agent["system_prompt"] == "Updated prompt"
    assert control_agent["router_system_prompt"] == "Router prompt"

    # The agent references its template by id only — provider config resolves
    # live from the template at activation, never journaled as a snapshot.
    {:ok, state} = SalixStore.Agent.read_state(agent_id, SalixAgent.State)
    refute Map.has_key?(state, :llm)
    {:ok, llm} = SalixAgent.Templates.resolve_llm_for_agent(agent_id)
    assert llm["model"] == "gpt-next"
    assert llm["protocol"] == "responses"

    hidden_session_id = SalixStore.Ids.new_session_id()

    assert {:ok, _} =
             SalixAgent.deliver(
               agent_id,
               %{
                 kind: "session_create",
                 session_id: hidden_session_id,
                 name: "Hidden route session",
                 hidden: true,
                 created_at: System.system_time(:second)
               },
               source_message_id: "test:hidden-route-session:#{hidden_session_id}"
             )

    assert eventually(fn ->
             match?({:ok, _}, SalixAgent.InternalSessionStore.read(agent_id, hidden_session_id))
           end)

    refute Enum.any?(
             treq(:get, "/v1/runtime/agents/#{agent_id}/sessions").body,
             &(&1["session_id"] == hidden_session_id)
           )

    assert Enum.any?(
             treq(:get, "/v1/runtime/agents/#{agent_id}/sessions?include_hidden=true").body,
             &(&1["session_id"] == hidden_session_id and &1["hidden"] == true)
           )

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/wake",
             json: %{operation_id: "op-1", result: "ok"}
           ).body[
             "status"
           ] == "queued"

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/cancel").body["status"] == "cancelled"
    poll_agent_stopped(agent_id)
    assert treq(:post, "/v1/runtime/agents/#{agent_id}/wake").body["status"] == "queued"

    {:ok, file_event} =
      SalixAgent.AgentWorkspace.prepare_write(agent_id, "/docs/readme.txt", "hello from vfs")

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(
               agent_id,
               "router-test-readme",
               %{},
               [file_event]
             )

    {:ok, _created_session} =
      SalixAgent.InternalSessionStore.prepare_create(agent_id, session_id, %{})

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(
        agent_id,
        session_id,
        [
          %{
            "type" => "delivery",
            "from_queue" => true,
            "session_id" => session_id,
            "message_id" => 1,
            "source_message_id" => "seed-search",
            "role" => "user",
            "content" => "Find the salix needle",
            "created_at" => 1_700_000_001
          }
        ],
        hwm: 1
      )

    assert [%{"path" => "/docs/", "kind" => "dir"}] =
             treq(:get, "/v1/runtime/agents/#{agent_id}/files").body

    assert [%{"path" => "/docs/readme.txt", "kind" => "file"}] =
             treq(:get, "/v1/runtime/agents/#{agent_id}/files/docs").body

    SalixStore.S3.Fake.reset_read_log()

    file_resp =
      Req.request!(
        method: :get,
        url: base() <> "/v1/runtime/agents/#{agent_id}/files/docs/readme.txt",
        headers: [{"authorization", "Bearer " <> tenant_key()}]
      )

    assert file_resp.status == 200
    assert Req.Response.get_header(file_resp, "content-length") == ["14"]
    assert Req.Response.get_header(file_resp, "transfer-encoding") == []
    assert file_resp.body == "hello from vfs"

    workspace_key = Keys.agent_workspace_state(agent_id)

    assert Enum.count(
             SalixStore.S3.Fake.read_log(),
             &(&1 == {:get, workspace_key})
           ) == 1

    large_size = SalixStore.Blob.max_bytes() + 1
    large_chunk = String.duplicate("L", 256 * 1024)

    {:ok, large_event} =
      SalixAgent.AgentWorkspace.prepare_write_stream(
        agent_id,
        "/docs/large.bin",
        fixed_stream(large_size, large_chunk)
      )

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(
               agent_id,
               "router-test-large",
               %{},
               [large_event]
             )

    large_resp =
      Req.request!(
        method: :get,
        url: base() <> "/v1/runtime/agents/#{agent_id}/files/docs/large.bin",
        headers: [{"authorization", "Bearer " <> tenant_key()}]
      )

    assert large_resp.status == 200

    assert Req.Response.get_header(large_resp, "content-length") == [
             Integer.to_string(large_size)
           ]

    assert Req.Response.get_header(large_resp, "transfer-encoding") == []
    assert byte_size(large_resp.body) == large_size

    put_resp =
      Req.request!(
        method: :put,
        url: base() <> "/v1/runtime/agents/#{agent_id}/files/uploads/new.txt",
        headers: [{"authorization", "Bearer " <> tenant_key()}],
        body: "uploaded over http"
      )

    assert put_resp.status == 200
    assert put_resp.body["path"] == "/uploads/new.txt"
    assert put_resp.body["kind"] == "file"

    upload_resp =
      Req.request!(
        method: :get,
        url: base() <> "/v1/runtime/agents/#{agent_id}/files/uploads/new.txt",
        headers: [{"authorization", "Bearer " <> tenant_key()}]
      )

    assert upload_resp.status == 200
    assert upload_resp.body == "uploaded over http"

    assert treq(:delete, "/v1/runtime/agents/#{agent_id}/files/uploads").status == 409

    assert treq(:delete, "/v1/runtime/agents/#{agent_id}/files/uploads?recursive=true").body ==
             %{
               "path" => "/uploads",
               "deleted" => 1
             }

    assert Req.request!(
             method: :get,
             url: base() <> "/v1/runtime/agents/#{agent_id}/files/uploads/new.txt",
             headers: [{"authorization", "Bearer " <> tenant_key()}]
           ).status == 404

    assert %{
             "results" => [%{"session_id" => ^session_id, "snippet" => snippet}],
             "scope" => "live_window"
           } = treq(:get, "/v1/runtime/agents/#{agent_id}/messages/search?q=needle").body

    assert String.contains?(snippet, "«needle»")

    SalixStore.S3.Fake.reset_read_log()
    assert treq(:get, "/v1/runtime/agents/#{agent_id}/sites").body == []

    assert Enum.count(
             SalixStore.S3.Fake.read_log(),
             &(&1 == {:get, Keys.ctl_agent(agent_id)})
           ) == 1

    SalixStore.S3.Fake.reset_read_log()
    sessions = treq(:get, "/v1/runtime/agents/#{agent_id}/sessions")

    assert Enum.count(
             SalixStore.S3.Fake.read_log(),
             &(&1 == {:get, Keys.ctl_agent(agent_id)})
           ) == 1

    assert Enum.any?(
             sessions.body,
             &(&1["session_id"] == session_id and
                 {&1["status"], &1["activity_status"]} in [
                   {"idle", "paused"},
                   {"active", "thinking"},
                   {"active", "execution"},
                   {"active", "messaging"}
                 ])
           )

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/sessions", json: %{name: "Follow-up"}).status ==
             404

    assert treq(:patch, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}",
             json: %{name: "Renamed"}
           ).status ==
             404

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/cancel").status ==
             404

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/fork",
             json: %{target_session_id: "not-a-session-id", fork_request_id: "req-bad"}
           ).status == 400

    # The fork contract requires a caller-stable key (owner 2026-08-08):
    # a keyless POST is a fixable 400, never a fork.
    assert treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/fork",
             json: %{name: "Forked", message_id: 1}
           ).status == 400

    forked =
      treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/fork",
        json: %{name: "Forked", message_id: 1, fork_request_id: "router-fork-1"}
      )

    assert forked.status == 201
    assert forked.body["name"] == "Forked"

    # The live Agent may still be active when the control request arrives.
    # Whether it compacts or defers, the seeded user request stays searchable.
    compact = treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/compact")
    assert compact.status == 200
    assert compact.body["status"] in ["noop", "compacted"]

    if compact.body["status"] == "noop" do
      assert compact.body["reason"] in ["session_active", "no_new_live_messages"]
    end

    assert treq(:get, "/v1/runtime/agents/#{agent_id}/messages/search?q=needle").body[
             "results"
           ] != []

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/microcompact").body[
             "status"
           ] == "microcompacted"

    assert treq(:delete, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}").status == 404

    tenant_resp = req(:post, "/v1/admin/tenants", json: %{name: "Acme"})
    assert tenant_resp.status == 201
    tenant_id = tenant_resp.body["tenant_id"]
    assert Enum.any?(req(:get, "/v1/admin/tenants").body, &(&1["tenant_id"] == tenant_id))
    assert req(:get, "/v1/admin/tenants/missing-tenant/api-keys").status == 404
    assert req(:get, "/v1/admin/tenants/missing-tenant/agent-groups").status == 404
    assert req(:get, "/v1/admin/tenants/missing-tenant/bridge-conversations").status == 404
    assert req(:delete, "/v1/admin/tenants/missing-tenant/api-keys/missing-key").status == 404

    api_key = req(:post, "/v1/admin/tenants/#{tenant_id}/api-keys", json: %{name: "dev"})
    assert api_key.status == 201
    assert String.starts_with?(api_key.body["key"], "salix_")

    assert req_as(api_key.body["key"], :get, "/v1/admin/templates/catalog").status == 401

    assert req_as(api_key.body["key"], :post, "/v1/admin/templates",
             json: %{template_id: template_id, name: "Tenant key denied"}
           ).status == 401

    assert req_as(api_key.body["key"], :get, "/v1/admin/tenants").status == 401

    assert Enum.any?(
             req(:get, "/v1/admin/tenants/#{tenant_id}/api-keys").body,
             &(&1["key_hash"] == api_key.body["key_hash"])
           )

    assert req(:delete, "/v1/admin/tenants/#{tenant_id}/api-keys/#{api_key.body["key_hash"]}").body[
             "status"
           ] == "deleted"

    now = System.system_time(:second)

    {:ok, _} =
      SalixCluster.Nodes.put("peer-node", %{
        "address" => "10.0.0.2",
        "started_at" => now - 10,
        "heartbeat_at" => now,
        "agent_count" => 7,
        "max_agents" => 50,
        "status" => "active",
        "registry" => %{
          "status" => "active",
          "running_agents" => 7,
          "max_agents" => 50,
          "timestamp" => now,
          "last_seen_at" => now
        }
      })

    stats = req(:get, "/v1/admin/cluster/stats").body
    assert stats["active_nodes"] == 2
    assert stats["total_nodes"] == 2
    assert stats["total_agents"] >= 7
    assert stats["total_capacity"] >= 1050

    nodes = req(:get, "/v1/admin/cluster/nodes").body
    assert Enum.any?(nodes, &(&1["node_id"] == to_string(node())))
    peer = Enum.find(nodes, &(&1["node_id"] == "peer-node"))
    assert peer["agent_count"] == 7
    assert peer["registry"]["running_agents"] == 7
    assert peer["registry"]["fresh_for_handoff"] == true
    assert req(:get, "/v1/admin/cluster/bridge-authz").status == 404

    assert treq(:get, "/v1/browser-rendering-config").status == 404
    assert treq(:patch, "/v1/browser-rendering-config", json: %{}).status == 404

    defaults =
      treq(:patch, "/v1/agent-defaults", json: %{worker_system_prompt: "worker default"})

    assert defaults.body["worker_system_prompt"] == "worker default"

    im_cfg =
      treq(:patch, "/v1/integrations/im",
        json: %{
          slack: %{bot_token: "x"},
          imessage: %{shared_identity: "Shared Bot", shared_handle: "bot@example.test"}
        }
      )

    assert im_cfg.body["slack"]["bot_token"] == "x"
    assert im_cfg.body["imessage"]["shared_identity"] == "Shared Bot"

    default_config =
      req(:get, "/v1/admin/tenants/#{tenant_id()}").body["config"]
      |> Jason.decode!()

    assert default_config["agent_defaults"]["worker_system_prompt"] == "worker default"
    assert default_config["slack"]["bot_token"] == "x"
    assert default_config["imessage"]["shared_handle"] == "bot@example.test"

    branded_config =
      default_config
      |> Map.put("favicon_url", "https://cdn.example.test/favicon.ico")
      |> Map.put("default_og_image_url", "https://cdn.example.test/default-og.png")

    returned_config =
      req(:patch, "/v1/admin/tenants/#{tenant_id()}",
        json: %{config: Jason.encode!(branded_config)}
      ).body[
        "config"
      ]
      |> Jason.decode!()

    assert returned_config["favicon_url"] == "https://cdn.example.test/favicon.ico"
    assert returned_config["default_og_image_url"] == "https://cdn.example.test/default-og.png"

    assert treq(:get, "/v1/runtime/im-conversations").status == 404

    assert req(:get, "/v1/admin/tenants/#{tenant_id()}/bridge-conversations").status == 404

    oauth_app =
      treq(:put, "/v1/runtime/oauth/provider-apps/github",
        json: %{client_id: "gh-client", client_secret: "secret"}
      )

    assert oauth_app.body["client_secret_configured"] == true
    # The secret is stored but never echoed (willow providerAppView).
    refute Map.has_key?(oauth_app.body, "client_secret")

    assert Enum.any?(
             treq(:get, "/v1/runtime/oauth/provider-apps").body,
             &(&1["provider"] == "github" and &1["client_id"] == "gh-client" and
                 not Map.has_key?(&1, "client_secret"))
           )

    assert treq(:put, "/v1/runtime/oauth/provider-apps/not-a-provider", json: %{client_id: "x"}).status ==
             400

    assert treq(:put, "/v1/runtime/oauth/provider-apps/github", json: %{client_id: ""}).status ==
             400

    auth =
      treq(:post, "/v1/runtime/agent-groups/#{group_id}/oauth/github/authorize",
        json: %{alias: "work", scopes: ["repo"]}
      )

    assert auth.status == 200
    assert is_binary(auth.body["state"])
    assert String.contains?(auth.body["authorization_url"], "client_id=gh-client")
    assert String.contains?(auth.body["authorization_url"], auth.body["state"])

    # Willow parity: the binding is created by the provider callback, not by
    # the authorize call — until then the group has no oauth connections.
    assert treq(:get, "/v1/runtime/agent-groups/#{group_id}/oauth-connections").body == []

    assert treq(:post, "/v1/runtime/agent-groups/#{group_id}/oauth/github/authorize",
             json: %{scopes: ["repo"]}
           ).status == 400

    assert treq(:post, "/v1/runtime/agent-groups/#{group_id}/oauth/not-a-provider/authorize",
             json: %{alias: "work"}
           ).status == 400

    # Configured-app precondition (google has no provider app).
    assert treq(:post, "/v1/runtime/agent-groups/#{group_id}/oauth/google/authorize",
             json: %{alias: "work"}
           ).status == 412

    assert treq(
             :patch,
             "/v1/runtime/agent-groups/#{group_id}/oauth-connections/missing-binding",
             json: %{alias: "renamed"}
           ).status == 404

    assert treq(
             :delete,
             "/v1/runtime/agent-groups/#{group_id}/oauth-connections/missing-binding"
           ).status ==
             404

    assert treq(:delete, "/v1/runtime/oauth/provider-apps/github").body["status"] ==
             "deleted"

    refute Enum.any?(
             treq(:get, "/v1/runtime/oauth/provider-apps").body,
             &(&1["provider"] == "github" and &1["client_id"] == "gh-client")
           )

    assert treq(:patch, "/v1/runtime/agent-groups/#{group_id}",
             json: %{router_agent_id: router_agent_id}
           ).body[
             "router_agent_id"
           ] == router_agent_id

    router_conversation =
      treq(:get, "/v1/runtime/agent-groups/#{group_id}/router/conversation")

    assert router_conversation.status == 200
    assert router_conversation.body["created_by_agent_id"] == router_agent_id
    assert router_conversation.body["kind"] == "user_chat"

    router_send =
      treq(:post, "/v1/runtime/agent-groups/#{group_id}/router/messages",
        json: %{content: "hello router", client_request_id: "router-msg-1"}
      )

    assert router_send.status == 201
    assert router_send.body["delivery_status"] == "queued"
    assert router_send.body["conversation_id"] == router_conversation.body["conversation_id"]
    router_message_id = router_send.body["message_id"]
    assert SalixStore.Ids.valid_message_id?(router_message_id)

    assert Enum.any?(
             treq(:get, "/v1/runtime/agent-groups/#{group_id}/router/messages").body,
             &(&1["message_id"] == router_message_id and
                 &1["content"] == [%{"type" => "text", "text" => "hello router"}])
           )

    group_conversation =
      treq(:post, "/v1/runtime/agent-groups/#{group_id}/conversations",
        json: %{
          title: "Group task",
          client_request_id: "frontend-group-task",
          participants: [
            %{
              actor_type: "user",
              user_id: "current",
              state: "active",
              notification_filter: %{messages: "all", statuses: "none"}
            },
            %{
              actor_type: "agent",
              agent_id: agent_id,
              state: "active",
              notification_filter: %{messages: "all", statuses: "none"}
            }
          ]
        }
      )

    assert group_conversation.status == 201
    assert group_conversation.body["agent_group_id"] == group_id
    assert group_conversation.body["title"] == "Group task"
    refute Map.has_key?(group_conversation.body, "participants")
    group_conversation_id = group_conversation.body["conversation_id"]
    assert SalixStore.Ids.valid_conversation_id?(group_conversation_id)

    participants =
      treq(
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{group_conversation_id}/participants"
      ).body["participants"]

    agent_participant =
      Enum.find(
        participants,
        &(&1["actor_type"] == "agent" and &1["agent_id"] == agent_id)
      )

    assert SalixStore.Ids.valid_participant_id?(agent_participant["participant_id"])

    first_group_message =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{group_conversation_id}/messages",
        json: %{
          content: [%{type: "text", text: "first group message"}],
          client_request_id: "gm-1"
        }
      ).body

    assert first_group_message["delivery_status"] == "queued"
    first_group_message_id = first_group_message["message_id"]
    assert SalixStore.Ids.valid_message_id?(first_group_message_id)

    # Idempotent duplicate: still queues delivery so a retry after a partial
    # write (message persisted but wakeup marker missing) cannot lose delivery.
    duplicate_group_message =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{group_conversation_id}/messages",
        json: %{
          content: [%{type: "text", text: "first group message"}],
          client_request_id: "gm-1"
        }
      ).body

    assert duplicate_group_message["delivery_status"] == "queued"
    assert duplicate_group_message["message_id"] == first_group_message_id

    second_group_message =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{group_conversation_id}/messages",
        json: %{
          content: [%{type: "text", text: "second group message"}],
          client_request_id: "gm-2"
        }
      ).body

    assert second_group_message["delivery_status"] == "queued"
    second_group_message_id = second_group_message["message_id"]
    assert SalixStore.Ids.valid_message_id?(second_group_message_id)

    # The materialized router conversation shares the group conversation store.
    group_conversation_ids =
      treq(:get, "/v1/runtime/agent-groups/#{group_id}/conversations").body["data"]
      |> Enum.map(& &1["conversation_id"])

    assert group_conversation_id in group_conversation_ids
    assert router_conversation.body["conversation_id"] in group_conversation_ids

    # >= 2: the dispatched rounds may already have written the agent's reply back.
    assert treq(
             :get,
             "/v1/runtime/agent-groups/#{group_id}/conversations/#{group_conversation_id}"
           ).body[
             "message_count"
           ] >= 2

    assert treq(
             :patch,
             "/v1/runtime/agent-groups/#{group_id}/conversations/#{group_conversation_id}",
             json: %{name: "Renamed group task"}
           ).body["title"] == "Renamed group task"

    assert treq(
             :patch,
             "/v1/runtime/agent-groups/#{group_id}/conversations/#{group_conversation_id}",
             json: %{title: " "}
           ).status == 400

    # The agent's reply is written back asynchronously — assert the user
    # messages exactly and tolerate projected assistant turns.
    group_messages =
      treq(
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{group_conversation_id}/messages"
      ).body

    assert [first_user_message, second_user_message] =
             Enum.filter(group_messages, &(&1["actor_type"] == "user"))

    assert first_user_message["message_id"] == first_group_message_id
    assert first_user_message["content"] == [%{"type" => "text", "text" => "first group message"}]
    assert second_user_message["message_id"] == second_group_message_id

    assert second_user_message["content"] == [
             %{"type" => "text", "text" => "second group message"}
           ]

    after_ids =
      treq(
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{group_conversation_id}/messages?after_id=#{first_group_message_id}"
      ).body
      |> Enum.map(& &1["message_id"])

    assert second_group_message_id in after_ids
    refute first_group_message_id in after_ids

    group_title_search =
      treq(:get, "/v1/runtime/agent-groups/#{group_id}/conversations/search?q=group").body

    assert Enum.any?(
             group_title_search,
             &(&1["conversation_id"] == group_conversation_id and &1["role"] == "conversation")
           )

    group_message_search =
      treq(:get, "/v1/runtime/agent-groups/#{group_id}/conversations/search?q=second").body

    assert Enum.any?(
             group_message_search,
             &(&1["conversation_id"] == group_conversation_id and
                 &1["message_id"] == second_group_message_id and
                 String.contains?(&1["snippet"], "«second»"))
           )

    assert treq(:get, "/v1/runtime/agent-groups/#{group_id}/conversations/search").status ==
             400

    group_delete_conversation =
      treq(:post, "/v1/runtime/agent-groups/#{group_id}/conversations",
        json: %{title: "Temporary group task", client_request_id: "frontend-delete-task"}
      )

    assert group_delete_conversation.status == 201
    group_delete_conversation_id = group_delete_conversation.body["conversation_id"]
    assert SalixStore.Ids.valid_conversation_id?(group_delete_conversation_id)

    assert treq(
             :delete,
             "/v1/runtime/agent-groups/#{group_id}/conversations/#{group_delete_conversation_id}"
           ).status ==
             204

    assert treq(
             :get,
             "/v1/runtime/agent-groups/#{group_id}/conversations/#{group_delete_conversation_id}"
           ).status == 404

    assert treq(
             :get,
             "/v1/runtime/agent-groups/#{group_id}/conversations?cursor=not-a-cursor"
           ).status ==
             400

    {:ok, memory_event} =
      SalixAgent.AgentWorkspace.prepare_write(
        agent_id,
        "/memory/semantic/user.md",
        "tenant memory"
      )

    {:ok, salix_site_event} =
      SalixAgent.AgentWorkspace.prepare_write(
        agent_id,
        "/.salix/websites/docs/index.html",
        "<!doctype html><html><body>docs</body></html>"
      )

    {:ok, preview_site_event} =
      SalixAgent.AgentWorkspace.prepare_write(
        agent_id,
        "/.salix/websites/snake-demo/preview/index.html",
        "<!doctype html><html><body>snake</body></html>"
      )

    {:ok, non_site_file_event} =
      SalixAgent.AgentWorkspace.prepare_write(
        agent_id,
        "/.salix/websites/empty-site/readme.txt",
        "no entrypoint"
      )

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(
               agent_id,
               "router-test-memory-sites",
               %{},
               [
                 memory_event,
                 salix_site_event,
                 preview_site_event,
                 non_site_file_event
               ]
             )

    heartbeat_a_session_id = SalixStore.Ids.new_session_id()
    heartbeat_b_session_id = SalixStore.Ids.new_session_id()
    heartbeat_followup_session_id = SalixStore.Ids.new_session_id()

    for heartbeat_session_id <- [
          heartbeat_a_session_id,
          heartbeat_b_session_id,
          heartbeat_followup_session_id
        ] do
      assert {:ok, _created} =
               SalixAgent.InternalSessionStore.prepare_create(
                 agent_id,
                 heartbeat_session_id,
                 %{}
               )
    end

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(agent_id, heartbeat_a_session_id, [
        %{
          "type" => "session_created",
          "session_id" => heartbeat_a_session_id,
          "name" => "Heartbeat A",
          "hidden" => true,
          "created_at" => 1_700_000_020
        }
      ])

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(agent_id, heartbeat_b_session_id, [
        %{
          "type" => "session_created",
          "session_id" => heartbeat_b_session_id,
          "name" => "Heartbeat B",
          "hidden" => true,
          "created_at" => 1_700_000_030
        }
      ])

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(agent_id, heartbeat_followup_session_id, [
        %{
          "type" => "session_created",
          "session_id" => heartbeat_followup_session_id,
          "name" => "Heartbeat follow-up",
          "source_session_id" => heartbeat_b_session_id,
          "created_at" => 1_700_000_040
        }
      ])

    im_status = treq(:get, "/v1/integrations/im/status").body

    slack_status = Enum.find(im_status, &(&1["platform"] == "slack"))
    assert slack_status["configured"] == true
    assert slack_status["online"] == false

    imessage_status = Enum.find(im_status, &(&1["platform"] == "imessage"))
    assert imessage_status["configured"] == true
    assert imessage_status["shared_identity"] == "Shared Bot"
    assert imessage_status["shared_handle"] == "bot@example.test"

    sites = treq(:get, "/v1/runtime/agents/#{agent_id}/sites").body
    assert Enum.map(sites, & &1["name"]) == ["docs", "snake-demo"]

    assert Enum.all?(sites, fn %{"name" => name, "url" => url} ->
             is_binary(url) and String.contains?(url, name)
           end)

    hosted_sites = treq(:get, "/v1/runtime/hosted-sites?limit=1&offset=1").body
    assert hosted_sites["limit"] == 1
    assert hosted_sites["offset"] == 1
    assert hosted_sites["has_more"] == false
    assert [%{"agent_id" => ^agent_id, "name" => "snake-demo"}] = hosted_sites["sites"]

    assert treq(:get, "/v1/runtime/hosted-sites?limit=0").status == 400
    assert treq(:get, "/v1/runtime/hosted-sites?offset=-1").status == 400

    docs_site = Enum.find(sites, &(&1["name"] == "docs"))
    snake_site = Enum.find(sites, &(&1["name"] == "snake-demo"))

    docs_resp = site_req(docs_site["url"])
    assert docs_resp.status == 200
    assert docs_resp.headers["content-type"] == ["text/html; charset=utf-8"]
    assert docs_resp.body =~ "docs"
    assert docs_resp.body =~ ~s(<link rel="icon" href="https://cdn.example.test/favicon.ico">)

    assert docs_resp.body =~
             ~s(<meta property="og:image" content="https://cdn.example.test/default-og.png">)

    assert docs_resp.body =~ ~s(<meta name="twitter:card" content="summary_large_image">)

    snake_resp = site_req(snake_site["url"])
    assert snake_resp.status == 200
    assert snake_resp.body =~ "snake"

    assert Req.request!(method: :get, url: base() <> "/site/#{agent_id}/docs/_api.json").status ==
             404

    assert treq(:get, "/v1/runtime/im-conversations/telegram/chat-a/topic-a/sessions").status ==
             404

    admin_sessions = treq(:get, "/v1/runtime/agents/#{agent_id}/sessions").body
    admin_session_ids = Enum.map(admin_sessions, & &1["session_id"])
    assert heartbeat_followup_session_id in admin_session_ids
    refute heartbeat_b_session_id in admin_session_ids

    assert Enum.find(admin_sessions, &(&1["session_id"] == heartbeat_followup_session_id))[
             "source_session_id"
           ] == heartbeat_b_session_id

    assert req(
             :get,
             "/v1/admin/tenants/#{tenant_id()}/bridge-conversations/telegram/chat-a/topic-a/heartbeat-sessions"
           ).status == 404

    admin_memory_resp =
      Req.request!(
        method: :get,
        url: base() <> "/v1/runtime/agents/#{agent_id}/files/memory/semantic/user.md",
        headers: [{"authorization", "Bearer " <> tenant_key()}]
      )

    assert admin_memory_resp.status == 200
    assert admin_memory_resp.body == "tenant memory"

    assert Req.request!(
             method: :get,
             url: base() <> "/v1/runtime/agents/#{agent_id}/files/memory/missing.md",
             headers: [{"authorization", "Bearer " <> tenant_key()}]
           ).status == 404

    admin_runtime_file =
      Req.request!(
        method: :get,
        url: base() <> "/v1/runtime/agents/#{agent_id}/files/docs/readme.txt",
        headers: [{"authorization", "Bearer " <> tenant_key()}]
      )

    assert admin_runtime_file.status == 200
    assert admin_runtime_file.body == "hello from vfs"

    assert Req.request!(
             method: :get,
             url: base() <> "/v1/admin/agents/#{agent_id}/files/docs/readme.txt",
             headers: [{"authorization", "Bearer test-token"}]
           ).status == 404

    assert Req.request!(
             method: :get,
             url:
               base() <>
                 "/v1/runtime/im-conversations/telegram/chat-a/topic-a/memory/semantic/user.md",
             headers: [{"authorization", "Bearer " <> tenant_key()}]
           ).status == 404

    conversation_agent =
      treq(:post, "/v1/runtime/agents",
        json: %{
          group_id: group_id,
          template_id: template_id,
          name: "Conversation Route Agent"
        }
      ).body

    conversation_agent_id = conversation_agent["agent_id"]

    assert treq(:get, "/v1/runtime/agents/#{conversation_agent_id}/conversations").status == 404
    assert treq(:post, "/v1/runtime/agents/#{conversation_agent_id}/conversations").status == 404

    assert treq(
             :get,
             "/v1/runtime/agents/#{conversation_agent_id}/conversations/search?q=body"
           ).status == 404

    assert treq(
             :get,
             "/v1/runtime/agents/#{conversation_agent_id}/conversations/conv-http-chat"
           ).status == 404

    assert treq(
             :post,
             "/v1/runtime/agents/#{conversation_agent_id}/conversations/conv-http-chat/messages",
             json: %{content: "not allowed", source_message_id: "test-msg-3"}
           ).status == 404

    env_id = "env-#{System.unique_integer([:positive])}"
    device_id = SalixStore.Ids.new_device_id()

    {:ok, ^env_id, device} =
      SalixEnv.Registry.connect(
        "node-a",
        %{
          "tenant_id" => tenant_id(),
          "group_id" => group_id,
          "device_id" => device_id,
          "connector_id" => "connector-http",
          "name" => "Devbox",
          "os" => "linux",
          "arch" => "amd64"
        },
        transport_id: env_id
      )

    assert Enum.any?(
             treq(:get, "/v1/runtime/environments").body,
             &(&1["connector_run_id"] == device["connector_run_id"])
           )

    path = "/v1/runtime/groups/#{group_id}/environments/#{device_id}"
    assert treq(:get, path).body["name"] == "Devbox"

    assert treq(:delete, path).body["status"] == "disconnected"
  end

  test "meeting agent routes deliver events without legacy conversation side effects" do
    suffix = System.unique_integer([:positive])

    group = treq(:post, "/v1/runtime/agent-groups", json: %{name: "Meeting HTTP"}).body

    assert treq(:get, "/v1/agent-groups/#{group["group_id"]}/meeting-agent").status == 404

    start = treq(:post, "/v1/agent-groups/#{group["group_id"]}/meeting-agent/start")
    assert start.status == 200

    meeting_agent = start.body["meeting_agent"]
    assert meeting_agent["group_id"] == group["group_id"]
    assert meeting_agent["status"] == "running"

    heartbeat = treq(:post, "/v1/agent-groups/#{group["group_id"]}/meeting-agent/heartbeat")
    assert heartbeat.status == 200
    assert heartbeat.body["meeting_agent"]["status"] == "running"
    assert heartbeat.body["meeting_agent"]["heartbeat_at"] >= meeting_agent["heartbeat_at"]

    event = %{
      "event_id" => "meeting-http-#{suffix}",
      "provider" => "slack",
      "meet_url" => "https://meet.google.com/abc-defg-hij",
      "source" => %{"channel_id" => "C-meet", "message_ts" => "111.222"}
    }

    delivered =
      treq(:post, "/v1/agent-groups/#{group["group_id"]}/meeting-agent/events",
        json: %{event: event}
      )

    assert delivered.status == 202
    # Fresh event id + single ledger commit: deterministically created (the
    # staged-era two-layer timing slack is gone, A2).
    assert delivered.body["status"] == "created"

    meeting_agent = delivered.body["meeting_agent"]

    assert SalixStore.Ids.valid_agent_id_for_group?(
             meeting_agent["meeting_agent_id"],
             group["group_id"]
           )

    assert is_binary(meeting_agent["meeting_session_id"])
    assert meeting_agent["meeting_session_id"] != ""
    assert SalixAgent.Fleet.running?(meeting_agent["meeting_agent_id"])

    assert [_] =
             Registry.lookup(
               SalixAgent.Registry,
               SalixAgent.InternalSessionActor.key(
                 meeting_agent["meeting_agent_id"],
                 meeting_agent["meeting_session_id"]
               )
             )

    assert eventually(fn ->
             case SalixAgent.InternalSessionStore.read(
                    meeting_agent["meeting_agent_id"],
                    meeting_agent["meeting_session_id"]
                  ) do
               {:ok, session} ->
                 Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
                   to_string(Map.get(message, :content)) =~ event["event_id"]
                 end)

               _ ->
                 false
             end
           end)

    {:ok, agent} = read_json(Keys.ctl_agent(meeting_agent["meeting_agent_id"]))
    assert agent["role"] == "meeting"
    assert agent["purpose"] == "meeting"
    assert agent["hidden"] == true
    assert agent["group_id"] == group["group_id"]

    group_after = treq(:get, "/v1/runtime/agent-groups/#{group["group_id"]}").body
    refute Map.has_key?(group_after, "router_agent_id")

    assert {:ok, []} = S3.list_all(Keys.ctl_group_conversations_prefix(group["group_id"]))
    assert {:ok, []} = S3.list_all("ctl/bridge_conversations/#{tenant_id()}/")
    assert {:ok, []} = S3.list_all("ctl/bridge/")

    stop = treq(:post, "/v1/agent-groups/#{group["group_id"]}/meeting-agent/stop")
    assert stop.status == 200
    assert stop.body["meeting_agent"]["status"] == "stopped"
    assert SalixAgent.Fleet.running?(meeting_agent["meeting_agent_id"])

    status = treq(:get, "/v1/agent-groups/#{group["group_id"]}/meeting-agent")
    assert status.status == 200
    assert status.body["meeting_agent"]["status"] == "stopped"
  end

  test "meeting runtime callback uses runtime token without tenant auth" do
    suffix = System.unique_integer([:positive])
    meeting_id = "meeting-runtime-http-#{suffix}"
    runtime_token = "runtime-token-#{suffix}"

    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Meeting Runtime HTTP"}).body

    group_id = group["group_id"]

    start = treq(:post, "/v1/agent-groups/#{group["group_id"]}/meeting-agent/start")
    meeting_agent = start.body["meeting_agent"]

    {:ok, _doc, _etag} =
      SalixMeet.Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id(),
          "group_id" => group_id,
          "meeting_agent_id" => meeting_agent["meeting_agent_id"],
          "meeting_session_id" => meeting_agent["meeting_session_id"],
          "provider" => "slack",
          "connect_id" => "slack-runtime",
          "runtime_token" => runtime_token,
          "artifact_root" => SalixMeet.RuntimeEvents.artifact_root(meeting_id),
          "status" => "active"
        }
      )

    runtime_path = "/v1/agent-groups/#{group_id}/meeting-agent/runtime-events"

    rejected =
      Req.request!(
        method: :post,
        url: base() <> runtime_path,
        json: %{
          event: %{
            "type" => "meeting_runtime_update",
            "event_id" => "runtime-http-bad-#{suffix}",
            "meeting_id" => meeting_id,
            "runtime_token" => "wrong-token",
            "status" => "done"
          }
        }
      )

    assert rejected.status == 401

    accepted =
      Req.request!(
        method: :post,
        url: base() <> runtime_path,
        json: %{
          event: %{
            "type" => "meeting_runtime_update",
            "event_id" => "runtime-http-good-#{suffix}",
            "meeting_id" => meeting_id,
            "runtime_token" => runtime_token,
            "status" => "done",
            "artifacts" => [
              %{
                "kind" => "transcript",
                "data" => "runtime transcript"
              }
            ]
          }
        }
      )

    assert accepted.status == 202
    assert accepted.body["status"] == "created"

    {:ok, doc, _etag} = SalixMeet.Store.get(meeting_id)
    assert doc["state"]["status"] == "done"

    assert doc["state"]["artifacts"]["transcript"]["path"] ==
             "/meetings/#{meeting_id}/transcript.txt"

    {:ok, session} =
      SalixAgent.InternalSessionStore.read(
        meeting_agent["meeting_agent_id"],
        meeting_agent["meeting_session_id"]
      )

    contents =
      Enum.map_join(
        SalixAgent.InternalSession.get(session, :messages),
        "\n",
        &to_string(&1.content)
      )

    assert contents =~ "runtime-http-good-#{suffix}"
    refute contents =~ runtime_token
  end

  test "meeting agent has conversation participant shape" do
    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Meeting Participant"}).body

    start = treq(:post, "/v1/agent-groups/#{group["group_id"]}/meeting-agent/start")
    meeting_agent = start.body["meeting_agent"]

    conversation =
      treq(:post, "/v1/runtime/agent-groups/#{group["group_id"]}/conversations",
        json: %{
          kind: "agent_task",
          title: "Meeting Conversation",
          created_by_agent_id: meeting_agent["meeting_agent_id"],
          participants: [
            %{
              actor_type: "agent",
              agent_id: meeting_agent["meeting_agent_id"],
              agent_name: "__internal_meeting_agent",
              payload: %{"session_id" => meeting_agent["meeting_session_id"]},
              role_label: "meeting",
              state: "active",
              notification_filter: %{messages: "none", statuses: "none"},
              created_at: 1_700_000_000,
              updated_at: 1_700_000_000
            }
          ]
        }
      )

    assert conversation.status == 201
    conversation_id = conversation.body["conversation_id"]
    assert Ids.valid_conversation_id?(conversation_id)
    assert conversation.body["kind"] == "agent_task"
    assert conversation.body["created_by_agent_id"] == meeting_agent["meeting_agent_id"]
    refute Map.has_key?(conversation.body, "participants")

    participants =
      treq(
        :get,
        "/v1/runtime/agent-groups/#{group["group_id"]}/conversations/#{conversation_id}/participants"
      ).body["participants"]

    assert [
             %{
               "actor_type" => "agent",
               "agent_id" => agent_id,
               "role_label" => "meeting",
               "notification_filter" => %{"messages" => "none", "statuses" => "none"}
             } = participant
           ] = participants

    assert agent_id == meeting_agent["meeting_agent_id"]
    assert Ids.valid_participant_id?(participant["participant_id"])
    assert get_in(participant, ["payload", "session_id"]) == meeting_agent["meeting_session_id"]
    refute Map.has_key?(participant, "session_id")
    assert SalixAgent.Fleet.running?(meeting_agent["meeting_agent_id"])
  end

  test "meeting agent event route requires an explicit event envelope" do
    group_id = create_test_group("Meeting Invalid")["group_id"]

    response =
      treq(:post, "/v1/agent-groups/#{group_id}/meeting-agent/events",
        json: %{event_id: "not-enveloped"}
      )

    assert response.status == 400
    assert response.body["error"] == "event is required"
    assert {:error, :not_found} = S3.get(Keys.meet_agent(group_id))
  end

  test "initial agent slots list, upsert, and materialize into group agents" do
    suffix = System.unique_integer([:positive])

    worker_template =
      req(:post, "/v1/admin/templates",
        json: %{
          template_id: "tmpl-worker-slot-#{suffix}",
          name: "Default Worker",
          model: "gpt-worker"
        }
      ).body

    router_template =
      req(:post, "/v1/admin/templates",
        json: %{
          template_id: "tmpl-router-slot-#{suffix}",
          name: "Default Router",
          model: "gpt-router"
        }
      ).body

    main =
      treq(:post, "/v1/initial-agents/main",
        json: %{
          display_name: "Bridge",
          description: "Main worker",
          template_id: worker_template["template_id"],
          avatar_url: "https://cdn.example/bridge.png"
        }
      ).body["initial_agent"]

    assert main["slot"] == "main"
    assert main["is_default"] == true
    assert main["is_router"] == false
    assert main["role"] == "worker"
    assert main["template_name"] == "Default Worker"
    assert main["model"] == "gpt-worker"
    assert main["avatar_url"] == "https://cdn.example/bridge.png"

    router =
      treq(:put, "/v1/initial-agents/router",
        json: %{
          display_name: "Router",
          template_id: router_template["template_id"],
          is_router: true,
          role: "router",
          sort_order: 10,
          enabled: true
        }
      ).body["initial_agent"]

    assert router["slot"] == "router"
    assert router["is_router"] == true
    assert router["role"] == "router"

    slots = treq(:get, "/v1/initial-agents").body["initial_agents"]
    assert Enum.map(slots, & &1["slot"]) == ["main", "router"]

    assert treq(:put, "/v1/initial-agents/bad-role",
             json: %{
               template_id: worker_template["template_id"],
               is_default: true,
               role: "router"
             }
           ).status == 400

    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Slots"}).body

    materialized_worker =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group["group_id"]}/initial-agent-slots/main/materialize"
      ).body[
        "agent"
      ]

    assert materialized_worker["group_id"] == group["group_id"]
    assert materialized_worker["template_id"] == worker_template["template_id"]
    assert materialized_worker["source_initial_agent_slot"] == "main"
    assert materialized_worker["role"] == "worker"

    repeated_worker =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group["group_id"]}/initial-agent-slots/main/materialize"
      ).body[
        "agent"
      ]

    assert repeated_worker["agent_id"] == materialized_worker["agent_id"]

    materialized_router =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group["group_id"]}/initial-agent-slots/router/materialize"
      ).body["agent"]

    assert materialized_router["source_initial_agent_slot"] == "router"
    assert materialized_router["role"] == "router"

    assert treq(:get, "/v1/runtime/agent-groups/#{group["group_id"]}").body[
             "router_agent_id"
           ] ==
             materialized_router["agent_id"]

    assert Enum.any?(
             treq(:get, "/v1/runtime/agents?group_id=#{group["group_id"]}").body,
             &(&1["source_initial_agent_slot"] == "main")
           )
  end

  test "repeat materialization fails closed when the existence check cannot list agents" do
    suffix = System.unique_integer([:positive])
    tmpl_id = "tmpl-mat-failclosed-#{suffix}"

    req(:post, "/v1/admin/templates",
      json: %{template_id: tmpl_id, name: "MatFC", model: "gpt-test"}
    )

    assert treq(:put, "/v1/initial-agents/main",
             json: %{display_name: "Main", template_id: tmpl_id, is_default: true}
           ).status == 200

    group = treq(:post, "/v1/runtime/agent-groups", json: %{name: "MatFC"}).body

    materialize_path =
      "/v1/runtime/agent-groups/#{group["group_id"]}/initial-agent-slots/main/materialize"

    assert treq(:post, materialize_path).status == 200

    sibling =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group["group_id"], template_id: tmpl_id, name: "MatFCSibling"}
      ).body

    # An unrelated record read failing must surface as an error, not read as
    # "slot not materialized" — that would mint a duplicate agent.
    SalixStore.S3.Fake.set_fault({:fail, 500, :get, Keys.ctl_agent(sibling["agent_id"])})

    assert treq(:post, materialize_path).status == 500

    main_agents =
      treq(:get, "/v1/runtime/agents?group_id=#{group["group_id"]}").body
      |> Enum.filter(&(&1["source_initial_agent_slot"] == "main"))

    assert length(main_agents) == 1
  end

  test "agent group capability requests do not project runtime waits without durable records" do
    suffix = System.unique_integer([:positive])
    template_id = "tmpl-capability-wait-only-#{suffix}"

    req(:post, "/v1/admin/templates",
      json: %{template_id: template_id, name: "Capability", model: "gpt-test"}
    )

    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Capability"}).body

    agent =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group["group_id"], template_id: template_id, name: "Capability"}
      ).body

    now = System.system_time(:second)
    session_id = SalixStore.Ids.new_session_id()

    assert {:ok, _created} =
             SalixAgent.InternalSessionStore.prepare_create(agent["agent_id"], session_id, %{})

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(agent["agent_id"], session_id, [
        %{"type" => "session_created", "session_id" => session_id, "created_at" => now},
        %{
          "type" => "wait_set",
          "session_id" => session_id,
          "wait" => %{
            "tool_call_id" => "location-hidden",
            "tool_name" => "location.request",
            "reason" => "need a map",
            "created_at" => now
          }
        }
      ])

    assert treq(
             :get,
             "/v1/agent-groups/#{group["group_id"]}/capability-requests?status=pending"
           ).body["data"] == []
  end

  test "capability request create is idempotent by source tool call identity" do
    suffix = System.unique_integer([:positive])
    template_id = "tmpl-capability-idempotent-#{suffix}"

    req(:post, "/v1/admin/templates",
      json: %{template_id: template_id, name: "Capability", model: "gpt-test"}
    )

    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Capability"}).body

    agent =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group["group_id"], template_id: template_id, name: "Capability"}
      ).body

    session_id = SalixStore.Ids.new_session_id()

    attrs = %{
      "source_agent_id" => agent["agent_id"],
      "source_session_id" => session_id,
      "tool_call_id" => "tool-call-123",
      "request_type" => "location",
      "request_payload" => %{"location" => %{"reason" => "need location"}}
    }

    {:ok, first} = SalixAgent.CapabilityRequests.create_capability_request(attrs)
    {:ok, second} = SalixAgent.CapabilityRequests.create_capability_request(attrs)

    assert first["request_id"] == second["request_id"]
    assert String.starts_with?(first["request_id"], "cap-")

    assert SalixAgent.CapabilityRequests.pending_capability_request?(
             agent["agent_id"],
             session_id,
             "tool-call-123"
           )

    pending =
      treq(
        :get,
        "/v1/agent-groups/#{group["group_id"]}/capability-requests?status=pending"
      ).body["data"]

    assert 1 == Enum.count(pending, &(&1["request_id"] == first["request_id"]))

    admin_pending =
      treq(
        :get,
        "/v1/runtime/agent-groups/#{group["group_id"]}/capability-requests?status=pending"
      ).body["data"]

    assert 1 == Enum.count(admin_pending, &(&1["request_id"] == first["request_id"]))

    {:ok, completed} =
      SalixAgent.CapabilityRequests.create_capability_request(
        Map.merge(attrs, %{
          "status" => "completed",
          "response_payload" => %{"status" => "success"},
          "completed_at" => System.system_time(:second)
        })
      )

    assert completed["request_id"] == first["request_id"]
    assert completed["status"] == "completed"

    {:ok, retry_after_completion} = SalixAgent.CapabilityRequests.create_capability_request(attrs)

    assert retry_after_completion["request_id"] == first["request_id"]
    assert retry_after_completion["status"] == "completed"
    assert retry_after_completion["response_payload"] == %{"status" => "success"}

    pending_after =
      treq(
        :get,
        "/v1/agent-groups/#{group["group_id"]}/capability-requests?status=pending"
      ).body["data"]

    refute Enum.any?(pending_after, &(&1["request_id"] == first["request_id"]))

    completed_after =
      treq(
        :get,
        "/v1/agent-groups/#{group["group_id"]}/capability-requests?status=completed"
      ).body["data"]

    assert 1 == Enum.count(completed_after, &(&1["request_id"] == first["request_id"]))

    cancel_attrs = Map.put(attrs, "tool_call_id", "tool-call-cancel")
    assert {:ok, _} = SalixAgent.CapabilityRequests.create_capability_request(cancel_attrs)

    assert {:ok, %{"status" => "cancelled"}} =
             SalixAgent.CapabilityRequests.cancel_capability_request(
               agent["agent_id"],
               session_id,
               "tool-call-cancel",
               "caller canceled"
             )

    refute SalixAgent.CapabilityRequests.pending_capability_request?(
             agent["agent_id"],
             session_id,
             "tool-call-cancel"
           )
  end

  test "capability request events stream receives live creates after subscribing" do
    suffix = System.unique_integer([:positive])
    template_id = "tmpl-capability-sse-live-#{suffix}"

    req(:post, "/v1/admin/templates",
      json: %{template_id: template_id, name: "Capability", model: "gpt-test"}
    )

    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Capability"}).body

    agent =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group["group_id"], template_id: template_id, name: "Capability"}
      ).body

    session_id = SalixStore.Ids.new_session_id()

    stream =
      open_sse_stream("/v1/agent-groups/#{group["group_id"]}/capability-requests/events")

    try do
      assert_receive {:sse_headers, headers}, 5_000
      assert headers =~ "200"

      {:ok, request} =
        SalixAgent.CapabilityRequests.create_capability_request(%{
          "source_agent_id" => agent["agent_id"],
          "source_session_id" => session_id,
          "tool_call_id" => "tool-sse-live",
          "request_type" => "location",
          "request_payload" => %{"location" => %{"reason" => "live event"}}
        })

      assert_receive {:sse_frame,
                      %{
                        "event" => "request_upsert",
                        "data" => %{"request_id" => request_id}
                      }},
                     5_000

      assert request_id == request["request_id"]
    after
      Process.exit(stream, :kill)
    end
  end

  test "agent group capability requests use durable records while activities still show waits" do
    suffix = System.unique_integer([:positive])
    template_id = "tmpl-capability-#{suffix}"

    req(:post, "/v1/admin/templates",
      json: %{template_id: template_id, name: "Capability", model: "gpt-test"}
    )

    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Capability"}).body

    agent =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group["group_id"], template_id: template_id, name: "Capability"}
      ).body

    agent_id = agent["agent_id"]
    now = System.system_time(:second)
    location_session_id = SalixStore.Ids.new_session_id()
    oauth_session_id = SalixStore.Ids.new_session_id()
    host_session_id = SalixStore.Ids.new_session_id()
    computer_session_id = SalixStore.Ids.new_session_id()

    for session_id <- [
          location_session_id,
          oauth_session_id,
          host_session_id,
          computer_session_id
        ] do
      assert {:ok, _created} =
               SalixAgent.InternalSessionStore.prepare_create(agent_id, session_id, %{})
    end

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(agent_id, location_session_id, [
        %{"type" => "session_created", "session_id" => location_session_id, "created_at" => now},
        %{
          "type" => "async_tool_call_started",
          "session_id" => location_session_id,
          "tool_call_id" => "tool-location",
          "tool_name" => "location.request",
          "input" => Jason.encode!(%{"reason" => "need a map"}),
          "status" => "running",
          "started_at" => now * 1000,
          "auto_wait_seconds" => 120
        },
        %{
          "type" => "wait_set",
          "session_id" => location_session_id,
          "wait" => %{
            "tool_call_id" => "tool-location",
            "tool_name" => "location.request",
            "reason" => "need a map",
            "created_at" => now
          }
        }
      ])

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(agent_id, oauth_session_id, [
        %{"type" => "session_created", "session_id" => oauth_session_id, "created_at" => now},
        %{
          "type" => "async_tool_call_started",
          "session_id" => oauth_session_id,
          "tool_call_id" => "tool-oauth",
          "tool_name" => "oauth.request_authorization",
          "input" => Jason.encode!(%{"provider" => "github", "alias" => "main"}),
          "status" => "running",
          "started_at" => now * 1000,
          "auto_wait_seconds" => 120
        },
        %{
          "type" => "wait_set",
          "session_id" => oauth_session_id,
          "wait" => %{
            "tool_call_id" => "tool-oauth",
            "tool_name" => "oauth.request_authorization",
            "reason" => "oauth authorization: github/main"
          }
        }
      ])

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(agent_id, host_session_id, [
        %{"type" => "session_created", "session_id" => host_session_id, "created_at" => now},
        %{
          "type" => "async_tool_call_started",
          "session_id" => host_session_id,
          "tool_call_id" => "tool-host",
          "tool_name" => "permission.request",
          "input" => Jason.encode!(%{"capability" => "host_access"}),
          "status" => "running",
          "started_at" => now * 1000,
          "auto_wait_seconds" => 120
        },
        %{
          "type" => "wait_set",
          "session_id" => host_session_id,
          "wait" => %{
            "tool_call_id" => "tool-host",
            "tool_name" => "permission.request",
            "reason" => "needs host files"
          }
        }
      ])

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(agent_id, computer_session_id, [
        %{
          "type" => "session_created",
          "session_id" => computer_session_id,
          "created_at" => now
        },
        %{
          "type" => "async_tool_call_started",
          "session_id" => computer_session_id,
          "tool_call_id" => "tool-computer",
          "tool_name" => "permission.request",
          "input" => Jason.encode!(%{"capability" => "computer_use_start"}),
          "status" => "running",
          "started_at" => now * 1000,
          "auto_wait_seconds" => 120
        },
        %{
          "type" => "wait_set",
          "session_id" => computer_session_id,
          "wait" => %{
            "tool_call_id" => "tool-computer",
            "tool_name" => "permission.request",
            "reason" => "needs the browser",
            "available_modes" => ["observe", "control"]
          }
        }
      ])

    {:ok, created_location} =
      SalixAgent.CapabilityRequests.create_capability_request(%{
        "request_id" => "req-location-#{suffix}",
        "source_agent_id" => agent_id,
        "source_session_id" => location_session_id,
        "tool_call_id" => "tool-location",
        "request_type" => "location",
        "request_payload" => %{"location" => %{"reason" => "need a map"}}
      })

    {:ok, created_oauth} =
      SalixAgent.CapabilityRequests.create_capability_request(%{
        "request_id" => "req-oauth-#{suffix}",
        "source_agent_id" => agent_id,
        "source_session_id" => oauth_session_id,
        "tool_call_id" => "tool-oauth",
        "request_type" => "oauth_authorization",
        "request_payload" => %{
          "oauth_authorization" => %{
            "provider" => "github",
            "alias" => "main",
            "state" => "state-123"
          }
        }
      })

    {:ok, created_host} =
      SalixAgent.CapabilityRequests.create_capability_request(%{
        "request_id" => "req-host-#{suffix}",
        "source_agent_id" => agent_id,
        "source_session_id" => host_session_id,
        "tool_call_id" => "tool-host",
        "request_type" => "host_access",
        "request_payload" => %{
          "host_access" => %{"capability" => "host_access", "reason" => "needs host files"}
        }
      })

    {:ok, created_computer} =
      SalixAgent.CapabilityRequests.create_capability_request(%{
        "request_id" => "req-computer-#{suffix}",
        "source_agent_id" => agent_id,
        "source_session_id" => computer_session_id,
        "tool_call_id" => "tool-computer",
        "request_type" => "computer_use_start",
        "request_payload" => %{
          "computer_use_start" => %{
            "capability" => "computer_use_start",
            "reason" => "needs the browser",
            "available_modes" => ["observe", "control"]
          }
        }
      })

    requests =
      treq(
        :get,
        "/v1/agent-groups/#{group["group_id"]}/capability-requests?status=pending"
      ).body[
        "data"
      ]

    assert Enum.map(requests, & &1["request_type"]) |> Enum.sort() ==
             ["computer_use_start", "host_access", "location", "oauth_authorization"]

    location = Enum.find(requests, &(&1["request_id"] == created_location["request_id"]))
    oauth = Enum.find(requests, &(&1["request_id"] == created_oauth["request_id"]))
    host = Enum.find(requests, &(&1["request_id"] == created_host["request_id"]))
    computer = Enum.find(requests, &(&1["request_id"] == created_computer["request_id"]))

    assert location["source_agent_id"] == agent_id
    assert location["source_session_id"] == location_session_id
    assert location["request_payload"]["location"]["reason"] == "need a map"

    assert computer["request_payload"]["computer_use_start"]["available_modes"] == [
             "observe",
             "control"
           ]

    [event] =
      read_sse_frames(
        "/v1/agent-groups/#{group["group_id"]}/capability-requests/events",
        1
      )

    assert event["event"] == "request_upsert"
    assert Enum.any?(requests, &(&1["request_id"] == event["data"]["request_id"]))

    activities = treq(:get, "/v1/runtime/agent-activities").body

    assert Enum.any?(
             activities,
             &(&1["agent_id"] == agent_id and &1["session_id"] == location_session_id)
           )

    # The stream is now long-lived: on connect it replays the current snapshot
    # (one `activity` frame per listed activity) before streaming live deltas, so
    # read exactly the snapshot's worth of frames rather than the whole body.
    activity_frames =
      read_sse_frames("/v1/runtime/agent-activities/stream", length(activities))

    assert Enum.all?(activity_frames, &(&1["event"] == "activity"))
    assert Enum.any?(activity_frames, &(&1["data"]["session_id"] == location_session_id))

    completed_location =
      treq(
        :post,
        "/v1/agent-groups/#{group["group_id"]}/capability-requests/#{location["request_id"]}/location/share",
        json: %{
          status: "success",
          location: %{latitude: 37.78, longitude: -122.41, accuracy_m: 10.0}
        }
      ).body

    assert completed_location["status"] == "completed"
    assert completed_location["response_payload"]["status"] == "success"

    completed_oauth =
      treq(
        :post,
        "/v1/agent-groups/#{group["group_id"]}/capability-requests/#{oauth["request_id"]}/oauth-authorization/confirm"
      ).body

    assert completed_oauth["status"] == "completed"
    assert completed_oauth["response_payload"]["status"] == "confirmed"

    completed_host =
      treq(
        :post,
        "/v1/agent-groups/#{group["group_id"]}/capability-requests/#{host["request_id"]}/host-access/decision",
        json: %{approved: true}
      ).body

    assert completed_host["status"] == "completed"
    assert completed_host["response_payload"]["approved"] == true

    completed_computer =
      treq(
        :post,
        "/v1/agent-groups/#{group["group_id"]}/capability-requests/#{computer["request_id"]}/computer-use-start/decision",
        json: %{approved: false, mode: "observe"}
      ).body

    assert completed_computer["status"] == "completed"
    assert completed_computer["response_payload"]["approved"] == false
    assert completed_computer["response_payload"]["mode"] == "observe"

    pending_after =
      treq(
        :get,
        "/v1/agent-groups/#{group["group_id"]}/capability-requests?status=pending"
      ).body["data"]

    completed_ids =
      [
        completed_location["request_id"],
        completed_oauth["request_id"],
        completed_host["request_id"],
        completed_computer["request_id"]
      ]

    refute Enum.any?(pending_after, &(&1["request_id"] in completed_ids))

    completed =
      treq(
        :get,
        "/v1/agent-groups/#{group["group_id"]}/capability-requests?status=completed"
      ).body["data"]

    assert Enum.all?(completed_ids, fn request_id ->
             Enum.any?(completed, &(&1["request_id"] == request_id))
           end)
  end

  test "agent heartbeat and schedule routes expose Willow-shaped records" do
    suffix = System.unique_integer([:positive])
    template_id = "tmpl-schedules-#{suffix}"

    req(:post, "/v1/admin/templates",
      json: %{template_id: template_id, name: "Schedules", model: "gpt-test"}
    )

    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Schedules"}).body

    agent =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group["group_id"], template_id: template_id, name: "Schedules"}
      ).body

    agent_id = agent["agent_id"]
    now_ms = System.system_time(:millisecond)
    schedule_id = "sched-user-#{suffix}"
    scheduled_for_ms = now_ms - 60_000

    {:ok, _} =
      SalixStore.Schedules.create(
        %{
          "id" => schedule_id,
          "agent_id" => agent_id,
          "name" => "Morning check",
          "prompt" => "Summarize the day",
          "interval_minutes" => 60,
          "status" => "active",
          "created_at" => now_ms - 120_000,
          "updated_at" => now_ms - 120_000,
          "last_run" => scheduled_for_ms
        },
        scheduled_for_ms + 60 * 60_000
      )

    :claimed =
      SalixStore.ScheduleRuns.claim(schedule_id, scheduled_for_ms, %{
        "receiver" => "agent",
        "agent_id" => agent_id,
        "disposition" => "dispatch",
        "fired_at" => scheduled_for_ms
      })

    heartbeat =
      treq(:put, "/v1/runtime/agents/#{agent_id}/heartbeat",
        json: %{
          prompt: "Check in",
          cron_expr: "15 */12 * * *",
          timezone: "America/Los_Angeles",
          template_id: template_id,
          reasoning_effort: "low"
        }
      ).body

    assert heartbeat["agent_id"] == agent_id
    assert SalixStore.Ids.valid_schedule_id?(heartbeat["schedule_id"])
    assert heartbeat["status"] == "active"
    assert heartbeat["cron_expr"] == "15 */12 * * *"
    assert heartbeat["template_id"] == template_id

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/heartbeat/pause").body["status"] ==
             "paused"

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/heartbeat/resume").body["status"] ==
             "active"

    assert treq(:get, "/v1/runtime/agents/#{agent_id}/heartbeat").body["timezone"] ==
             "America/Los_Angeles"

    schedules = treq(:get, "/v1/runtime/agents/#{agent_id}/schedules").body
    assert Enum.map(schedules, & &1["schedule_id"]) == [schedule_id]
    [schedule] = schedules
    assert schedule["name"] == "Morning check"
    assert schedule["cron_expr"] == "0 */1 * * *"
    assert is_integer(schedule["next_run_at"])
    assert schedule["last_run_at"] == div(scheduled_for_ms, 1000)

    runs = treq(:get, "/v1/runtime/agents/#{agent_id}/schedules/#{schedule_id}/runs").body

    expected_scheduled_for = div(scheduled_for_ms, 1000)

    assert [
             %{
               "run_id" => run_id,
               "schedule_id" => ^schedule_id,
               "status" => "dispatched",
               "scheduled_for" => ^expected_scheduled_for
             }
           ] = runs

    assert run_id == schedule_id <> ":" <> Integer.to_string(scheduled_for_ms)

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/schedules/#{schedule_id}/pause").body[
             "status"
           ] ==
             "paused"

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/schedules/#{schedule_id}/resume").body[
             "status"
           ] ==
             "active"

    assert treq(:delete, "/v1/runtime/agents/#{agent_id}/schedules/#{schedule_id}").status ==
             204

    assert treq(:get, "/v1/runtime/agents/#{agent_id}/schedules").body == []
  end

  test "agent archive and unarchive routes match Willow management API" do
    suffix = System.unique_integer([:positive])
    template_id = "tmpl-archive-#{suffix}"

    req(:post, "/v1/admin/templates",
      json: %{template_id: template_id, name: "Archive", model: "gpt-test"}
    )

    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Archive"}).body

    agent =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group["group_id"], template_id: template_id, name: "Archive"}
      ).body

    agent_id = agent["agent_id"]

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/archive").status == 204
    assert treq(:get, "/v1/runtime/agents/#{agent_id}").status == 404
    assert treq(:get, "/v1/runtime/agents/#{agent_id}/sessions").status == 404
    assert treq(:get, "/v1/runtime/agents/#{agent_id}/sites").status == 404

    archived = treq(:get, "/v1/runtime/agents/#{agent_id}?include_archived=true").body
    assert archived["agent_id"] == agent_id
    assert is_integer(archived["archived_at"])

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/unarchive").status == 204
    restored = treq(:get, "/v1/runtime/agents/#{agent_id}").body
    assert restored["agent_id"] == agent_id
    refute Map.has_key?(restored, "archived_at")
    assert treq(:get, "/v1/runtime/agents/#{agent_id}/sessions").status == 200
    assert treq(:get, "/v1/runtime/agents/#{agent_id}/sites").status == 200
  end

  test "legacy session summary routes are gone and group conversations still work" do
    suffix = System.unique_integer([:positive])
    template_id = "tmpl-legacy-conv-#{suffix}"

    req(:post, "/v1/admin/templates",
      json: %{template_id: template_id, name: "Legacy Conversation", model: "gpt-test"}
    )

    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Legacy Conversation"}).body

    agent =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group["group_id"], template_id: template_id, name: "Legacy"}
      ).body

    agent_id = agent["agent_id"]
    assert treq(:get, "/v1/runtime/agents/#{agent_id}/session-summaries").status == 404
    assert treq(:get, "/v1/runtime/agents/#{agent_id}/session-summaries/events").status == 404

    created =
      treq(:post, "/v1/runtime/agent-groups/#{group["group_id"]}/conversations",
        json: %{
          title: "Group Conversation",
          participants: [
            %{
              actor_type: "user",
              user_id: "current",
              state: "active",
              notification_filter: %{messages: "all", statuses: "none"}
            }
          ]
        }
      )

    assert created.status == 201
    conversation_id = created.body["conversation_id"]
    assert Ids.valid_conversation_id?(conversation_id)

    assert treq(
             :get,
             "/v1/runtime/agent-groups/#{group["group_id"]}/conversations/#{conversation_id}/messages"
           ).body == []

    sent =
      treq(
        :post,
        "/v1/runtime/agent-groups/#{group["group_id"]}/conversations/#{conversation_id}/messages",
        json: %{content: "group conversation message", source_message_id: "test-msg-4"}
      )

    assert sent.status == 201
    assert sent.body["conversation_id"] == conversation_id
    assert sent.body["delivery_status"] in ["queued", "recorded"]

    messages =
      treq(
        :get,
        "/v1/runtime/agent-groups/#{group["group_id"]}/conversations/#{conversation_id}/messages"
      ).body

    assert Enum.any?(messages, fn message ->
             Enum.any?(message["content"] || [], &(&1["text"] == "group conversation message"))
           end)
  end

  test "direct session message and tool routes work through runtime session APIs" do
    suffix = System.unique_integer([:positive])
    template_id = "tmpl-session-tools-#{suffix}"

    req(:post, "/v1/admin/templates",
      json: %{template_id: template_id, name: "Session Tools", model: "gpt-test"}
    )

    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Session Tools"}).body

    agent =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group["group_id"], template_id: template_id, name: "Session Tools"}
      ).body

    agent_id = agent["agent_id"]
    session_id = SalixStore.Ids.new_session_id()

    Mock.script([{:final, "ready"}])

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/messages",
             json: %{content: "prime", source_message_id: "test-msg-5"}
           ).status ==
             202

    _ =
      poll_until(agent_id, session_id, fn messages ->
        Enum.any?(messages, &(&1["content"] == "ready"))
      end)

    wrote =
      treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/tools/fs.write_file",
        json: %{path: "/notes/tool.txt", content: "hello from tool"}
      ).body

    assert wrote["result"] == "wrote 15 bytes to /notes/tool.txt"

    read =
      treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/tools/fs.read_file",
        json: %{path: "/notes/tool.txt"}
      ).body

    assert read["result"] == "hello from tool"
  end

  test "direct session tool route bounds its wait and returns the running handle" do
    previous_provider = Application.get_env(:salix_agent, :mcp_provider_mod)
    previous_wait = Application.get_env(:salix_web, :session_tool_http_wait_timeout_ms)

    Application.put_env(:salix_agent, :mcp_provider_mod, HangingMCPProvider)
    Application.put_env(:salix_web, :session_tool_http_wait_timeout_ms, 50)
    HangingMCPProvider.set_owner(self())

    on_exit(fn ->
      restore_env(:salix_agent, :mcp_provider_mod, previous_provider)
      restore_env(:salix_web, :session_tool_http_wait_timeout_ms, previous_wait)
      HangingMCPProvider.clear_owner()
    end)

    agent_id = create_test_agent()
    session_id = SalixStore.Ids.new_session_id()

    Mock.script([{:final, "ready"}])

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/messages",
             json: %{content: "prime", source_message_id: "test-msg-6"}
           ).status == 202

    _messages =
      poll_until(agent_id, session_id, fn messages ->
        Enum.any?(messages, &(&1["content"] == "ready"))
      end)

    response =
      treq(
        :post,
        "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/tools/mcp.router_liveness.hang",
        json: %{}
      )

    assert_received {:router_hanging_mcp_started, dependency_pid}
    assert is_pid(dependency_pid)
    assert response.status == 200
    assert response.body["status"] == "running"
    assert response.body["tool_name"] == "mcp.router_liveness.hang"
    assert response.body["auto_wait_seconds"] > 0

    tool_call_id = response.body["tool_call_id"]
    assert is_binary(tool_call_id) and tool_call_id != ""

    assert {:ok,
            %{
              "tool_call_id" => ^tool_call_id,
              "tool_name" => "mcp.router_liveness.hang",
              "status" => "running",
              "completion_owner" => "direct_poll"
            }} = SalixAgent.Runtime.get_async_tool_call(agent_id, session_id, tool_call_id)

    polled =
      treq(
        :post,
        "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/tools/tool_call.get_status",
        json: %{tool_call_id: tool_call_id}
      )

    assert polled.status == 200
    assert polled.body["status"] == "running"
    assert polled.body["tool_call_id"] == tool_call_id

    cancelled =
      treq(
        :post,
        "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/tools/tool_call.cancel",
        json: %{tool_call_id: tool_call_id, reason: "router test cleanup"}
      )

    assert cancelled.status == 200
    assert cancelled.body["status"] == "cancelled"
    assert cancelled.body["tool_call_id"] == tool_call_id
  end

  test "direct session tool route keeps external-callback setup poll-owned" do
    agent_id = create_test_agent()
    session_id = SalixStore.Ids.new_session_id()

    Mock.script([{:final, "ready"}])

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/messages",
             json: %{content: "prime", source_message_id: "test-msg-7"}
           ).status == 202

    _messages =
      poll_until(agent_id, session_id, fn messages ->
        Enum.any?(messages, &(&1["content"] == "ready"))
      end)

    # Make the setup dependency miss the actor's exact zero-wait poll so this
    # exercises the durable handoff hydration path rather than the inline fast
    # path. Whichever setup/session PUT arrives first is delayed only once.
    :ok = S3.Fake.set_fault({:delay, 50, :put, :any})

    response =
      treq(
        :post,
        "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/tools/permission.request",
        json: %{capability: "host_access", description: "Router handoff"}
      )

    assert response.status == 200
    assert response.body["status"] == "running"
    assert response.body["capability"] == "host_access"
    assert is_binary(response.body["request_id"])
    tool_call_id = response.body["tool_call_id"]
    assert is_binary(tool_call_id)

    assert {:ok,
            %{
              "tool_call_id" => ^tool_call_id,
              "status" => "running",
              "completion_mode" => "external_callback"
            }} = SalixAgent.Runtime.get_async_tool_call(agent_id, session_id, tool_call_id)

    assert {:ok, setup_result} =
             SalixAgent.Runtime.get_async_tool_setup_result(agent_id, session_id, tool_call_id)

    assert setup_result["content"] |> Jason.decode!() |> Map.fetch!("request_id") ==
             response.body["request_id"]

    assert eventually(fn ->
             {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, session_id)

             call =
               SalixAgent.InternalSession.get(session, :async_tool_calls)[tool_call_id] || %{}

             call["completion_owner"] == "direct_poll" and
               call["completion_mode"] == "external_callback" and
               SalixAgent.InternalSession.wait(session)["tool_call_id"] == tool_call_id
           end)

    {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, session_id)

    refute Enum.any?(SalixAgent.InternalSession.get(session, :input_queue) || [], fn entry ->
             payload = entry["payload"] || %{}

             payload["type"] == "tool_call_handoff" and
               payload["source_tool_call_id"] == tool_call_id
           end)

    refute Enum.any?(SalixAgent.InternalSession.get(session, :messages) || [], fn message ->
             type = message[:type] || message["type"]

             source_tool_call_id =
               message[:source_tool_call_id] || message["source_tool_call_id"]

             type == "tool_call_handoff" and source_tool_call_id == tool_call_id
           end)

    assert SalixAgent.InternalSession.get(session, :visible_reply_repair) == nil
  end

  test "direct session MCP management executes on the first call without a capability request" do
    agent_id = create_test_agent()
    session_id = SalixStore.Ids.new_session_id()

    Mock.script([{:final, "ready"}])

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/messages",
             json: %{content: "prime", source_message_id: "test-msg-mcp-direct"}
           ).status == 202

    _messages =
      poll_until(agent_id, session_id, fn messages ->
        Enum.any?(messages, &(&1["content"] == "ready"))
      end)

    response =
      treq(
        :post,
        "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/tools/mcp_manager.definition_create",
        json: %{url: "https://example.test/mcp", name: "Router handoff"}
      )

    assert response.status == 200
    definition = response.body["definition"]
    assert is_map(definition)
    assert is_binary(definition["mcp_id"])
    assert definition["name"] == "Router handoff"

    {:ok, agent} = SalixAgent.Control.get(agent_id)
    group_id = agent["group_id"]

    requests =
      treq(
        :get,
        "/v1/runtime/agent-groups/#{group_id}/capability-requests?status=pending"
      ).body
      |> Map.get("data", [])

    refute Enum.any?(requests, &(&1["request_type"] == "mcp_management"))

    assert treq(
             :post,
             "/v1/runtime/agent-groups/#{group_id}/capability-requests/cap-obsolete/mcp-management/decision",
             json: %{approved: true}
           ).status == 404
  end

  test "agent billing state and history routes expose Willow-shaped usage pages" do
    suffix = System.unique_integer([:positive])
    template_id = "tmpl-billing-#{suffix}"

    req(:post, "/v1/admin/templates",
      json: %{template_id: template_id, name: "Billing", model: "gpt-billing"}
    )

    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Billing"}).body

    agent =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group["group_id"], template_id: template_id, name: "Billing"}
      ).body

    agent_id = agent["agent_id"]
    session_id = SalixStore.Ids.new_session_id()

    state =
      treq(:put, "/v1/runtime/agents/#{agent_id}/billing-state",
        json: %{state: "suspended", vfs_billing_exempt: true}
      ).body

    assert state["state"] == "suspended"
    assert state["vfs_billing_exempt"] == true

    assert treq(:get, "/v1/runtime/agents/#{agent_id}/billing-state").body["state"] ==
             "suspended"

    Mock.script([
      {:final, "billed",
       %{
         "model" => "gpt-billing",
         "usage" => %{
           "prompt_tokens" => 17,
           "completion_tokens" => 5,
           "cache_read_input_tokens" => 3,
           "cache_write_input_tokens" => 2
         }
       }}
    ])

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/messages",
             json: %{content: "bill", source_message_id: "test-msg-8"}
           ).status ==
             202

    _ =
      poll_until(agent_id, session_id, fn messages ->
        Enum.any?(messages, &(&1["content"] == "billed"))
      end)

    history =
      treq(:get, "/v1/runtime/agents/#{agent_id}/billing-history?after_id=0&limit=100").body

    assert history["has_more"] == false
    assert history["next_after_id"] == 1

    assert [
             %{
               "billing_id" => 1,
               "session_id" => ^session_id,
               "model" => "gpt-billing",
               "provider_type" => "openai",
               "call_kind" => "agent",
               "input_tokens" => 17,
               "output_tokens" => 5,
               "total_tokens" => 22,
               "cache_read_input_tokens" => 3,
               "cache_write_input_tokens" => 2,
               "cost_micros" => 0
             }
           ] = history["data"]

    assert treq(
             :get,
             "/v1/runtime/agents/#{agent_id}/resource-usage-history?after_id=0&limit=100"
           ).body ==
             %{"data" => [], "next_after_id" => 0, "has_more" => false}
  end

  test "agent group conversation pins list, pin, and unpin conversations" do
    suffix = System.unique_integer([:positive])
    template_id = "tmpl-pins-#{suffix}"

    req(:post, "/v1/admin/templates",
      json: %{template_id: template_id, name: "Pins", model: "gpt-test"}
    )

    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Pins"}).body

    treq(:post, "/v1/runtime/agents",
      json: %{group_id: group["group_id"], template_id: template_id, name: "Pins"}
    )

    conversation =
      treq(:post, "/v1/runtime/agent-groups/#{group["group_id"]}/conversations",
        json: %{title: "Pinned conversation"}
      ).body

    assert treq(:get, "/v1/runtime/agent-groups/#{group["group_id"]}/conversation-pins").body ==
             %{
               "data" => [],
               "has_more" => false
             }

    pin =
      treq(
        :put,
        "/v1/runtime/agent-groups/#{group["group_id"]}/conversations/#{conversation["conversation_id"]}/pin"
      ).body

    assert pin["agent_group_id"] == group["group_id"]
    assert pin["conversation_id"] == conversation["conversation_id"]
    assert is_integer(pin["pinned_at"])

    assert treq(:get, "/v1/runtime/agent-groups/#{group["group_id"]}/conversation-pins").body[
             "data"
           ] == [
             pin
           ]

    assert treq(
             :delete,
             "/v1/runtime/agent-groups/#{group["group_id"]}/conversations/#{conversation["conversation_id"]}/pin"
           ).status == 204

    assert treq(:get, "/v1/runtime/agent-groups/#{group["group_id"]}/conversation-pins").body[
             "data"
           ] == []
  end

  test "HTTP wake queues only and does not synthesize operation wait results" do
    template_id = "tmpl-wake-#{System.unique_integer([:positive])}"

    req(:post, "/v1/admin/templates",
      json: %{template_id: template_id, name: "Wake", model: "gpt-test"}
    )

    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "Wake"}).body

    agent =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group["group_id"], template_id: template_id, name: "Wake"}
      ).body

    agent_id = agent["agent_id"]
    session_id = SalixStore.Ids.new_session_id()

    wait = SalixAgent.Waits.build("background job", 60, "wait_for")

    assert {:ok, _created} =
             SalixAgent.InternalSessionStore.prepare_create(agent_id, session_id, %{})

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(agent_id, session_id, [
        %{"type" => "session_created", "session_id" => session_id},
        %{"type" => "wait_set", "session_id" => session_id, "wait" => wait}
      ])

    {:ok, waiting} = SalixAgent.InternalSessionStore.read(agent_id, session_id)
    assert InternalSession.derived_state(waiting) == :waiting
    assert treq(:get, "/v1/runtime/agents/#{agent_id}").body["status"] == "idle"

    assert treq(:get, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}").body[
             "activity_status"
           ] ==
             "waiting"

    refute Enum.any?(
             treq(:get, "/v1/runtime/agents?status=waiting").body,
             &(&1["agent_id"] == agent_id)
           )

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/wake",
             json: %{operation_id: "op-http", result: "finished"}
           ).body["status"] == "queued"

    assert {:ok, raw_agent} = SalixAgent.AgentControl.get_record(agent_id)
    refute raw_agent["status"] == "queued"

    assert treq(:post, "/v1/runtime/agents/#{agent_id}/wake",
             json: %{operation_id: "op-http", result: "finished"}
           ).body["status"] == "queued"

    assert {:ok, raw_agent} = SalixAgent.AgentControl.get_record(agent_id)
    refute raw_agent["status"] == "queued"

    session =
      poll_session(agent_id, session_id, fn session ->
        not is_nil(InternalSession.wait(session))
      end)

    assert InternalSession.wait(session)["wait_id"] == wait["wait_id"]
    assert InternalSession.derived_state(session) == :waiting

    assert InternalSession.get(session, :messages) == []
  end

  test "GET on unknown session returns 404" do
    a = create_test_agent()
    session_id = SalixStore.Ids.new_session_id()
    unknown_session_id = SalixStore.Ids.new_session_id()

    # ensure the agent exists but the session doesn't
    Mock.script([{:final, "ok"}])

    treq(:post, "/v1/runtime/agents/#{a}/sessions/#{session_id}/messages",
      json: %{content: "x", source_message_id: "test-msg-9"}
    )

    _ = poll_until(a, session_id, fn msgs -> msgs != [] end)

    resp = treq(:get, "/v1/runtime/agents/#{a}/sessions/#{unknown_session_id}/messages")
    assert resp.status == 404
  end

  defp poll_until(agent, session, pred, retries \\ 100) do
    resp = treq(:get, "/v1/runtime/agents/#{agent}/sessions/#{session}/messages")
    msgs = (resp.status == 200 && resp.body["messages"]) || []

    cond do
      pred.(msgs) -> msgs
      retries == 0 -> flunk("condition not met; last messages: #{inspect(msgs)}")
      true -> Process.sleep(20) && poll_until(agent, session, pred, retries - 1)
    end
  end

  defp decoded_message_content(%{"content" => content}) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, payload} when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp decoded_message_content(_message), do: %{}

  defp poll_session(agent, session_id, pred, retries \\ 100) do
    session =
      case SalixAgent.InternalSessionStore.read(agent, session_id) do
        {:ok, session} -> session
        _ -> nil
      end

    cond do
      session && pred.(session) -> session
      retries == 0 -> flunk("session condition not met; last session: #{inspect(session)}")
      true -> Process.sleep(20) && poll_session(agent, session_id, pred, retries - 1)
    end
  end

  defp poll_agent_stopped(agent, retries \\ 100) do
    cond do
      not SalixAgent.Fleet.running?(agent) -> :ok
      retries == 0 -> flunk("agent #{agent} still running")
      true -> Process.sleep(20) && poll_agent_stopped(agent, retries - 1)
    end
  end

  defp read_json(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> Jason.decode(body)
      other -> other
    end
  end

  defp fixed_stream(total, chunk) when total >= 0 and is_binary(chunk) and byte_size(chunk) > 0 do
    Stream.resource(
      fn -> total end,
      fn
        0 ->
          {:halt, 0}

        remaining ->
          size = min(remaining, byte_size(chunk))
          {[binary_part(chunk, 0, size)], remaining - size}
      end,
      fn _ -> :ok end
    )
  end

  defp fake_records_with_prefix(prefix) do
    case SalixStore.S3.list_all(prefix) do
      {:ok, objects} ->
        objects
        |> Enum.map(& &1.key)
        |> Map.new(fn key ->
          {:ok, %{body: body}} = SalixStore.S3.get(key)
          {key, Jason.decode!(body)}
        end)

      {:error, _reason} ->
        %{}
    end
  end

  defp participant_delivery_records(group_id, conversation_id) do
    case SalixIM.Conversations.group_conversation_delivery_status(
           group_id,
           conversation_id,
           limit: 1000
         ) do
      {:ok, %{"deliveries" => deliveries}} ->
        deliveries

      {:error, _reason} ->
        []
    end
  end

  test "oauth default apps: admin CRUD and tenant fallback resolution" do
    on_exit(fn -> Salix.Control.OAuthApps.delete_default("github") end)

    # Baseline: the defaults list covers supported providers, unconfigured.
    # A tenant key must not reach the deployment-wide defaults (admin only).
    assert treq(:get, "/v1/admin/oauth/default-apps").status == 401

    defaults = req(:get, "/v1/admin/oauth/default-apps").body
    github_default = Enum.find(defaults, &(&1["provider"] == "github"))
    assert github_default["client_secret_configured"] == false

    # Validation mirrors the tenant apps.
    assert req(:put, "/v1/admin/oauth/default-apps/not-a-provider", json: %{client_id: "x"}).status ==
             400

    assert req(:put, "/v1/admin/oauth/default-apps/github", json: %{client_id: ""}).status ==
             400

    put =
      req(:put, "/v1/admin/oauth/default-apps/github",
        json: %{client_id: "gh-default", client_secret: "default-secret"}
      )

    assert put.status == 200
    assert put.body["client_secret_configured"] == true
    # Write-only, like the tenant apps.
    refute Map.has_key?(put.body, "client_secret")

    # The tenant view reports the effective source without inventing a tenant
    # record.
    tenant_github =
      Enum.find(treq(:get, "/v1/runtime/oauth/provider-apps").body, &(&1["provider"] == "github"))

    assert tenant_github["source"] == "default"
    assert tenant_github["default_client_id"] == "gh-default"
    assert tenant_github["client_id"] == ""

    # A group authorize flow runs on the default credentials.
    group =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "D"})

    assert group.status == 201
    group_id = group.body["group_id"]

    auth =
      treq(:post, "/v1/runtime/agent-groups/#{group_id}/oauth/github/authorize",
        json: %{alias: "work"}
      )

    assert auth.status == 200
    assert String.contains?(auth.body["authorization_url"], "client_id=gh-default")

    # Tenant credentials always win over the default.
    assert treq(:put, "/v1/runtime/oauth/provider-apps/github",
             json: %{client_id: "gh-tenant", client_secret: "tenant-secret"}
           ).status == 200

    tenant_github =
      Enum.find(treq(:get, "/v1/runtime/oauth/provider-apps").body, &(&1["provider"] == "github"))

    assert tenant_github["source"] == "tenant"

    auth =
      treq(:post, "/v1/runtime/agent-groups/#{group_id}/oauth/github/authorize",
        json: %{alias: "work-tenant"}
      )

    assert String.contains?(auth.body["authorization_url"], "client_id=gh-tenant")

    # A partial tenant record (client id, no secret) is never paired with the
    # default's secret — the complete default pair applies instead.
    assert treq(:delete, "/v1/runtime/oauth/provider-apps/github").body["status"] == "deleted"

    assert treq(:put, "/v1/runtime/oauth/provider-apps/github", json: %{client_id: "gh-partial"}).status ==
             200

    auth =
      treq(:post, "/v1/runtime/agent-groups/#{group_id}/oauth/github/authorize",
        json: %{alias: "work-partial"}
      )

    assert String.contains?(auth.body["authorization_url"], "client_id=gh-default")

    # Removing the default (and the tenant record) restores the
    # configured-app precondition.
    assert treq(:delete, "/v1/runtime/oauth/provider-apps/github").body["status"] == "deleted"
    assert req(:delete, "/v1/admin/oauth/default-apps/github").body["status"] == "deleted"

    assert treq(:post, "/v1/runtime/agent-groups/#{group_id}/oauth/github/authorize",
             json: %{alias: "work-none"}
           ).status == 412
  end

  test "oauth list endpoints return 503 (not a 500 crash) when the control store is unavailable" do
    # Simulate a Postgres fault by renaming the table away: OAuthApps.list*
    # raises, is rescued to {:error, :unavailable}, and the endpoint must map
    # that to 503 rather than JSON-encoding the tuple (Protocol.UndefinedError).
    # (Remote-MCP provider apps still read S3, so they are unaffected here.)
    Repo.query!("ALTER TABLE oauth_provider_apps RENAME TO oauth_provider_apps_tmp")

    on_exit(fn ->
      Repo.query!("ALTER TABLE oauth_provider_apps_tmp RENAME TO oauth_provider_apps")
    end)

    assert treq(:get, "/v1/runtime/oauth/provider-apps").status == 503
    assert req(:get, "/v1/admin/oauth/default-apps").status == 503
  end

  test "vm default-config: admin CRUD, write-only secrets, tenant-key denied" do
    on_exit(fn -> SalixWeb.CloudVM.delete_default_vm_config() end)

    assert treq(:get, "/v1/admin/vm/default-config").status == 401
    assert req(:get, "/v1/admin/vm/default-config").body == %{}

    put =
      req(:put, "/v1/admin/vm/default-config",
        json: %{
          default_provider: "cloudflare",
          providers: %{
            cloudflare: %{
              enabled: true,
              gateway_base_url: "https://gateway.example.test",
              gateway_secret: "admin-vm-secret"
            }
          }
        }
      )

    assert put.status == 200
    assert put.body["providers"]["cloudflare"]["gateway_secret_configured"] == true
    refute Map.has_key?(put.body["providers"]["cloudflare"], "gateway_secret")

    assert req(:put, "/v1/admin/vm/default-config", json: %{default_provider: "nope"}).status ==
             400

    {:ok, default_tenant} = Salix.Control.Tenants.create(%{})
    assert {:ok, cfg} = SalixWeb.CloudVM.cloudflare_config(default_tenant["tenant_id"])
    assert cfg.secret == "admin-vm-secret"

    {:ok, platform_tenant} =
      Salix.Control.Tenants.create(%{
        "config" => Jason.encode!(%{"vm" => %{"config_source" => "platform"}})
      })

    assert {:ok, cfg} = SalixWeb.CloudVM.cloudflare_config(platform_tenant["tenant_id"])
    assert cfg.secret == "admin-vm-secret"

    assert req(:delete, "/v1/admin/vm/default-config").body["status"] == "deleted"
    assert req(:get, "/v1/admin/vm/default-config").body == %{}
  end

  test "vm ops routes expose stuck records and keepalive leak candidates" do
    SalixStore.Repo.query!(
      "TRUNCATE compute_reconciler_claims, compute_reconciler_cursors, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools CASCADE"
    )

    now = System.system_time(:millisecond)
    stuck_group = SalixStore.Ids.new_group_id(tenant_id())
    leak_group = SalixStore.Ids.new_group_id(tenant_id())
    ready_group = SalixStore.Ids.new_group_id(tenant_id())
    ready_device_id = SalixStore.Ids.new_device_id()

    put_vm_record(stuck_group, %{
      "tenant_id" => tenant_id(),
      "group_id" => stuck_group,
      "provider" => "cloudflare",
      "provider_resource_id" => "sandbox-stuck",
      "status" => "waking",
      "created_at" => now - 600_000,
      "archive" => %{"data" => "owned-archive-not-for-ops-list"},
      "last_wake_at" => now - 10_000
    })

    put_vm_record(leak_group, %{
      "tenant_id" => tenant_id(),
      "group_id" => leak_group,
      "provider" => "cloudflare",
      "provider_resource_id" => "sandbox-leak",
      "env_id" => "env-leak",
      "status" => "ready",
      "ready_at" => now - 20_000
    })

    put_vm_record(ready_group, %{
      "tenant_id" => tenant_id(),
      "group_id" => ready_group,
      "provider" => "cloudflare",
      "provider_resource_id" => "sandbox-ready",
      "env_id" => "env-ready",
      "device_id" => ready_device_id,
      "connector_id" => "connector-ready",
      "status" => "ready",
      "ready_at" => now - 30_000
    })

    {:ok, "env-ready", _} =
      SalixEnv.Registry.connect(
        to_string(node()),
        %{
          "alias" => "cloud-vm",
          "group_id" => ready_group,
          "tenant_id" => tenant_id(),
          "device_id" => ready_device_id,
          "connector_id" => "connector-ready"
        },
        transport_id: "env-ready"
      )

    assert treq(:get, "/v1/admin/vm/ops/stuck").status == 401

    %{"data" => stuck, "next_cursor" => nil} = req(:get, "/v1/admin/vm/ops/stuck").body
    assert [%{"group_id" => ^stuck_group, "status" => "waking", "ops_age_ms" => age}] = stuck
    assert age >= 9_000
    assert age < 60_000

    %{"data" => leaks, "next_cursor" => nil} = req(:get, "/v1/admin/vm/ops/keepalive-leaks").body

    assert Enum.any?(
             leaks,
             &(&1["group_id"] == leak_group and &1["attachment_status"] == "missing")
           )

    assert Enum.any?(
             leaks,
             &(&1["group_id"] == ready_group and &1["attachment_status"] == "stale_connected")
           )

    refute Map.has_key?(hd(stuck), "archive")
    assert req(:get, "/v1/admin/vm/ops/stuck?limit=101").status == 400
    assert req(:get, "/v1/admin/vm/ops/stuck?limit=no").status == 400

    pages =
      Stream.unfold("", fn
        nil ->
          nil

        cursor ->
          page =
            req(:get, "/v1/admin/vm/ops/stuck?limit=1&cursor=" <> URI.encode_www_form(cursor)).body

          assert length(page["data"]) <= 1
          {page["data"], page["next_cursor"]}
      end)
      |> Enum.take(4)

    assert length(pages) == 3
    assert Enum.map(List.flatten(pages), & &1["group_id"]) == [stuck_group]
  end

  test "image release API fences managed starts and reports active Group claims" do
    maintenance_id = "image-release-test"
    on_exit(fn -> S3.delete(Keys.ctl_vm_maintenance()) end)

    cloud_group = SalixStore.Ids.new_group_id(tenant_id())
    source_group = SalixStore.Ids.new_group_id(tenant_id())
    archived_group = SalixStore.Ids.new_group_id(tenant_id())

    put_vm_record(cloud_group, %{
      "tenant_id" => tenant_id(),
      "group_id" => cloud_group,
      "provider" => "cloudflare",
      "provider_resource_id" => "sandbox-image-release",
      "status" => "ready"
    })

    put_vm_record(source_group, %{
      "tenant_id" => tenant_id(),
      "group_id" => source_group,
      "provider" => "cloudflare",
      "provider_resource_id" => "sandbox-source",
      "status" => "ready"
    })

    put_vm_record(archived_group, %{
      "tenant_id" => tenant_id(),
      "group_id" => archived_group,
      "provider" => "cloudflare",
      "provider_resource_id" => "sandbox-archived-image-release",
      "status" => "archived",
      "archive" => %{
        "type" => "connector_tar_gz_chunks",
        "storage" => "r2",
        "operation" => "archive-recorded",
        "byte_size" => 4,
        "chunk_size" => 4 * 1024 * 1024,
        "chunk_count" => 1,
        "sessions" => 0
      },
      "connector_archive" => %{
        "type" => "connector_tar_gz_chunks",
        "storage" => "r2",
        "operation" => "archive-recorded",
        "byte_size" => 4,
        "chunk_count" => 1,
        "archived_at" => 1
      }
    })

    assert treq(:post, "/v1/admin/vm/image-release/prepare",
             json: %{maintenance_id: maintenance_id}
           ).status == 401

    assert {:ok, "direct-probe"} =
             Compute.begin_cloudflare_direct_gateway_attempt("direct-probe")

    assert {:ok, "group-start"} =
             Compute.begin_cloudflare_gateway_attempt(source_group, "group-start")

    assert req(:post, "/v1/admin/vm/image-release/prepare",
             json: %{maintenance_id: maintenance_id}
           ).body["maintenance_id"] == maintenance_id

    assert req(
             :get,
             "/v1/admin/vm/image-release/workloads?maintenance_id=#{maintenance_id}&limit=100"
           ).status == 503

    assert :ok = Compute.finish_cloudflare_direct_gateway_attempt("direct-probe")

    page =
      req(
        :get,
        "/v1/admin/vm/image-release/workloads?maintenance_id=#{maintenance_id}&limit=100"
      ).body

    assert Enum.any?(page["data"], &(&1["group_id"] == cloud_group))

    assert Enum.find(page["data"], &(&1["group_id"] == archived_group))[
             "archive_recorded"
           ] == true

    assert Enum.find(page["data"], &(&1["group_id"] == cloud_group))[
             "gateway_attempt_count"
           ] == 0

    assert Enum.find(page["data"], &(&1["group_id"] == source_group))[
             "gateway_attempt_count"
           ] == 1

    assert :ok = Compute.finish_cloudflare_gateway_attempt(source_group, "group-start")

    assert {:error, {:vm_service_upgrading, _}} =
             Compute.begin_cloudflare_gateway_attempt(cloud_group, "late-image-release-call")

    assert req(:post, "/v1/admin/vm/image-release/finish",
             json: %{maintenance_id: "other-release"}
           ).status == 409

    assert req(:post, "/v1/admin/vm/image-release/finish",
             json: %{maintenance_id: maintenance_id}
           ).body["error"] == "vm_maintenance_phase_mismatch"

    assert req(:post, "/v1/admin/vm/image-release/deploying",
             json: %{maintenance_id: maintenance_id}
           ).body["phase"] == "deploying"

    assert req(:get, "/v1/admin/vm/image-release/status").body["maintenance"]["phase"] ==
             "deploying"

    assert req(:post, "/v1/admin/vm/image-release/prepare",
             json: %{maintenance_id: maintenance_id}
           ).body["phase"] == "deploying"

    assert req(
             :get,
             "/v1/admin/vm/image-release/workloads?maintenance_id=#{maintenance_id}&limit=100"
           ).status == 200

    assert req(:post, "/v1/admin/vm/image-release/cancel",
             json: %{maintenance_id: maintenance_id}
           ).body["error"] == "vm_maintenance_phase_mismatch"

    assert req(:post, "/v1/admin/vm/image-release/finish",
             json: %{maintenance_id: maintenance_id}
           ).body["status"] == "released"

    assert req(:get, "/v1/admin/vm/image-release/status").body["maintenance"] == nil
  end

  test "a known app_id resolves at the route level in two point reads", %{
    tenant_id: tenant_id
  } do
    # Option B (final owner disposition): the authority key accelerates
    # KNOWN identities to two point GETs with zero LISTs — the dominant
    # real-traffic path. Unknown ids fall back to the compatibility scan
    # (main's pre-existing per-event behavior, retained under a recorded
    # AGENTS.md waiver with the bounded-miss design kept on file as a
    # follow-up; see docs/identity-security.md).
    group_resp = treq(:post, "/v1/runtime/agent-groups", json: %{name: "Budget"})
    group_id = group_resp.body["group_id"]

    router =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group_id, name: "Budget Router", is_router: true}
      )

    assert treq(:patch, "/v1/runtime/agent-groups/#{group_id}",
             json: %{router_agent_id: router.body["agent_id"]}
           ).status == 200

    {:ok, connect} =
      SalixIM.ProviderConnects.create_slack_im_connect(tenant_id, group_id, %{
        "app_id" => "A-ROUTE-KNOWN",
        "client_id" => "client-r",
        "client_secret" => "secret-r",
        "signing_secret" => "sign-r"
      })

    {:ok, _} =
      SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, %{
        "bot_token" => "xoxb-r",
        "bot_id" => "BR",
        "bot_user_id" => "UR",
        "workspace_id" => "TR",
        "workspace_name" => "WS R",
        "enterprise_id" => nil,
        "owner_user_id" => "U999"
      })

    SalixStore.S3.Fake.reset_read_log()

    resp =
      Req.request!(
        method: :post,
        url: base() <> "/v1/im/slack/events",
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{type: "event_callback", api_app_id: "A-ROUTE-KNOWN"}),
        retry: false
      )

    # Resolution succeeded in two point GETs (the 401 is the signature
    # check REJECTING our unsigned request AFTER bounded resolution).
    assert resp.status == 401

    reads = SalixStore.S3.Fake.read_log()

    refute Enum.any?(reads, fn
             {:list, _prefix, _opts} -> true
             _ -> false
           end)

    assert [{:get, _identity_key}, {:get, _connect_key} | _] = reads
  end

  describe "Slack Task commands" do
    @describetag :slash_task

    setup %{tenant_id: tenant_id} do
      start_supervised!(MockSlackOAuth)
      port = start_bandit_retry!(fn p -> {Bandit, plug: MockSlackOAuth, port: p} end)
      Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")
      MockSlackOAuth.respond(&slash_slack_response/1)

      group_id = create_test_group("Slash Command")["group_id"]

      router =
        treq(:post, "/v1/runtime/agents",
          json: %{group_id: group_id, name: "Slash Router", role: "router"}
        )

      assert router.status == 201
      router_id = router.body["agent_id"]

      assert treq(:patch, "/v1/runtime/agent-groups/#{group_id}",
               json: %{router_agent_id: router_id}
             ).status == 200

      {:ok, connect} =
        ProviderConnects.create_slack_im_connect(tenant_id, group_id, %{
          "app_id" => "A-SLASH",
          "client_id" => "client-slash",
          "client_secret" => "secret-slash",
          "signing_secret" => "sign-slash"
        })

      {:ok, _} =
        SalixIM.SlackCommands.update(
          group_id,
          connect["connect_id"],
          connect["app_id"],
          &Map.put(
            &1,
            "commands",
            SalixIM.SlackCommands.task_aliases() ++
              [
                %{
                  "command" => "/review",
                  "prompt" => "Review privately: ",
                  "description" => "Review",
                  "usage_hint" => "",
                  "enabled" => true
                }
              ]
          )
        )

      {:ok, _} =
        ProviderConnects.complete_slack_im_connect_oauth(connect, %{
          "bot_token" => "xoxb-slash",
          "bot_id" => "B-SLASH",
          "bot_user_id" => "U-SLASH",
          "workspace_id" => "T-SLASH",
          "owner_user_id" => "U-OWNER"
        })

      %{
        group_id: group_id,
        router_id: router_id,
        connect: connect,
        command_path: "/v1/im/slack/commands",
        command: %{
          "api_app_id" => "A-SLASH",
          "team_id" => "T-SLASH",
          "channel_id" => "C-SLASH",
          "user_id" => "U-OWNER",
          "command" => "/newgpttask",
          "trigger_id" => "123.456.slash",
          "text" => "Fix login & keep C++ support\nAdd a regression test"
        }
      }
    end

    for {command_name, prefix, input} <- [
          {"/newgpttask", "Create a task using a Codex worker. Task content: ",
           "Generate an image of Hatsune Miku for me."},
          {"/newclaudetask", "Create a task using a Claude worker. Task content: ",
           " Fix login & keep C++ support\nAdd a regression test "},
          {"/review", "Review privately: ", "Review PR 1869 without changing code"}
        ] do
      test "#{command_name} delivers the exact prefixed prompt once through the public HTTP route",
           ctx do
        command = %{ctx.command | "command" => unquote(command_name), "text" => unquote(input)}
        expected = unquote(prefix <> input)
        source = "im_provider:slack:#{ctx.connect["connect_id"]}:slash:123.456.slash"
        response = post_slack_command(ctx.command_path, command)
        assert response.status == 200
        assert response.body == ""

        session = assert_router_session_message(ctx.router_id, ctx.group_id, source, expected)
        message = Enum.find(InternalSession.get(session, :messages), &(&1.role == "user"))
        assert message.trusted_origin["source_text"] == expected
        assert message.trusted_origin["principal_ref"]["subject_id"] == "U-OWNER"
        assert message.trusted_origin["provider_context"]["channel_id"] == "C-SLASH"
        assert message.trusted_origin["provider_context"]["thread_ts"] == "1234567890.123456"

        assert post_slack_command(ctx.command_path, command).status == 200

        {:ok, session_id} =
          ProviderConnects.agent_group_router_session_id(ctx.router_id, ctx.group_id)

        {:ok, session} = InternalSessionStore.read(ctx.router_id, session_id)
        assert Enum.count(InternalSession.get(session, :messages), &(&1.role == "user")) == 1
        assert InternalSession.get(session, :input_queue) == []
        posts = Enum.filter(MockSlackOAuth.requests(), &(&1.method == "chat.postMessage"))
        assert [post] = posts
        assert post.params["channel"] == command["channel_id"]

        assert post.params["text"] ==
                 "<@U-OWNER> : <@U-SLASH> " <> String.replace(unquote(input), "&", "&amp;")

        refute Map.has_key?(post.params, "thread_ts")
      end
    end

    test "App aliases change on the next callback and deletion stops new work", ctx do
      entry = %{
        "command" => "/review",
        "prompt" => "Review: ",
        "description" => "Review",
        "usage_hint" => "",
        "enabled" => true
      }

      {:ok, _} =
        SalixIM.SlackCommands.update(
          ctx.group_id,
          ctx.connect["connect_id"],
          ctx.connect["app_id"],
          &Map.put(&1, "commands", [entry])
        )

      cmd = %{ctx.command | "command" => "/review", "trigger_id" => "hot-1"}
      assert post_slack_command(ctx.command_path, cmd).status == 200
      source = "im_provider:slack:#{ctx.connect["connect_id"]}:slash:hot-1"

      assert_router_session_message(
        ctx.router_id,
        ctx.group_id,
        source,
        "Review: " <> cmd["text"]
      )

      {:ok, _} =
        SalixIM.SlackCommands.update(
          ctx.group_id,
          ctx.connect["connect_id"],
          ctx.connect["app_id"],
          &Map.put(&1, "commands", [%{entry | "prompt" => "Changed: "}])
        )

      cmd = %{cmd | "trigger_id" => "hot-2"}
      assert post_slack_command(ctx.command_path, cmd).status == 200
      source = "im_provider:slack:#{ctx.connect["connect_id"]}:slash:hot-2"

      assert_router_session_message(
        ctx.router_id,
        ctx.group_id,
        source,
        "Changed: " <> cmd["text"]
      )

      {:ok, _} =
        SalixIM.SlackCommands.update(
          ctx.group_id,
          ctx.connect["connect_id"],
          ctx.connect["app_id"],
          &Map.put(&1, "commands", [])
        )

      assert post_slack_command(ctx.command_path, %{cmd | "trigger_id" => "hot-3"}).body["text"] =~
               "not enabled"

      posts = Enum.filter(MockSlackOAuth.requests(), &(&1.method == "chat.postMessage"))
      assert length(posts) == 2

      assert Enum.all?(
               posts,
               &(&1.params["text"] ==
                   "<@U-OWNER> : <@U-SLASH> " <> String.replace(cmd["text"], "&", "&amp;"))
             )
    end

    test "dynamic alias disable blocks publication and re-enable reuses a confirmed root", ctx do
      cmd = %{ctx.command | "command" => "/review"}
      connect = Map.merge(ctx.connect, %{"bot_token" => "xoxb-slash", "bot_user_id" => "U-SLASH"})

      assert {:ok, "1234567890.123456"} =
               SalixIM.SlackCommandThread.ensure(connect, cmd, fn -> 2_500 end)

      update_alias = fn enabled, prefix ->
        SalixIM.SlackCommands.update(
          ctx.group_id,
          ctx.connect["connect_id"],
          ctx.connect["app_id"],
          fn state ->
            Map.update!(state, "commands", fn entries ->
              Enum.map(entries, fn entry ->
                if entry["command"] == "/review",
                  do: Map.merge(entry, %{"enabled" => enabled, "prompt" => prefix}),
                  else: entry
              end)
            end)
          end
        )
      end

      assert {:ok, _} = update_alias.(false, "Review privately: ")

      for trigger <- [cmd["trigger_id"], "disabled-new-trigger"] do
        response = post_slack_command(ctx.command_path, %{cmd | "trigger_id" => trigger})
        assert response.body["response_type"] == "ephemeral"
        assert response.body["text"] =~ "not enabled"
      end

      assert Enum.count(MockSlackOAuth.requests(), &(&1.method == "chat.postMessage")) == 1
      assert {:ok, _} = update_alias.(true, "New private prefix: ")
      assert post_slack_command(ctx.command_path, cmd).body == ""
      source = "im_provider:slack:#{ctx.connect["connect_id"]}:slash:#{cmd["trigger_id"]}"

      session =
        assert_router_session_message(
          ctx.router_id,
          ctx.group_id,
          source,
          "New private prefix: " <> cmd["text"]
        )

      message = Enum.find(InternalSession.get(session, :messages), &(&1.role == "user"))
      assert message.trusted_origin["provider_context"]["thread_ts"] == "1234567890.123456"
      assert {:ok, _} = update_alias.(true, "Later prefix: ")
      assert post_slack_command(ctx.command_path, cmd).body == ""
      assert Enum.count(MockSlackOAuth.requests(), &(&1.method == "chat.postMessage")) == 1

      {:ok, session_id} =
        ProviderConnects.agent_group_router_session_id(ctx.router_id, ctx.group_id)

      {:ok, final} = InternalSessionStore.read(ctx.router_id, session_id)
      assert Enum.count(InternalSession.get(final, :messages), &(&1.role == "user")) == 1
    end

    test "inaccessible channels do not enqueue and can retry after inviting the app", ctx do
      {:ok, session_id} =
        ProviderConnects.agent_group_router_session_id(ctx.router_id, ctx.group_id)

      for provider_response <- [
            %{"ok" => false, "error" => "channel_not_found"},
            %{"ok" => true, "channel" => %{"is_member" => false}}
          ] do
        MockSlackOAuth.respond(provider_response)
        response = post_slack_command(ctx.command_path, ctx.command)

        assert InternalSessionStore.read(ctx.router_id, session_id) == {:error, :not_found}
        assert response.status == 200
        assert response.body["response_type"] == "ephemeral"
        assert response.body["text"] =~ "Invite this app"
      end

      MockSlackOAuth.respond(&slash_slack_response/1)
      assert post_slack_command(ctx.command_path, ctx.command).status == 200

      source = "im_provider:slack:#{ctx.connect["connect_id"]}:slash:123.456.slash"
      expected = "Create a task using a Codex worker. Task content: " <> ctx.command["text"]
      assert_router_session_message(ctx.router_id, ctx.group_id, source, expected)

      requests = Enum.filter(MockSlackOAuth.requests(), &(&1.method == "conversations.info"))
      assert length(requests) == 3
      assert Enum.all?(requests, &(&1.params == %{"channel" => "C-SLASH"}))
      assert Enum.all?(requests, &(&1.auth == "Bearer xoxb-slash"))
    end

    test "an accessible bot DM can submit without a channel membership field", ctx do
      MockSlackOAuth.respond(fn req ->
        if req.method == "conversations.info",
          do: %{"ok" => true, "channel" => %{"is_im" => true}},
          else: slash_slack_response(req)
      end)

      command = %{ctx.command | "channel_id" => "D-SLASH"}
      assert post_slack_command(ctx.command_path, command).status == 200

      source = "im_provider:slack:#{ctx.connect["connect_id"]}:slash:123.456.slash"
      expected = "Create a task using a Codex worker. Task content: " <> command["text"]
      session = assert_router_session_message(ctx.router_id, ctx.group_id, source, expected)
      message = Enum.find(InternalSession.get(session, :messages), &(&1.role == "user"))
      assert message.trusted_origin["provider_context"]["channel_id"] == "D-SLASH"
    end

    test "archived channels and failed access checks return repair guidance without enqueueing",
         ctx do
      for {provider_response, guidance} <- [
            {%{"ok" => true, "channel" => %{"is_member" => true, "is_archived" => true}},
             "active channel"},
            {%{"ok" => false, "error" => "missing_scope"}, "reinstall the app"},
            {%{"ok" => false, "error" => "ratelimited"}, "Try again"}
          ] do
        MockSlackOAuth.respond(provider_response)
        response = post_slack_command(ctx.command_path, ctx.command)
        assert response.status == 200
        assert response.body["response_type"] == "ephemeral"
        assert response.body["text"] =~ guidance
      end

      {:ok, session_id} =
        ProviderConnects.agent_group_router_session_id(ctx.router_id, ctx.group_id)

      assert InternalSessionStore.read(ctx.router_id, session_id) == {:error, :not_found}
      assert Enum.count(MockSlackOAuth.requests(), &(&1.method == "conversations.info")) == 3
    end

    test "a slow Slack access check returns private retry guidance within the acknowledgement window",
         ctx do
      MockSlackOAuth.respond(fn ->
        Process.sleep(3_500)
        %{"ok" => true, "channel" => %{"is_member" => true}}
      end)

      started = System.monotonic_time(:millisecond)
      response = post_slack_command(ctx.command_path, ctx.command)
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 2_500
      assert response.status == 200
      assert response.body["response_type"] == "ephemeral"
      assert response.body["text"] =~ "No task was submitted"

      {:ok, session_id} =
        ProviderConnects.agent_group_router_session_id(ctx.router_id, ctx.group_id)

      assert InternalSessionStore.read(ctx.router_id, session_id) == {:error, :not_found}
      assert Enum.count(MockSlackOAuth.requests(), &(&1.method == "conversations.info")) == 1
    end

    test "invalid signatures, wrong workspaces, and empty or malformed input do not enqueue",
         ctx do
      assert post_slack_command(ctx.command_path, ctx.command, "wrong-secret").status == 401

      assert post_slack_command(ctx.command_path, %{ctx.command | "team_id" => "T-OTHER"}).status ==
               401

      assert post_slack_command(ctx.command_path, Map.delete(ctx.command, "trigger_id")).status ==
               400

      unknown = post_slack_command(ctx.command_path, %{ctx.command | "command" => "/unknown"})
      assert unknown.status == 200
      assert unknown.body["text"] =~ "not enabled"

      for command_name <- ["/newgpttask", "/newclaudetask"] do
        empty =
          post_slack_command(ctx.command_path, %{
            ctx.command
            | "command" => command_name,
              "text" => " \n "
          })

        assert empty.status == 200
        assert empty.body["response_type"] == "ephemeral"
        assert empty.body["text"] =~ command_name
      end

      {:ok, session_id} =
        ProviderConnects.agent_group_router_session_id(ctx.router_id, ctx.group_id)

      assert InternalSessionStore.read(ctx.router_id, session_id) == {:error, :not_found}

      refute Enum.any?(
               MockSlackOAuth.requests(),
               &(&1.method in ["conversations.info", "chat.postMessage"])
             )
    end

    test "the bot's echoed root mention does not create another Router input", ctx do
      assert post_slack_command(ctx.command_path, ctx.command).body == ""
      source = "im_provider:slack:#{ctx.connect["connect_id"]}:slash:123.456.slash"
      expected = "Create a task using a Codex worker. Task content: " <> ctx.command["text"]
      assert_router_session_message(ctx.router_id, ctx.group_id, source, expected)

      response =
        slack_event(
          Jason.encode!(%{
            "type" => "event_callback",
            "api_app_id" => "A-SLASH",
            "team_id" => "T-SLASH",
            "event_id" => "Ev-SLASH-ROOT",
            "event" => %{
              "type" => "app_mention",
              "user" => "U-SLASH",
              "bot_id" => "B-SLASH",
              "channel" => "C-SLASH",
              "ts" => "1234567890.123456",
              "text" => "<@U-OWNER> : <@U-SLASH> " <> ctx.command["text"]
            }
          }),
          "sign-slash"
        )

      assert response.status == 200

      {:ok, session_id} =
        ProviderConnects.agent_group_router_session_id(ctx.router_id, ctx.group_id)

      {:ok, session} = InternalSessionStore.read(ctx.router_id, session_id)
      assert Enum.count(InternalSession.get(session, :messages), &(&1.role == "user")) == 1
      assert InternalSession.get(session, :input_queue) == []
    end

    test "concurrent callbacks publish one source message and admit one input", ctx do
      MockSlackOAuth.respond(fn req ->
        if req.method == "chat.postMessage", do: Process.sleep(100)
        slash_slack_response(req)
      end)

      responses =
        1..3
        |> Task.async_stream(fn _ -> post_slack_command(ctx.command_path, ctx.command) end,
          max_concurrency: 3
        )
        |> Enum.map(fn {:ok, response} -> response end)

      assert Enum.all?(responses, &(&1.status == 200))
      assert Enum.any?(responses, &(&1.body == ""))
      assert Enum.count(MockSlackOAuth.requests(), &(&1.method == "chat.postMessage")) == 1

      source = "im_provider:slack:#{ctx.connect["connect_id"]}:slash:123.456.slash"
      expected = "Create a task using a Codex worker. Task content: " <> ctx.command["text"]
      session = assert_router_session_message(ctx.router_id, ctx.group_id, source, expected)
      assert Enum.count(InternalSession.get(session, :messages), &(&1.role == "user")) == 1
    end

    test "a published root survives retry before Router admission", ctx do
      connect = Map.merge(ctx.connect, %{"bot_token" => "xoxb-slash", "bot_user_id" => "U-SLASH"})

      assert {:ok, "1234567890.123456"} =
               SalixIM.SlackCommandThread.ensure(connect, ctx.command, fn -> 2_500 end)

      assert post_slack_command(ctx.command_path, ctx.command).body == ""
      assert Enum.count(MockSlackOAuth.requests(), &(&1.method == "chat.postMessage")) == 1
      source = "im_provider:slack:#{ctx.connect["connect_id"]}:slash:123.456.slash"
      expected = "Create a task using a Codex worker. Task content: " <> ctx.command["text"]
      session = assert_router_session_message(ctx.router_id, ctx.group_id, source, expected)
      message = Enum.find(InternalSession.get(session, :messages), &(&1.role == "user"))
      assert message.trusted_origin["provider_context"]["thread_ts"] == "1234567890.123456"
    end

    test "definitive publication failure is private and retryable without admitting a task",
         ctx do
      MockSlackOAuth.respond(fn req ->
        if req.method == "chat.postMessage",
          do: %{"ok" => false, "error" => "missing_scope"},
          else: slash_slack_response(req)
      end)

      response = post_slack_command(ctx.command_path, ctx.command)
      assert response.status == 200
      assert response.body["response_type"] == "ephemeral"
      assert response.body["text"] =~ "No task was submitted"

      {:ok, session_id} =
        ProviderConnects.agent_group_router_session_id(ctx.router_id, ctx.group_id)

      assert InternalSessionStore.read(ctx.router_id, session_id) == {:error, :not_found}

      MockSlackOAuth.respond(&slash_slack_response/1)
      assert post_slack_command(ctx.command_path, ctx.command).body == ""
      assert Enum.count(MockSlackOAuth.requests(), &(&1.method == "chat.postMessage")) == 2
    end

    test "a timed-out write is not blindly published again on callback retry", ctx do
      ctx = %{ctx | command: Map.put(ctx.command, "command", "/review")}

      MockSlackOAuth.respond(fn req ->
        if req.method == "chat.postMessage", do: Process.sleep(1_500)
        slash_slack_response(req)
      end)

      for _ <- 1..2 do
        response = post_slack_command(ctx.command_path, ctx.command)
        assert response.status == 200
        assert response.body["response_type"] == "ephemeral"
        assert response.body["text"] =~ "could not be confirmed"
      end

      assert Enum.count(MockSlackOAuth.requests(), &(&1.method == "chat.postMessage")) == 1

      {:ok, session_id} =
        ProviderConnects.agent_group_router_session_id(ctx.router_id, ctx.group_id)

      assert InternalSessionStore.read(ctx.router_id, session_id) == {:error, :not_found}
    end

    test "prompt control syntax stays literal while the two attribution mentions remain real",
         ctx do
      text = "Draw <!channel> and <@U-OTHER> & <https://example.com|a link>"
      command = Map.put(ctx.command, "text", text)
      assert post_slack_command(ctx.command_path, command).body == ""
      [post] = Enum.filter(MockSlackOAuth.requests(), &(&1.method == "chat.postMessage"))

      assert post.params["text"] ==
               "<@U-OWNER> : <@U-SLASH> Draw &lt;!channel&gt; and &lt;@U-OTHER&gt; &amp; &lt;https://example.com|a link&gt;"

      source = "im_provider:slack:#{ctx.connect["connect_id"]}:slash:123.456.slash"
      expected = "Create a task using a Codex worker. Task content: " <> text
      session = assert_router_session_message(ctx.router_id, ctx.group_id, source, expected)
      message = Enum.find(InternalSession.get(session, :messages), &(&1.role == "user"))
      assert message.trusted_origin["source_text"] == expected
    end

    test "escaping cannot silently truncate a prompt which fits before encoding", ctx do
      command = Map.put(ctx.command, "text", String.duplicate("<", 10_000))
      response = post_slack_command(ctx.command_path, command)
      assert response.body["text"] =~ "too long to publish in full"
      refute Enum.any?(MockSlackOAuth.requests(), &(&1.method == "chat.postMessage"))
    end

    test "a slow receipt claim cannot hold the HTTP acknowledgement past its deadline", ctx do
      key = Keys.ctl_im_slack_command_thread(ctx.connect["connect_id"], ctx.command["trigger_id"])
      SalixStore.S3.Fake.set_fault({:delay, 3_200, :put, key})

      started = System.monotonic_time(:millisecond)
      response = post_slack_command(ctx.command_path, ctx.command)
      assert System.monotonic_time(:millisecond) - started < 3_000
      assert response.status == 200
      assert response.body["text"] =~ "could not be confirmed"
      # A conditional write can complete after the caller is killed. Retain it.
      assert {:ok, %{"state" => "posting"}} = SalixStore.CasRecord.get(key)

      assert post_slack_command(ctx.command_path, ctx.command).body["text"] =~
               "could not be confirmed"

      refute Enum.any?(MockSlackOAuth.requests(), &(&1.method == "chat.postMessage"))

      {:ok, session_id} =
        ProviderConnects.agent_group_router_session_id(ctx.router_id, ctx.group_id)

      assert InternalSessionStore.read(ctx.router_id, session_id) == {:error, :not_found}
    end

    for {label, claim_delay, channel_delay, post_delay, settle_delay} <- [
          {"slow settlement", 0, 0, 0, 3_200},
          {"combined callback latency", 1_100, 250, 300, 1_100}
        ] do
      test "#{label} is bounded and late settlement reuses the published thread", ctx do
        key =
          Keys.ctl_im_slack_command_thread(ctx.connect["connect_id"], ctx.command["trigger_id"])

        if unquote(claim_delay) > 0 do
          SalixStore.S3.Fake.set_fault({:delay, unquote(claim_delay), :put, key})
        end

        MockSlackOAuth.respond(fn req ->
          case req.method do
            "conversations.info" ->
              Process.sleep(unquote(channel_delay))

            "chat.postMessage" ->
              Process.sleep(unquote(post_delay))
              SalixStore.S3.Fake.set_fault({:delay, unquote(settle_delay), :put, key})

            _ ->
              :ok
          end

          slash_slack_response(req)
        end)

        started = System.monotonic_time(:millisecond)
        response = post_slack_command(ctx.command_path, ctx.command)
        assert System.monotonic_time(:millisecond) - started < 3_000
        assert response.status == 200
        assert response.body["text"] =~ "could not be confirmed"

        assert {:ok, %{"state" => "posted", "ts" => "1234567890.123456"}} =
                 SalixStore.CasRecord.get(key)

        {:ok, session_id} =
          ProviderConnects.agent_group_router_session_id(ctx.router_id, ctx.group_id)

        assert InternalSessionStore.read(ctx.router_id, session_id) == {:error, :not_found}

        MockSlackOAuth.respond(&slash_slack_response/1)
        assert post_slack_command(ctx.command_path, ctx.command).body == ""
        assert Enum.count(MockSlackOAuth.requests(), &(&1.method == "chat.postMessage")) == 1
        source = "im_provider:slack:#{ctx.connect["connect_id"]}:slash:123.456.slash"
        expected = "Create a task using a Codex worker. Task content: " <> ctx.command["text"]
        session = assert_router_session_message(ctx.router_id, ctx.group_id, source, expected)
        message = Enum.find(InternalSession.get(session, :messages), &(&1.role == "user"))
        assert message.trusted_origin["provider_context"]["thread_ts"] == "1234567890.123456"
      end
    end

    test "a trigger cannot be reused to redirect an existing thread or change its prompt", ctx do
      assert post_slack_command(ctx.command_path, ctx.command).body == ""
      changed = Map.put(ctx.command, "text", "A different task")
      response = post_slack_command(ctx.command_path, changed)
      assert response.body["response_type"] == "ephemeral"
      assert Enum.count(MockSlackOAuth.requests(), &(&1.method == "chat.postMessage")) == 1
    end

    test "oversized prompts are rejected privately instead of being silently truncated", ctx do
      response =
        post_slack_command(
          ctx.command_path,
          Map.put(ctx.command, "text", String.duplicate("x", 39_001))
        )

      assert response.body["response_type"] == "ephemeral"
      assert response.body["text"] =~ "too long to publish in full"
      refute Enum.any?(MockSlackOAuth.requests(), &(&1.method == "chat.postMessage"))
    end

    test "disabled connections cannot submit a command", ctx do
      assert treq(
               :post,
               "/v1/runtime/agent-groups/#{ctx.group_id}/im/connects/#{ctx.connect["connect_id"]}/disable"
             ).status == 200

      assert post_slack_command(ctx.command_path, ctx.command).status == 200

      {:ok, session_id} =
        ProviderConnects.agent_group_router_session_id(ctx.router_id, ctx.group_id)

      assert InternalSessionStore.read(ctx.router_id, session_id) == {:error, :not_found}
    end
  end

  defp slash_slack_response(%{method: "chat.postMessage", params: params}),
    do: %{"ok" => true, "channel" => params["channel"], "ts" => "1234567890.123456"}

  defp slash_slack_response(_request),
    do: %{"ok" => true, "channel" => %{"is_member" => true}}

  defp post_slack_command(path, params, secret \\ "sign-slash") do
    raw = URI.encode_query(params)
    timestamp = Integer.to_string(System.system_time(:second))

    Req.request!(
      method: :post,
      url: base() <> path,
      headers: [
        {"content-type", "application/x-www-form-urlencoded"},
        {"x-slack-request-timestamp", timestamp},
        {"x-slack-signature", slack_sig(secret, timestamp, raw)}
      ],
      body: raw,
      retry: false
    )
  end

  test "the public Slack interaction route accepts signed form payloads and updates checkbox state",
       %{tenant_id: tenant_id} do
    start_supervised!(MockSlackOAuth)
    port = start_bandit_retry!(fn p -> {Bandit, plug: MockSlackOAuth, port: p} end)
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

    group_id = create_test_group("Slack Checkbox Route")["group_id"]

    router =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group_id, name: "Checkbox Router", role: "router"}
      )

    assert treq(:patch, "/v1/runtime/agent-groups/#{group_id}",
             json: %{router_agent_id: router.body["agent_id"]}
           ).status == 200

    {:ok, connect} =
      ProviderConnects.create_slack_im_connect(tenant_id, group_id, %{
        "app_id" => "A-CHECKBOX-ROUTE",
        "client_id" => "client-checkbox",
        "client_secret" => "secret-checkbox",
        "signing_secret" => "sign-checkbox"
      })

    {:ok, _} =
      ProviderConnects.complete_slack_im_connect_oauth(connect, %{
        "bot_token" => "xoxb-checkbox",
        "bot_id" => "B-CHECKBOX",
        "bot_user_id" => "U-CHECKBOX",
        "workspace_id" => "T-CHECKBOX",
        "workspace_name" => "Checkbox Workspace",
        "enterprise_id" => nil,
        "owner_user_id" => "U-OWNER"
      })

    assert {:ok, %{text: fallback, blocks: blocks}} =
             SalixIM.Provider.Slack.MessageRenderer.render("- [ ] First\n- [x] Second")

    actions = hd(blocks)
    checkbox = get_in(actions, ["elements", Access.at(0)])
    [first, _second] = checkbox["options"]

    payload = %{
      "type" => "block_actions",
      "api_app_id" => "A-CHECKBOX-ROUTE",
      "team" => %{"id" => "T-CHECKBOX"},
      "container" => %{
        "type" => "message",
        "channel_id" => "C-CHECKBOX",
        "message_ts" => "1787827000.123"
      },
      "message" => %{
        "text" => fallback,
        "ts" => "1787827000.123",
        "blocks" => blocks
      },
      "actions" => [
        %{
          "type" => "checkboxes",
          "block_id" => actions["block_id"],
          "action_id" => checkbox["action_id"],
          "selected_options" => [first]
        }
      ]
    }

    raw_body = "payload=" <> URI.encode_www_form(Jason.encode!(payload))
    timestamp = Integer.to_string(System.system_time(:second))

    response =
      Req.request!(
        method: :post,
        url: base() <> "/v1/im/slack/interactions",
        headers: [
          {"content-type", "application/x-www-form-urlencoded"},
          {"x-slack-request-timestamp", timestamp},
          {"x-slack-signature", slack_sig("sign-checkbox", timestamp, raw_body)}
        ],
        body: raw_body,
        retry: false
      )

    assert response.status == 200
    assert response.body == %{"ok" => true}

    [update] = Enum.filter(MockSlackOAuth.requests(), &(&1.method == "chat.update"))
    assert update.params["channel"] == "C-CHECKBOX"
    assert update.params["ts"] == "1787827000.123"
    assert update.params["text"] == fallback

    updated_blocks = Jason.decode!(update.params["blocks"])
    updated_checkbox = get_in(hd(updated_blocks), ["elements", Access.at(0)])
    assert updated_checkbox["initial_options"] == [first]
  end

  test "an absent scan limiter returns 503 without an identity scan" do
    # Round-10: the hard bound must hold even with the permit owner
    # down. An absent owner yields the retryable 503, never an
    # unbounded pre-auth scan.
    :ok = Supervisor.terminate_child(SalixIM.Supervisor, SalixIM.ProviderIdentityScanLimiter)

    on_exit(fn ->
      {:ok, _} = Supervisor.restart_child(SalixIM.Supervisor, SalixIM.ProviderIdentityScanLimiter)
    end)

    SalixStore.S3.Fake.reset_read_log()

    # Background receipt maintenance can list an unrelated prefix while this
    # HTTP request runs. It must not count as a pre-auth identity scan.
    {:ok, _} =
      Task.async(fn ->
        SalixStore.S3.Fake.list(Keys.ctl_im_slack_event_receipts_prefix(), max_keys: 25)
      end)
      |> Task.await()

    resp =
      Req.request!(
        method: :post,
        url: base() <> "/v1/im/slack/events",
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{type: "event_callback", api_app_id: "A-ROUTE-NOLIMITER"}),
        retry: false
      )

    assert resp.status == 503

    identity_prefix = Keys.ctl_im_connects_all_prefix()

    refute Enum.any?(SalixStore.S3.Fake.read_log(), fn
             {:list, ^identity_prefix, _opts} -> true
             _ -> false
           end)
  end

  test "an over-capacity fallback scan answers 503 at the route level" do
    # The unknown-app_id fallback walks the whole connect prefix behind
    # a concurrency permit; over-permit webhook events get a retryable
    # 503 (providers redeliver) instead of stacking more scans.
    prev = Application.fetch_env(:salix_im, :identity_scan_max_concurrency)
    Application.put_env(:salix_im, :identity_scan_max_concurrency, 0)

    on_exit(fn ->
      case prev do
        {:ok, value} -> Application.put_env(:salix_im, :identity_scan_max_concurrency, value)
        :error -> Application.delete_env(:salix_im, :identity_scan_max_concurrency)
      end
    end)

    resp =
      Req.request!(
        method: :post,
        url: base() <> "/v1/im/slack/events",
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{type: "event_callback", api_app_id: "A-ROUTE-OVERCAP"}),
        retry: false
      )

    assert resp.status == 503
  end
end
