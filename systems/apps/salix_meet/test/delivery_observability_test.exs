defmodule SalixMeet.DeliveryObservabilityTest do
  use ExUnit.Case, async: false

  alias SalixMeet.Delivery

  setup do
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end

    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:salix_store, :s3_backend),
        else: Application.put_env(:salix_store, :s3_backend, previous)
    end)

    :ok
  end

  test "a claim-stage storage failure is logged and metered instead of a silent skip" do
    meeting_id = "mtg-observability-claim-failure"
    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :get, "meet/#{meeting_id}/state.json"})

    handler_id = "delivery-claim-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:salix, :operation, :stop],
        fn _event, _measurements, metadata, _config -> send(parent, {:operation, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :skipped = Delivery.deliver_one(meeting_id)
      end)

    assert log =~ "meeting delivery claim failed"
    assert log =~ meeting_id

    assert_receive {:operation,
                    %{
                      component: "salix_meet",
                      operation: "meeting_delivery_claim",
                      outcome: "error"
                    }}
  end
end
