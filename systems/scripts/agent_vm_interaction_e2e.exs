Code.require_file("support/comma_workspace_bootstrap.exs", __DIR__)

defmodule AgentVMInteractionE2E do
  @moduledoc false

  import Plug.Conn
  import Plug.Test

  alias BridgeForTeams.{Agents, Orgs, Projects}
  alias BridgeForTeams.Salix.Reconciler
  alias SalixEnv.Registry
  alias SalixEnv.VM.Providers.Cloudflare.Attachments
  alias SalixWeb.{CloudVM, EnvDispatch}

  @admin_token "agent-vm-interaction-e2e-admin"
  @env_alias "cloud-vm"
  @comma_opts CommaWeb.Router.init([])

  def run do
    surface = required_env!("SALIX_AGENT_VM_E2E_SURFACE")
    provider = System.get_env("SALIX_AGENT_VM_E2E_PROVIDER") || "cloudflare"

    unless surface in ["comma", "bft"], do: raise("unsupported surface: #{surface}")

    unless provider == "cloudflare", do: raise("unsupported provider: #{provider}")

    setup_runtime!([provider], surface)

    ref =
      case surface do
        "comma" -> create_comma_agent_vm!(provider)
        "bft" -> create_bft_agent_vm!(provider)
      end

    rec = assert_ready!(ref, provider)
    marker = "/tmp/agent-vm-interaction-#{System.unique_integer([:positive])}.txt"

    marker_payload =
      "agent-vm-marker #{surface} #{provider} #{System.unique_integer([:positive])}"

    visible_reply = "AGENT_VM_VISIBLE_REPLY #{surface} #{provider}"

    script_agent_turn!(ref, marker, marker_payload, visible_reply)
    send_user_message!(ref, "Please run the VM marker command.")

    messages = wait_for_visible_reply!(ref, visible_reply)
    assert_tool_result!(ref.agent_id, ref.session_id, marker_payload)
    assert_marker_file!(ref.agent_id, marker, marker_payload)

    IO.puts(
      "AGENT_VM_INTERACTION_E2E: PASS surface=#{surface} provider=#{provider} env_id=#{rec["env_id"]} messages=#{length(messages)}"
    )
  rescue
    error ->
      IO.puts("AGENT_VM_INTERACTION_E2E: FAIL #{Exception.message(error)}")
      IO.puts(Exception.format(:error, error, __STACKTRACE__))
      System.halt(1)
  end

  defp setup_runtime!(providers, surface) do
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    {:ok, _} = Application.ensure_all_started(:salix_web)
    {:ok, _} = Application.ensure_all_started(:billing_core)
    ensure_repo_started!(BillingCore.Repo)
    {:ok, _} = Application.ensure_all_started(:billing_commerce)
    {:ok, _} = Application.ensure_all_started(:bridge_for_teams_core)
    {:ok, _} = Application.ensure_all_started(:comma_web)
    {:ok, _} = SalixAgent.LLM.Mock.start_link()

    setup_repo!(BridgeForTeams.Repo)
    setup_repo!(BillingCore.Repo)

    if surface == "comma" do
      ensure_repo_started!(Comma.Repo)
      setup_repo!(Comma.Repo)
    end

    Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [Node.self()])
    Application.put_env(:salix_agent, :env_dispatch, SalixWeb.EnvDispatch)
    Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)

    Application.put_env(
      :salix_web,
      :vm_authorization_mod,
      SalixWeb.ComputeProviders.Cloudflare.VMAuthorization.Noop
    )

    Application.put_env(:salix_web, :api_token, @admin_token)
    Application.put_env(:comma_web, :api_token, @admin_token)
    Application.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)

    Application.put_env(:comma_core, :auth,
      challenge_store: Comma.AuthChallengeStore.Memory,
      email_delivery: Comma.EmailDelivery.Logger,
      secret: "comma-agent-vm-e2e-secret",
      challenge_ttl_seconds: 900,
      max_attempts: 5,
      session_ttl_seconds: 3600,
      auto_create_users: true,
      expose_codes: true
    )

    if Process.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised_s3_fake!()

    Attachments.stop_all()
    SalixAgent.TestSupport.stop_all_agents()
    Comma.AuthChallengeStore.Memory.reset!()

    sections = provider_sections!(providers)
    Application.put_env(:salix_web, :vm_e2e_provider_sections, sections)
    Application.put_env(:comma_core, :salix_vm, %{"providers" => sections})

    if surface == "comma" do
      CommaScripts.WorkspaceBootstrap.ensure_operation_runtime_started!()
    end
  end

  defp create_comma_agent_vm!(provider) do
    suffix = unique("comma-#{provider}")

    user =
      admin_req(:post, "/v1/comma/admin/users", %{
        "email" => "comma-agent-vm-#{suffix}@example.com",
        "name" => "Comma Agent VM #{suffix}"
      })
      |> expect_json!(201)

    {session, workspace} =
      bootstrap_comma_workspace!(user["id"], %{
        "name" => "Comma Agent VM #{suffix}",
        "vm" => %{"enabled" => true, "provider" => provider}
      })

    issue_comma_billing_grant!(workspace)

    assistant_chat_path =
      "/v1/comma/groups/#{workspace["default_group_id"]}/assistant-chat"

    conversation =
      CommaScripts.WorkspaceBootstrap.ensure_assistant_chat_ready!(
        fn ->
          user_req(
            session["token"],
            :post,
            assistant_chat_path,
            %{}
          )
        end,
        max_attempts: max(div(timeout_ms(), 2_000), 1),
        poll_ms: 2_000
      )

    salix_conversation_id = conversation["id"]

    expect!(
      SalixStore.Ids.valid_conversation_id?(salix_conversation_id),
      "comma canonical Salix conversation id"
    )

    {:ok, activity_context} =
      CommaWeb.SalixClient.conversation_activity_context(workspace, salix_conversation_id)

    %{
      surface: "comma",
      user: user,
      workspace: workspace,
      session_token: session["token"],
      agent_id: activity_context.agent_id,
      group_id: workspace["default_group_id"],
      conversation_id: conversation["id"],
      runtime_conversation_id: salix_conversation_id,
      session_id: activity_context.session_id
    }
  end

  defp create_bft_agent_vm!(provider) do
    suffix = unique("bft-#{provider}")

    {:ok, org} = Orgs.create_org(%{"name" => "BFT Agent VM #{suffix}", "slug" => suffix})

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "VM #{suffix}", "slug" => suffix})

    issue_bridge_billing_grant!(org)

    drain_all!()
    configure_tenant_vm!(org.salix_tenant_id, provider)

    {:ok, agent} =
      Agents.create_agent(project.id, %{
        "role" => "worker",
        "name" => "worker-#{suffix}",
        "vm" => %{"enabled" => true, "provider" => provider}
      })

    drain_all!()

    tenant_key = create_tenant_key!(org.salix_tenant_id, suffix)

    conversation =
      create_runtime_conversation!(
        tenant_key,
        project.salix_group_id,
        agent.salix_agent_id,
        "agent-vm-#{suffix}"
      )

    conversation_id = Map.fetch!(conversation, "conversation_id")
    expect!(SalixStore.Ids.valid_conversation_id?(conversation_id), "canonical conversation id")

    session_id =
      agent_session_id!(tenant_key, project.salix_group_id, conversation_id, agent.salix_agent_id)

    %{
      surface: "bft",
      org: org,
      project: project,
      agent: agent,
      tenant_key: tenant_key,
      agent_id: agent.salix_agent_id,
      group_id: project.salix_group_id,
      conversation_id: conversation_id,
      runtime_conversation_id: conversation_id,
      session_id: session_id
    }
  end

  defp script_agent_turn!(ref, marker, payload, visible_reply) do
    target = cloud_target(ref.agent_id, @env_alias)

    command =
      "mkdir -p #{Path.dirname(marker)} && printf '%s' #{shell_quote(payload)} > #{shell_quote(marker)} && cat #{shell_quote(marker)}"

    SalixAgent.LLM.Mock.script([
      {:assistant, "running command",
       [
         %{
           id: "agent-vm-exec",
           name: "call",
           args: %{
             "tool" => "env.exec",
             "params" => %{
               "device_id" => target.device_id,
               "environment" => target.environment_id,
               "command" => command,
               "description" => "write marker"
             }
           }
         }
       ]},
      {:assistant, "publishing result",
       [
         %{
           id: "agent-vm-visible",
           name: "call",
           args: %{
             "tool" => "im_api.internal.send_message",
             "params" => %{
               "connect_id" => "internal",
               "conversation_id" => ref.runtime_conversation_id,
               "content" => [%{"type" => "text", "text" => visible_reply}]
             }
           }
         }
       ]},
      {:final, "done"}
    ])
  end

  defp send_user_message!(%{surface: "comma"} = ref, text) do
    user_req(
      ref.session_token,
      :post,
      "/v1/comma/groups/#{ref.group_id}/conversations/#{ref.conversation_id}/messages",
      %{
        "content" => [%{"type" => "text", "text" => text}],
        "client_request_id" => unique("comma-msg")
      }
    )
    |> expect_json!(202)
  end

  defp send_user_message!(%{surface: "bft"} = ref, text) do
    post_runtime!(
      ref.tenant_key,
      "/v1/runtime/agent-groups/#{ref.group_id}/conversations/#{ref.conversation_id}/messages",
      %{
        "content" => [%{"type" => "text", "text" => text}],
        "client_request_id" => unique("bft-msg")
      },
      201
    )
  end

  defp wait_for_visible_reply!(%{surface: "comma"} = ref, visible_reply) do
    eventually!("comma visible VM reply", fn ->
      messages =
        user_req(
          ref.session_token,
          :get,
          "/v1/comma/groups/#{ref.group_id}/conversations/#{ref.conversation_id}/messages",
          nil
        )
        |> expect_json!(200)
        |> Map.fetch!("data")

      if Enum.any?(messages, &(content_text(&1["content"]) == visible_reply)), do: messages
    end)
  end

  defp wait_for_visible_reply!(%{surface: "bft"} = ref, visible_reply) do
    eventually!("bft visible VM reply", fn ->
      messages =
        get_runtime!(
          ref.tenant_key,
          "/v1/runtime/agent-groups/#{ref.group_id}/conversations/#{ref.conversation_id}/messages?limit=100"
        )

      if Enum.any?(messages, &(content_text(&1["content"]) == visible_reply)), do: messages
    end)
  end

  defp assert_ready!(ref, provider) do
    rec =
      eventually!("vm ready #{ref.group_id}", fn ->
        case SalixWeb.ComputeProviders.Cloudflare.get_record(ref.group_id) do
          {:ok, %{"provider" => ^provider, "status" => "ready", "env_id" => env_id} = rec}
          when is_binary(env_id) ->
            rec

          _ ->
            nil
        end
      end)

    expect!(
      rec["env_id"] == SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(ref.group_id),
      "deterministic env id"
    )

    connected_devices =
      expect_ok!(Registry.list_connected_by_group(ref.group_id), "registry connected devices")

    expect!(connected_devices != [], "cloud-vm connector registered")
    rec
  end

  defp assert_marker_file!(agent_id, marker, payload) do
    result =
      expect_ok!(
        EnvDispatch.request(
          agent_id,
          cloud_target(agent_id, @env_alias),
          "read",
          %{"path" => marker}
        ),
        "read marker"
      )

    expect!(result["content"] == payload, "marker file side effect")
  end

  defp assert_tool_result!(agent_id, session_id, expected_stdout) do
    eventually!("env.exec tool result", fn ->
      matching_tool_result(agent_id, session_id, expected_stdout)
    end)
  end

  defp matching_tool_result(agent_id, session_id, expected_stdout) do
    sessions =
      case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
        {:ok, session} ->
          [session]

        _ ->
          case SalixAgent.InternalSessionStore.list(agent_id) do
            {:ok, sessions} -> sessions
            _ -> []
          end
      end

    Enum.find_value(sessions, fn %{messages: messages} ->
      Enum.find(messages, fn message ->
        (message[:role] || message["role"]) == "tool" and
          (message[:tool_name] || message["tool_name"]) == "env.exec" and
          String.contains?(message[:content] || message["content"] || "", expected_stdout)
      end)
    end)
  end

  defp create_runtime_conversation!(tenant_key, group_id, agent_id, request_id) do
    post_runtime!(
      tenant_key,
      "/v1/runtime/agent-groups/#{group_id}/conversations",
      %{
        "client_request_id" => request_id,
        "title" => "Agent VM interaction",
        "participants" => [
          %{
            "actor_type" => "user",
            "user_id" => "current",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          },
          %{
            "actor_type" => "agent",
            "agent_id" => agent_id,
            "role_label" => "agent",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          }
        ]
      },
      201
    )
  end

  defp agent_session_id!(tenant_key, group_id, conversation_id, agent_id) do
    session_id =
      tenant_key
      |> get_runtime!(
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/participants"
      )
      |> Map.fetch!("participants")
      |> Enum.find_value(fn participant ->
        if participant["agent_id"] == agent_id do
          get_in(participant, ["payload", "session_id"])
        end
      end)

    expect!(is_binary(session_id) and session_id != "", "agent participant session id")
    session_id
  end

  defp create_tenant_key!(tenant_id, suffix) do
    key =
      post_admin!("/v1/admin/tenants/#{tenant_id}/api-keys", %{
        "name" => "agent-vm-e2e-#{suffix}"
      })

    key["key"] || raise("tenant API key response did not include key")
  end

  defp configure_tenant_vm!(tenant_id, default_provider) do
    sections = Application.fetch_env!(:salix_web, :vm_e2e_provider_sections)

    {:ok, _} =
      Salix.Control.Tenants.update(tenant_id, %{
        "config" =>
          Jason.encode!(%{
            "vm" => %{
              "default_provider" => default_provider,
              "providers" => sections
            }
          })
      })
  end

  defp provider_sections!(["cloudflare"]) do
    %{
      "cloudflare" => %{
        "enabled" => true,
        "gateway_base_url" => required_env!("SALIX_E2E_CF_GATEWAY_BASE_URL"),
        "gateway_secret" => required_env!("SALIX_E2E_CF_GATEWAY_SECRET")
      }
    }
  end

  defp issue_comma_billing_grant!(%{"billing_account_id" => account_id, "id" => workspace_id}) do
    :ok =
      BillingCore.Accounts.ensure_account(%{
        repo: BillingCore.Repo,
        billing_account_id: account_id,
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: workspace_id
      })

    issue_billing_grant!(account_id, "agent-vm-e2e:comma:#{workspace_id}")
  end

  defp issue_bridge_billing_grant!(org) do
    :ok =
      BillingCore.Accounts.ensure_account(%{
        repo: BillingCore.Repo,
        billing_account_id: org.billing_account_id,
        surface: "bridge",
        product_owner_type: "organization",
        product_owner_id: org.id
      })

    issue_billing_grant!(org.billing_account_id, "agent-vm-e2e:bft:#{org.id}")
  end

  defp issue_billing_grant!(account_id, source_id) do
    {:ok, _grant} =
      BillingCore.Credits.issue_grant(%{
        repo: BillingCore.Repo,
        billing_account_id: account_id,
        credits: 100,
        valid_from: ~U[2026-06-17 00:00:00Z],
        expires_at: DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second),
        source_type: "manual_contract",
        source_id: source_id,
        source_event_id: source_id,
        idempotency_key: "#{source_id}:2026-07"
      })

    :ok
  end

  defp ensure_repo_started!(repo) do
    if Process.whereis(repo) do
      :ok
    else
      case repo.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> raise("failed to start #{inspect(repo)}: #{inspect(reason)}")
      end
    end
  end

  defp setup_repo!(repo) do
    Ecto.Migrator.run(repo, :up, all: true)
    Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)

    case Ecto.Adapters.SQL.Sandbox.checkout(repo,
           sandbox: false,
           ownership_timeout: timeout_ms() + 60_000
         ) do
      :ok ->
        Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})

      {:already, _} ->
        Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})

      {:error, {:already, _}} ->
        Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})

      other ->
        raise("sandbox checkout failed for #{inspect(repo)}: #{inspect(other)}")
    end
  end

  defp drain_all! do
    case Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all!()
      {:error, reason} -> raise("BFT reconcile failed: #{inspect(reason)}")
    end
  end

  defp comma_session!(user_id) do
    admin_req(:post, "/v1/comma/admin/users/#{user_id}/sessions", %{})
    |> expect_json!(201)
  end

  defp bootstrap_comma_workspace!(user_id, attrs) do
    session = comma_session!(user_id)

    workspace =
      CommaScripts.WorkspaceBootstrap.ensure_ready!(
        fn -> user_req(session["token"], :post, "/v1/comma/me/bootstrap", %{}) end,
        max_attempts: max(div(timeout_ms(), 2_000), 1),
        poll_ms: 2_000
      )

    workspace_id = workspace["id"]

    [{"name", attrs["name"]}, {"vm", attrs["vm"]}]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.each(fn {key, value} ->
      patch_comma_workspace!(session["token"], workspace_id, %{key => value})
    end)

    workspace =
      case Comma.Workspaces.get(workspace_id) do
        {:ok, stored} when is_map(stored) -> stored
        other -> raise("Comma workspace is unavailable: #{inspect(other)}")
      end

    {session, workspace}
  end

  defp patch_comma_workspace!(token, workspace_id, attrs) do
    workspace =
      user_req(token, :patch, "/v1/comma/workspaces/#{workspace_id}", attrs)
      |> expect_json!(200)

    CommaScripts.WorkspaceBootstrap.progress_external_operations!()
    workspace
  end

  defp admin_req(method, path, body) do
    method
    |> json_conn(path, body)
    |> put_req_header("authorization", "Bearer #{@admin_token}")
    |> call_comma()
  end

  defp user_req(token, method, path, body) do
    method
    |> json_conn(path, body)
    |> put_req_header("authorization", "Bearer #{token}")
    |> call_comma()
  end

  defp json_conn(method, path, nil), do: conn(method, path)

  defp json_conn(method, path, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
  end

  defp call_comma(conn), do: CommaWeb.Router.call(conn, @comma_opts)

  defp post_admin!(path, body, expected_status \\ 201),
    do: request!(@admin_token, :post, path, body, expected_status)

  defp post_runtime!(token, path, body, expected_status),
    do: request!(token, :post, path, body, expected_status)

  defp get_runtime!(token, path), do: request!(token, :get, path, nil, 200)

  defp request!(token, method, path, body, expected_status) do
    opts = [
      method: method,
      url: SalixWeb.Application.base_url() <> path,
      headers: [{"authorization", "Bearer " <> token}],
      retry: false
    ]

    opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)
    response = Req.request!(opts)

    expect!(
      response.status == expected_status,
      "#{method} #{path} returned #{response.status}: #{inspect(response.body)}"
    )

    response.body
  end

  defp expect_json!(conn, status) do
    if conn.status == status do
      Jason.decode!(conn.resp_body)
    else
      raise("expected HTTP #{status}, got #{conn.status}: #{conn.resp_body}")
    end
  end

  defp expect_ok!({:ok, value}, _label), do: value
  defp expect_ok!({:error, reason}, label), do: raise("#{label} failed: #{inspect(reason)}")

  defp eventually!(label, fun), do: eventually!(label, fun, attempts())

  defp eventually!(label, fun, attempts) when attempts > 0 do
    case fun.() do
      nil -> Process.sleep(500) && eventually!(label, fun, attempts - 1)
      false -> Process.sleep(500) && eventually!(label, fun, attempts - 1)
      value -> value
    end
  end

  defp eventually!(label, _fun, 0), do: raise("timed out waiting for #{label}")

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp content_text(content), do: to_string(content)

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp timeout_ms, do: String.to_integer(System.get_env("SALIX_VM_E2E_TIMEOUT_MS") || "300000")
  defp attempts, do: max(div(timeout_ms(), 500), 1)
  defp required_env!(key), do: System.get_env(key) || raise("missing required env #{key}")
  defp expect!(true, _label), do: :ok
  defp expect!(false, label), do: raise("expectation failed: #{label}")

  defp start_supervised_s3_fake! do
    {:ok, _} = SalixStore.S3.Fake.start_link([])
    :ok
  end

  # Cloud fixtures already have a deterministic device identity. This helper
  # constructs a target without performing discovery or any storage reads.
  defp cloud_target(agent_id, environment_id) do
    %{
      device_id:
        SalixStore.RuntimeIds.cloud_vm_device_id(SalixStore.Ids.group_id_from_agent!(agent_id)),
      environment_id: environment_id
    }
  end
end

AgentVMInteractionE2E.run()
