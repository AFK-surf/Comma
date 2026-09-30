defmodule SalixWeb.MeetingRuntimeTest do
  use ExUnit.Case, async: false

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _ -> SalixStore.S3.Fake.reset()
    end

    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
    :ok
  end

  defp put_meeting(id) do
    {:ok, _doc, _etag} =
      SalixMeet.Store.create_once(id,
        state: %{"tenant_id" => "t1", "group_id" => "g1", "runtime_token" => "tok"}
      )
  end

  test "rejects an event whose runtime token does not match" do
    put_meeting("m1")

    event = %{
      "event" => %{"meeting_id" => "m1", "runtime_token" => "WRONG", "type" => "joiner_event"}
    }

    assert {:error, :unauthorized} =
             SalixWeb.MeetingRuntime.handle_connector_event("env1", event, %{})
  end

  test "rejects an event for an unknown meeting" do
    event = %{"event" => %{"meeting_id" => "missing", "runtime_token" => "tok"}}

    assert {:error, :not_found} =
             SalixWeb.MeetingRuntime.handle_connector_event("env1", event, %{})
  end

  test "rejects params without an event" do
    assert {:error, :missing_event} =
             SalixWeb.MeetingRuntime.handle_connector_event("env1", %{}, %{})
  end

  test "rejects an event from a connector scoped to a different group" do
    put_meeting("m1")

    event = %{"event" => %{"meeting_id" => "m1", "runtime_token" => "tok"}}
    meta = %{"tenant_id" => "t1", "group_id" => "other-group"}

    assert {:error, :scope_mismatch} =
             SalixWeb.MeetingRuntime.handle_connector_event("env1", event, meta)
  end
end
