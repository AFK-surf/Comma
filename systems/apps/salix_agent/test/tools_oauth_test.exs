defmodule SalixAgent.Tools.OAuthTest do
  @moduledoc """
  Willow-parity OAuth tools (list/request/complete) against the Fake S3
  backend, a stubbed `SalixAgent.OAuthStore` seam, and a fake adapter wired
  through the `:oauth_adapters_fn` seam: list output parity shape, request
  creating a pending `SalixStore.OAuth.AuthState` record plus async tool-call
  state and auto wait, and complete mapping all four auth-state statuses
  (pending/completed/failed/expired). No inline token exchange — the HTTP
  callback owns it.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.Tools.OAuth, as: OAuthTools
  alias SalixStore.OAuth.AuthState

  defmodule StubStore do
    @moduledoc false
    @behaviour SalixAgent.OAuthStore

    defp cfg, do: SystemsRuntime.get_env(:salix_agent, :oauth_store_stub, %{})

    @impl true
    def agent_oauth_context(_agent_id) do
      case cfg()[:context] do
        nil -> {:error, :agent_not_found}
        ctx -> {:ok, ctx}
      end
    end

    @impl true
    def provider_app(tenant, provider) do
      case get_in(cfg(), [:provider_apps, {tenant, provider}]) do
        nil -> {:error, :not_configured}
        app -> {:ok, app}
      end
    end

    @impl true
    def bindings_for_group(group_id) do
      case cfg()[:bindings] do
        %{} = by_group -> {:ok, Map.get(by_group, group_id, [])}
        list when is_list(list) -> {:ok, list}
        nil -> {:ok, []}
      end
    end

    @impl true
    def public_base_url, do: cfg()[:base_url]

    @impl true
    def delete_binding(tenant, group_id, binding_id) do
      pid = SystemsRuntime.get_env(:salix_agent, :oauth_store_test_pid)
      if pid, do: SystemsRuntime.Proc.send(pid, {:deleted_binding, tenant, group_id, binding_id})

      case cfg()[:delete_result] do
        nil -> :ok
        result -> result
      end
    end
  end

  defmodule CapabilityRequestStoreStub do
    @moduledoc false
    @behaviour SalixAgent.CapabilityRequestStore

    @impl true
    def create_capability_request(attrs) do
      request =
        attrs
        |> Map.put_new("request_id", "req-#{SystemsRuntime.Proc.unique_integer([:positive])}")
        |> Map.put_new("status", "pending")
        |> Map.put_new("response_payload", %{})

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :capability_request_store_test_pid),
        {
          :created_capability_request,
          request
        }
      )

      {:ok, request}
    end

    @impl true
    def cancel_capability_request(_agent_id, _session_id, _tool_call_id, _reason),
      do: {:ok, :not_found}
  end

  defmodule FakeAdapter do
    @moduledoc false
    def authorization_url(app, req) do
      {:ok,
       "https://fake.example/authorize?client_id=#{app["client_id"]}&state=#{req["state"]}" <>
         "&challenge=#{req["code_challenge"]}&redirect=#{req["redirect_uri"]}" <>
         "&scopes=#{Enum.join(req["scopes"], ",")}"}
    end

    def default_env_var, do: "GH_TOKEN"
  end

  defmodule NativePrompt do
    def request(scope, type, args, call_id) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :capability_request_store_test_pid),
        {:native_prompt, scope, type, args, call_id}
      )

      {:ok, %{"status" => "question_delivered", "request_id" => "native-request"}}
    end
  end

  @app_envs [
    :oauth_store_mod,
    :oauth_store_stub,
    :oauth_store_test_pid,
    :oauth_adapters_fn,
    :capability_request_store_mod,
    :capability_request_store_test_pid,
    :telegram_interaction_mod
  ]

  setup do
    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case start_supervised(SalixStore.S3.Fake) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> SalixStore.S3.Fake.reset()
    end

    prev = Map.new(@app_envs, fn k -> {k, SystemsRuntime.get_env(:salix_agent, k)} end)
    SystemsRuntime.put_env(:salix_agent, :oauth_store_mod, StubStore)

    SystemsRuntime.put_env(
      :salix_agent,
      :capability_request_store_mod,
      CapabilityRequestStoreStub
    )

    SystemsRuntime.put_env(
      :salix_agent,
      :capability_request_store_test_pid,
      SystemsRuntime.Proc.self()
    )

    SystemsRuntime.put_env(:salix_agent, :oauth_adapters_fn, fn
      "github" -> {:ok, FakeAdapter}
      _ -> {:error, :unsupported_provider}
    end)

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_s3)

      for {k, v} <- prev do
        if v,
          do: SystemsRuntime.put_env(:salix_agent, k, v),
          else: SystemsRuntime.delete_env(:salix_agent, k)
      end
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    sid = SalixStore.Ids.new_session_id()

    {:ok, agent: agent, sid: sid, ctx: %{agent_id: agent, session_id: sid}}
  end

  defp put_stub(cfg), do: SystemsRuntime.put_env(:salix_agent, :oauth_store_stub, cfg)

  defp configured_stub do
    %{
      context: %{tenant: "t1", group_id: "g1"},
      provider_apps: %{{"t1", "github"} => %{"client_id" => "cid", "client_secret" => "sec"}},
      base_url: "https://api.example.com/"
    }
  end

  # ---- list_oauth_credentials ----

  test "list returns willow's parity shape sorted by provider then alias, no token values",
       %{ctx: ctx} do
    put_stub(%{
      context: %{tenant: "t1", group_id: "g1"},
      bindings: [
        %{
          "binding_id" => "b2",
          "provider" => "slack",
          "alias" => "team",
          "connection_id" => "c2",
          "status" => "active",
          "provider_account_name" => "U123",
          "scopes" => ["chat:write"]
        },
        %{
          "binding_id" => "b1",
          "provider" => "github",
          "alias" => "work",
          "connection_id" => "c1",
          "status" => "active",
          "provider_account_name" => "octocat",
          "scopes" => ["repo"]
        },
        %{
          "binding_id" => "b3",
          "provider" => "github",
          "alias" => "home",
          "connection_id" => "c3",
          "status" => "reauthorization_required",
          "provider_account_name" => "",
          "scopes" => []
        },
        %{
          "binding_id" => "b4",
          "provider" => "github",
          "alias" => "sandbox",
          "connection_id" => "c4",
          "enabled" => false,
          "status" => "disabled",
          "provider_account_name" => "octocat-disabled",
          "scopes" => ["repo"]
        }
      ]
    })

    out = OAuthTools.list_oauth_credentials(%{}, ctx)
    %{"credentials" => creds} = Jason.decode!(out)

    assert Enum.map(creds, &{&1["provider"], &1["alias"]}) ==
             [{"github", "home"}, {"github", "sandbox"}, {"github", "work"}, {"slack", "team"}]

    [home, sandbox, work, team] = creds

    assert work["enabled"] == true
    assert work["status"] == "active"
    assert work["provider_account_name"] == "octocat"
    assert work["scopes"] == ["repo"]

    assert sandbox["enabled"] == false
    assert sandbox["status"] == "disabled"
    refute Map.has_key?(sandbox, "usage")

    # provider not in the adapter registry → OAUTH_TOKEN fallback.
    assert team["enabled"] == true
    assert team["usage"] =~ "\"env_var\": \"OAUTH_TOKEN\""

    # omitempty parity: blank account name / empty scopes are absent.
    assert home["enabled"] == true
    refute Map.has_key?(home, "provider_account_name")
    refute Map.has_key?(home, "scopes")
    assert home["status"] == "reauthorization_required"

    refute out =~ "access_token\": \"tok"
  end

  # ---- request_oauth_authorization ----

  test "request creates a pending AuthState and emits wait_set (derived waiting)",
       %{ctx: ctx, sid: sid, agent: agent} do
    put_stub(configured_stub())

    {content, [started, wait_set]} =
      OAuthTools.request_oauth_authorization(
        %{
          "provider" => " GitHub ",
          "alias" => "work",
          "reason" => "need repo access",
          "scopes" => ["repo", " read:user ", ""]
        },
        ctx
      )

    assert %{"type" => "wait_set", "session_id" => ^sid, "wait" => wait} = wait_set
    assert wait["reason"] == "oauth authorization: github/work"
    assert wait["source"] == "auto_wait"
    assert wait["timeout_seconds"] == 120
    assert wait["tool_call_id"] == started["tool_call_id"]
    assert started["type"] == "async_tool_call_started"
    assert started["tool_name"] == "oauth.request_authorization"
    assert started["completion_mode"] == "external_callback"
    assert started["auto_wait_seconds"] == 120

    decoded = Jason.decode!(content)
    assert decoded["status"] == "running"
    assert is_binary(decoded["request_id"])
    assert decoded["tool_call_id"] == started["tool_call_id"]
    assert decoded["provider"] == "github"
    assert decoded["alias"] == "work"
    state = decoded["state"]
    assert decoded["state"] == state
    assert decoded["authorization_url"] =~ "state=#{state}"
    assert decoded["authorization_url"] =~ "client_id=cid"
    assert decoded["authorization_url"] =~ "/v1/oauth/github/callback"
    assert is_integer(decoded["expires_at"])
    assert decoded["message"] == "oauth authorization request is pending"

    assert {:ok, record} = AuthState.get(state)
    assert record["status"] == "pending"
    assert record["provider"] == "github"
    assert record["alias"] == "work"
    assert record["scopes"] == ["repo", "read:user"]
    assert record["origin"] == "agent"
    assert record["tenant"] == "t1"
    assert record["group_id"] == "g1"
    assert record["agent_id"] == agent
    assert record["session_id"] == sid
    assert record["redirect_uri"] == "https://api.example.com/v1/oauth/github/callback"
    assert is_binary(record["code_verifier"]) and record["code_verifier"] != ""
    assert record["code_verifier"] != state
    # default timeout 600s, ms timestamps
    assert record["expires_at"] == record["created_at"] + 600_000

    settle_receive({:created_capability_request, request})
    assert request["tenant_id"] == "t1"
    assert request["group_id"] == "g1"
    assert request["source_agent_id"] == agent
    assert request["source_session_id"] == sid
    assert request["tool_call_id"] == started["tool_call_id"]
    assert request["request_type"] == "oauth_authorization"
    assert request["expires_at"] == div(record["expires_at"], 1000)
    assert request["request_payload"]["oauth_authorization"]["provider"] == "github"
    assert request["request_payload"]["oauth_authorization"]["alias"] == "work"
    assert request["request_payload"]["oauth_authorization"]["state"] == state

    assert request["request_payload"]["oauth_authorization"]["authorization_url"] ==
             decoded["authorization_url"]

    # wait_set derives :waiting on the idle runtime session.
    session =
      agent
      |> SalixAgent.InternalSession.new(sid)
      |> SalixAgent.InternalSession.apply_event(wait_set)

    assert SalixAgent.InternalSession.derived_state(session) == :waiting
  end

  # ---- complete_oauth_authorization ----

  defp request!(ctx, alias_) do
    {content, [_started, _wait_set]} =
      OAuthTools.request_oauth_authorization(
        %{"provider" => "github", "alias" => alias_, "reason" => "r"},
        ctx
      )

    Jason.decode!(content)["state"]
  end

  test "complete maps pending / completed / failed / expired", %{ctx: ctx, sid: sid} do
    put_stub(configured_stub())

    # pending: content only, no wait_clear (the wait stays set)
    state1 = request!(ctx, "work")
    pending = OAuthTools.complete_oauth_authorization(%{"state" => state1}, ctx)
    assert is_binary(pending)
    decoded = Jason.decode!(pending)
    assert decoded["status"] == "pending"
    assert decoded["provider"] == "github"
    assert decoded["alias"] == "work"
    assert is_integer(decoded["expires_at"])
    assert decoded["message"] =~ "still pending"

    # completed: the HTTP callback recorded the binding
    :ok =
      AuthState.record_completion(state1, %{
        "binding_id" => "bind-1",
        "connection_id" => "conn-1",
        "provider_account_name" => "octocat"
      })

    done = OAuthTools.complete_oauth_authorization(%{"state" => state1}, ctx)
    decoded = Jason.decode!(done)
    assert decoded["status"] == "completed"
    assert decoded["provider"] == "github"
    assert decoded["alias"] == "work"
    assert decoded["binding_id"] == "bind-1"
    assert decoded["provider_account_name"] == "octocat"

    # idempotent: a second call returns the same completed result
    done2 = OAuthTools.complete_oauth_authorization(%{"state" => state1}, ctx)
    assert Jason.decode!(done2)["status"] == "completed"

    # failed
    state2 = request!(ctx, "second")
    :ok = AuthState.record_failure(state2, "user denied the authorization")

    failed = OAuthTools.complete_oauth_authorization(%{"state" => state2}, ctx)

    decoded = Jason.decode!(failed)
    assert decoded["status"] == "failed"
    assert decoded["error"] == "user denied the authorization"

    # expired: a pending record past its deadline flips lazily on read
    now = SystemsClock.system_time(:millisecond)

    :ok =
      AuthState.create(%{
        "state" => "expired-state-1",
        "tenant" => "t1",
        "group_id" => "g1",
        "agent_id" => ctx.agent_id,
        "session_id" => sid,
        "provider" => "github",
        "alias" => "old",
        "scopes" => [],
        "code_verifier" => "v",
        "redirect_uri" => "https://api.example.com/v1/oauth/github/callback",
        "redirect_after" => nil,
        "origin" => "agent",
        "status" => "pending",
        "error" => nil,
        "binding_id" => nil,
        "connection_id" => nil,
        "provider_account_name" => nil,
        "expires_at" => now - 1_000,
        "created_at" => now - 601_000
      })

    expired = OAuthTools.complete_oauth_authorization(%{"state" => "expired-state-1"}, ctx)

    decoded = Jason.decode!(expired)
    assert decoded["status"] == "expired"

    assert decoded["message"] ==
             "authorization expired; call oauth.request_authorization to start a fresh flow"
  end

  test "complete guards: missing state, unknown state, cross-group, non-agent origin",
       %{ctx: ctx, sid: sid} do
    put_stub(configured_stub())

    assert_raise RuntimeError, "'state' is required", fn ->
      OAuthTools.complete_oauth_authorization(%{}, ctx)
    end

    assert_raise RuntimeError,
                 "authorization state not found; call oauth.request_authorization again",
                 fn ->
                   OAuthTools.complete_oauth_authorization(%{"state" => "nope"}, ctx)
                 end

    base = %{
      "tenant" => "t1",
      "agent_id" => ctx.agent_id,
      "session_id" => sid,
      "provider" => "github",
      "alias" => "x",
      "scopes" => [],
      "code_verifier" => "v",
      "redirect_uri" => "https://api.example.com/v1/oauth/github/callback",
      "redirect_after" => nil,
      "status" => "pending",
      "error" => nil,
      "binding_id" => nil,
      "connection_id" => nil,
      "provider_account_name" => nil,
      "expires_at" => SystemsClock.system_time(:millisecond) + 600_000,
      "created_at" => SystemsClock.system_time(:millisecond)
    }

    # Another group's row must not leak its existence.
    :ok =
      AuthState.create(
        base
        |> Map.merge(%{"state" => "other-group", "group_id" => "g-other", "origin" => "agent"})
      )

    assert_raise RuntimeError,
                 "authorization state not found; call oauth.request_authorization again",
                 fn ->
                   OAuthTools.complete_oauth_authorization(%{"state" => "other-group"}, ctx)
                 end

    # Web-origin rows are not pollable by the agent tool.
    :ok =
      AuthState.create(
        base
        |> Map.merge(%{"state" => "web-origin", "group_id" => "g1", "origin" => "web"})
      )

    assert_raise RuntimeError, ~r/was not initiated by an agent/, fn ->
      OAuthTools.complete_oauth_authorization(%{"state" => "web-origin"}, ctx)
    end
  end

  # ---- delete_oauth_credential ----

  for {name, provider} <- [
        {"delete removes a matching (provider, alias) binding via the store seam", "github"},
        {"delete normalizes the provider name before matching", "GitHub"}
      ] do
    test name, %{ctx: ctx} do
      SystemsRuntime.put_env(:salix_agent, :oauth_store_test_pid, SystemsRuntime.Proc.self())

      put_stub(%{
        context: %{tenant: "t1", group_id: "g1"},
        bindings: [
          %{
            "binding_id" => "b1",
            "provider" => "github",
            "alias" => "work",
            "status" => "active"
          },
          %{"binding_id" => "b2", "provider" => "slack", "alias" => "team", "status" => "active"}
        ]
      })

      out =
        OAuthTools.delete_oauth_credential(
          %{"provider" => unquote(provider), "alias" => "work"},
          ctx
        )

      assert Jason.decode!(out) == %{
               "status" => "deleted",
               "provider" => "github",
               "alias" => "work",
               "binding_id" => "b1"
             }

      # The (tenant, group, binding_id) reached the control-plane delete seam.
      assert_received {:deleted_binding, "t1", "g1", "b1"}
    end
  end
end
