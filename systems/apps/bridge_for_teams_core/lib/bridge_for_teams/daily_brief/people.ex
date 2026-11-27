defmodule BridgeForTeams.DailyBrief.People do
  @moduledoc """
  The people of one pass, as the model sees them: each actor ref gets a short
  label (`@Alice`), the same in item authors, mentions in text, and follow-up
  owners. The model answers with labels, and only labels from this table map
  back to an actor ref and a member.

  A member's label is their first name alias; anyone else's is the name
  Slack, Feishu, or Lark shows for them, or else the id part of their ref. Labels are unique
  within the pass.
  """

  alias BridgeForTeams.Schema.DailyBriefMember
  alias BridgeForTeams.DailyBrief.ActorRef

  defstruct by_ref: %{}, by_label: %{}, unmentionable: MapSet.new()

  @type t :: %__MODULE__{
          by_ref: %{ActorRef.t() => String.t()},
          by_label: %{String.t() => {ActorRef.t(), Ecto.UUID.t() | nil}},
          unmentionable: MapSet.t(ActorRef.t())
        }

  @doc """
  A table of the members, then of `refs` in order; `names` are known names by
  ref. A member's label maps back to their ref in `app_id`, the Feishu or Lark
  app whose bot sends the brief (their own ref without one). Their open ids
  in other apps (messages read through another Swarm's bot) carry the same
  label. `unmentionable` names external refs that cannot be `@`-mentioned in
  `app_id`; a Feishu or Lark member without an open id in `app_id` is marked
  unmentionable automatically.
  """
  @spec build(
          [DailyBriefMember.t()],
          [ActorRef.t() | nil],
          %{ActorRef.t() => String.t()},
          String.t() | nil,
          Enumerable.t()
        ) :: t()
  def build(members, refs, names \\ %{}, app_id \\ nil, unmentionable \\ []) do
    table =
      Enum.reduce(members, %__MODULE__{}, fn member, table ->
        primary = ActorRef.member_ref(member, app_id)
        table = add(table, primary, member_name(member), member.id)

        table =
          if is_binary(app_id) and Map.get(member, :provider) in ["feishu", "lark"] and
               is_nil(ActorRef.member_actor_id(member, app_id)) and is_binary(primary) do
            %{table | unmentionable: MapSet.put(table.unmentionable, primary)}
          else
            table
          end

        case label(table, primary) do
          nil ->
            table

          label ->
            member
            |> ActorRef.member_all_refs()
            |> Enum.reduce(table, fn ref, table ->
              %{table | by_ref: Map.put_new(table.by_ref, ref, label)}
            end)
        end
      end)

    table =
      refs
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(table, fn ref, table -> add(table, ref, name(names, ref), nil) end)

    extra_unmentionable = MapSet.new(unmentionable)

    if MapSet.size(extra_unmentionable) == 0 do
      table
    else
      %{table | unmentionable: MapSet.union(table.unmentionable, extra_unmentionable)}
    end
  end

  @doc "Whether `ref` may be written as a native `@`-mention in the sending app."
  @spec mentionable?(t(), ActorRef.t() | nil) :: boolean()
  def mentionable?(%__MODULE__{unmentionable: unmentionable}, ref),
    do: not MapSet.member?(unmentionable, ref)

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
      [_, id] ->
        resolve(table, Map.get(by_ref, ActorRef.slack(id), ""))

      nil ->
        case Regex.run(~r/^<@(ou_[A-Za-z0-9_-]{2,64})>$/, String.trim(mention)) do
          [_, id] ->
            label =
              Map.get(by_ref, ActorRef.feishu(id)) || Map.get(by_ref, ActorRef.lark(id)) || ""

            resolve(table, label)

          nil ->
            {nil, nil}
        end
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
      [] -> ActorRef.member_actor_id(member)
    end
  end

  defp member_name(member), do: ActorRef.member_actor_id(member)

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
