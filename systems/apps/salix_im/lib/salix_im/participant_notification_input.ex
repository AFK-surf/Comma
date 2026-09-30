defmodule SalixIM.ParticipantNotificationInput do
  @moduledoc "Validates immutable delivery metadata for a participant notification."

  @max_delivery_mentions 100
  @max_mention_name_graphemes 100
  @user_id_pattern ~r/\A[A-Za-z0-9_:-]{1,160}\z/

  def validate(attrs) when is_map(attrs) do
    attrs = string_keys(attrs)

    with {:ok, metadata} <- metadata(attrs["metadata"]),
         false <- Map.has_key?(metadata, "delivery_mentions"),
         {:ok, mentions} <- mentions(attrs["mentions"]) do
      metadata =
        if is_nil(mentions),
          do: metadata,
          else: Map.put(metadata, "delivery_mentions", mentions)

      {:ok, attrs |> Map.delete("mentions") |> Map.put("metadata", metadata)}
    else
      true -> {:error, {:bad_request, "message metadata contains reserved delivery_mentions"}}
      {:error, _reason} = error -> error
    end
  end

  defp metadata(nil), do: {:ok, %{}}
  defp metadata(value) when is_map(value), do: {:ok, string_keys(value)}
  defp metadata(_value), do: {:error, {:bad_request, "invalid message metadata"}}

  defp mentions(nil), do: {:ok, nil}
  defp mentions(%{"mode" => "none", "users" => []}), do: {:ok, %{"mode" => "none", "users" => []}}

  defp mentions(%{"mode" => "users", "users" => users})
       when is_list(users) and length(users) <= @max_delivery_mentions do
    ids = Enum.map(users, &trim(&1["user_id"]))

    if Enum.all?(users, &valid_mention?/1) and length(ids) == length(Enum.uniq(ids)) do
      {:ok,
       %{
         "mode" => "users",
         "users" =>
           Enum.map(users, &%{"user_id" => trim(&1["user_id"]), "name" => trim(&1["name"])})
       }}
    else
      {:error, {:bad_request, "invalid or duplicate message mentions"}}
    end
  end

  defp mentions(_mentions), do: {:error, {:bad_request, "invalid message mentions"}}

  defp valid_mention?(%{"user_id" => user_id, "name" => name}) do
    user_id = trim(user_id)
    name = trim(name)

    Regex.match?(@user_id_pattern, user_id) and name != "" and
      String.length(name) <= @max_mention_name_graphemes
  end

  defp valid_mention?(_mention), do: false

  defp string_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
