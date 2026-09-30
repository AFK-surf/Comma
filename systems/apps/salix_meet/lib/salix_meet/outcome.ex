defmodule SalixMeet.Outcome do
  @moduledoc """
  Provider-confirmed meeting endings. Never infer a denial from a timeout or
  transport error. Contract: docs/meetings-calendar.md.
  """
  @codes ~w(admission_denied meeting_full removed_from_meeting admission_timeout)
  def normalize(code) when code in @codes, do: code
  def normalize(_), do: nil
  def no_retry?(code), do: code in ~w(admission_denied meeting_full removed_from_meeting)

  def partial_recording?(%{"status" => "failed", "reason_code" => "removed_from_meeting"} = state) do
    Enum.any?(~w(transcript audio), fn kind ->
      path = get_in(state, ["artifacts", kind, "path"])
      is_binary(path) and path != ""
    end)
  end

  def partial_recording?(_state), do: false

  def notice(state) do
    if partial_recording?(state),
      do: "bot 已被移出会议。会议处理失败，以下记录可能不完整。",
      else: text(state["reason_code"])
  end

  def text("admission_denied"), do: "入会请求被拒绝。"
  def text("meeting_full"), do: "会议已满，无法加入。"
  def text("removed_from_meeting"), do: "bot 已被移出会议。"
  def text("admission_timeout"), do: "等待准入超时。"
  def text(_), do: nil
end
