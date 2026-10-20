defmodule SalixMeetNative.Recorder.GapFillerTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec

  alias Membrane.{Buffer, Testing}

  test "a 205 ms hole in an Opus stream is filled with valid 20 ms and 2.5 ms loss packets" do
    frame = <<0xFC, 0xFF, 0xFE>>
    ms = &Membrane.Time.milliseconds/1
    hole = Membrane.Time.microseconds(205_000)

    input =
      [0, 20, 40 + 205, 60 + 205]
      |> Enum.map(&Membrane.Time.microseconds(&1 * 1000))
      |> Enum.map(&%Buffer{payload: frame, pts: &1, metadata: %{duration: ms.(20)}})

    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec:
          child(:source, %Testing.Source{
            output: input,
            stream_format: %Membrane.Opus{channels: 2, self_delimiting?: false}
          })
          |> child(:gaps, SalixMeetNative.Recorder.GapFiller)
          |> child(:sink, Testing.Sink)
      )

    out = collect(pipeline, [])
    fillers = Enum.filter(out, &(&1.payload != frame))

    assert Enum.map(fillers, & &1.payload) ==
             List.duplicate(<<0x98>>, 10) ++ List.duplicate(<<0x80>>, 2)

    assert fillers |> Enum.map(& &1.metadata.duration) |> Enum.sum() == hole
    assert Enum.map(out, & &1.pts) == Enum.sort(Enum.map(out, & &1.pts))
    assert List.last(out).pts == ms.(60) + hole
  end

  defp collect(pipeline, acc) do
    receive do
      {Testing.Pipeline, ^pipeline, {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
        collect(pipeline, [buffer | acc])

      {Testing.Pipeline, ^pipeline, {:handle_element_end_of_stream, {:sink, :input}}} ->
        Enum.reverse(acc)
    end
  end
end
