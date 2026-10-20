defmodule SalixMeetNative.EventsTest do
  use ExUnit.Case, async: true

  alias SalixMeetNative.Events

  @media_streams "1f8b0800000000000000e3dace28b485516a2323170747e3b3f713ee2ec81072e560146054e23232343035333631363632922f2e484c4e2dd67749358eca31f2c830700e74d24f492dcb04091a5a9a38b171ccb9d3fa86dd8b498031888983a188898341288e8351804989cbd0c2dcccdcd8c2d2c894b031b21c6fdb3eff63e36838f15b4748808bd9cdd345002c220012f16212600862e2608c6004990f001b51db09ba000000"

  test "media streams with fields whose wire type differs from the schema still decode, as in the Go runtime" do
    raw = Base.decode16!(@media_streams, case: :lower)

    assert [
             %{
               type: "media.audioState",
               payload: %{"device" => "spaces/De3Zl2Hh0CQB/devices/194", "stream" => "2105634332"}
             },
             %{type: "media.videoState", payload: %{"stream" => "1876738925"}}
           ] = Events.decode("collections", raw)

    assert [%{device: "spaces/De3Zl2Hh0CQB/devices/194", ssrc: "2105634332"}] =
             SalixMeetNative.Frames.media_streams(raw, :audio)
  end

  test "a counters-only collections frame from a live meeting is not undecodable" do
    raw =
      Base.decode16!("1f8b0800000000000000e3e215e2cee2ec6264e362e260146004002ff368920f000000",
        case: :lower
      )

    assert Events.decode("collections", raw) == []
  end
end
