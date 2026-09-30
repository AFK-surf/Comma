defmodule SalixEnv.ProtocolTest do
  @moduledoc "The connector wire envelope: build/encode/decode, method timeouts, outcome."
  use ExUnit.Case, async: false

  alias SalixEnv.Protocol

  test "request/3 builds a request envelope with a fresh id" do
    msg = Protocol.request("exec", %{"command" => "ls"})
    assert msg["type"] == "request"
    assert msg["method"] == "exec"
    assert msg["params"] == %{"command" => "ls"}
    assert is_binary(msg["id"]) and String.starts_with?(msg["id"], "req_")
  end

  test "encode/decode round trips" do
    msg = Protocol.request("read", %{"path" => "/x"}, "fixed-id")
    assert {:ok, decoded} = Protocol.decode(Protocol.encode(msg))
    assert decoded == msg
  end

  test "decode rejects non-objects and bad json" do
    assert {:error, _} = Protocol.decode("not json")
    assert {:error, {:not_an_object, _}} = Protocol.decode("[1,2,3]")
  end

  test "per-method timeouts; exec honors a larger caller timeout" do
    assert Protocol.timeout("read") == 30_000
    assert Protocol.timeout("grep") == 60_000
    assert Protocol.timeout("exec") == 120_000
    assert Protocol.timeout("process_start") == 30_000
    assert Protocol.timeout("process_tail") == 35_000
    assert Protocol.timeout("meeting_artifact_read") == 90_000
    assert Protocol.timeout("android") == 220_000

    assert Protocol.timeout("meeting_artifact_read", %{"expected_size" => 30 * 1024 * 1024}) ==
             150_000

    assert Protocol.meeting_artifact_request_timeout(%{
             "expected_size" => 30 * 1024 * 1024
           }) == 180_000

    assert Protocol.meeting_artifact_request_timeout(%{"expected_size" => 2 * 1024 * 1024}) ==
             120_000

    # caller timeout (seconds) + slop beats the floor
    assert Protocol.timeout("exec", %{"timeout" => 600}) == 605_000
    # smaller caller timeout keeps the floor
    assert Protocol.timeout("exec", %{"timeout" => 5}) == 120_000
    assert Protocol.timeout("exec", %{"timeout" => "300"}) == 305_000
    assert Protocol.timeout("process_tail", %{"wait_seconds" => 60}) == 65_000
    assert Protocol.timeout("process_tail", %{"wait_seconds" => "120"}) == 125_000
  end

  test "timeout factor scales protocol floors without shrinking explicit exec deadlines" do
    previous = Application.get_env(:salix_env, :timeout_factor)

    try do
      Application.put_env(:salix_env, :timeout_factor, 3)

      assert Protocol.timeout("read") == 90_000
      assert Protocol.timeout("write_stream") == 180_000
      assert Protocol.timeout("exec", %{"timeout" => 5}) == 360_000
      assert Protocol.timeout("exec", %{"timeout" => 600}) == 605_000
    after
      if previous do
        Application.put_env(:salix_env, :timeout_factor, previous)
      else
        Application.delete_env(:salix_env, :timeout_factor)
      end
    end
  end

  test "method timeouts can be overridden from app env" do
    original = Application.fetch_env(:salix_env, :protocol_timeouts)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:salix_env, :protocol_timeouts, value)
        :error -> Application.delete_env(:salix_env, :protocol_timeouts)
      end
    end)

    Application.put_env(:salix_env, :protocol_timeouts, %{"write_stream" => 360_000})

    assert Protocol.timeout("write_stream") == 360_000
    assert Protocol.timeout("read_stream") == 60_000
  end

  test "outcome maps response/error envelopes" do
    assert Protocol.outcome(%{"type" => "response", "result" => %{"exit_code" => 0}}) ==
             {:ok, %{"exit_code" => 0}}

    assert Protocol.outcome(%{"type" => "error", "error" => "boom"}) == {:error, "boom"}
    assert Protocol.outcome(%{"error" => "bad"}) == {:error, "bad"}
    assert Protocol.outcome(%{"result" => "scalar"}) == {:ok, %{"value" => "scalar"}}
    assert Protocol.outcome(%{"type" => "response"}) == {:ok, %{}}
  end
end
