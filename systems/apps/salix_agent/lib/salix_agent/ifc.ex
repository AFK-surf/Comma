defmodule SalixAgent.IFC do
  @moduledoc """
  Information-flow integrity for the shared Router session
  (`docs/verification.md`).

  The decision itself is `SalixIFC.decide/4`, a pure function in the
  dependency-free `salix_ifc` app. Everything in this namespace is the impure
  half around it: resolving the facts it reads, resolving an effect's
  destination, carrying the model's declaration, archiving the verdict, and
  turning a denial into something a person can read.

  Nothing here compares labels. `SalixAgent.IFC.Check` gathers inputs, calls
  the kernel once per effect, and acts on the answer.

  ## The facts seam

  Labels are provider facts, and `salix_agent` deliberately does not depend on
  `salix_im`. One runtime seam supplies them, the same way `im_provider_mod`
  supplies provider operations:

      config :salix_agent, ifc_facts_mod: SalixIM.IFC.Facts

  With no seam configured every Group is `off` and no call site changes
  behaviour, which is what an unmigrated deployment and most test suites want.

  ## Modes

    * `:off` — no decision is made at all; the resolver is not even asked for
      facts beyond the mode.
    * `:audit` — the decision runs and is archived; the effect executes
      regardless. This is how a Group measures would-be denials before anyone
      is blocked.
    * `:enforce` — a denied effect becomes a `guidance` result and never
      reaches `Tools.execute/2`.
  """

  @modes %{"off" => :off, "audit" => :audit, "enforce" => :enforce}
  @languages %{"zh" => :zh, "en" => :en}

  @typedoc "The language the runtime composes its own user-facing sentences in."
  @type language :: :zh | :en

  @doc """
  Facts for one decision.

  The request names what the decision will touch, so the resolver can answer
  with one bounded projection read instead of a workspace-wide scan:

      %{
        "tenant_id" => …, "group_id" => …,
        "atoms" => [encoded audience atom],   # destination, sources, source scope
        "principals" => [encoded principal],  # the requester
        "now" => system_time_ms
      }

  The reply is the wire shape `SalixIFC.Codec.decode_facts/1` reads, plus
  `"mode"` and an optional `"display_names"` map used only for the
  user-facing sentence of rule A.
  """
  @callback resolve(request :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  This Group's mode, read once per activation rather than once per effect.

  The dispatch context carries the answer, so a resolver outage cannot
  silently downgrade an enforced Group to no enforcement at all: the mode is
  already known when the per-effect facts call fails.
  """
  @callback mode(tenant_id :: String.t(), group_id :: String.t()) :: String.t() | atom()

  @doc """
  Spends one declassification receipt, answering whether this caller is the
  one that spent it.

  A person confirms one transfer, so the receipt authorizes one effect. The
  decision that read the receipt is pure and cannot spend it; the caller does,
  between the verdict and the effect, and `{:ok, false}` means someone else
  already had it.
  """
  @callback consume_receipt(request :: map()) :: {:ok, boolean()} | {:error, term()}

  @doc "Asks the configured seam for facts; `off` when none is configured."
  @spec resolve(map()) :: {:ok, map()} | {:error, term()}
  def resolve(request) when is_map(request) do
    case facts_mod() do
      nil -> {:ok, %{"mode" => "off"}}
      mod -> mod.resolve(request)
    end
  end

  @doc """
  Spends one receipt through the configured seam.

  Fails closed everywhere it cannot get a definite yes: with no seam, with a
  seam that predates this callback, or with a store that cannot answer, the
  effect that wanted the receipt does not get it.
  """
  @spec consume_receipt(map()) :: {:ok, boolean()} | {:error, term()}
  def consume_receipt(request) when is_map(request) do
    case facts_mod() do
      nil ->
        {:error, :unavailable}

      mod ->
        if function_exported?(mod, :consume_receipt, 1),
          do: mod.consume_receipt(request),
          else: {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  @doc """
  The mode a dispatch context should carry. Total: an unconfigured seam, an
  unknown Group, or a resolver fault all read as `:off`, because a Group that
  has not opted in must never be blocked by this design.
  """
  @spec mode_for(String.t() | nil, String.t() | nil) :: :off | :audit | :enforce
  def mode_for(tenant_id, group_id) do
    with mod when not is_nil(mod) <- facts_mod(),
         true <- text(group_id) != "" do
      mode(mod.mode(text(tenant_id), text(group_id)))
    else
      _other -> :off
    end
  rescue
    _ -> :off
  catch
    _kind, _reason -> :off
  end

  @doc """
  Whether a streaming reply draft may reach its audience before this round's
  effects have been decided.

  A draft is published while the model is still writing, so it necessarily
  precedes the declaration the check reads: nothing has authorized it yet. The
  refusal that would stop the completed send arrives after the text has been
  seen, and clearing a draft does not unsee it — so under `enforce` the draft
  waits and the reply appears once it is allowed. `audit` streams as before,
  because audit may never change what happens, and `off` is untouched.
  """
  @spec draft_before_decision?(term()) :: boolean()
  def draft_before_decision?(mode), do: mode(mode) != :enforce

  @doc """
  The sealed origin one schedule fire delivers with, or `nil` when the
  schedule carries no authority of its own (§8).

  A fire acts with its creator's authority: the principal is
  `{:schedule, id, creator}`, which the kernel keys by the creator, so every
  effect the fire causes is decided against the creator's *current* membership
  rather than against whatever was true when the schedule was made. The
  schedule id rides alongside so a decision, and its archive row, can say which
  schedule acted.

  `creator` and `label` are what `SalixAgent.IFC.Check` established while
  deciding the `schedule.create` that made it; without an allow verdict the
  creator is the person who asked and there is no label
  (`unchecked_creator/1`). A schedule nobody asked for, or one made before
  creators were recorded this way, has no creator: its fire delivers unsealed
  and authorizes nothing, which is the fail-closed reading.
  """
  @spec schedule_origin(term(), term(), term()) :: map() | nil
  def schedule_origin(schedule_id, creator, label) do
    id = text(schedule_id)

    with false <- id == "",
         true <- is_binary(creator),
         {:ok, decoded} <- SalixIFC.Codec.decode_principal(creator),
         {:ok, principal} <- SalixIFC.Codec.encode_principal({:schedule, id, decoded}) do
      block =
        %{"integrity" => "command", "principal" => principal}
        |> then(&if(is_list(label), do: Map.put(&1, "label", label), else: &1))

      %{"provider" => "schedule", "schedule_id" => id, "ifc" => block}
    else
      _no_authority -> nil
    end
  end

  @doc """
  The sealed origin of a background Loop notification or host call.

  A Loop acts with its creator's authority, exactly as a schedule fire does
  (§8): the principal is the kernel's delegated-principal wrapper
  `{:schedule, "loop:" <> loop_id, creator}`, keyed by the creator, so every
  effect the Loop causes is decided against the creator's *current*
  membership. The `loop:` prefix on the wrapper id says which Loop acted; the
  wrapper itself is the one the verified kernel already accepts, so no new
  principal kind is introduced.

  `creator` and `label` are what `SalixAgent.IFC.Check` established while
  deciding the `loop.create` that made it, or the person who asked with no
  label when there was no allow verdict (`unchecked_creator/1`). A Loop with no
  creator delivers unsealed and authorizes nothing, which is the fail-closed
  reading.
  """
  @spec loop_origin(term(), term(), term()) :: map() | nil
  def loop_origin(loop_id, creator, label) do
    id = text(loop_id)

    with false <- id == "",
         true <- is_binary(creator),
         {:ok, decoded} <- SalixIFC.Codec.decode_principal(creator),
         {:ok, principal} <- SalixIFC.Codec.encode_principal({:schedule, "loop:" <> id, decoded}) do
      block =
        %{"integrity" => "command", "principal" => principal}
        |> then(&if(is_list(label), do: Map.put(&1, "label", label), else: &1))

      %{"provider" => "loop", "loop_id" => id, "ifc" => block}
    else
      _no_authority -> nil
    end
  end

  @doc """
  The sealed origin of a registry tool call a Task's own station makes
  (`SalixAgent.StationToolCalls`).

  The station acts with the authority of the person whose Task it is, as a
  schedule fire acts with its creator's (§8): the principal is the kernel's
  delegated-principal wrapper `{:schedule, "station:" <> device_id, person}`,
  keyed by the requester (a Comma user id, or the person's principal), so every effect is
  decided against that person's *current* membership, and the `station:` id
  says which station acted. The origin says `provider: "schedule"`, the one
  form the kernel reads a sealed principal from with no Session item behind
  it (`originPrincipal`); no new provider or principal kind is introduced. A
  Worker is never the principal: an agent's id does not command effects
  (§3.1). `label` is the Task conversation's own audience, so what the call
  produces is labelled as the Task's. Nothing without a device and a
  requester, which the fail-closed reading authorizes nothing.
  """
  @spec station_origin(term(), term(), term()) :: map() | nil
  def station_origin(device_id, requester, label) do
    device = text(device_id)
    id = "station:" <> device

    with false <- device == "",
         {:ok, person} <- station_person(requester),
         {:ok, principal} <- SalixIFC.Codec.encode_principal({:schedule, id, person}) do
      block =
        %{"integrity" => "command", "principal" => principal}
        |> then(&if(is_list(label) and label != [], do: Map.put(&1, "label", label), else: &1))

      %{"provider" => "schedule", "schedule_id" => id, "device_id" => device, "ifc" => block}
    else
      _no_authority -> nil
    end
  end

  # A Comma user id, or a person's principal: a provider user is the requester
  # of a Task asked for in a provider chat (`ifc_requester`).
  defp station_person({:comma_user, user} = person) when is_binary(user) and user != "",
    do: {:ok, person}

  defp station_person({:provider_user, connect, user} = person)
       when is_binary(connect) and connect != "" and is_binary(user) and user != "",
       do: {:ok, person}

  defp station_person(user) when is_binary(user) do
    case text(user) do
      "" -> :error
      user -> {:ok, {:comma_user, user}}
    end
  end

  defp station_person(_requester), do: :error

  @doc """
  Who a schedule or Loop made without an allow verdict acts for, encoded, or
  `nil` when nobody asked.

  Under `audit` a denied effect still runs and keeps its activation's
  requester (`ifc_requester`); with the check `off` the sealed origin still
  names the person who asked. Either is the creator, as an allow verdict's
  requester would be, so the schedule keeps working when its Group later
  enforces (§8). No label comes with it: a fire without one reads as
  `agent_private`, so the creator's authority never makes the prompt itself
  readable to anyone.
  """
  @spec unchecked_creator(term()) :: String.t() | nil
  def unchecked_creator(%{} = ctx) do
    case text(value(ctx, "ifc_requester")) do
      "" -> origin_person(value(ctx, "trusted_origin"))
      requester -> requester
    end
  end

  def unchecked_creator(_ctx), do: nil

  defp origin_person(%{} = origin) do
    case origin |> principal() |> origin_person_principal() do
      nil -> nil
      person -> SalixIFC.Codec.encode_principal!(person)
    end
  end

  defp origin_person(_origin), do: nil

  defp origin_person_principal({:comma_user, _user} = person), do: person
  defp origin_person_principal({:provider_user, _connect, _user} = person), do: person
  defp origin_person_principal({:schedule, _id, inner}), do: origin_person_principal(inner)
  defp origin_person_principal(_principal), do: nil

  @doc false
  def facts_mod, do: SystemsRuntime.get_env(:salix_agent, :ifc_facts_mod)

  @doc "Reads a mode out of a resolver reply or a group record."
  @spec mode(term()) :: :off | :audit | :enforce
  def mode(%{} = reply), do: mode(reply["mode"] || reply[:mode])
  def mode(value) when is_binary(value), do: Map.get(@modes, value, :off)
  def mode(value) when value in [:off, :audit, :enforce], do: value
  def mode(_value), do: :off

  @doc """
  The language the runtime composes its own user-facing sentences in — rule
  A's refusal summary, rule B's provenance footer, the confirmation card (§6.4).

  Those sentences are written by the runtime rather than by the model, so they
  cannot follow the model's instruction to answer in the asker's language: a
  workspace that works in English would get a Chinese sentence at exactly the
  moment it needs to be understood. The Group says which one it wants.

  Chinese by default, because that is what every existing workspace has been
  getting and a default that changes what people already read would be a
  regression dressed as a feature.
  """
  @spec language(term()) :: :zh | :en
  def language(%{} = reply), do: language(reply["language"] || reply[:language])
  def language(value) when is_binary(value), do: Map.get(@languages, text(value), :zh)
  def language(value) when value in [:zh, :en], do: value
  def language(_value), do: :zh

  @doc "The language tags a Group may be set to."
  @spec languages() :: [String.t()]
  def languages, do: Map.keys(@languages)

  @doc """
  The `src:` ref of one staged input. Inputs are cited by the id the session
  already gives them, so a ref is stable for the life of the transcript.
  """
  @spec input_ref(term()) :: String.t() | nil
  def input_ref(message_id), do: prefixed_ref("src:q-", message_id)

  @doc "The `src:` ref of one tool result."
  @spec result_ref(term()) :: String.t() | nil
  def result_ref(tool_call_id), do: prefixed_ref("src:t-", tool_call_id)

  @doc "The `src:` ref of one item inside a list-shaped tool result."
  @spec result_item_ref(term(), non_neg_integer()) :: String.t() | nil
  def result_item_ref(tool_call_id, index) when is_integer(index) and index >= 0 do
    case result_ref(tool_call_id) do
      nil -> nil
      ref -> ref <> "#" <> Integer.to_string(index)
    end
  end

  @doc "The `src:` ref of one assistant record."
  @spec assistant_ref(term()) :: String.t() | nil
  def assistant_ref(message_id), do: prefixed_ref("src:a-", message_id)

  @doc """
  The principal a sealed `trusted_origin` names, or `nil`.

  Provider identity is the only human principal in this model: a Bridge For
  Teams login configures labels and never reads or writes through the kernel
  (§3.1), so no BFT account appears here.
  """
  @spec principal(term()) :: SalixIFC.Principal.t() | nil
  def principal(%{} = trusted_origin) do
    ref = value(trusted_origin, "principal_ref")

    cond do
      is_map(ref) ->
        connect = ref |> value("connect_id") |> text()
        subject = ref |> value("subject_id") |> text()

        cond do
          connect != "" and subject != "" -> {:provider_user, connect, subject}
          subject != "" -> {:comma_user, subject}
          true -> nil
        end

      # A schedule fire. Its principal was sealed onto the delivery by
      # `schedule_origin/3` from what the creating activation established, so
      # it is read back rather than reconstructed — nothing at fire time knows
      # who asked for the schedule (§8).
      text(value(trusted_origin, "provider")) in ["schedule", "loop"] ->
        sealed_principal(trusted_origin)

      text(value(trusted_origin, "provider")) == "internal" and
          (is_map(value(trusted_origin, "meeting_preparation")) or
             is_map(value(trusted_origin, "triage_investigation"))) ->
        # Organization commands retain their sealed assigned-agent identity.
        # Command integrity alone does not make a Task participant a person.
        case sealed_principal(trusted_origin) do
          {:agent, _} = principal -> principal
          _ -> nil
        end

      text(value(trusted_origin, "provider")) == "internal" ->
        # A participant id names whoever the delivery came from, agents and
        # system posts included. It is a human principal only when the
        # delivery itself says a person authored it; manufacturing one from a
        # worker's id would hand an agent the authority to command effects
        # (§3.1, §3.4).
        if human_authored?(trusted_origin) do
          case text(value(trusted_origin, "participant_id")) do
            "" -> nil
            participant -> {:comma_user, participant}
          end
        end

      true ->
        nil
    end
  end

  def principal(_trusted_origin), do: nil

  defp sealed_principal(trusted_origin) do
    ifc = value(trusted_origin, "ifc") || %{}

    case SalixIFC.Codec.decode_principal(text(value(ifc, "principal"))) do
      {:ok, principal} -> principal
      :error -> nil
    end
  end

  @doc """
  The delivery's own account of who authored it: the integrity class ingress
  sealed when it labelled the message, and the actor type it came in with
  when there is no sealed block. Anything else — an agent, a system post, a
  delivery that says nothing — is not a person.
  """
  def human_authored?(trusted_origin) when is_map(trusted_origin) do
    case value(trusted_origin, "ifc") do
      %{} = ifc when is_map_key(ifc, "integrity") ->
        text(value(ifc, "integrity")) == "command"

      _absent ->
        text(value(trusted_origin, "source_actor_type")) in ["user", "provider_user"]
    end
  end

  def human_authored?(_trusted_origin), do: false

  @doc false
  def value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, safe_atom(key))
    end
  end

  def value(_map, _key), do: nil

  @doc false
  def text(nil), do: ""
  def text(value) when is_binary(value), do: String.trim(value)
  def text(value), do: value |> to_string() |> String.trim()

  defp prefixed_ref(prefix, id) do
    case text(id) do
      "" -> nil
      id -> prefix <> id
    end
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
