defmodule SalixAgent.ToolsPeersTest do
  @moduledoc """
  Remote-environment tools (`SalixAgent.Tools.Peers`) against the
  Fake S3 backend: `env.exec` / `env.computer_use` /
  `device.list` through both an in-test
  `SalixAgent.EnvDispatch` implementation and the `None` default error path.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{ToolDisclosure, Tools}
  alias SalixAgent.Tools.Peers

  defmodule FakeDispatch do
    @moduledoc false
    @behaviour SalixAgent.EnvDispatch

    @impl true
    def list_devices(_agent_id, opts) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:device_page_requested, opts})

      {:ok,
       %{
         devices: [%{"device_id" => "device-laptop", "name" => "Laptop", "status" => "connected"}],
         next_cursor: "next-page"
       }}
    end

    @impl true
    def list_envs(_agent_id) do
      {:ok,
       [
         %{
           "environment_id" => "laptop",
           "alias" => "laptop",
           "name" => "Laptop",
           "status" => "connected",
           "description" => "a developer laptop",
           "memory_path" => "/memory/environments/laptop.md",
           "os" => "darwin",
           "arch" => "arm64"
         },
         %{
           "environment_id" => "cloud-vm",
           "alias" => "cloud-vm",
           "name" => "Cloud VM",
           "status" => "connected",
           "persistence_scope" => "connector root files restore; processes do not"
         },
         %{
           "environment_id" => "comma-disabled",
           "alias" => "comma-client",
           "name" => "Comma Client",
           "status" => "permission_required",
           "requires_permission" => true,
           "permission_message" =>
             "Comma Full Access is off. Ask the user to enable Full Access in Comma Settings > General, then retry."
         }
       ]}
    end

    @impl true
    def get_device(_agent_id, "device-laptop") do
      {:ok,
       %{
         "device_id" => "device-laptop",
         "name" => "Laptop",
         "status" => "connected",
         "device_runtimes" => []
       }}
    end

    def get_device(_agent_id, "dev-sbx-task") do
      {:ok,
       %{"device_id" => "dev-sbx-task", "environments" => [%{"environment_id" => "sbx-task"}]}}
    end

    # A computer added through Add computer: its environment ids are hashes.
    def get_device(_agent_id, "dev_added") do
      {:ok,
       %{
         "device_id" => "dev_added",
         "environments" => [
           %{"environment_id" => "env-3f9a", "status" => "connected"},
           %{"environment_id" => "env-offline", "status" => "disconnected"}
         ]
       }}
    end

    def get_device(_agent_id, "dev_idle"),
      do: {:ok, %{"device_id" => "dev_idle", "environments" => []}}

    def get_device(_agent_id, "lookup-failed"), do: {:error, :timeout}
    def get_device(_agent_id, _device_id), do: {:error, :not_found}

    @impl true
    def exec(_agent_id, %{device_id: "dev-sbx-task", environment_id: "sbx-task"}, cmd, _opts) do
      {:ok, %{"status" => "completed", "exit_code" => 0, "stdout" => "self: " <> cmd}}
    end

    def exec(_agent_id, %{device_id: "device-laptop", environment_id: "laptop"}, cmd, opts) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:forwarded_env, opts["env"]})

      {:ok,
       %{
         "status" => "completed",
         "exit_code" => 0,
         "stdout" => "ran: " <> cmd,
         "stderr" => "",
         "description" => opts["description"],
         "timeout" => opts["timeout"],
         # Echo the full forwarded opts so tests can assert what the
         # connector would actually see (env injected, credential_env absent).
         "forwarded_opts" => opts
       }}
    end

    def exec(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "cloud-vm"},
          "interrupt",
          _opts
        ) do
      {:error,
       %{
         "error_class" => "vm_call_interrupted",
         "message" => "VM call interrupted",
         "retryable" => true,
         "env_id" => "cloud-vm-env",
         "sandbox_id" => "sandbox-1",
         "connection_generation" => 42
       }}
    end

    def exec(_agent_id, %{device_id: "device-laptop", environment_id: "cloud-vm"}, "wake", _opts) do
      {:error, {:vm_waking, %{"retry_after_ms" => 1_000, "env_id" => "cloud-vm-env"}}}
    end

    def exec(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "cloud-vm"},
          "maintenance",
          _opts
        ) do
      {:error,
       {:vm_service_upgrading,
        %{"retry_after_ms" => 2_000, "maintenance_id" => "maint-1", "env_id" => "cloud-vm-env"}}}
    end

    def exec(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "comma-disabled"},
          _cmd,
          _opts
        ) do
      {:error,
       {:permission_required,
        "Comma Full Access is off. Ask the user to enable Full Access in Comma Settings > General, then retry."}}
    end

    def exec(_agent_id, _env, _cmd, _opts), do: {:error, :no_environment}

    @impl true
    def computer_use(_agent_id, %{device_id: "device-laptop", environment_id: "laptop"}, %{
          "action" => "screenshot"
        }),
        do:
          {:ok,
           %{
             "ok" => true,
             "image_path" => "capture-example.png",
             "image_content_type" => "image/png",
             "image_width" => 800,
             "image_height" => 600,
             "image_size_bytes" => 1234
           }}

    def computer_use(_agent_id, %{device_id: "device-laptop", environment_id: "laptop"}, %{
          "action" => "get_app_state"
        }),
        do:
          {:ok,
           %{
             "ok" => true,
             "text" => "Computer Use state (ComputerUseNext Snapshot: s1)",
             "image_path" => "capture-state.png",
             "image_content_type" => "image/png",
             "image_width" => 800,
             "image_height" => 600,
             "image_size_bytes" => 1234
           }}

    def computer_use(_agent_id, %{device_id: "device-laptop", environment_id: "laptop"}, %{
          "action" => "boom"
        }),
        do: {:ok, %{"ok" => false, "error" => "daemon exploded"}}

    def computer_use(_agent_id, %{device_id: "device-laptop", environment_id: "laptop"}, %{
          "action" => "start"
        }),
        do:
          {:ok,
           %{
             "ok" => true,
             "mode" => "background",
             "help" => "use snapshot then click",
             "message" => "session started"
           }}

    def computer_use(_agent_id, %{device_id: "device-laptop", environment_id: "laptop"}, payload),
      do:
        {:ok,
         %{
           "ok" => true,
           "result" => "did #{payload["action"]} (thinking: #{payload["thinking"]})"
         }}

    def computer_use(_agent_id, _env, _payload), do: {:error, :no_environment}

    @impl true
    def android(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "android-host"},
          payload
        ),
        do: {:ok, Map.merge(%{"ok" => true, "image_data" => "private-image"}, payload)}

    def android(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "android-timeout"},
          _payload
        ),
        do: {:error, :timeout}

    def android(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "android-disconnected"},
          _payload
        ),
        do: {:error, :disconnected}

    def android(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "android-profile-required"},
          _payload
        ),
        do: {:error, :android_profile_required}

    def android(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "android-profile-not-allowed"},
          _payload
        ),
        do: {:error, :android_profile_not_allowed}

    def android(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "android-profile-unavailable"},
          _payload
        ),
        do: {:error, :android_profile_unavailable}

    # A computer's own phone (device mode): a start without Salix's consent is refused.
    def android(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "android-own"},
          %{"action" => "start"} = payload
        ) do
      if payload["consent"] == true,
        do: {:ok, %{"ok" => true, "lease_id" => "lease-1"}},
        else:
          {:ok,
           %{
             "ok" => false,
             "error_code" => "android_consent_required",
             "target" => payload["target"],
             "title" => "Pixel 8 · Android 15"
           }}
    end

    def android(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "android-own"},
          %{"action" => "observe"}
        ),
        do:
          {:ok,
           %{
             "ok" => true,
             "observation_id" => 1,
             "image_path" => "capture-phone.png",
             "image_content_type" => "image/png",
             "image_size_bytes" => 10,
             "image_width" => 1080,
             "image_height" => 2400,
             "locked" => false
           }}

    def android(_agent_id, _env, _payload), do: {:error, :android_not_authorized}

    # A computer's own simulator: a start without Salix's consent is refused; a station from
    # before has no simulators to offer.
    @impl true
    def screen(_agent_id, %{environment_id: "sim-old"}, _payload),
      do: {:error, :screen_capability_missing}

    def screen(_agent_id, %{environment_id: "sim-mac"}, %{"action" => "start"} = payload) do
      if payload["consent"] == true,
        do: {:ok, %{"ok" => true, "lease_id" => "lease-sim"}},
        else:
          {:ok,
           %{
             "ok" => false,
             "error_code" => "screen_consent_required",
             "target" => payload["target"],
             "title" => "iPhone 17 Pro · iOS 27.2"
           }}
    end

    def screen(_agent_id, %{environment_id: "sim-mac"}, %{"action" => "tap"}),
      do:
        {:ok,
         %{
           "ok" => false,
           "error_code" => "screen_held_by_person",
           "error" => "a person is driving this simulator in Comma now"
         }}

    def screen(_agent_id, %{environment_id: "sim-mac"}, %{"action" => "observe"}),
      do:
        {:ok,
         %{
           "ok" => true,
           "observation_id" => 1,
           "image_path" => "capture-sim.png",
           "image_content_type" => "image/png",
           "image_size_bytes" => 10,
           "image_width" => 1206,
           "image_height" => 2622
         }}

    @impl true
    def request(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "laptop"},
          "screen_links",
          %{}
        ) do
      {:ok,
       %{
         "device_id" => "device-laptop",
         "screens" => [
           %{
             "link" =>
               "comma:screen/device-laptop/simulator%3A0702F8CC-2E2A-4D0A-8401-C37FA01E1646",
             "kind" => "simulator",
             "title" => "iPhone 17 Pro · iOS 27.2"
           }
         ],
         "bootable_simulators" => [],
         "startable_avds" => []
       }}
    end

    # A station from before `screen_links`, as the connector answers it.
    def request(_agent_id, %{device_id: "device-old"}, "screen_links", _params),
      do: {:error, "screen_links: unknown method: screen_links"}

    def request(_agent_id, _env, _method, _params), do: {:error, :no_environment}

    @impl true
    def process_list(_agent_id, _env), do: {:error, :no_environment}

    @impl true
    def process_write(_agent_id, _env, _process_name, _data, _opts),
      do: {:error, :no_environment}

    @impl true
    def process_tail(_agent_id, _env, _process_name, _opts), do: {:error, :no_environment}

    @impl true
    def read_stream(_agent_id, %{device_id: "device-laptop", environment_id: "laptop"}, path) do
      body = "streamed #{path}"
      {:ok, [body], byte_size(body)}
    end

    def read_stream(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "cloud-vm"},
          "/interrupt"
        ) do
      {:error,
       %{
         "error_class" => "vm_call_interrupted",
         "message" => "VM call interrupted",
         "retryable" => true,
         "env_id" => "cloud-vm-env",
         "sandbox_id" => "sandbox-1",
         "connection_generation" => 42
       }}
    end

    def read_stream(_agent_id, %{device_id: "device-laptop", environment_id: "cloud-vm"}, "/wake") do
      {:error, {:vm_waking, %{"retry_after_ms" => 1_000, "env_id" => "cloud-vm-env"}}}
    end

    def read_stream(_agent_id, _env, _path), do: {:error, :no_environment}

    @impl true
    def write_stream(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "laptop"},
          _path,
          stream
        ) do
      body = IO.iodata_to_binary(Enum.to_list(stream))
      {:ok, %{"size" => byte_size(body)}}
    end

    def write_stream(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "cloud-vm"},
          "/interrupt",
          _stream
        ) do
      {:error,
       %{
         "error_class" => "vm_call_interrupted",
         "message" => "VM call interrupted",
         "retryable" => true,
         "env_id" => "cloud-vm-env",
         "sandbox_id" => "sandbox-1",
         "connection_generation" => 42
       }}
    end

    def write_stream(_agent_id, _env, _path, _stream), do: {:error, :no_environment}
  end

  defmodule OAuthStubStore do
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
    def bindings_for_group(_group_id), do: {:ok, cfg()[:bindings] || []}

    @impl true
    def public_base_url, do: cfg()[:base_url]

    @impl true
    def delete_binding(_tenant, _group_id, _binding_id), do: :ok
  end

  defmodule FakeOAuthAdapter do
    @moduledoc false
    def refresh(_app, _conn) do
      {:ok,
       %{
         "access_token" => "tok-refreshed",
         "expires_at" => SystemsClock.system_time(:millisecond) + 3_600_000,
         # blank/empty refresh fields must be dropped, preserving the
         # authorization-time values (willow token_type/scopes carry-over)
         "refresh_token" => nil,
         "token_type" => "",
         "scopes" => []
       }}
    end

    def resolve_credential_value(conn, "access_token"), do: {:ok, conn["access_token"]}

    def resolve_credential_value(_conn, value),
      do: {:error, "unsupported credential value #{value}"}

    def validate_credential_value(_value, _scopes), do: :ok
    def default_env_var, do: "GH_TOKEN"
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    # Capture and RESTORE (not delete) the dispatcher: in the umbrella's shared
    # test VM another app (salix_web) configures a real dispatcher at boot;
    # deleting it would clobber that for tests that run later.
    prev_dispatch = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    prev_group_context = SystemsRuntime.get_env(:salix_agent, :group_context_mod)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SystemsRuntime.delete_env(:salix_agent, :env_dispatch)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)
      restore_dispatch(prev_dispatch)
      restore_env(:group_context_mod, prev_group_context)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()

    ctx =
      %{agent_id: agent}
      |> SalixAgent.TestSupport.with_plugin_projection()

    {:ok, agent: agent, ctx: ctx}
  end

  defp with_fake_dispatch do
    prev = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, FakeDispatch)
    on_exit(fn -> restore_dispatch(prev) end)
  end

  defp restore_dispatch(nil), do: SystemsRuntime.delete_env(:salix_agent, :env_dispatch)
  defp restore_dispatch(mod), do: SystemsRuntime.put_env(:salix_agent, :env_dispatch, mod)

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: SystemsRuntime.put_env(:salix_agent, key, value)

  # ---- defs ----

  # ---- device discovery ----

  test "device.screens returns the station's links, and an older station says it cannot", %{
    ctx: ctx
  } do
    with_fake_dispatch()

    assert %{"result" => %{"screens" => [%{"link" => link, "kind" => "simulator"}]}} =
             Jason.decode!(
               Peers.screens(%{"device_id" => "device-laptop", "environment" => "laptop"}, ctx)
             )

    assert link == "comma:screen/device-laptop/simulator%3A0702F8CC-2E2A-4D0A-8401-C37FA01E1646"

    assert_raise RuntimeError, ~r/^screens_unsupported: .*update Comma/, fn ->
      Peers.screens(%{"device_id" => "device-old", "environment" => "mac"}, ctx)
    end

    assert_raise RuntimeError, ~r/'environment' is required/, fn ->
      Peers.screens(%{"device_id" => "device-laptop"}, ctx)
    end
  end

  test "device discovery forwards a bounded page and opaque cursor", %{ctx: ctx} do
    with_fake_dispatch()

    assert %{"devices" => [%{"device_id" => "device-laptop"}], "next_cursor" => "next-page"} =
             Jason.decode!(Peers.list_devices(%{}, ctx))

    settle_receive({:device_page_requested, [limit: 20]})
    Peers.list_devices(%{"limit" => 1, "cursor" => "next-page"}, ctx)
    settle_receive({:device_page_requested, [limit: 1, cursor: "next-page"]})

    assert_raise RuntimeError, ~r/limit must be/, fn ->
      Peers.list_devices(%{"limit" => 101}, ctx)
    end

    settle_refute_receive({:device_page_requested, _})
  end

  # ---- Copy ----

  for {name, tool, args, error_class} <- [
        {"copy VM lifecycle tuple errors are failed runtime tool results", "env.copy",
         %{
           "src_device_id" => "device-laptop",
           "src_environment" => "cloud-vm",
           "src_path" => "/wake",
           "dst_environment" => "vfs",
           "dst_path" => "/out"
         }, "vm_waking"},
        {"exec VM interruption is a failed runtime tool result", "env.exec",
         %{
           "device_id" => "device-laptop",
           "environment" => "cloud-vm",
           "command" => "interrupt",
           "description" => "interrupt"
         }, "vm_call_interrupted"},
        {"exec VM waking is a failed runtime tool result", "env.exec",
         %{
           "device_id" => "device-laptop",
           "environment" => "cloud-vm",
           "command" => "wake",
           "description" => "wake"
         }, "vm_waking"},
        {"exec VM maintenance is a failed runtime tool result", "env.exec",
         %{
           "device_id" => "device-laptop",
           "environment" => "cloud-vm",
           "command" => "maintenance",
           "description" => "maintenance"
         }, "vm_service_upgrading"}
      ] do
    test name, %{ctx: ctx} do
      with_fake_dispatch()

      [result] =
        Tools.execute(
          [
            %{
              "id" => "vm-failure",
              "name" => unquote(tool),
              "args" => unquote(Macro.escape(args))
            }
          ],
          worker_tool_ctx(ctx)
        )

      assert result.error == true
      assert result.status == "error"
      assert result.error_class == unquote(error_class)
      assert Jason.decode!(result.content)["error_class"] == unquote(error_class)
    end
  end

  # ---- Exec ----

  test "exec dispatches through the seam and returns the result map", %{ctx: ctx} do
    with_fake_dispatch()

    out =
      Peers.exec(
        %{
          "device_id" => "device-laptop",
          "environment" => "laptop",
          "command" => "echo hi",
          "description" => "say hi",
          "timeout" => 5
        },
        ctx
      )

    decoded = Jason.decode!(out)
    assert decoded["stdout"] == "ran: echo hi"
    assert decoded["exit_code"] == 0
    assert decoded["description"] == "say hi"
    assert decoded["timeout"] == 5
  end

  test "an env tool that reaches no environment says whether the device or its environment is wrong",
       %{ctx: ctx} do
    with_fake_dispatch()

    exec = fn device_id, environment ->
      Peers.exec(
        %{
          "device_id" => device_id,
          "environment" => environment,
          "command" => "expense-cli list",
          "description" => "list expenses"
        },
        ctx
      )
    end

    assert_raise RuntimeError,
                 ~s|tool "env.exec": device dev_added has no environment "station"; its environments: env-3f9a, env-offline|,
                 fn -> exec.("dev_added", "station") end

    assert_raise RuntimeError,
                 ~s|tool "env.process_list": device dev_added has no environment "station"; its environments: env-3f9a, env-offline|,
                 fn ->
                   Peers.process_list(
                     %{"device_id" => "dev_added", "environment" => "station"},
                     ctx
                   )
                 end

    assert_raise RuntimeError,
                 ~r/device dev_idle has no environment "station"; it has no environment connected/,
                 fn ->
                   exec.("dev_idle", "station")
                 end

    assert_raise RuntimeError, ~r/device dev_gone is not in this workspace; device.list/, fn ->
      exec.("dev_gone", "station")
    end

    # The right environment, not connected now, or a failed lookup: not connected.
    for {device_id, environment} <- [{"dev_added", "env-offline"}, {"lookup-failed", "station"}] do
      assert_raise RuntimeError,
                   ~s|tool "env.exec" unavailable (not_installed): no environment connected|,
                   fn -> exec.(device_id, environment) end
    end
  end

  # ---- Exec credential_env (willow exec.go + internal/oauth/resolver.go) ----

  @oauth_envs [:oauth_store_mod, :oauth_store_stub, :oauth_adapters_fn, :oauth_refresher_fn]

  defp with_oauth_seams(bindings) do
    prev = Map.new(@oauth_envs, fn k -> {k, SystemsRuntime.get_env(:salix_agent, k)} end)

    SystemsRuntime.put_env(:salix_agent, :oauth_store_mod, OAuthStubStore)

    SystemsRuntime.put_env(:salix_agent, :oauth_store_stub, %{
      context: %{tenant: "t1", group_id: "g1"},
      bindings: bindings,
      provider_apps: %{{"t1", "github"} => %{"client_id" => "cid", "client_secret" => "sec"}}
    })

    SystemsRuntime.put_env(:salix_agent, :oauth_adapters_fn, fn
      "github" -> {:ok, FakeOAuthAdapter}
      _ -> {:error, :unsupported_provider}
    end)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: SystemsRuntime.put_env(:salix_agent, k, v),
          else: SystemsRuntime.delete_env(:salix_agent, k)
      end
    end)
  end

  defp github_binding do
    %{
      "binding_id" => "b1",
      "provider" => "github",
      "alias" => "work",
      "connection_id" => "conn-cred-1",
      "status" => "active",
      "provider_account_name" => "octocat",
      "scopes" => ["repo"]
    }
  end

  defp seed_connection(record) do
    :ok = SalixStore.OAuth.put("conn-cred-1", record)
  end

  defp exec_with_credential_env(ctx, credential_env) do
    Peers.exec(
      %{
        "device_id" => "device-laptop",
        "environment" => "laptop",
        "command" => "gh repo list",
        "description" => "list repos",
        "credential_env" => credential_env
      },
      ctx
    )
  end

  @gh_entry %{
    "env_var" => "GH_TOKEN",
    "provider" => "github",
    "alias" => "work",
    "value" => "access_token"
  }

  test "exec on self runs on the sandbox the call came through, and only from one", %{ctx: ctx} do
    with_fake_dispatch()

    args = %{
      "device_id" => "self",
      "environment" => "self",
      "command" => "ls",
      "description" => "list"
    }

    assert Jason.decode!(Peers.exec(args, Map.put(ctx, :station_device_id, "dev-sbx-task")))[
             "stdout"
           ] == "self: ls"

    assert_raise RuntimeError, ~r/own sandbox/, fn -> Peers.exec(args, ctx) end

    assert_raise RuntimeError, ~r/no other device_id/, fn ->
      Peers.exec(
        Map.put(args, "device_id", "device-laptop"),
        Map.put(ctx, :station_device_id, "dev-sbx-task")
      )
    end
  end

  test "exec resolves credential_env into env and strips the references", %{ctx: ctx} do
    with_fake_dispatch()
    with_oauth_seams([github_binding()])

    seed_connection(%{
      "provider" => "github",
      "access_token" => "tok-live",
      "expires_at" => SystemsClock.system_time(:millisecond) + 3_600_000,
      "status" => "active",
      "scopes" => ["repo"]
    })

    decoded = Jason.decode!(exec_with_credential_env(ctx, [@gh_entry]))
    forwarded = decoded["forwarded_opts"]

    assert_received {:forwarded_env, %{"GH_TOKEN" => "tok-live"}}
    # What the command prints reaches the model with the credential taken out.
    assert forwarded["env"] == %{"GH_TOKEN" => "[redacted credential]"}
    refute Map.has_key?(forwarded, "credential_env")
    # untouched still-fresh connection: no refresh write happened
    assert {:ok, conn} = SalixStore.OAuth.get("conn-cred-1")
    assert conn["access_token"] == "tok-live"
  end

  test "exec passes a secret's fields and keeps only the secret ones out of its output",
       %{ctx: ctx} do
    with_fake_dispatch()

    with_oauth_seams([
      %{"provider" => "secret", "alias" => "hly", "connection_id" => "conn-cred-1"}
    ])

    SystemsRuntime.put_env(:salix_agent, :oauth_adapters_fn, fn
      "secret" -> {:ok, SalixStore.OAuth.Adapters.Secret}
      _ -> {:error, :unsupported_provider}
    end)

    seed_connection(%{
      "provider" => "secret",
      "status" => "active",
      "fields" => [
        %{"name" => "tenant", "secret" => false, "value" => "1001"},
        %{"name" => "app_secret", "secret" => true, "value" => "s3cr3t-value"}
      ]
    })

    entry = fn env_var, value ->
      %{"env_var" => env_var, "provider" => "secret", "alias" => "hly", "value" => value}
    end

    decoded =
      Jason.decode!(
        exec_with_credential_env(ctx, [
          entry.("HLY_TENANT", "tenant"),
          entry.("HLY_APP_SECRET", "app_secret")
        ])
      )

    assert_received {:forwarded_env,
                     %{"HLY_TENANT" => "1001", "HLY_APP_SECRET" => "s3cr3t-value"}}

    assert decoded["forwarded_opts"]["env"] == %{
             "HLY_TENANT" => "1001",
             "HLY_APP_SECRET" => "[redacted credential]"
           }
  end

  test "exec refreshes an expiring token via CAS before injecting", %{ctx: ctx} do
    with_fake_dispatch()
    with_oauth_seams([github_binding()])

    seed_connection(%{
      "provider" => "github",
      "access_token" => "tok-stale",
      "refresh_token" => "ref-1",
      "token_type" => "bearer",
      "scopes" => ["repo"],
      # already past expiry (also exercises willow's 60s leeway window)
      "expires_at" => SystemsClock.system_time(:millisecond) - 1_000,
      "status" => "active",
      "version" => 1
    })

    exec_with_credential_env(ctx, [@gh_entry])
    assert_received {:forwarded_env, %{"GH_TOKEN" => "tok-refreshed"}}

    # the refreshed token was persisted; blank refresh fields preserved old values
    assert {:ok, conn} = SalixStore.OAuth.get("conn-cred-1")
    assert conn["access_token"] == "tok-refreshed"
    assert conn["refresh_token"] == "ref-1"
    assert conn["token_type"] == "bearer"
    assert conn["scopes"] == ["repo"]
    assert conn["version"] == 2
    assert conn["expires_at"] > SystemsClock.system_time(:millisecond)
  end

  test "exec rejects a disabled OAuth credential before dispatch", %{ctx: ctx} do
    with_fake_dispatch()
    with_oauth_seams([Map.put(github_binding(), "enabled", false)])

    assert_raise RuntimeError, "oauth credential github/work for GH_TOKEN: is disabled", fn ->
      exec_with_credential_env(ctx, [@gh_entry])
    end
  end

  # ---- ComputerUse ----

  test "computer_use forwards action/thinking/args and maps the result envelope", %{ctx: ctx} do
    with_fake_dispatch()

    decoded =
      Jason.decode!(
        Peers.computer_use(
          %{
            "device_id" => "device-laptop",
            "environment" => "laptop",
            "action" => "click",
            "thinking" => "press OK",
            "args" => %{"x" => 1}
          },
          ctx
        )
      )

    assert decoded["result"] == "did click (thinking: press OK)"

    # start: message/mode/help joined like willow's computerUseResultFromRaw
    start =
      Jason.decode!(
        Peers.computer_use(
          %{"device_id" => "device-laptop", "environment" => "laptop", "action" => "start"},
          ctx
        )
      )

    assert start["result"] =~ "session started"
    assert start["result"] =~ "Mode: background"
    assert start["result"] =~ "Help:\nuse snapshot then click"

    # The screenshot remains on the device and returns a model-readable reference.
    shot =
      Jason.decode!(
        Peers.computer_use(
          %{"device_id" => "device-laptop", "environment" => "laptop", "action" => "screenshot"},
          Map.put(ctx, :model_supports_images, true)
        )
      )

    assert [%{"type" => "image", "file_ref" => ref, "width" => 800, "height" => 600}] = shot

    assert ref == %{
             "device_id" => "device-laptop",
             "environment_id" => "laptop",
             "path" => "capture-example.png"
           }

    # A background state keeps the accessibility tree beside its screenshot.
    state =
      Jason.decode!(
        Peers.computer_use(
          %{
            "device_id" => "device-laptop",
            "environment" => "laptop",
            "action" => "get_app_state"
          },
          Map.put(ctx, :model_supports_images, true)
        )
      )

    assert [
             %{"type" => "text", "text" => "Computer Use state (ComputerUseNext Snapshot: s1)"},
             %{"type" => "image", "file_ref" => %{"path" => "capture-state.png"}}
           ] = state

    # Without image input the state still returns its tree: the action already ran.
    text_only =
      Jason.decode!(
        Peers.computer_use(
          %{
            "device_id" => "device-laptop",
            "environment" => "laptop",
            "action" => "get_app_state"
          },
          Map.put(ctx, :model_supports_images, false)
        )
      )

    assert text_only == %{"result" => "Computer Use state (ComputerUseNext Snapshot: s1)"}

    # connector error envelope raises
    assert_raise RuntimeError, ~r/daemon exploded/, fn ->
      Peers.computer_use(
        %{"device_id" => "device-laptop", "environment" => "laptop", "action" => "boom"},
        ctx
      )
    end
  end

  test "android forwards the bounded envelope and strips screenshot bytes", %{ctx: ctx} do
    with_fake_dispatch()

    decoded =
      Peers.android(
        %{
          "device_id" => "device-laptop",
          "environment" => "android-host",
          "action" => "tap",
          "profile" => "api30-phone",
          "lease_id" => "lease-1",
          "lease_epoch" => 2,
          "observation_id" => 7,
          "args" => %{"ref" => "@3"}
        },
        ctx
      )
      |> Jason.decode!()

    assert decoded["result"]["action"] == "tap"
    assert decoded["result"]["profile"] == "api30-phone"
    assert decoded["result"]["lease_epoch"] == 2
    refute Map.has_key?(decoded["result"], "image_data")
  end

  test "android on a computer's own phone: an Agent's own consent is dropped, and a screenshot is a device image",
       %{ctx: ctx} do
    with_fake_dispatch()
    own = %{"device_id" => "device-laptop", "environment" => "android-own"}

    # Outside a Comma conversation nobody can be asked, whatever the Agent says it has.
    assert_raise RuntimeError, ~r/android_consent_unavailable/, fn ->
      Peers.android(
        Map.merge(own, %{
          "action" => "start",
          "target" => "android:3B162S00P0N00000",
          "consent" => true,
          "args" => %{"consent" => true}
        }),
        ctx
      )
    end

    assert [
             %{"type" => "text", "text" => text},
             %{"type" => "image", "file_ref" => ref, "width" => 1080}
           ] =
             Peers.android(
               Map.put(own, "action", "observe"),
               Map.put(ctx, :model_supports_images, true)
             )
             |> Jason.decode!()

    assert %{"result" => %{"observation_id" => 1, "locked" => false}} = Jason.decode!(text)

    assert ref == %{
             "device_id" => "device-laptop",
             "environment_id" => "android-own",
             "path" => "capture-phone.png"
           }
  end

  test "env.screen on a computer's simulator: an Agent's own consent is dropped, a person driving it and an old station refuse",
       %{ctx: ctx} do
    with_fake_dispatch()
    mac = %{"device_id" => "device-laptop", "environment" => "sim-mac"}

    # Outside a Comma conversation the computer's owner cannot be asked, whatever the Agent says it has.
    assert_raise RuntimeError, ~r/screen_consent_unavailable/, fn ->
      Peers.screen(
        Map.merge(mac, %{
          "action" => "start",
          "target" => "simulator:0702F8CC-2E2A-4D0A-8401-C37FA01E1646",
          "consent" => true,
          "args" => %{"consent" => true}
        }),
        ctx
      )
    end

    assert [%{"type" => "text"}, %{"type" => "image", "file_ref" => ref, "width" => 1206}] =
             Peers.screen(
               Map.put(mac, "action", "observe"),
               Map.put(ctx, :model_supports_images, true)
             )
             |> Jason.decode!()

    assert ref["path"] == "capture-sim.png"

    assert_raise RuntimeError, ~r/^screen_held_by_person: /, fn ->
      Peers.screen(Map.put(mac, "action", "tap"), ctx)
    end

    assert_raise RuntimeError, ~r/^screen_capability_missing: .*update Comma/, fn ->
      Peers.screen(
        %{"device_id" => "device-laptop", "environment" => "sim-old", "action" => "status"},
        ctx
      )
    end
  end

  defp worker_tool_ctx(ctx) do
    ctx = SalixAgent.TestSupport.with_plugin_projection(ctx)
    Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", :internal, ctx))
  end
end
