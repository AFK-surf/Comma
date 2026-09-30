defmodule SalixAgent.SessionHistory.Document do
  @moduledoc "Original-history text selection and identical hot/cold normalization."
  @excluded ~w(history.search history.list history.get)
  @chunk_size 8192
  @overlap 127

  def excluded_tools, do: @excluded

  def fold(text),
    do: text |> String.normalize(:nfkc) |> String.downcase() |> String.normalize(:nfkc)

  def text(%{kind: "message", data: data}) do
    if data["role"] == "tool" and excluded?(data) do
      ""
    else
      calls = Enum.reject(data["tool_calls"] || [], &excluded?/1)

      [plain(data["content"]), if(calls == [], do: "", else: Jason.encode!(calls))]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  def text(%{kind: kind, data: data}) when kind in ["tool_result", "async_result"] do
    if excluded?(data),
      do: "",
      else: plain(data["result_json"] || data["result"] || data["output"])
  end

  def text(_), do: ""

  def documents(record) do
    text(record)
    |> String.replace(<<0>>, "�")
    |> fold()
    |> String.codepoints()
    |> Enum.chunk_every(@chunk_size, @chunk_size - @overlap)
    |> Enum.with_index()
    |> Enum.map(fn {points, part} ->
      %{
        "seq" => record.seq,
        "part" => part,
        "text" => Enum.join(points),
        "kind" => record.kind,
        "tool_name" => record.data["tool_name"] || record.data["name"] || "",
        "label" => get_in(record.data, ["ifc", "label"]) || ["agent_private"]
      }
    end)
  end

  defp excluded?(data) when is_map(data),
    do: (data["tool_name"] || data["name"] || get_in(data, ["function", "name"])) in @excluded

  defp excluded?(_), do: false
  defp plain(nil), do: ""
  defp plain(text) when is_binary(text), do: text
  defp plain(blocks) when is_list(blocks), do: Enum.map_join(blocks, "\n", &block_text/1)
  defp plain(value), do: Jason.encode!(value)
  defp block_text(%{"type" => type}) when type in ["image", "image_url", "audio", "video"], do: ""
  defp block_text(%{"text" => text}) when is_binary(text), do: text
  defp block_text(value), do: plain(value)
end
