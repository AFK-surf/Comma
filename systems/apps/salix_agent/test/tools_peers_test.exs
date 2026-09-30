defmodule SalixAgent.ToolsPeersTest do
  @moduledoc """
  Remote-environment tools (`SalixAgent.Tools.Peers`) against the
  Fake S3 backend: `env.exec` / `env.computer_use` /
  `device.list` through both an in-test
  `SalixAgent.EnvDispatch` implementation and the `None` default error path.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{ToolDisclosure, Tools}
  alias SalixAgent.Tools.Peers

  defmodule FakeDispatch do
    @moduledoc false
    @behaviour SalixAgent.EnvDispatch

    @impl true
    def list_devices(_agent_id, opts) do
      send(self(), {:device_page_requested, opts})

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

    def get_device(_agent_id, "lookup-failed"), do: {:error, :timeout}
    def get_device(_agent_id, _device_id), do: {:error, :not_found}

    @impl true
    def exec(_agent_id, %{device_id: "device-laptop", environment_id: "laptop"}, cmd, opts) do
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

    def android(_agent_id, _env, _payload), do: {:error, :android_not_authorized}

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

    defp cfg, do: Application.get_env(:salix_agent, :oauth_store_stub, %{})

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
         "expires_at" => System.system_time(:millisecond) + 3_600_000,
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
    prev = Application.get_env(:salix_store, :s3_backend)
    # Capture and RESTORE (not delete) the dispatcher: in the umbrella's shared
    # test VM another app (salix_web) configures a real dispatcher at boot;
    # deleting it would clobber that for tests that run later.
    prev_dispatch = Application.get_env(:salix_agent, :env_dispatch)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    Application.delete_env(:salix_agent, :env_dispatch)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
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
    prev = Application.get_env(:salix_agent, :env_dispatch)
    Application.put_env(:salix_agent, :env_dispatch, FakeDispatch)
    on_exit(fn -> restore_dispatch(prev) end)
  end

  defp restore_dispatch(nil), do: Application.delete_env(:salix_agent, :env_dispatch)
  defp restore_dispatch(mod), do: Application.put_env(:salix_agent, :env_dispatch, mod)

  defp restore_env(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: Application.put_env(:salix_agent, key, value)

  # ---- defs ----

  test "defs are in registry order with stable names" do
    assert Enum.map(Peers.defs(), &Tools.entry_name/1) ==
             [
               "env.exec",
               "env.process_list",
               "env.process_write",
               "env.process_tail",
               "env.copy",
               "device.list",
               "device.get",
               "env.computer_use",
               "env.android"
             ]

    for entry <- Peers.defs() do
      desc = Tools.entry_description(entry)
      fun = Tools.entry_fun(entry)
      auto_wait_seconds = Tools.entry_auto_wait_seconds(entry)

      assert is_binary(desc) and desc != ""
      assert is_function(fun, 2)
      assert auto_wait_seconds == 20
    end
  end

  test "remote exec requires its device owner before credential resolution", %{ctx: ctx} do
    with_fake_dispatch()

    assert_raise RuntimeError, ~r/'device_id' is required/, fn ->
      Peers.exec(
        %{
          "environment" => "laptop",
          "command" => "echo unsafe",
          "description" => "probe",
          "credential_env" => "invalid"
        },
        ctx
      )
    end

    assert_raise RuntimeError, ~r/no environment connected/, fn ->
      Peers.exec(
        %{
          "device_id" => "wrong-device",
          "environment" => "laptop",
          "command" => "echo unsafe",
          "description" => "probe"
        },
        ctx
      )
    end
  end

  # ---- device discovery ----

  test "device discovery forwards a bounded page and opaque cursor", %{ctx: ctx} do
    with_fake_dispatch()

    assert %{"devices" => [%{"device_id" => "device-laptop"}], "next_cursor" => "next-page"} =
             Jason.decode!(Peers.list_devices(%{}, ctx))

    assert_receive {:device_page_requested, [limit: 20]}

    Peers.list_devices(%{"limit" => 1, "cursor" => "next-page"}, ctx)
    assert_receive {:device_page_requested, [limit: 1, cursor: "next-page"]}

    assert_raise RuntimeError, ~r/limit must be/, fn ->
      Peers.list_devices(%{"limit" => 101}, ctx)
    end

    refute_receive {:device_page_requested, _}
  end

  test "device discovery reports the unavailable owner", %{ctx: ctx} do
    assert_raise RuntimeError, ~r/device.list failed/, fn ->
      Peers.list_devices(%{}, ctx)
    end
  end

  test "get_device distinguishes a missing device from a failed lookup", %{
    ctx: ctx
  } do
    with_fake_dispatch()

    assert %{
             "device_id" => "device-laptop",
             "name" => "Laptop",
             "status" => "connected",
             "device_runtimes" => []
           } =
             %{"device_id" => "device-laptop"}
             |> Peers.get_device(ctx)
             |> Jason.decode!()

    assert {:tool_failure, content, "device_not_found", "user_reportable", message, []} =
             Peers.get_device(%{"device_id" => "missing-device"}, ctx)

    assert Jason.decode!(content)["device_id"] == "missing-device"
    assert message =~ "not found in the current workspace"
    assert message =~ "device.list"
    refute message =~ "no environment connected"

    assert {:tool_failure, failed, "device_lookup_failed", "user_reportable", message, []} =
             Peers.get_device(%{"device_id" => "lookup-failed"}, ctx)

    assert Jason.decode!(failed)["device_id"] == "lookup-failed"
    assert message =~ "current state is unknown"
    refute message =~ "not found"
  end

  # ---- Copy ----

  test "copy returns structured VM errors for read and write stream interruption", %{ctx: ctx} do
    with_fake_dispatch()

    read_error =
      Peers.copy(
        %{
          "src_device_id" => "device-laptop",
          "src_environment" => "cloud-vm",
          "src_path" => "/interrupt",
          "dst_environment" => "vfs",
          "dst_path" => "/out"
        },
        ctx
      )
      |> Jason.decode!()

    assert read_error["ok"] == false
    assert read_error["error_class"] == "vm_call_interrupted"
    assert read_error["connection_generation"] == 42

    write_error =
      Peers.copy(
        %{
          "src_device_id" => "device-laptop",
          "src_environment" => "laptop",
          "src_path" => "/memory.md",
          "dst_device_id" => "device-laptop",
          "dst_environment" => "cloud-vm",
          "dst_path" => "/interrupt"
        },
        ctx
      )
      |> Jason.decode!()

    assert write_error["ok"] == false
    assert write_error["error_class"] == "vm_call_interrupted"
  end

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
          external_tool_ctx(ctx)
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

  test "exec returns structured VM errors as stable tool JSON", %{ctx: ctx} do
    with_fake_dispatch()

    out =
      Peers.exec(
        %{
          "device_id" => "device-laptop",
          "environment" => "cloud-vm",
          "command" => "interrupt",
          "description" => "interrupt"
        },
        ctx
      )

    decoded = Jason.decode!(out)
    assert decoded["ok"] == false
    assert decoded["error_class"] == "vm_call_interrupted"
    assert decoded["message"] == "VM call interrupted"
    assert decoded["retryable"] == true
    assert decoded["env_id"] == "cloud-vm-env"
    assert decoded["sandbox_id"] == "sandbox-1"
    assert decoded["connection_generation"] == 42
  end

  test "exec validates environment and description", %{ctx: ctx} do
    with_fake_dispatch()

    assert_raise RuntimeError, ~r/exec requires a remote environment/, fn ->
      Peers.exec(%{"command" => "ls", "description" => "list"}, ctx)
    end

    assert_raise RuntimeError, ~r/exec requires a remote environment/, fn ->
      Peers.exec(
        %{
          "device_id" => "device-laptop",
          "environment" => "vfs",
          "command" => "ls",
          "description" => "list"
        },
        ctx
      )
    end

    assert_raise RuntimeError, ~r/'description' is required/, fn ->
      Peers.exec(
        %{"device_id" => "device-laptop", "environment" => "laptop", "command" => "ls"},
        ctx
      )
    end

    bounded =
      Peers.exec(
        %{
          "device_id" => "device-laptop",
          "environment" => "laptop",
          "command" => "ls",
          "description" => String.duplicate("x", 40)
        },
        ctx
      )
      |> Jason.decode!()

    assert bounded["description"] == String.duplicate("x", 19)
  end

  test "exec reports the actionable Comma Full Access requirement", %{ctx: ctx} do
    with_fake_dispatch()

    assert_raise RuntimeError, ~r/Ask the user to enable Full Access/, fn ->
      Peers.exec(
        %{
          "device_id" => "device-laptop",
          "environment" => "comma-disabled",
          "command" => "comma modules",
          "description" => "inspect Comma"
        },
        ctx
      )
    end
  end

  test "internal LLM exec bounds a presentation label before schema validation", %{ctx: ctx} do
    with_fake_dispatch()

    ctx =
      ctx
      |> Map.put(:role, "worker")
      |> Map.put(:runtime_kind, :internal)
      |> Map.put(:llm_tool_envelope, true)
      |> then(fn ctx ->
        Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", :internal, ctx))
      end)

    description = "  inspect " <> String.duplicate("🧑‍💻", 20) <> "  "

    [result] =
      Tools.execute(
        [
          %{
            id: "bounded-exec-description",
            name: "call",
            args: %{
              "tool" => "env.exec",
              "params" => %{
                "device_id" => "device-laptop",
                "environment" => "laptop",
                "command" => "printf ready",
                "description" => description
              }
            }
          }
        ],
        ctx
      )

    assert result.status == "completed"
    refute result.status == "guidance"

    payload = Jason.decode!(result.content)
    bounded_description = payload["description"]

    assert String.length(bounded_description) == 19

    assert bounded_description ==
             description |> String.trim() |> String.graphemes() |> Enum.take(19) |> Enum.join()

    assert payload["stdout"] == "ran: printf ready"
  end

  test "exec raises through the None default", %{ctx: ctx} do
    assert_raise RuntimeError, ~r/no environment connected/, fn ->
      Peers.exec(
        %{
          "device_id" => "device-laptop",
          "environment" => "laptop",
          "command" => "ls",
          "description" => "list"
        },
        ctx
      )
    end
  end

  # ---- Exec credential_env (willow exec.go + internal/oauth/resolver.go) ----

  @oauth_envs [:oauth_store_mod, :oauth_store_stub, :oauth_adapters_fn, :oauth_refresher_fn]

  defp with_oauth_seams(bindings) do
    prev = Map.new(@oauth_envs, fn k -> {k, Application.get_env(:salix_agent, k)} end)

    Application.put_env(:salix_agent, :oauth_store_mod, OAuthStubStore)

    Application.put_env(:salix_agent, :oauth_store_stub, %{
      context: %{tenant: "t1", group_id: "g1"},
      bindings: bindings,
      provider_apps: %{{"t1", "github"} => %{"client_id" => "cid", "client_secret" => "sec"}}
    })

    Application.put_env(:salix_agent, :oauth_adapters_fn, fn
      "github" -> {:ok, FakeOAuthAdapter}
      _ -> {:error, :unsupported_provider}
    end)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:salix_agent, k, v),
          else: Application.delete_env(:salix_agent, k)
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

  test "exec resolves credential_env into env and strips the references", %{ctx: ctx} do
    with_fake_dispatch()
    with_oauth_seams([github_binding()])

    seed_connection(%{
      "provider" => "github",
      "access_token" => "tok-live",
      "expires_at" => System.system_time(:millisecond) + 3_600_000,
      "status" => "active",
      "scopes" => ["repo"]
    })

    decoded = Jason.decode!(exec_with_credential_env(ctx, [@gh_entry]))
    forwarded = decoded["forwarded_opts"]

    assert forwarded["env"] == %{"GH_TOKEN" => "tok-live"}
    refute Map.has_key?(forwarded, "credential_env")
    # untouched still-fresh connection: no refresh write happened
    assert {:ok, conn} = SalixStore.OAuth.get("conn-cred-1")
    assert conn["access_token"] == "tok-live"
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
      "expires_at" => System.system_time(:millisecond) - 1_000,
      "status" => "active",
      "version" => 1
    })

    decoded = Jason.decode!(exec_with_credential_env(ctx, [@gh_entry]))
    assert decoded["forwarded_opts"]["env"] == %{"GH_TOKEN" => "tok-refreshed"}

    # the refreshed token was persisted; blank refresh fields preserved old values
    assert {:ok, conn} = SalixStore.OAuth.get("conn-cred-1")
    assert conn["access_token"] == "tok-refreshed"
    assert conn["refresh_token"] == "ref-1"
    assert conn["token_type"] == "bearer"
    assert conn["scopes"] == ["repo"]
    assert conn["version"] == 2
    assert conn["expires_at"] > System.system_time(:millisecond)
  end

  test "exec with an explicitly empty credential_env forwards no env", %{ctx: ctx} do
    with_fake_dispatch()
    with_oauth_seams([github_binding()])

    decoded = Jason.decode!(exec_with_credential_env(ctx, []))
    refute Map.has_key?(decoded["forwarded_opts"], "env")
    refute Map.has_key?(decoded["forwarded_opts"], "credential_env")
  end

  test "exec rejects a disabled OAuth credential before dispatch", %{ctx: ctx} do
    with_fake_dispatch()
    with_oauth_seams([Map.put(github_binding(), "enabled", false)])

    assert_raise RuntimeError, "oauth credential github/work for GH_TOKEN: is disabled", fn ->
      exec_with_credential_env(ctx, [@gh_entry])
    end
  end

  test "exec surfaces willow's per-entry credential error format", %{ctx: ctx} do
    with_fake_dispatch()
    with_oauth_seams([github_binding()])

    assert_raise RuntimeError,
                 "oauth credential github/missing for GH_TOKEN: is not bound to this agent group",
                 fn ->
                   exec_with_credential_env(ctx, [%{@gh_entry | "alias" => "missing"}])
                 end

    assert_raise RuntimeError,
                 "oauth credential slack/work for SLACK_USER_TOKEN: oauth provider \"slack\" is not supported",
                 fn ->
                   exec_with_credential_env(ctx, [
                     %{
                       "env_var" => "SLACK_USER_TOKEN",
                       "provider" => "slack",
                       "alias" => "work",
                       "value" => "access_token"
                     }
                   ])
                 end

    assert_raise RuntimeError, "oauth credential_env contains empty env_var", fn ->
      exec_with_credential_env(ctx, [%{@gh_entry | "env_var" => " "}])
    end

    assert_raise RuntimeError,
                 ~s(oauth credential_env contains duplicate env_var "GH_TOKEN"),
                 fn ->
                   exec_with_credential_env(ctx, [@gh_entry, @gh_entry])
                 end
  end

  test "exec marks the connection on refresh reauthorization failure", %{ctx: ctx} do
    with_fake_dispatch()
    with_oauth_seams([github_binding()])

    Application.put_env(:salix_agent, :oauth_refresher_fn, fn _adapter, _app, _conn ->
      {:error, :reauthorization_required}
    end)

    seed_connection(%{
      "provider" => "github",
      "access_token" => "tok-stale",
      "expires_at" => System.system_time(:millisecond) - 1_000,
      "status" => "active",
      "scopes" => ["repo"]
    })

    assert_raise RuntimeError,
                 "oauth credential github/work for GH_TOKEN: refresh failed (reauthorization required)",
                 fn -> exec_with_credential_env(ctx, [@gh_entry]) end

    assert {:ok, conn} = SalixStore.OAuth.get("conn-cred-1")
    assert conn["status"] == "reauthorization_required"

    # subsequent resolution short-circuits on the marked status
    assert_raise RuntimeError,
                 "oauth credential github/work for GH_TOKEN: requires reauthorization",
                 fn -> exec_with_credential_env(ctx, [@gh_entry]) end
  end

  # ---- ComputerUse ----

  test "computer_use help needs no environment and no dispatcher", %{ctx: ctx} do
    decoded = Jason.decode!(Peers.computer_use(%{"action" => "help"}, ctx))
    assert decoded["result"] =~ "env.computer_use modes"
    assert decoded["result"] =~ "background"
    assert decoded["result"] =~ "foreground"
    assert decoded["result"] =~ ~s(action="open-permission-flow")
    refute decoded["result"] =~ ~s(action="permissions-open-ui")
  end

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

    # connector error envelope raises
    assert_raise RuntimeError, ~r/daemon exploded/, fn ->
      Peers.computer_use(
        %{"device_id" => "device-laptop", "environment" => "laptop", "action" => "boom"},
        ctx
      )
    end
  end

  test "computer_use validates inputs and raises through the None default", %{ctx: ctx} do
    assert_raise RuntimeError, ~r/'action' is required/, fn ->
      Peers.computer_use(%{}, ctx)
    end

    assert_raise RuntimeError, ~r/computer_use requires a remote environment/, fn ->
      Peers.computer_use(%{"action" => "click"}, ctx)
    end

    assert_raise RuntimeError, ~r/no environment connected/, fn ->
      Peers.computer_use(
        %{"device_id" => "device-laptop", "environment" => "laptop", "action" => "click"},
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

  test "android preserves ambiguous transport failures", %{ctx: ctx} do
    with_fake_dispatch()

    assert_raise RuntimeError, ~r/android_transport_ambiguous: timeout/, fn ->
      Peers.android(
        %{
          "device_id" => "device-laptop",
          "environment" => "android-timeout",
          "action" => "status"
        },
        ctx
      )
    end

    assert_raise RuntimeError, ~r/android_transport_ambiguous: disconnected/, fn ->
      Peers.android(
        %{
          "device_id" => "device-laptop",
          "environment" => "android-disconnected",
          "action" => "status"
        },
        ctx
      )
    end
  end

  test "android preserves profile admission failures", %{ctx: ctx} do
    with_fake_dispatch()

    for reason <- ~w(profile_required profile_not_allowed profile_unavailable) do
      assert_raise RuntimeError, ~r/android_#{reason}/, fn ->
        Peers.android(
          %{
            "device_id" => "device-laptop",
            "environment" => "android-#{String.replace(reason, "_", "-")}",
            "action" => "start"
          },
          ctx
        )
      end
    end
  end

  test "android is disclosed and callable by compute and connected workers", %{ctx: base_ctx} do
    with_fake_dispatch()

    for runtime_kind <- [:internal, :external] do
      ctx =
        base_ctx
        |> SalixAgent.TestSupport.with_plugin_projection()
        |> Map.put(:role, "worker")
        |> Map.put(:runtime_kind, runtime_kind)
        |> then(fn ctx ->
          Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", runtime_kind, ctx))
        end)

      assert %{"callable" => true} =
               ToolDisclosure.find_disclosure_entry(ctx, "env.android")

      call = %{
        "id" => "android-#{runtime_kind}",
        "name" => "env.android",
        "args" => %{
          "device_id" => "device-laptop",
          "environment" => "android-host",
          "action" => "status"
        }
      }

      [result] = Tools.execute([call], ctx)
      assert result.status == "completed"
      assert Jason.decode!(result.content)["result"]["action"] == "status"
    end
  end

  defp external_tool_ctx(ctx) do
    ctx = SalixAgent.TestSupport.with_plugin_projection(ctx)
    Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", :external, ctx))
  end
end
