defmodule BridgeForTeams.FeishuProjectConnectSmokeTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Agents, Orgs, ProjectIMConnects, Projects, TestBandit}
  alias BridgeForTeams.Salix.Client
  alias SalixAgent.LLM.Mock

  defmodule MockFeishuAPI do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/open-apis/auth/v3/tenant_access_token/internal"} = conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"code" => 0, "tenant_access_token" => "test-token"}))
    end

    def call(%{request_path: "/open-apis/bot/v3/info"} = conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"code" => 0, "bot" => %{"open_id" => "ou_bot"}}))
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    prev_store = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_public_base_url = Application.get_env(:salix_im, :public_base_url)
    prev_feishu_api_base = Application.get_env(:salix_im, :feishu_api_base_url)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_im, :public_base_url, SalixWeb.Application.base_url())

    %{url: feishu_url} =
      TestBandit.start_supervised!(plug: MockFeishuAPI, startup_log: false)

    Application.put_env(:salix_im, :feishu_api_base_url, feishu_url <> "/open-apis")
    start_fake_store()

    case start_supervised(Mock) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    Application.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore_env(:salix_store, :s3_backend, prev_store)
      restore_env(:salix_agent, :llm, prev_llm)
      restore_env(:salix_im, :public_base_url, prev_public_base_url)
      restore_env(:salix_im, :feishu_api_base_url, prev_feishu_api_base)
    end)

    :ok
  end

  test "BridgeForTeams project Feishu connect verifies and routes a non-live group event" do
    suffix = System.unique_integer([:positive])
    app_id = "cli_smoke_#{suffix}"
    {:ok, org} = Orgs.create_org(%{name: "Smoke #{suffix}", slug: "smoke-#{suffix}"})
    {:ok, project} = Projects.create_project(org.id, %{name: "Bridge", slug: "bridge-#{suffix}"})

    {:ok, router_agent} =
      Agents.create_agent(project.id, %{"role" => "router", "name" => "Bridge"})

    drain_all()

    {:ok, _group} =
      Salix.Control.Groups.update(project.salix_group_id, %{
        "router_agent_id" => router_agent.salix_agent_id
      })

    assert {:ok, _app} =
             Salix.Control.Tenants.put_feishu_tenant_app(org.salix_tenant_id, %{
               "app_id" => app_id,
               "app_secret" => "fake-app-value-#{suffix}",
               "verification_token" => "fake-verification-value-#{suffix}",
               "encrypt_key" => "fake-encryption-value-#{suffix}"
             })

    assert {:ok, connect} =
             ProjectIMConnects.create_project_connect(org.id, project.id, "feishu", %{
               "app_id" => app_id
             })

    challenge = "challenge-#{suffix}"

    verified =
      Req.request!(
        method: :post,
        url: feishu_webhook_request_url(connect, app_id),
        headers: [{"content-type", "application/json"}],
        json: %{
          "type" => "url_verification",
          "app_id" => app_id,
          "token" => "fake-verification-value-#{suffix}",
          "challenge" => challenge
        }
      )

    assert verified.status == 200
    assert verified.body == %{"challenge" => challenge}

    Mock.script([{:final, "ack"}])

    chat_id = "oc_smoke_#{suffix}"
    body_text = "bridge smoke #{suffix}"

    delivered =
      Req.request!(
        method: :post,
        url: feishu_webhook_request_url(connect, app_id),
        headers: [{"content-type", "application/json"}],
        json: feishu_message_event(suffix, chat_id, body_text)
      )

    assert delivered.status == 200
    assert delivered.body["ok"] == true
    assert delivered.body["status"] == "queued"

    assert {:ok, evidence} =
             route_evidence(project, connect, body_text, router_agent.salix_agent_id)

    assert evidence.claim == "routed-but-silent"
    assert evidence.status == delivered.body["status"]
    assert evidence.connect_id == connect["connect_id"]
    assert evidence.group_id == project.salix_group_id
  end

  defp start_fake_store do
    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end
  end

  defp drain_all do
    case BridgeForTeams.Salix.Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp feishu_message_event(suffix, chat_id, text) do
    %{
      "schema" => "2.0",
      "header" => %{
        "event_id" => "evt-smoke-#{suffix}",
        "event_type" => "im.message.receive_v1",
        "token" => "fake-verification-value-#{suffix}",
        "app_id" => "cli_smoke_#{suffix}",
        "tenant_key" => "tenant-smoke"
      },
      "event" => %{
        "sender" => %{
          "sender_type" => "user",
          "sender_id" => %{"open_id" => "ou_smoke", "user_id" => "u_smoke"},
          "sender_name" => "Feishu User"
        },
        "message" => %{
          "message_id" => "om_smoke_#{suffix}",
          "chat_id" => chat_id,
          "chat_type" => "group",
          "message_type" => "text",
          "content" => Jason.encode!(%{"text" => text}),
          "create_time" => "1700000000000",
          "mentions" => [
            %{
              "key" => "@_user_1",
              "id" => %{"open_id" => "ou_bot"},
              "name" => "Bridge"
            }
          ]
        }
      }
    }
  end

  defp feishu_webhook_request_url(connect, app_id) do
    connect["webhook_url"]
    |> URI.parse()
    |> URI.append_query(URI.encode_query(%{"app_id" => app_id}))
    |> URI.to_string()
  end

  defp wait_for(fun, retries \\ 100) do
    case fun.() do
      {:ok, value} -> {:ok, value}
      _ when retries == 0 -> {:error, :timeout}
      _ -> Process.sleep(20) && wait_for(fun, retries - 1)
    end
  end

  defp route_evidence(project, connect, body_text, router_agent_id) do
    provider_source_message_id_prefix = "im_provider:feishu:#{connect["connect_id"]}:"

    assert {:ok, {session, session_message}} =
             wait_for(fn ->
               with {:ok, session_id} <-
                      apply(SalixIM.ProviderConnects, :agent_group_router_session_id, [
                        router_agent_id,
                        project.salix_group_id
                      ]),
                    {:ok, session} <-
                      Client.impl().get_session_messages(router_agent_id, session_id),
                    %{} = session_message <-
                      Enum.find(session["messages"] || [], fn message ->
                        content_contains?(message["content"], body_text) and
                          String.starts_with?(
                            message["source_message_id"] || "",
                            provider_source_message_id_prefix
                          )
                      end) do
                 {:ok, {session, session_message}}
               else
                 _ -> {:error, :not_ready}
               end
             end)

    {:ok,
     %{
       claim: "routed-but-silent",
       status: "queued",
       connect_id: connect["connect_id"],
       group_id: project.salix_group_id,
       source_message_id: session_message["source_message_id"],
       session_id: session["session_id"]
     }}
  end

  defp content_contains?(content, expected) when is_binary(content),
    do: String.contains?(content, expected)

  defp content_contains?(content, expected) when is_list(content) do
    Enum.any?(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        String.contains?(text, expected)

      _other ->
        false
    end)
  end

  defp content_contains?(_content, _expected), do: false

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
