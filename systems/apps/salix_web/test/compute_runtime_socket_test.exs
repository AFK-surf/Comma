defmodule SalixWeb.ComputeRuntimeSocketTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias SalixWeb.ComputeRuntimeSocket
  alias SalixWeb.ComputeRuntimeRPC

  test "runtime carrier upgrade stays open while an agent is idle" do
    conn =
      "GET"
      |> conn("http://localhost/v1/compute/runtime/socket")
      |> then(&%{&1 | req_headers: [{"host", "localhost"} | &1.req_headers]})
      |> Plug.Conn.put_req_header("connection", "Upgrade")
      |> Plug.Conn.put_req_header("upgrade", "websocket")
      |> Plug.Conn.put_req_header("sec-websocket-version", "13")
      |> Plug.Conn.put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
      |> Plug.Conn.put_req_header("authorization", "Bearer test-token")
      |> SalixWeb.Router.call(SalixWeb.Router.init([]))

    assert conn.state == :upgraded

    assert_receive {_ref, :upgrade,
                    {:websocket, {SalixWeb.ComputeRuntimeSocket, %{token: "test-token"}, opts}}}

    assert opts[:timeout] == :infinity
  end

  test "does not dispatch a runtime request before the carrier is ready" do
    state = %ComputeRuntimeSocket{}

    assert {:stop, {:shutdown, :invalid_runtime_request}, ^state} =
             ComputeRuntimeSocket.handle_in(
               {Jason.encode!(%{
                  "type" => "request",
                  "id" => "event-1",
                  "method" => "meeting_runtime_event",
                  "params" => %{}
                }), [opcode: :text]},
               state
             )
  end

  for {label, features, method} <- [
        {"an event request without the negotiated event feature", ["runtime.input.v1"],
         "external_runtime_event"},
        {"a meeting event through an external worker carrier",
         ["runtime.input.v1", "runtime.event.v1"], "meeting_runtime_event"}
      ] do
    @features features
    @method method

    test "does not dispatch #{label}" do
      state = %ComputeRuntimeSocket{
        status: :ready,
        runtime_kind: "external_worker",
        features: @features
      }

      assert {:push, {:text, response}, ^state} =
               ComputeRuntimeSocket.handle_in(
                 {Jason.encode!(%{
                    "type" => "request",
                    "id" => "event-1",
                    "method" => @method,
                    "params" => %{}
                  }), [opcode: :text]},
                 state
               )

      assert %{"type" => "error", "id" => "event-1", "error" => "unsupported_runtime_request"} =
               Jason.decode!(response)
    end
  end

  test "admits connector runtime proxy requests on a ready compute carrier" do
    state = %ComputeRuntimeSocket{
      status: :ready,
      runtime_kind: "external_worker",
      tenant_id: "tenant-1",
      features: ["runtime.input.v1", "runtime.event.v1"]
    }

    assert {:push, {:text, response}, ^state} =
             ComputeRuntimeSocket.handle_in(
               {Jason.encode!(%{
                  "type" => "request",
                  "id" => "proxy-1",
                  "method" => "runtime_proxy",
                  "params" => %{}
                }), [opcode: :text]},
               state
             )

    assert %{
             "type" => "response",
             "id" => "proxy-1",
             "result" => %{"status" => 401}
           } = Jason.decode!(response)
  end

  test "round trips one typed auth request without retaining ceremony material" do
    ref = make_ref()

    state = %ComputeRuntimeSocket{
      status: :ready,
      runtime_instance_id: "runtime-1",
      workload_id: "workload-1",
      generation: 3,
      connection_epoch: "9",
      runtime_kind: "external_worker",
      features: ["runtime.input.v1", "runtime.event.v1", "runtime.auth.v1"]
    }

    request = %{
      "method" => "runtime_auth_login_start",
      "params" => %{
        "target" => %{
          "tenant_id" => "tenant",
          "project_id" => "project",
          "workload_id" => "workload-1",
          "runtime_instance_id" => "runtime-1",
          "generation" => 3,
          "connection_epoch" => "9",
          "provider" => "codex"
        },
        "flow" => "device_code"
      }
    }

    assert {:push, {:text, frame}, pending} =
             ComputeRuntimeSocket.handle_info(
               {:compute_runtime_rpc, ref, self(), request},
               state
             )

    outbound = Jason.decode!(frame)
    assert outbound["method"] == "runtime_auth_login_start"
    assert outbound["params"] == request["params"]

    ceremony = %{
      "auth" => %{
        "schema_version" => 1,
        "status" => "pending",
        "requires_openai_auth" => true,
        "observed_at" => 1
      },
      "attempt_id" => "attempt-1",
      "flow" => "device_code",
      "verification_url" => "https://auth.openai.com/codex/device",
      "user_code" => "ABCD-EFGH",
      "expires_at" => System.system_time(:millisecond) + 60_000,
      "reused" => false
    }

    assert {:ok, settled} =
             ComputeRuntimeSocket.handle_in(
               {Jason.encode!(%{
                  "type" => "response",
                  "id" => outbound["id"],
                  "result" => ceremony
                }), [opcode: :text]},
               pending
             )

    assert_receive {:compute_runtime_rpc_reply, ^ref, {:ok, ^ceremony}}
    assert settled.rpc_requests == %{}
  end

  test "does not send auth over a carrier that did not negotiate runtime.auth.v1" do
    ref = make_ref()

    state = %ComputeRuntimeSocket{
      status: :ready,
      runtime_kind: "external_worker",
      features: ["runtime.input.v1", "runtime.event.v1"]
    }

    assert {:ok, ^state} =
             ComputeRuntimeSocket.handle_info(
               {:compute_runtime_rpc, ref, self(), %{"method" => "runtime_auth_read"}},
               state
             )

    assert_receive {:compute_runtime_rpc_reply, ^ref, {:error, :runtime_transport_unavailable}}
  end

  test "ignores a late response for a canceled auth request" do
    state = %ComputeRuntimeSocket{
      status: :ready,
      runtime_kind: "external_worker",
      features: ["runtime.auth.v1"]
    }

    assert {:ok, ^state} =
             ComputeRuntimeSocket.handle_in(
               {Jason.encode!(%{
                  "type" => "response",
                  "id" => Ecto.UUID.generate(),
                  "result" => %{"status" => "authenticated"}
                }), [opcode: :text]},
               state
             )
  end

  test "notifies pending auth callers when the carrier terminates" do
    ref = make_ref()

    state = %ComputeRuntimeSocket{
      status: :ready,
      runtime_instance_id: "missing-runtime",
      generation: 1,
      connection_epoch: "1",
      rpc_requests: %{
        "request" =>
          {ref, self(), :control,
           %{"method" => "runtime_auth_status", "params" => %{"target" => %{}}}}
      }
    }

    assert :ok = ComputeRuntimeSocket.terminate(:closed, state)

    assert_receive {:compute_runtime_rpc_reply, ^ref, {:error, :runtime_transport_unavailable}}
  end

  test "runtime execution requests are asynchronous and capped at two" do
    if Process.whereis(SalixWeb.ConnectorRequestTaskSupervisor) == nil do
      start_supervised!(
        {Task.Supervisor, name: SalixWeb.ConnectorRequestTaskSupervisor, max_children: 64}
      )
    end

    state = %ComputeRuntimeSocket{
      status: :ready,
      runtime_kind: "external_worker",
      runtime_instance_id: "runtime-1",
      workload_id: "workload-1",
      generation: 1,
      connection_epoch: "1",
      execution_target: %{
        "registration_id" => "registration-1",
        "allocation_id" => "allocation-1",
        "allocation_generation" => 1,
        "connection_epoch" => "1"
      },
      features: ["runtime.execution.v1"]
    }

    frame = fn id ->
      {Jason.encode!(%{
         "type" => "request",
         "id" => id,
         "method" => "runtime_execution",
         "params" => %{
           "action" => "acquire",
           "execution_id" => "execution-1",
           "kind" => "main_execution",
           "deadline_unix_nano" => "0",
           "target" => state.execution_target
         }
       }), [opcode: :text]}
    end

    assert {:ok, first_pending} = ComputeRuntimeSocket.handle_in(frame.("execution-1"), state)
    assert map_size(first_pending.execution_requests) == 1

    assert [{first_ref, {_id, _pid, _timer, :operation}}] =
             Map.to_list(first_pending.execution_requests)

    assert_receive {^first_ref, {:error, :runtime_execution_target_changed}}

    assert {:push, {:text, first_reply}, settled} =
             ComputeRuntimeSocket.handle_info(
               {first_ref, {:error, :runtime_execution_target_changed}},
               first_pending
             )

    assert Jason.decode!(first_reply) == %{
             "id" => "execution-1",
             "type" => "error",
             "error" => "runtime_execution_target_changed"
           }

    refute Map.has_key?(settled.execution_requests, first_ref)

    saturated = %{
      state
      | execution_requests: %{
          make_ref() => {"one", self(), make_ref(), :operation},
          make_ref() => {"two", self(), make_ref(), :operation}
        }
    }

    assert {:push, {:text, capacity_reply}, ^saturated} =
             ComputeRuntimeSocket.handle_in(frame.("execution-3"), saturated)

    assert Jason.decode!(capacity_reply) == %{
             "id" => "execution-3",
             "type" => "error",
             "error" => "runtime_execution_capacity_exhausted"
           }

    control_frame =
      {Jason.encode!(%{
         "type" => "request",
         "id" => "execution-list",
         "method" => "runtime_execution",
         "params" => %{"action" => "list"}
       }), [opcode: :text]}

    assert {:ok, control_pending} =
             ComputeRuntimeSocket.handle_in(control_frame, saturated)

    assert map_size(control_pending.execution_requests) == 3

    assert Enum.count(control_pending.execution_requests, fn {_ref, {_id, _pid, _timer, class}} ->
             class == :control
           end) == 1
  end

  test "derives auth operation identity from the pending server request" do
    if Process.whereis(SalixWeb.ConnectorRequestTaskSupervisor) == nil do
      start_supervised!(
        {Task.Supervisor, name: SalixWeb.ConnectorRequestTaskSupervisor, max_children: 64}
      )
    end

    request_id = "auth-request"
    target = %{"runtime_instance_id" => "runtime-1", "provider" => "codex"}

    family =
      :crypto.hash(:sha256, "runtime-1" <> <<0>> <> "codex")
      |> binary_part(0, 16)
      |> Base.encode16(case: :lower)
      |> then(&("auth:" <> &1))

    ref = make_ref()

    state = %ComputeRuntimeSocket{
      status: :ready,
      runtime_kind: "external_worker",
      runtime_instance_id: "runtime-1",
      workload_id: "workload-1",
      generation: 1,
      connection_epoch: "1",
      features: ["runtime.execution.v1"],
      rpc_requests: %{
        request_id =>
          {ref, self(), :operation,
           %{"method" => "runtime_auth_verify", "params" => %{"target" => target}}}
      }
    }

    frame = fn activity_id ->
      {Jason.encode!(%{
         "type" => "request",
         "id" => Ecto.UUID.generate(),
         "method" => "runtime_execution",
         "params" => %{
           "action" => "acquire",
           "operation_request_id" => request_id,
           "execution_id" => activity_id,
           "kind" => "auth_operation"
         }
       }), [opcode: :text]}
    end

    assert {:push, {:text, rejected}, ^state} =
             ComputeRuntimeSocket.handle_in(frame.(family), state)

    assert %{"error" => "runtime_execution_context_mismatch"} = Jason.decode!(rejected)

    assert {:ok, accepted} =
             ComputeRuntimeSocket.handle_in(frame.(family <> ":verify:" <> request_id), state)

    assert map_size(accepted.execution_requests) == 1
  end

  test "the exact epoch carrier is the only live auth target" do
    :ok = ComputeRuntimeRPC.join("runtime-bridge", "11")

    task =
      Task.async(fn ->
        ComputeRuntimeRPC.call(
          "runtime-bridge",
          "11",
          %{"method" => "runtime_auth_read", "params" => %{}}
        )
      end)

    assert_receive {:compute_runtime_rpc, ref, caller, request}
    assert request["method"] == "runtime_auth_read"
    send(caller, {:compute_runtime_rpc_reply, ref, {:ok, %{"ready" => false}}})
    assert Task.await(task) == {:ok, %{"ready" => false}}

    assert {:error, :runtime_transport_unavailable} =
             ComputeRuntimeRPC.call(
               "runtime-bridge",
               "10",
               %{"method" => "runtime_auth_read", "params" => %{}}
             )
  end
end

defmodule SalixWeb.ComputeSubscriptionSocketTest do
  use ExUnit.Case, async: false

  defmodule ReadySocket do
    @behaviour WebSock
    def init(_),
      do:
        {:ok,
         %SalixWeb.ComputeRuntimeSocket{
           status: :ready,
           runtime_kind: "external_worker",
           features: ["runtime.subscription.v1"]
         }}

    defdelegate handle_in(frame, state), to: SalixWeb.ComputeRuntimeSocket
    defdelegate handle_info(message, state), to: SalixWeb.ComputeRuntimeSocket
    defdelegate terminate(reason, state), to: SalixWeb.ComputeRuntimeSocket
  end

  defmodule Endpoint do
    def init(opts), do: opts

    def call(conn, _),
      do: conn |> WebSockAdapter.upgrade(ReadySocket, %{}, timeout: 5_000) |> Plug.Conn.halt()
  end

  defmodule Client do
    use WebSockex

    def handle_frame({:text, frame}, test) do
      send(test, {:frame, Jason.decode!(frame)})
      {:ok, test}
    end

    def handle_disconnect(reason, test) do
      send(test, {:disconnected, reason})
      {:ok, test}
    end
  end

  @tag :compute_subscription_socket
  test "shared task saturation rejects only the pull and preserves the carrier" do
    supervisor = SalixWeb.ConnectorRequestTaskSupervisor

    if Process.whereis(supervisor) == nil,
      do: start_supervised!({Task.Supervisor, name: supervisor, max_children: 64})

    children = fill_pool(supervisor, [], 128)
    assert children != []
    on_exit(fn -> Enum.each(children, &Task.Supervisor.terminate_child(supervisor, &1)) end)
    listener = start_supervised!({Bandit, plug: Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(listener)

    client =
      start_supervised!(%{
        id: Client,
        start: {WebSockex, :start_link, ["ws://127.0.0.1:#{port}", Client, self()]},
        restart: :temporary
      })

    :ok =
      WebSockex.send_frame(
        client,
        {:text,
         Jason.encode!(%{
           "type" => "request",
           "id" => "pull",
           "method" => "runtime_subscription_access",
           "params" => %{}
         })}
      )

    assert_receive {:frame,
                    %{
                      "id" => "pull",
                      "type" => "error",
                      "error" => "subscription_access_unavailable"
                    }},
                   2_000

    :ok =
      WebSockex.send_frame(
        client,
        {:text,
         Jason.encode!(%{
           "type" => "request",
           "id" => "next",
           "method" => "external_runtime_event",
           "params" => %{}
         })}
      )

    assert_receive {:frame,
                    %{"id" => "next", "type" => "error", "error" => "unsupported_runtime_request"}},
                   2_000

    refute_received {:disconnected, _}
  end

  defp fill_pool(supervisor, children, remaining) when remaining > 0 do
    case Task.Supervisor.start_child(supervisor, fn ->
           receive do
             :release -> :ok
           end
         end) do
      {:ok, pid} -> fill_pool(supervisor, [pid | children], remaining - 1)
      {:error, :max_children} -> children
    end
  end

  defp fill_pool(_, children, 0) do
    Enum.each(children, &Process.exit(&1, :kill))
    flunk("shared task supervisor has no bounded capacity")
  end
end
