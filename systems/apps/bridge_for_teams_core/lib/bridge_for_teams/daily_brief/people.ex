defmodule BridgeForTeams.DailyBrief.People do
  @moduledoc """
  The people of one pass, as the model sees them: each actor ref gets a short
  label (`@Alice`), the same in item authors, mentions in text, and follow-up
  owners. The model answers with labels, and only labels from this table map
  back to an actor ref and a member.

  A member's label is their first name alias; anyone else's is the name
  Slack shows for them, or else the id part of their ref. Labels are unique
  within the pass.
  """

  alias BridgeForTeams.Schema.DailyBriefMember
  alias BridgeForTeams.DailyBrief.ActorRef

  defstruct by_ref: %{}, by_label: %{}

  @type t :: %__MODULE__{
          by_ref: %{ActorRef.t() => String.t()},
          by_label: %{String.t() => {ActorRef.t(), Ecto.UUID.t() | nil}}
        }

  @doc "A table of the members, then of `refs` in order; `names` are known names by ref."
  @spec build([DailyBriefMember.t()], [ActorRef.t() | nil], %{ActorRef.t() => String.t()}) :: t()
  def build(members, refs, names \\ %{}) do
    table =
      Enum.reduce(members, %__MODULE__{}, fn member, table ->
        add(table, ActorRef.slack(member.slack_user_id), member_name(member), member.id)
      end)

    refs
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(table, fn ref, table -> add(table, ref, name(names, ref), nil) end)
  end

  @doc "The label of a ref in the table, or `nil`."
  @spec label(t(), ActorRef.t() | nil) :: String.t() | nil
  def label(%__MODULE__{by_ref: by_ref}, ref), do: Map.get(by_ref, ref)

  @doc """
  The actor ref and member of a label the model returned, or `{nil, nil}`.
  A label without its `@` still matches.
  """
  @spec resolve(t(), term()) :: {ActorRef.t() | nil, Ecto.UUID.t() | nil}
  def resolve(%__MODULE__{by_label: by_label}, "@" <> _ = label),
    do: Map.get(by_label, String.trim(label), {nil, nil})

  # A model that echoes a source's own mention still names someone in the table.
  def resolve(%__MODULE__{by_ref: by_ref} = table, "<@" <> _ = mention) do
    case Regex.run(~r/^<@([UW][A-Z0-9]{2,32})(?:\|[^>]*)?>$/, String.trim(mention)) do
      [_, id] -> resolve(table, Map.get(by_ref, ActorRef.slack(id), ""))
      nil -> {nil, nil}
    end
  end

  def resolve(table, label) when is_binary(label) and label != "",
    do: resolve(table, "@" <> String.trim(label))

  def resolve(_table, _label), do: {nil, nil}

  defp add(%__MODULE__{} = table, nil, _name, _member_id), do: table

  defp add(%__MODULE__{by_ref: by_ref} = table, ref, _name, _member_id)
       when is_map_key(by_ref, ref),
       do: table

  defp add(%__MODULE__{} = table, ref, name, member_id) do
    label = unique(table, "@" <> name, 1)

    %{
      table
      | by_ref: Map.put(table.by_ref, ref, label),
        by_label: Map.put(table.by_label, label, {ref, member_id})
    }
  end

  defp unique(table, base, 1) do
    if Map.has_key?(table.by_label, base), do: unique(table, base, 2), else: base
  end

  defp unique(table, base, n) do
    label = "#{base}-#{n}"
    if Map.has_key?(table.by_label, label), do: unique(table, base, n + 1), else: label
  end

  defp member_name(%DailyBriefMember{aliases: aliases} = member) when is_list(aliases) do
    names =
      for %{kind: kind, term: term} <- aliases,
          kind in ["name", "handle"],
          name = clean(term),
          name != "",
          do: name

    case names do
      [name | _] -> name
      [] -> member.slack_user_id
    end
  end

  defp member_name(member), do: member.slack_user_id

  defp name(names, ref) do
    case clean(Map.get(names, ref) || "") do
      "" -> plain(ref)
      name -> name
    end
  end

  defp plain(ref) do
    case String.split(ref, ":", parts: 2) do
      [_source, id] -> id
      _ -> ref
    end
  end

  # A label is one short token: no spaces, `@`, `<`, or `>`.
  defp clean(name),
    do: name |> String.replace(~r/[\s@<>]+/u, "_") |> String.trim("_") |> String.slice(0, 32)
end
