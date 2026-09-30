defmodule SalixIFC.Codec do
  @moduledoc """
  The wire form of the kernel's data: JSON-able strings and maps.

  Resolvers live outside this app (provider ingress, the Postgres label
  projection, the dispatcher) and exchange atoms, labels, principals and
  decisions across app boundaries and durable records. Encoding them in one
  pure module keeps every caller reading the same grammar and keeps the
  kernel's structs out of stored payloads.

  Atoms and principals encode as `|`-separated tuples, because provider ids
  (Slack `C…`/`U…`, Feishu `oc_…`/`ou_…`) never contain `|` while they do
  contain almost everything else. An id that would break the grammar is
  refused at encode time rather than round-tripping wrong.

      :public                      "public"
      :agent_private               "agent_private"
      {:space, "w1"}               "space|w1"
      {:scope, "w1", "C1"}         "scope|w1|C1"
      {:tag, "finance"}            "tag|finance"
      {:conversation, "c1"}        "conversation|c1"
      {:group, "g1"}               "group|g1"
      {:task, "c2"}                "task|c2"

      {:provider_user, "w1", "U1"} "provider_user|w1|U1"
      {:comma_user, "u1"}            "comma_user|u1"
      {:agent, "a1"}               "agent|a1"
      :system                      "system"
      {:schedule, "s1", creator}   "schedule|s1|<creator>"
      {:api_key, "gak_1", creator} "api_key|gak_1|<creator>"

  Every decoder is total and returns `:error` rather than raising, because it
  reads data that a resolver, an older binary, or a stored record produced.
  """

  alias SalixIFC.{Evidence, Facts, Label, Policy, Principal, Reason, Receipt}

  @separator "|"

  # ---------------------------------------------------------------------------
  # Atoms
  # ---------------------------------------------------------------------------

  @doc "Encodes one audience atom, or `:error` when it cannot round-trip."
  @spec encode_atom(SalixIFC.Atom.t()) :: {:ok, binary} | :error
  def encode_atom(:public), do: {:ok, "public"}
  def encode_atom(:agent_private), do: {:ok, "agent_private"}
  def encode_atom({:space, c}), do: join(["space", c])
  def encode_atom({:scope, c, id}), do: join(["scope", c, id])
  def encode_atom({:tag, name}), do: join(["tag", name])
  def encode_atom({:conversation, id}), do: join(["conversation", id])
  def encode_atom({:group, id}), do: join(["group", id])
  def encode_atom({:task, id}), do: join(["task", id])
  def encode_atom(_other), do: :error

  @doc "Encodes one audience atom, raising when it cannot round-trip."
  @spec encode_atom!(SalixIFC.Atom.t()) :: binary
  def encode_atom!(atom) do
    case encode_atom(atom) do
      {:ok, encoded} -> encoded
      :error -> raise ArgumentError, "unencodable audience atom #{inspect(atom)}"
    end
  end

  @doc "Decodes one audience atom."
  @spec decode_atom(term) :: {:ok, SalixIFC.Atom.t()} | :error
  def decode_atom(value) when is_binary(value) do
    case String.split(value, @separator) do
      ["public"] -> {:ok, :public}
      ["agent_private"] -> {:ok, :agent_private}
      ["space", c] -> present({:space, c}, [c])
      ["scope", c, id] -> present({:scope, c, id}, [c, id])
      ["tag", name] -> present({:tag, name}, [name])
      ["conversation", id] -> present({:conversation, id}, [id])
      ["group", id] -> present({:group, id}, [id])
      ["task", id] -> present({:task, id}, [id])
      _other -> :error
    end
  end

  def decode_atom(_value), do: :error

  # ---------------------------------------------------------------------------
  # Labels
  # ---------------------------------------------------------------------------

  @doc "Encodes a label as a sorted list of atom strings."
  @spec encode_label(Label.t()) :: [binary]
  def encode_label(%Label{} = label),
    do: label |> Label.atoms() |> Enum.map(&encode_atom!/1) |> Enum.sort()

  @doc """
  Decodes a label. An empty list decodes to `⊥`; any unreadable atom makes
  the whole label unreadable, because a partially decoded label would be
  weaker than the one that was stored.
  """
  @spec decode_label(term) :: {:ok, Label.t()} | :error
  def decode_label(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case decode_atom(value) do
        {:ok, atom} -> {:cont, {:ok, [atom | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, atoms} -> {:ok, Label.new(atoms)}
      :error -> :error
    end
  end

  def decode_label(_values), do: :error

  @doc "Decodes a label, falling back to `default` when it cannot be read."
  @spec decode_label(term, Label.t()) :: Label.t()
  def decode_label(values, %Label{} = default) do
    case decode_label(values) do
      {:ok, label} -> label
      :error -> default
    end
  end

  # ---------------------------------------------------------------------------
  # Principals
  # ---------------------------------------------------------------------------

  @doc "Encodes a principal, or `:error` when it cannot round-trip."
  @spec encode_principal(Principal.t()) :: {:ok, binary} | :error
  def encode_principal(:system), do: {:ok, "system"}
  def encode_principal({:provider_user, c, u}), do: join(["provider_user", c, u])
  def encode_principal({:comma_user, id}), do: join(["comma_user", id])
  def encode_principal({:agent, id}), do: join(["agent", id])

  def encode_principal({:schedule, id, creator}) do
    case encode_principal(creator) do
      {:ok, creator} -> join_tail(["schedule", id], creator)
      :error -> :error
    end
  end

  def encode_principal({:api_key, id, creator}) do
    case encode_principal(creator) do
      {:ok, creator} -> join_tail(["api_key", id], creator)
      :error -> :error
    end
  end

  def encode_principal(_other), do: :error

  @doc "Encodes a principal, raising when it cannot round-trip."
  @spec encode_principal!(Principal.t()) :: binary
  def encode_principal!(principal) do
    case encode_principal(principal) do
      {:ok, encoded} -> encoded
      :error -> raise ArgumentError, "unencodable principal #{inspect(principal)}"
    end
  end

  @doc "Decodes a principal."
  @spec decode_principal(term) :: {:ok, Principal.t()} | :error
  def decode_principal(value) when is_binary(value) do
    case String.split(value, @separator, parts: 3) do
      ["system"] ->
        {:ok, :system}

      ["comma_user", id] ->
        present({:comma_user, id}, [id])

      ["agent", id] ->
        present({:agent, id}, [id])

      ["provider_user", c, u] ->
        present({:provider_user, c, u}, [c, u])

      ["schedule", id, creator] ->
        case decode_principal(creator) do
          {:ok, creator} -> present({:schedule, id, creator}, [id])
          :error -> :error
        end

      ["api_key", id, creator] ->
        case decode_principal(creator) do
          {:ok, creator} -> present({:api_key, id, creator}, [id])
          :error -> :error
        end

      _other ->
        :error
    end
  end

  def decode_principal(_value), do: :error

  # ---------------------------------------------------------------------------
  # Facts
  # ---------------------------------------------------------------------------

  @doc """
  Builds `SalixIFC.Facts` from the wire shape a resolver returns:

      %{
        "scopes" => %{atom => %{"kind" => "room", "within" => atom | nil}},
        "membership" => %{atom => %{"members" => [principal], "revision" => 3} | "unknown"},
        "placements" => %{principal => %{connect => "internal" | "external"}},
        "receipts" => [%{"id" =>, "requester" =>, "sources" => [atom],
                         "destination" => [atom], "expires_at" => int | nil}],
        "policy" => %{"declassification" =>, "sealed_atoms" => [atom],
                      "external_principals" =>, "public_egress" =>},
        "now" => 1_760_000_000
      }

  Unreadable entries are dropped, never guessed: a membership row whose atom
  does not decode simply stays unknown, which the kernel treats as deny.
  """
  @spec decode_facts(term) :: Facts.t()
  def decode_facts(wire) when is_map(wire) do
    Facts.new(
      scopes: decode_scopes(get(wire, "scopes")),
      membership: decode_membership(get(wire, "membership")),
      placements: decode_placements(get(wire, "placements")),
      receipts: decode_receipts(get(wire, "receipts")),
      policy: decode_policy(get(wire, "policy")),
      now: non_negative_integer(get(wire, "now"))
    )
  end

  def decode_facts(_wire), do: Facts.new()

  @doc "Reads the group policy out of its wire shape; unknown values keep the default."
  @spec decode_policy(term) :: Policy.t()
  def decode_policy(wire) when is_map(wire) do
    Policy.new(
      declassification:
        enum_value(
          get(wire, "declassification"),
          [:in_place_and_receipt, :receipt_only, :trust_requester_instruction, :none],
          :in_place_and_receipt
        ),
      sealed_atoms: decode_atom_list(get(wire, "sealed_atoms")),
      external_principals:
        enum_value(
          get(wire, "external_principals"),
          [:own_thread_only, :deny, :as_internal],
          :own_thread_only
        ),
      public_egress:
        enum_value(
          get(wire, "public_egress"),
          [:receipt, :deny, :allow_public_sources_only],
          :receipt
        )
    )
  end

  def decode_policy(_wire), do: %Policy{}

  @doc "The wire shape of a policy, for storage and for archive facts."
  @spec encode_policy(Policy.t()) :: map
  def encode_policy(%Policy{} = policy) do
    %{
      "declassification" => Atom.to_string(policy.declassification),
      "sealed_atoms" => policy.sealed_atoms |> Enum.map(&encode_atom!/1) |> Enum.sort(),
      "external_principals" => Atom.to_string(policy.external_principals),
      "public_egress" => Atom.to_string(policy.public_egress)
    }
  end

  # ---------------------------------------------------------------------------
  # Decisions
  # ---------------------------------------------------------------------------

  @doc """
  The archive shape of one decision. Labels and clause names only: never the
  content the effect carried, and never an atom's display name.
  """
  @spec encode_decision({:allow, Evidence.t()} | {:deny, Reason.t()}) :: map
  def encode_decision({:allow, %Evidence{} = evidence}) do
    %{
      "outcome" => "allow",
      "request" => evidence.request,
      "requester" => encode_principal!(evidence.requester),
      "destination" => encode_label(evidence.destination),
      "sources" => Enum.map(evidence.sources, &encode_admitted_source/1),
      "membership_revisions" =>
        Enum.map(evidence.membership_revisions, fn {atom, revision} ->
          %{"atom" => encode_atom!(atom), "revision" => revision}
        end)
    }
  end

  def encode_decision({:deny, %Reason{} = reason}) do
    %{
      "outcome" => "deny",
      "clause" => Atom.to_string(reason.clause),
      "ref" => reason.ref,
      "detail" => encode_detail(reason.detail),
      "source_failures" =>
        Enum.map(reason.source_failures, fn failure ->
          %{
            "ref" => failure.ref,
            "clause" => Atom.to_string(failure.clause),
            "detail" => encode_detail(failure.detail)
          }
        end)
    }
  end

  @doc "The clause that admitted one source, in wire form."
  @spec encode_admitted_source({binary, Evidence.clause()}) :: map
  def encode_admitted_source({ref, {:receipt, id}}),
    do: %{"ref" => ref, "clause" => "receipt", "receipt_id" => id}

  def encode_admitted_source({ref, clause}),
    do: %{"ref" => ref, "clause" => Atom.to_string(clause)}

  # ---------------------------------------------------------------------------
  # internal
  # ---------------------------------------------------------------------------

  defp decode_scopes(wire) when is_map(wire) do
    wire
    |> Enum.flat_map(fn {atom, fact} ->
      with {:ok, atom} <- decode_atom(atom),
           true <- is_map(fact),
           kind when kind != nil <- scope_kind(get(fact, "kind")) do
        [{atom, %{kind: kind, within: optional_atom(get(fact, "within"))}}]
      else
        _other -> []
      end
    end)
    |> Map.new()
  end

  defp decode_scopes(_wire), do: %{}

  defp scope_kind("room"), do: :room
  defp scope_kind("direct"), do: :direct
  defp scope_kind("shared"), do: :shared
  defp scope_kind(_other), do: nil

  defp optional_atom(value) do
    case decode_atom(value) do
      {:ok, atom} -> atom
      :error -> nil
    end
  end

  defp decode_membership(wire) when is_map(wire) do
    wire
    |> Enum.flat_map(fn {atom, entry} ->
      case decode_atom(atom) do
        {:ok, atom} -> [{atom, decode_membership_entry(entry)}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp decode_membership(_wire), do: %{}

  defp decode_membership_entry(entry) when is_map(entry) do
    members =
      entry
      |> get("members")
      |> List.wrap()
      |> Enum.flat_map(fn member ->
        case decode_principal(member) do
          {:ok, principal} -> [Principal.key(principal)]
          :error -> []
        end
      end)

    {:members, MapSet.new(members), non_negative_integer(get(entry, "revision"))}
  end

  defp decode_membership_entry(_entry), do: :unknown

  defp decode_placements(wire) when is_map(wire) do
    wire
    |> Enum.flat_map(fn {principal, by_connect} ->
      with {:ok, principal} <- decode_principal(principal),
           true <- is_map(by_connect),
           placements when placements != %{} <- decode_connect_placements(by_connect) do
        [{Principal.key(principal), placements}]
      else
        _other -> []
      end
    end)
    |> Map.new()
  end

  defp decode_placements(_wire), do: %{}

  defp decode_connect_placements(by_connect) do
    by_connect
    |> Enum.flat_map(fn
      {connect, "internal"} when is_binary(connect) -> [{connect, :internal}]
      {connect, "external"} when is_binary(connect) -> [{connect, :external}]
      _other -> []
    end)
    |> Map.new()
  end

  defp decode_receipts(wire) when is_list(wire) do
    Enum.flat_map(wire, fn receipt ->
      with true <- is_map(receipt),
           id when is_binary(id) and id != "" <- get(receipt, "id"),
           {:ok, requester} <- decode_principal(get(receipt, "requester")),
           {:ok, sources} <- decode_label(get(receipt, "sources")),
           {:ok, destination} <- decode_label(get(receipt, "destination")) do
        [
          %Receipt{
            id: id,
            requester: requester,
            sources: sources,
            destination: destination,
            expires_at: expires_at(get(receipt, "expires_at"))
          }
        ]
      else
        _other -> []
      end
    end)
  end

  defp decode_receipts(_wire), do: []

  defp decode_atom_list(values) when is_list(values) do
    Enum.flat_map(values, fn value ->
      case decode_atom(value) do
        {:ok, atom} -> [atom]
        :error -> []
      end
    end)
  end

  defp decode_atom_list(_values), do: []

  defp expires_at(value) when is_integer(value) and value >= 0, do: value
  defp expires_at(_value), do: :never

  defp encode_detail(detail) when is_list(detail),
    do: Enum.flat_map(detail, &List.wrap(encode_detail(&1)))

  defp encode_detail(nil), do: nil
  defp encode_detail(detail) when is_atom(detail), do: Atom.to_string(detail)
  defp encode_detail(detail) when is_binary(detail), do: detail
  defp encode_detail(_detail), do: nil

  defp enum_value(value, allowed, default) when is_binary(value),
    do: Enum.find(allowed, default, fn candidate -> Atom.to_string(candidate) == value end)

  defp enum_value(value, allowed, default), do: if(value in allowed, do: value, else: default)

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp get(map, key) when is_map(map), do: Map.get(map, key)

  # Every part must be a non-empty binary free of the separator, so that
  # `String.split/2` inverts `Enum.join/2` exactly.
  defp join(parts) do
    if Enum.all?(parts, &encodable_part?/1),
      do: {:ok, Enum.join(parts, @separator)},
      else: :error
  end

  # The tail is itself an encoded value, so it may contain separators; the
  # matching decoder splits with a bounded part count.
  defp join_tail(parts, tail) do
    if Enum.all?(parts, &encodable_part?/1) and is_binary(tail) and tail != "",
      do: {:ok, Enum.join(parts ++ [tail], @separator)},
      else: :error
  end

  defp encodable_part?(part),
    do: is_binary(part) and part != "" and not String.contains?(part, @separator)

  defp present(value, parts) do
    if Enum.all?(parts, &(is_binary(&1) and &1 != "")), do: {:ok, value}, else: :error
  end
end
