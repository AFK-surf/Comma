defmodule Salix.Bindings.MeetingSpeakerAlignmentTest do
  use SystemsClock.Case, async: true

  alias Salix.Bindings.MeetingSpeakerAlignment, as: A

  # Phrases said more than once match an earlier caption too. Those votes
  # scatter, so the offset follows the largest cluster, not their median.
  test "repeated phrases elsewhere in the meeting do not move the offset" do
    repeated = ["好的好的我们继续往下", "对对对就是这个意思", "那我先说一下我这边", "可以可以没有问题的"]

    earlier =
      repeated
      |> Enum.with_index()
      |> Enum.map(fn {text, i} -> caption("Early Bird", text, 380 + 40 * i) end)

    captions =
      earlier ++
        [
          caption("Rui Ren", "现在一共有869个注册账户", 1_010),
          caption("Heyang Zhou", "这得做一下可以加一个指标", 1_020),
          caption("JINFEI YANG", "我这边有几件事token数据开放", 1_030)
        ] ++
        (repeated
         |> Enum.with_index()
         |> Enum.map(fn {text, i} -> caption("Zijian Zuo", text, 1_040 + 10 * i) end))

    asr =
      Enum.join(
        [
          "[00:00:10] Speaker 1: 现在一共有 869 个注册账户。",
          "[00:00:20] Speaker 2: 这得做一下，可以加一个指标。",
          "[00:00:30] Unknown: 我这边有几件事，token 数据开放。"
        ] ++
          (repeated
           |> Enum.with_index()
           |> Enum.map(fn {text, i} -> "[#{clock(40 + 10 * i)}] Unknown: #{text}" end)),
        "\n"
      )

    assert {:ok, aligned} = A.align(asr, captions)

    assert aligned |> String.split("\n") |> Enum.map(&speaker/1) ==
             ["Rui Ren", "Heyang Zhou", "JINFEI YANG"] ++ List.duplicate("Zijian Zuo", 4)
  end

  defp caption(speaker, text, at), do: %{"speaker" => speaker, "text" => text, "timestamp" => at}

  defp clock(seconds),
    do: "00:" <> pad(div(seconds, 60)) <> ":" <> pad(rem(seconds, 60))

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp speaker(line),
    do: line |> String.split(" ", parts: 2) |> List.last() |> String.split(":") |> hd()
end
