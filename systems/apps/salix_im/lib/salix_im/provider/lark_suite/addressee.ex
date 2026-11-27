defmodule SalixIM.Provider.LarkSuite.Addressee do
  @moduledoc """
  Stateless Feishu / Lark mention evidence shared by inbound admission.

  Classifies who a message explicitly `@`-mentions from `connect["bot_open_id"]`
  and `message["mentions"]`. Group broadcasts (`@_all` / `all`) are ignored so
  they are never treated as an explicit foreign-only recipient. Thread ownership
  cannot override an explicit foreign-only recipient.
  """

  @doc "Classifies provider IDs in the same identity space."
  @spec classify(String.t(), [String.t()]) :: String.t()
  def classify(self_ref, mentioned_refs) do
    self_ref = trim(self_ref)

    mentioned_refs =
      mentioned_refs
      |> List.wrap()
      |> Enum.map(&trim/1)
      |> Enum.reject(&(&1 == ""))

    mentions_self? = self_ref != "" and self_ref in mentioned_refs
    mentions_other? = Enum.any?(mentioned_refs, &(&1 != self_ref))

    case {mentions_self?, mentions_other?} do
      {true, true} -> "mixed"
      {true, false} -> "self"
      {false, true} -> "other"
      {false, false} -> "none"
    end
  end

  @doc "Classifies a Feishu / Lark message's explicit mentions as `self`, `mixed`, `other`, or `none`."
  @spec for_message(map(), map()) :: String.t()
  def for_message(connect, message) when is_map(connect) and is_map(message) do
    self_ref = trim(connect["bot_open_id"])

    mentioned_refs =
      message["mentions"]
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.reject(&broadcast_mention?/1)
      |> Enum.map(&mention_ref/1)
      |> Enum.reject(&(&1 == ""))

    classify(self_ref, mentioned_refs)
  end

  def for_message(_connect, _message), do: "none"

  @doc "True when the message explicitly mentions this connect's bot."
  @spec mentions_self?(map(), map()) :: boolean()
  def mentions_self?(connect, message), do: for_message(connect, message) in ["self", "mixed"]

  @doc "True when a non-DM message explicitly mentions only other recipients."
  @spec directed_elsewhere?(map(), map()) :: boolean()
  def directed_elsewhere?(connect, message) when is_map(connect) and is_map(message) do
    trim(message["chat_type"]) != "p2p" and for_message(connect, message) == "other"
  end

  def directed_elsewhere?(_connect, _message), do: false

  defp broadcast_mention?(mention) do
    key = mention["key"] |> trim() |> String.downcase()
    ids = map(mention["id"])
    open_id = ids["open_id"] |> trim() |> String.downcase()
    user_id = ids["user_id"] |> trim() |> String.downcase()

    key == "@_all" or open_id == "all" or user_id == "all"
  end

  defp mention_ref(mention) do
    ids = map(mention["id"])

    [ids["open_id"], ids["user_id"], ids["union_id"]]
    |> Enum.map(&trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp map(%{} = value), do: value
  defp map(_other), do: %{}

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_other), do: ""
end
