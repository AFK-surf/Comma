defmodule SalixVoice.RouterPersona do
  @moduledoc """
  A call that speaks as the Group's Router (docs/messaging-voice.md#router-calls).

  When the Group turned on Router calls, the voice model takes the Router's
  identity instead of the fixed Comma voice: its name, its own instructions
  (`router_system_prompt` without the shared prompt it may start with: the
  persona a person set or imported), its notes
  about the user (`/memory/semantic/user.md`) and the newest user and
  assistant texts of its canonical session, which open the voice session as
  history. Requests that need tools still go to the Router as delegations.

  The notes and history pass the same confidentiality check as the Router's
  own `voice.say` to this call: when the Group's IFC mode is not `off`, a
  message or the notes file is kept only when everyone who can hear the call
  (the one-to-one audience ingress records for the caller) may read its
  label. Unlabelled content reads as agent-private and is left out; a
  resolver failure leaves out both. A Signal group call is not a one-to-one
  and never speaks as the Router (`SalixVoice.CallActor`).

  Bounds: instructions and notes at most 6,000 bytes each; history at most 24
  messages of 1,500 bytes within 10 KiB, newest kept, under GPT-Live's
  8,192-token startup history limit. Nothing is stored.
  """

  require Logger

  alias SalixAgent.{AgentWorkspace, IFC, RouterDecision}
  alias SalixIFC.{Codec, Label}

  @max_persona_bytes 6_000
  @max_notes_bytes 6_000
  @max_messages 24
  @max_history_bytes 10 * 1024
  @notes_path "/memory/semantic/user.md"
  # Workspace provisioning names a Router "<workspace> Router"; every
  # workspace starts as "Default workspace". The clients show the brand for a
  # Router nobody named (`routerDisplayName`); calls do the same.
  @default_prefix ~r/^Default workspace\s+/i
  @brand "Comma"

  @type t :: %{
          name: String.t(),
          persona: String.t() | nil,
          notes: String.t() | nil,
          input: [%{String.t() => String.t()}]
        }

  @typedoc """
  Who hears the call: the voice connect, the caller's id as voice ingress
  records it (`from_user_id`) and the caller's encoded principal, if any.
  """
  @type audience :: %{
          tenant_id: String.t(),
          connect_id: String.t(),
          user_id: String.t(),
          requester: String.t() | nil
        }

  @doc "The Router identity of `group_id`'s calls heard by `audience`, or `{:error, code}`."
  @spec resolve(String.t(), audience()) :: {:ok, t()} | {:error, String.t()}
  def resolve(group_id, audience) do
    with {:ok, agent, session} <- RouterDecision.router(group_id) do
      agent_id = agent["agent_id"]
      messages = RouterDecision.recent_texts(session, @max_messages, labels: true)
      # The label and the body come from one manifest entry, so a later write
      # of the notes cannot pass under the label of an earlier one.
      notes_entry = notes_entry(agent_id)
      notes_label = notes_entry && notes_entry["ifc_label"]
      readable = readable(group_id, audience, [notes_label | Enum.map(messages, & &1["label"])])

      {:ok,
       %{
         name: display_name(agent["name"]),
         persona: agent |> own_instructions() |> cut(@max_persona_bytes),
         notes: if(readable.(notes_label), do: notes(agent_id, notes_entry)),
         input: messages |> Enum.filter(&readable.(&1["label"])) |> history()
       }}
    end
  rescue
    exception ->
      Logger.warning(
        "voice router persona failed group=#{group_id} error=#{inspect(exception.__struct__)}"
      )

      {:error, "router_unavailable"}
  catch
    :exit, _ -> {:error, "router_unavailable"}
  end

  @doc "The name a call introduces itself with."
  @spec display_name(term()) :: String.t()
  def display_name(name) when is_binary(name) do
    name = name |> String.replace(@default_prefix, "") |> String.trim()
    if name == "" or String.downcase(name) == "router", do: @brand, else: name
  end

  def display_name(_name), do: @brand

  @doc """
  The voice session instructions for `persona`. `base_rules` are the call's
  delegation rules, shared with calls that do not speak as the Router.
  """
  @spec instructions(t(), String.t()) :: String.t()
  def instructions(persona, base_rules) do
    [
      "You are #{persona.name}, the caller's own assistant, on a live voice call with them. " <>
        "You are the same assistant they chat with in Comma, not an operator or a separate " <>
        "voice service: speak as #{persona.name} in the first person and keep your " <>
        "personality. When the request you delegate comes back, it is your own work; say it " <>
        "as yours. The history this session starts with is your recent conversation with " <>
        "the caller; continue from it and speak the language they use with you.",
      base_rules,
      section("Your persona and standing instructions, set by the caller", persona.persona),
      section("Your notes about the caller", persona.notes)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc "The greeting instruction for `persona`."
  @spec greeting(t()) :: String.t()
  def greeting(persona) do
    "Greet the caller now as #{persona.name}, in the language of your recent conversation " <>
      "with them, briefly and in your own style. Then pause and listen."
  end

  # The Router's own instructions without the shared prompt they may start
  # with: editing them in Comma starts from the effective prompt
  # (`ToolPolicy.system_prompt/2`), and imports append to it.
  defp own_instructions(agent) do
    own = present(agent["router_system_prompt"])
    shared = present(agent["system_prompt"])

    if own && shared && String.starts_with?(own, shared),
      do: own |> String.replace_prefix(shared, "") |> present(),
      else: own
  end

  defp section(_title, nil), do: nil
  defp section(title, text), do: title <> ":\n" <> text

  defp notes_entry(agent_id) when is_binary(agent_id) do
    case AgentWorkspace.entry(agent_id, @notes_path) do
      {:ok, %{"ref" => _} = entry} -> entry
      _ -> nil
    end
  end

  defp notes_entry(_agent_id), do: nil

  defp notes(agent_id, %{"ref" => ref}) do
    case SalixStore.Blob.get(agent_id, ref) do
      {:ok, body} when is_binary(body) -> body |> present() |> cut(@max_notes_bytes)
      _ -> nil
    end
  end

  defp notes(_agent_id, _entry), do: nil

  # Newest first in; the result is oldest first, without labels, and fits the
  # history bound.
  defp history(messages) do
    messages
    |> Enum.reduce_while({[], 0}, fn message, {kept, size} ->
      size = size + byte_size(message["text"])

      if size > @max_history_bytes,
        do: {:halt, {kept, size}},
        else: {:cont, {[Map.take(message, ["role", "text"]) | kept], size}}
    end)
    |> elem(0)
  end

  # A predicate over stored labels: may everyone who hears the call read
  # content with this label? One facts read covers every label at once. The
  # destination is the caller's one-to-one on the voice connect, the audience
  # voice ingress records for the call.
  defp readable(group_id, audience, labels) do
    request = %{
      "tenant_id" => audience.tenant_id,
      "group_id" => group_id,
      "requester" => audience.requester,
      "destination" => %{
        "kind" => "provider_direct",
        "provider" => "voice",
        "connect_id" => audience.connect_id,
        "user_id" => audience.user_id
      },
      "atoms" => labels |> Enum.flat_map(&Codec.encode_label(label(&1))) |> Enum.uniq(),
      "now" => SystemsClock.system_time(:millisecond)
    }

    case IFC.resolve(request) do
      {:ok, reply} ->
        if IFC.mode(reply) == :off do
          fn _label -> true end
        else
          facts = Codec.decode_facts(reply)
          destination = label(get_in(reply, ["destination", "label"]))
          &(SalixIFC.readers_subset?(destination, label(&1), facts) == true)
        end

      {:error, reason} ->
        Logger.warning(
          "voice router persona ifc facts failed group=#{group_id} reason=#{inspect(reason)}"
        )

        fn _label -> false end
    end
  end

  # How `SalixAgent.IFC.Context` reads a stored label: no label is
  # agent-private, an empty one is public, an unreadable one fails closed.
  defp label([]), do: Label.new([:public])
  defp label(atoms) when is_list(atoms), do: Codec.decode_label(atoms, private())
  defp label(_none), do: private()

  defp private, do: Label.new([:agent_private])

  defp present(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  defp present(_text), do: nil

  defp cut(nil, _max), do: nil
  defp cut(text, max) when byte_size(text) <= max, do: text

  defp cut(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {acc, size} ->
      size = size + byte_size(grapheme)
      if size > max - 3, do: {:halt, {acc, size}}, else: {:cont, {acc <> grapheme, size}}
    end)
    |> elem(0)
    |> Kernel.<>("…")
  end
end
