defmodule Salix.Bindings.MeetingConnectDispatchTest do
  use SystemsClock.Case, async: false

  alias Salix.Bindings.MeetingConnectDispatch
  alias SalixMeet.Store

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> SalixStore.S3.Fake.reset()
    end

    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, previous) end)
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
end
