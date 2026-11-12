defmodule SalixAgent.InternalSessionStoreWithSessionTest do
  @moduledoc """
  A reader outside the session actor loads the whole state into the kernel.
  `with_session/3` releases it when the reader is done, so a long-lived process
  that reads once and then idles does not keep the state resident until its
  next collection.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{InternalAgentRuntime, InternalSession, InternalSessionStore}

  @session_id "ses1_0000000000000009101"

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, previous) end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    {:ok, _session} =
      SalixAgent.TestSupport.SessionFixture.commit(agent_id, @session_id, [
        %{"type" => "session_created", "session_id" => @session_id},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => @session_id,
          "message_id" => 1,
          "content" => "hello"
        },
        %{
          "type" => "assistant",
          "session_id" => @session_id,
          "message_id" => 2,
          "content" => "hi"
        },
        %{"type" => "ack", "session_id" => @session_id, "last_ack_message_id" => 2}
      ])

    %{agent_id: agent_id}
  end

  # A reader must not keep the handle. The tests below do, only to show that
  # the handle is dead once `with_session/3` returns.
  test "returns the reader's value and releases the state", %{agent_id: agent_id} do
    assert {:ok, 2} =
             InternalSessionStore.with_session(agent_id, @session_id, fn session ->
               send(self(), {:handle, session})
               {:ok, InternalSession.last_ack_message_id(session)}
             end)

    assert_received {:handle, session}
    assert_raise ArgumentError, fn -> InternalSession.export(session) end
  end

  test "releases the state when the reader raises", %{agent_id: agent_id} do
    assert_raise RuntimeError, "reader failed", fn ->
      InternalSessionStore.with_session(agent_id, @session_id, fn session ->
        send(self(), {:handle, session})
        raise "reader failed"
      end)
    end

    assert_received {:handle, session}
    assert_raise ArgumentError, fn -> InternalSession.export(session) end
  end

  test "a read leaves no resident state once the reader is done", %{agent_id: agent_id} do
    before = SalixVerifiedKernel.memory_stats().residents

    assert {:ok, 2} =
             InternalSessionStore.with_session(agent_id, @session_id, fn session ->
               {:ok, InternalSession.last_ack_message_id(session)}
             end)

    # A read admits, restores, and revisions the state before it returns it;
    # every handle of that chain must be gone. The count is node-wide, and
    # handles that other processes release meanwhile only lower it.
    assert SalixVerifiedKernel.memory_stats().residents <= before
  end

  test "passes a missing session through as the read error", %{agent_id: agent_id} do
    assert {:error, :not_found} =
             InternalSessionStore.with_session(agent_id, "ses1_0000000000000009102", fn _ ->
               flunk("the reader must not run")
             end)
  end

  test "runtime readers answer from a released state", %{agent_id: agent_id} do
    assert {:ok, %{"session_id" => @session_id}} =
             InternalAgentRuntime.get_session_summary(agent_id, @session_id)

    assert {:ok, %{"message_count" => 2}} =
             InternalAgentRuntime.session_status(agent_id, @session_id)
  end
end
