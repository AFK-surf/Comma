defmodule SalixIM.IFC.ConfirmationText do
  @moduledoc """
  Every word a person reads on a declassification card
  (`docs/verification.md` §6.2, §6.4).

  One module for two surfaces, because the card is the same question whichever
  provider renders it, and because a sentence that has to be exactly right —
  what a confirmation actually grants — should not exist twice.

  The Group says which language it is written in: the card is composed by the
  runtime, not by the model, so it cannot follow the model's instruction to
  answer in the asker's language. Chinese unless the Group says otherwise,
  which is what every existing workspace already reads.
  """

  @languages %{"zh" => :zh, "en" => :en}

  @doc "The language one request's card is written in."
  @spec language(map()) :: :zh | :en
  def language(payload) when is_map(payload),
    do: Map.get(@languages, text(payload["language"]), :zh)

  def language(_payload), do: :zh

  @doc "The card's title."
  @spec title(:zh | :en) :: String.t()
  def title(:en), do: "Confirm the transfer"
  def title(_zh), do: "确认转发"

  @doc "The button that approves, and the button that does not."
  @spec approve_label(:zh | :en) :: String.t()
  def approve_label(:en), do: "Confirm"
  def approve_label(_zh), do: "确认"

  @spec deny_label(:zh | :en) :: String.t()
  def deny_label(:en), do: "Cancel"
  def deny_label(_zh), do: "取消"

  @doc """
  The Router's one-sentence account of what it wants to carry, or a neutral
  stand-in when it wrote none. Never the content itself.
  """
  @spec summary(map()) :: String.t()
  def summary(payload) do
    case text(is_map(payload) && payload["summary"]) do
      "" -> default_summary(language(payload))
      summary -> summary
    end
  end

  defp default_summary(:en), do: "Carry this information to another place."
  defp default_summary(_zh), do: "把这部分信息带到另一个位置。"

  @doc """
  Where it came from and where it would go, by display name. Never the
  content: the person asking already has that, and the card would otherwise
  copy it into a second conversation on its own.

  What the person is told must be what they actually grant. The receipt is
  scoped to an audience pair, not to this particular text: it authorizes one
  transfer, and any one transfer between those two places counts. Saying only
  "just this once" would read as a promise about *this message*, which is not
  what is stored (§6.2).
  """
  @spec flow_line(map()) :: String.t()
  def flow_line(payload) do
    language = language(payload)
    from = names(payload["source_names"], language) || unknown_source(language)
    to = names(payload["destination_names"], language) || unknown_destination(language)

    flow_sentence(language, from, to)
  end

  defp flow_sentence(:en, from, to) do
    "From #{from} → to #{to}. Confirming releases one transfer, and expires unused after an hour; " <>
      "what it releases is a transfer between those two places, not this particular text."
  end

  defp flow_sentence(_zh, from, to) do
    "来自 #{from} → 发往 #{to}。确认后只放行一次转发，一小时内未使用即失效；" <>
      "这一次放行针对的是这两个位置之间的传递，不限定于上面这段内容。"
  end

  defp unknown_source(:en), do: "another conversation"
  defp unknown_source(_zh), do: "另一处对话"

  defp unknown_destination(:en), do: "that destination"
  defp unknown_destination(_zh), do: "该目的地"

  @doc "What the card becomes once it has been answered."
  @spec settled(map(), boolean()) :: String.t()
  def settled(payload, approved?) do
    case {language(payload), approved?} do
      {:en, true} -> "Transfer confirmed: #{summary(payload)}"
      {:en, false} -> "Cancelled, nothing was carried over: #{summary(payload)}"
      {_zh, true} -> "已确认转发：#{summary(payload)}"
      {_zh, false} -> "已取消，未转发：#{summary(payload)}"
    end
  end

  @doc "The one-word acknowledgement a provider shows on the press itself."
  @spec toast(map(), boolean()) :: String.t()
  def toast(payload, approved?) do
    case {language(payload), approved?} do
      {:en, true} -> "Confirmed"
      {:en, false} -> "Cancelled"
      {_zh, true} -> "已确认"
      {_zh, false} -> "已取消"
    end
  end

  @doc "The notification line a surface shows before the card renders."
  @spec fallback(map()) :: String.t()
  def fallback(payload) do
    case language(payload) do
      :en -> "Confirm the transfer: " <> summary(payload)
      _zh -> "确认转发：" <> summary(payload)
    end
  end

  @doc "Several display names as one phrase, in this language's list style."
  @spec names(term(), :zh | :en) :: String.t() | nil
  def names(values, language) when is_list(values) do
    case values |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq() do
      [] -> nil
      names -> Enum.join(names, if(language == :en, do: ", ", else: "、"))
    end
  end

  def names(_values, _language), do: nil

  defp text(nil), do: ""
  defp text(false), do: ""
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value), do: value |> to_string() |> String.trim()
end
