defmodule Comma.SkillMentions do
  @moduledoc """
  Server-authored skill activation protocol for chat messages.

  The client submits only skill locations. The actual protocol block is built
  from the server-side catalog so spoofed client names or instructions never
  enter the machine-authored section.
  """

  @protocol_marker "[[comma-protocol]]"
  @max_mentions 10

  def protocol_marker, do: @protocol_marker

  def compose(content, workspace, skills_param)
  def compose(content, _workspace, nil), do: escape_user_content(content)
  def compose(content, _workspace, []), do: escape_user_content(content)

  def compose(content, workspace, skills_param)
      when is_binary(content) and is_list(skills_param) do
    content = escape_user_content(content)

    case admitted(workspace, skills_param) do
      [] -> content
      skills -> content <> "\n\n" <> @protocol_marker <> "\n" <> instructions(skills)
    end
  end

  def compose(content, _workspace, _malformed), do: escape_user_content(content)

  defp escape_user_content(content) when is_binary(content) do
    String.replace(content, @protocol_marker, "[[comma-protocol-user]]")
  end

  defp escape_user_content(content), do: content

  defp admitted(workspace, entries) do
    with {:ok, loaded} <- Comma.Skills.list_for_workspace(workspace) do
      entries
      |> Enum.flat_map(fn
        %{"location" => location} when is_binary(location) -> [location]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.take(@max_mentions)
      |> Enum.flat_map(fn location ->
        case Enum.find(loaded, &(&1["location"] == location)) do
          nil -> []
          skill -> [skill]
        end
      end)
    else
      _ -> []
    end
  end

  defp instructions(skills) do
    lines = Enum.map_join(skills, "\n", &"- #{&1["name"]} — #{&1["location"]}")

    "The user tagged these skills for this message. Activate each one now: " <>
      "read the SKILL.md at the given location and follow it while doing the work:\n" <>
      lines
  end
end
