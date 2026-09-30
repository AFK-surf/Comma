defmodule Salix.Bindings.MeetingConnectDispatchTest do
  use ExUnit.Case, async: false

  alias Salix.Bindings.MeetingConnectDispatch
  alias SalixMeet.Store

  setup do
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> SalixStore.S3.Fake.reset()
    end

    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, previous) end)
    :ok
  end

  test "send rejects a payload connector identity that differs from durable meeting state" do
    assert {:ok, _doc, _etag} =
             Store.create_once("meeting-connect-identity",
               state: %{
                 "group_id" => "group-connect-identity",
                 "connect_id" => "durable-connect"
               }
             )

    assert {:error, :meeting_connector_identity_mismatch} =
             MeetingConnectDispatch.send_chat(%{
               "meeting_id" => "meeting-connect-identity",
               "group_id" => "group-connect-identity",
               "runtime_source" => "connected_runtime",
               "connect_id" => "different-connect",
               "text" => "hello"
             })
  end

  test "session_status requires identifiers" do
    assert {:error, :missing_meeting_id} =
             MeetingConnectDispatch.session_status(%{"group_id" => "g"})

    assert {:error, :missing_group_id} =
             MeetingConnectDispatch.session_status(%{"meeting_id" => "m"})
  end

  test "session_status is fail-closed to unavailable on every resolution gap" do
    # No durable meeting document.
    assert {:ok, :unavailable} =
             MeetingConnectDispatch.session_status(%{
               "meeting_id" => "session-status-missing",
               "group_id" => "group-session-status",
               "runtime_source" => "connected_runtime"
             })

    assert {:ok, _doc, _etag} =
             Store.create_once("session-status-meeting",
               state: %{
                 "group_id" => "group-session-status",
                 "connect_id" => "durable-connect"
               }
             )

    # Connector identity mismatch: a read never errors, it reports unavailable.
    assert {:ok, :unavailable} =
             MeetingConnectDispatch.session_status(%{
               "meeting_id" => "session-status-meeting",
               "group_id" => "group-session-status",
               "runtime_source" => "connected_runtime",
               "connect_id" => "different-connect"
             })

    # No connected meeting-capable environment for the group.
    assert {:ok, :unavailable} =
             MeetingConnectDispatch.session_status(%{
               "meeting_id" => "session-status-meeting",
               "group_id" => "group-session-status",
               "runtime_source" => "connected_runtime"
             })

    # A carrier this primitive does not cover yet is a gap, not an answer.
    assert {:ok, :unavailable} =
             MeetingConnectDispatch.session_status(%{
               "meeting_id" => "session-status-meeting",
               "group_id" => "group-session-status",
               "runtime_source" => "compute_workload"
             })
  end
end
