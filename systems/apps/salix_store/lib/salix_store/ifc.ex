defmodule SalixStore.IFC do
  @moduledoc """
  Postgres data access for information-flow facts
  (`docs/verification.md` §3.6, §8).

  Six tables, three writers:

    * an organization administrator, through the Bridge For Teams dashboard —
      `ifc_scope_labels` (a room's classification tags, audience mode, sealed
      flag), `ifc_tag_clearances` (which principals may read a tag) and
      `ifc_principal_facts` (internal/external placement overrides);
    * the provider projection — `ifc_scope_facts` (what a conversation
      structurally is) and `ifc_scope_members` (who is in it);
    * the declassification flow — `ifc_receipts`.

  Nothing here decides anything. The rows are the facts
  `SalixIFC.decide/4` reads, and every read is scoped to one
  `(tenant_id, group_id)` so one organization's configuration can never
  answer another's question.

  `members_complete` carries the distinction the kernel must never lose:
  a scope with no member rows and `members_complete = false` is *unknown*,
  which denies, while `members_complete = true` means the empty set is the
  answer. Store faults surface as `{:error, :unavailable}`.
  """

  import Ecto.Query

  alias SalixStore.Repo

  @audience_modes ~w(space members)
  @placements ~w(internal external)
  # The dashboard lists read one row past this, so a longer list says so.
  @dashboard_rows 200

  # `public` is a real observation and not a scope kind the kernel knows: a
  # public room's audience IS its space, so the resolver emits no scope atom
  # for it at all. Recording it here is what lets a later lookup skip the
  # provider round trip.
  @scope_kinds ~w(room direct shared public)

  defmodule ScopeLabel do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "ifc_scope_labels" do
      field(:tenant_id, :string, primary_key: true)
      field(:group_id, :string, primary_key: true)
      field(:connect_id, :string, primary_key: true)
      field(:scope_id, :string, primary_key: true)
      field(:tags, {:array, :string})
      field(:audience_mode, :string)
      field(:sealed, :boolean)
      field(:revision, :integer)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule TagClearance do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "ifc_tag_clearances" do
      field(:tenant_id, :string, primary_key: true)
      field(:group_id, :string, primary_key: true)
      field(:connect_id, :string, primary_key: true)
      field(:tag, :string, primary_key: true)
      field(:principal_key, :string, primary_key: true)
      field(:revision, :integer)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule PrincipalFact do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "ifc_principal_facts" do
      field(:tenant_id, :string, primary_key: true)
      field(:group_id, :string, primary_key: true)
      field(:connect_id, :string, primary_key: true)
      field(:user_id, :string, primary_key: true)
      field(:placement_observed, :string)
      field(:placement_override, :string)
      field(:revision, :integer)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule ScopeFact do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "ifc_scope_facts" do
      field(:tenant_id, :string, primary_key: true)
      field(:group_id, :string, primary_key: true)
      field(:connect_id, :string, primary_key: true)
      field(:scope_id, :string, primary_key: true)
      field(:kind, :string)
      field(:within_scope_id, :string)
      field(:canonical_scope_id, :string)
      field(:display_name, :string)
      field(:members_complete, :boolean)
      field(:revision, :integer)
      field(:observed_at, :utc_datetime_usec)
    end
  end

  defmodule ScopeMember do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "ifc_scope_members" do
      field(:tenant_id, :string, primary_key: true)
      field(:group_id, :string, primary_key: true)
      field(:connect_id, :string, primary_key: true)
      field(:scope_id, :string, primary_key: true)
      field(:member_key, :string, primary_key: true)
      field(:observed_at, :utc_datetime_usec)
    end
  end

  defmodule Receipt do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "ifc_receipts" do
      field(:tenant_id, :string, primary_key: true)
      field(:group_id, :string, primary_key: true)
      field(:receipt_id, :string, primary_key: true)
      field(:requester_key, :string)
      field(:source_atoms, {:array, :string})
      field(:destination_atoms, {:array, :string})
      field(:thread_ref, :string)
      field(:expires_at_ms, :integer)
      field(:created_at, :utc_datetime_usec)
    end
  end

  @type scope :: %{tenant_id: String.t(), group_id: String.t()}

  # ---------------------------------------------------------------------------
  # Operator configuration
  # ---------------------------------------------------------------------------

  @doc """
  Upserts one room's operator classification. `tags` are opaque names, and
  `audience_mode` is `"space"` (a public room over-approximated by its space)
  or `"members"` (exact membership even when the room is public).

  Every write bumps `revision`, so a decision archived under an old
  configuration is distinguishable from one made under the new.
  """
  @spec put_scope_label(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def put_scope_label(tenant_id, group_id, connect_id, scope_id, attrs)
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(connect_id) and
             is_binary(scope_id) and is_map(attrs) do
    tags = attrs |> Map.get(:tags, Map.get(attrs, "tags", [])) |> normalize_tags()

    mode =
      attrs |> Map.get(:audience_mode, Map.get(attrs, "audience_mode", "space")) |> to_string()

    sealed = truthy(Map.get(attrs, :sealed, Map.get(attrs, "sealed", false)))

    if mode in @audience_modes do
      row = %{
        tenant_id: tenant_id,
        group_id: group_id,
        connect_id: connect_id,
        scope_id: scope_id,
        tags: tags,
        audience_mode: mode,
        sealed: sealed,
        revision: 1,
        updated_at: now()
      }

      upsert_with_revision(
        ScopeLabel,
        row,
        [:tenant_id, :group_id, :connect_id, :scope_id],
        tags: tags,
        audience_mode: mode,
        sealed: sealed
      )
    else
      {:error, :invalid_audience_mode}
    end
  end

  @doc "Removes one room's operator classification, restoring provider defaults."
  @spec delete_scope_label(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :unavailable}
  def delete_scope_label(tenant_id, group_id, connect_id, scope_id) do
    ScopeLabel
    |> where(
      tenant_id: ^tenant_id,
      group_id: ^group_id,
      connect_id: ^connect_id,
      scope_id: ^scope_id
    )
    |> Repo.delete_all()

    :ok
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Grants one principal the clearance to read a tag."
  @spec put_tag_clearance(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def put_tag_clearance(tenant_id, group_id, connect_id, tag, principal_key)
      when is_binary(tag) and tag != "" and is_binary(principal_key) and principal_key != "" do
    row = %{
      tenant_id: tenant_id,
      group_id: group_id,
      connect_id: connect_id,
      tag: tag,
      principal_key: principal_key,
      revision: 1,
      updated_at: now()
    }

    upsert_with_revision(
      TagClearance,
      row,
      [:tenant_id, :group_id, :connect_id, :tag, :principal_key],
      []
    )
  end

  @doc "Revokes one principal's clearance for a tag."
  @spec delete_tag_clearance(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :unavailable}
  def delete_tag_clearance(tenant_id, group_id, connect_id, tag, principal_key) do
    TagClearance
    |> where(
      tenant_id: ^tenant_id,
      group_id: ^group_id,
      connect_id: ^connect_id,
      tag: ^tag,
      principal_key: ^principal_key
    )
    |> Repo.delete_all()

    :ok
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Overrides the provider-derived placement of one provider user."
  @spec put_principal_fact(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def put_principal_fact(tenant_id, group_id, connect_id, user_id, placement),
    do: put_placement(tenant_id, group_id, connect_id, user_id, placement, :placement_override)

  @doc """
  Records what the provider itself said about one user: a guest, a
  single-channel guest, or a member of another workspace is external.

  Observation never overwrites an administrator's override; the two are
  separate columns and the override wins at read time.
  """
  @spec observe_placement(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def observe_placement(tenant_id, group_id, connect_id, user_id, placement),
    do: put_placement(tenant_id, group_id, connect_id, user_id, placement, :placement_observed)

  defp put_placement(tenant_id, group_id, connect_id, user_id, placement, column)
       when is_binary(user_id) and user_id != "" do
    placement = to_string(placement)

    if placement in @placements do
      row =
        %{
          tenant_id: tenant_id,
          group_id: group_id,
          connect_id: connect_id,
          user_id: user_id,
          placement_observed: nil,
          placement_override: nil,
          revision: 1,
          updated_at: now()
        }
        |> Map.put(column, placement)

      upsert_with_revision(
        PrincipalFact,
        row,
        [:tenant_id, :group_id, :connect_id, :user_id],
        [{column, placement}]
      )
    else
      {:error, :invalid_placement}
    end
  end

  defp put_placement(_tenant_id, _group_id, _connect_id, _user_id, _placement, _column),
    do: {:error, :invalid_placement}

  @doc "Removes a placement override, restoring the provider-derived placement."
  @spec delete_principal_fact(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :unavailable}
  def delete_principal_fact(tenant_id, group_id, connect_id, user_id) do
    PrincipalFact
    |> where(
      tenant_id: ^tenant_id,
      group_id: ^group_id,
      connect_id: ^connect_id,
      user_id: ^user_id
    )
    |> Repo.delete_all()

    :ok
  rescue
    _ -> {:error, :unavailable}
  end

  # ---------------------------------------------------------------------------
  # Provider projection
  # ---------------------------------------------------------------------------

  @doc """
  Records what one provider conversation structurally is: `"room"`,
  `"direct"` or `"shared"`, optionally inside a parent scope.

  This never touches membership; use `replace_scope_members/5` for the
  bootstrap enumeration and `add_scope_member/5` / `remove_scope_member/5`
  for the join/leave events.
  """
  @spec observe_scope(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def observe_scope(tenant_id, group_id, connect_id, scope_id, attrs) when is_map(attrs) do
    kind = attrs |> Map.get(:kind, Map.get(attrs, "kind")) |> to_string()
    within = attrs |> Map.get(:within, Map.get(attrs, "within")) |> nonblank()
    name = attrs |> Map.get(:display_name, Map.get(attrs, "display_name")) |> nonblank()

    canonical =
      attrs |> Map.get(:canonical_scope_id, Map.get(attrs, "canonical_scope_id")) |> nonblank()

    if kind in @scope_kinds do
      row = %{
        tenant_id: tenant_id,
        group_id: group_id,
        connect_id: connect_id,
        scope_id: scope_id,
        kind: kind,
        within_scope_id: within,
        canonical_scope_id: canonical,
        display_name: name,
        members_complete: false,
        revision: 1,
        observed_at: now()
      }

      upsert_with_revision(
        ScopeFact,
        row,
        [:tenant_id, :group_id, :connect_id, :scope_id],
        [
          kind: kind,
          within_scope_id: within,
          canonical_scope_id: canonical,
          display_name: name
        ],
        :observed_at
      )
    else
      {:error, :invalid_scope_kind}
    end
  end

  @doc """
  Replaces one scope's member set with the complete enumeration `members`
  and marks it complete. This is the only call that may claim completeness.
  """
  @spec replace_scope_members(String.t(), String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def replace_scope_members(tenant_id, group_id, connect_id, scope_id, members)
      when is_list(members) do
    members = members |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    observed_at = now()

    Repo.transaction(fn ->
      ScopeMember
      |> where(
        tenant_id: ^tenant_id,
        group_id: ^group_id,
        connect_id: ^connect_id,
        scope_id: ^scope_id
      )
      |> Repo.delete_all()

      rows =
        Enum.map(members, fn member ->
          %{
            tenant_id: tenant_id,
            group_id: group_id,
            connect_id: connect_id,
            scope_id: scope_id,
            member_key: member,
            observed_at: observed_at
          }
        end)

      if rows != [], do: Repo.insert_all(ScopeMember, rows)

      bump_scope_revision(tenant_id, group_id, connect_id, scope_id, true, observed_at)
    end)
    |> case do
      {:ok, revision} -> {:ok, revision}
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Adds one member, from a join event. Never claims completeness on its own."
  @spec add_scope_member(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def add_scope_member(tenant_id, group_id, connect_id, scope_id, member_key)
      when is_binary(member_key) and member_key != "" do
    observed_at = now()

    Repo.insert_all(
      ScopeMember,
      [
        %{
          tenant_id: tenant_id,
          group_id: group_id,
          connect_id: connect_id,
          scope_id: scope_id,
          member_key: member_key,
          observed_at: observed_at
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :group_id, :connect_id, :scope_id, :member_key]
    )

    {:ok, bump_scope_revision(tenant_id, group_id, connect_id, scope_id, nil, observed_at)}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Removes one member, from a leave event."
  @spec remove_scope_member(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def remove_scope_member(tenant_id, group_id, connect_id, scope_id, member_key)
      when is_binary(member_key) and member_key != "" do
    observed_at = now()

    ScopeMember
    |> where(
      tenant_id: ^tenant_id,
      group_id: ^group_id,
      connect_id: ^connect_id,
      scope_id: ^scope_id,
      member_key: ^member_key
    )
    |> Repo.delete_all()

    {:ok, bump_scope_revision(tenant_id, group_id, connect_id, scope_id, nil, observed_at)}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Marks a scope's membership no longer enumerated, so the kernel reads it as
  unknown. Used when the provider refuses a member listing or a connect is
  reauthorized.
  """
  @spec invalidate_scope_members(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def invalidate_scope_members(tenant_id, group_id, connect_id, scope_id) do
    {:ok, bump_scope_revision(tenant_id, group_id, connect_id, scope_id, false, now())}
  rescue
    _ -> {:error, :unavailable}
  end

  # ---------------------------------------------------------------------------
  # Receipts
  # ---------------------------------------------------------------------------

  @doc """
  Writes one declassification receipt. `source_atoms` and `destination_atoms`
  are encoded audience atoms (`SalixIFC.Codec`); `expires_at_ms` is a
  millisecond epoch or `nil` for a receipt that never expires.
  """
  @spec put_receipt(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put_receipt(tenant_id, group_id, receipt_id, attrs)
      when is_binary(receipt_id) and receipt_id != "" and is_map(attrs) do
    requester = attrs |> Map.get(:requester_key, Map.get(attrs, "requester_key")) |> nonblank()
    sources = attrs |> Map.get(:source_atoms, Map.get(attrs, "source_atoms", [])) |> atom_list()

    destination =
      attrs |> Map.get(:destination_atoms, Map.get(attrs, "destination_atoms", [])) |> atom_list()

    expires_at = attrs |> Map.get(:expires_at_ms, Map.get(attrs, "expires_at_ms")) |> integer()
    thread_ref = attrs |> Map.get(:thread_ref, Map.get(attrs, "thread_ref")) |> nonblank()

    cond do
      is_nil(requester) ->
        {:error, :invalid_requester}

      sources == [] ->
        {:error, :invalid_sources}

      destination == [] ->
        {:error, :invalid_destination}

      true ->
        insert_receipt(
          tenant_id,
          group_id,
          receipt_id,
          requester,
          sources,
          destination,
          thread_ref,
          expires_at
        )
    end
  end

  @doc """
  Every receipt this requester holds that is still valid at `now_ms`.
  Expired rows are filtered here rather than in the kernel, which has no
  clock of its own.
  """
  @spec receipts(String.t(), String.t(), [String.t()], integer()) ::
          {:ok, [map()]} | {:error, :unavailable}
  def receipts(tenant_id, group_id, requester_keys, now_ms)
      when is_list(requester_keys) and is_integer(now_ms) do
    keys = requester_keys |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    if keys == [] do
      {:ok, []}
    else
      rows =
        Receipt
        |> where([r], r.tenant_id == ^tenant_id and r.group_id == ^group_id)
        |> where([r], r.requester_key in ^keys)
        |> where([r], is_nil(r.expires_at_ms) or r.expires_at_ms > ^now_ms)
        |> Repo.all()
        |> Enum.map(fn row ->
          %{
            "id" => row.receipt_id,
            "requester" => row.requester_key,
            "sources" => row.source_atoms,
            "destination" => row.destination_atoms,
            "expires_at" => row.expires_at_ms,
            "thread_ref" => row.thread_ref
          }
        end)

      {:ok, rows}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Consumes one receipt, returning whether this caller is the one that used it.

  A person confirms one transfer, so the receipt authorizes one effect: the
  delete is the claim, and `{:ok, false}` means it was already spent (or had
  expired out from under the decision that just read it) and the effect that
  asked must not proceed on it.
  """
  @spec consume_receipt(String.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, :unavailable}
  def consume_receipt(tenant_id, group_id, receipt_id)
      when is_binary(receipt_id) and receipt_id != "" do
    {count, _} =
      Receipt
      |> where([r], r.tenant_id == ^tenant_id and r.group_id == ^group_id)
      |> where([r], r.receipt_id == ^receipt_id)
      |> Repo.delete_all()

    {:ok, count > 0}
  rescue
    _ -> {:error, :unavailable}
  end

  def consume_receipt(_tenant_id, _group_id, _receipt_id), do: {:error, :unavailable}

  @doc "Drops receipts that expired before `before_ms`."
  @spec prune_receipts(integer()) :: {:ok, non_neg_integer()} | {:error, :unavailable}
  def prune_receipts(before_ms) when is_integer(before_ms) do
    {count, _} =
      Receipt
      |> where([r], not is_nil(r.expires_at_ms) and r.expires_at_ms <= ^before_ms)
      |> Repo.delete_all()

    {:ok, count}
  rescue
    _ -> {:error, :unavailable}
  end

  # ---------------------------------------------------------------------------
  # Reads for the facts resolver
  # ---------------------------------------------------------------------------

  @doc """
  Everything known about `scope_ids` inside one connect: the observed
  structure, the member sets, and the operator classification, in one round
  trip per table.

  Returns `%{scope_id => %{kind:, within:, members: [key] | :unknown,
  revision:, tags: [name], audience_mode:, sealed:}}`. A scope with no rows
  at all is simply absent, which the resolver reads as unknown.
  """
  @spec scopes(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, %{String.t() => map()}} | {:error, :unavailable}
  def scopes(tenant_id, group_id, connect_id, scope_ids) when is_list(scope_ids) do
    ids = scope_ids |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    if ids == [] do
      {:ok, %{}}
    else
      facts =
        ScopeFact
        |> where([s], s.tenant_id == ^tenant_id and s.group_id == ^group_id)
        |> where([s], s.connect_id == ^connect_id and s.scope_id in ^ids)
        |> Repo.all()
        |> Map.new(&{&1.scope_id, &1})

      members =
        ScopeMember
        |> where([m], m.tenant_id == ^tenant_id and m.group_id == ^group_id)
        |> where([m], m.connect_id == ^connect_id and m.scope_id in ^ids)
        |> Repo.all()
        |> Enum.group_by(& &1.scope_id, & &1.member_key)

      labels =
        ScopeLabel
        |> where([l], l.tenant_id == ^tenant_id and l.group_id == ^group_id)
        |> where([l], l.connect_id == ^connect_id and l.scope_id in ^ids)
        |> Repo.all()
        |> Map.new(&{&1.scope_id, &1})

      {:ok,
       ids
       |> Enum.flat_map(fn id ->
         fact = Map.get(facts, id)
         label = Map.get(labels, id)

         if is_nil(fact) and is_nil(label) do
           []
         else
           [{id, scope_row(fact, label, Map.get(members, id, []))}]
         end
       end)
       |> Map.new()}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "The principals cleared for each of `tags` in one connect."
  @spec tag_clearances(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, %{String.t() => %{members: [String.t()], revision: non_neg_integer()}}}
          | {:error, :unavailable}
  def tag_clearances(tenant_id, group_id, connect_id, tags) when is_list(tags) do
    tags = tags |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    if tags == [] do
      {:ok, %{}}
    else
      rows =
        TagClearance
        |> where([c], c.tenant_id == ^tenant_id and c.group_id == ^group_id)
        |> where([c], c.connect_id == ^connect_id and c.tag in ^tags)
        |> Repo.all()
        |> Enum.group_by(& &1.tag)

      {:ok,
       Map.new(tags, fn tag ->
         entries = Map.get(rows, tag, [])

         {tag,
          %{
            members: Enum.map(entries, & &1.principal_key),
            revision: entries |> Enum.map(& &1.revision) |> Enum.max(fn -> 0 end)
          }}
       end)}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  The effective placement of each of `user_ids` in one connect: the
  administrator's override when there is one, otherwise what the provider
  said. A user with neither is absent, which the kernel reads as unknown.
  """
  @spec placement_overrides(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, %{String.t() => String.t()}} | {:error, :unavailable}
  def placement_overrides(tenant_id, group_id, connect_id, user_ids) when is_list(user_ids) do
    ids = user_ids |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    if ids == [] do
      {:ok, %{}}
    else
      rows =
        PrincipalFact
        |> where([p], p.tenant_id == ^tenant_id and p.group_id == ^group_id)
        |> where([p], p.connect_id == ^connect_id and p.user_id in ^ids)
        |> Repo.all()
        |> Enum.flat_map(fn row ->
          case row.placement_override || row.placement_observed do
            placement when placement in @placements -> [{row.user_id, placement}]
            _none -> []
          end
        end)
        |> Map.new()

      {:ok, rows}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  # Scope labels and facts are listed in byte order (`COLLATE "C"`), the order
  # Elixir compares binaries in, so `SalixIM.IFC.Admin` can line the two
  # bounded reads up against each other.
  @doc "The rows each dashboard list returns; it reads one more to flag a longer list."
  def dashboard_rows, do: @dashboard_rows

  @doc "Operator classifications in one connect, for the dashboard (bounded)."
  @spec list_scope_labels(String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, :unavailable}
  def list_scope_labels(tenant_id, group_id, connect_id) do
    rows =
      ScopeLabel
      |> where([l], l.tenant_id == ^tenant_id and l.group_id == ^group_id)
      |> where([l], l.connect_id == ^connect_id)
      |> order_by([l], asc: fragment("? COLLATE \"C\"", l.scope_id))
      |> limit(^(@dashboard_rows + 1))
      |> Repo.all()
      |> Enum.map(
        &%{
          "scope_id" => &1.scope_id,
          "tags" => &1.tags,
          "audience_mode" => &1.audience_mode,
          "sealed" => &1.sealed,
          "revision" => &1.revision
        }
      )

    {:ok, rows}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  The conversations this connect has observed, for the dashboard (bounded).

  The classifications in `list_scope_labels/3` only cover conversations an
  operator has already touched. This is the other half — what the projection
  has actually seen — so the page can offer an unclassified channel rather than
  only listing the ones already classified.
  """
  @spec list_scope_facts(String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, :unavailable}
  def list_scope_facts(tenant_id, group_id, connect_id) do
    rows =
      ScopeFact
      |> where([f], f.tenant_id == ^tenant_id and f.group_id == ^group_id)
      |> where([f], f.connect_id == ^connect_id)
      |> order_by([f], asc: fragment("? COLLATE \"C\"", f.scope_id))
      |> limit(^(@dashboard_rows + 1))
      |> Repo.all()
      |> Enum.map(
        &%{
          "scope_id" => &1.scope_id,
          "kind" => &1.kind,
          "within_scope_id" => &1.within_scope_id,
          "canonical_scope_id" => &1.canonical_scope_id,
          "display_name" => &1.display_name,
          "members_complete" => &1.members_complete,
          "observed_at" => &1.observed_at && DateTime.to_iso8601(&1.observed_at)
        }
      )

    {:ok, rows}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  The principals this connect knows a placement for, for the dashboard (bounded).

  Both halves: what the provider said (`placement_observed`) and what an
  operator decided instead (`placement_override`), because the page has to show
  which one a decision is actually using.
  """
  @spec list_principal_facts(String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, :unavailable}
  def list_principal_facts(tenant_id, group_id, connect_id) do
    rows =
      PrincipalFact
      |> where([p], p.tenant_id == ^tenant_id and p.group_id == ^group_id)
      |> where([p], p.connect_id == ^connect_id)
      |> order_by([p], asc: p.user_id)
      |> limit(^(@dashboard_rows + 1))
      |> Repo.all()
      |> Enum.map(
        &%{
          "user_id" => &1.user_id,
          "placement_observed" => &1.placement_observed,
          "placement_override" => &1.placement_override
        }
      )

    {:ok, rows}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Clearances in one connect, for the dashboard (bounded)."
  @spec list_tag_clearances(String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, :unavailable}
  def list_tag_clearances(tenant_id, group_id, connect_id) do
    rows =
      TagClearance
      |> where([c], c.tenant_id == ^tenant_id and c.group_id == ^group_id)
      |> where([c], c.connect_id == ^connect_id)
      |> order_by([c], asc: c.tag, asc: c.principal_key)
      |> limit(^(@dashboard_rows + 1))
      |> Repo.all()
      |> Enum.map(&%{"tag" => &1.tag, "principal_key" => &1.principal_key})

    {:ok, rows}
  rescue
    _ -> {:error, :unavailable}
  end

  # ---------------------------------------------------------------------------
  # internal
  # ---------------------------------------------------------------------------

  defp insert_receipt(
         tenant_id,
         group_id,
         receipt_id,
         requester,
         sources,
         destination,
         thread_ref,
         expires_at
       ) do
    Repo.insert_all(
      Receipt,
      [
        %{
          tenant_id: tenant_id,
          group_id: group_id,
          receipt_id: receipt_id,
          requester_key: requester,
          source_atoms: sources,
          destination_atoms: destination,
          thread_ref: thread_ref,
          expires_at_ms: expires_at,
          created_at: now()
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :group_id, :receipt_id]
    )

    :ok
  rescue
    _ -> {:error, :unavailable}
  end

  defp scope_row(fact, label, members) do
    %{
      kind: fact && fact.kind,
      within: fact && fact.within_scope_id,
      canonical_scope_id: fact && fact.canonical_scope_id,
      display_name: fact && fact.display_name,
      members: if(fact && fact.members_complete, do: Enum.sort(members), else: :unknown),
      # When the projection last heard from the provider. The caller owns the
      # freshness bound: only it knows what re-observing costs, and a member
      # set past its bound must read as unknown rather than as an answer.
      observed_at_ms: fact && DateTime.to_unix(fact.observed_at, :millisecond),
      revision: max((fact && fact.revision) || 0, (label && label.revision) || 0),
      tags: (label && label.tags) || [],
      audience_mode: (label && label.audience_mode) || "space",
      sealed: (label && label.sealed) || false
    }
  end

  # Upsert that always advances `revision`, so every configuration or
  # membership change is visible to an archived decision.
  defp upsert_with_revision(schema, row, conflict_target, updates, stamp \\ :updated_at) do
    set = Keyword.put(updates, stamp, row[stamp])

    {_count, [%{revision: revision}]} =
      Repo.insert_all(schema, [row],
        on_conflict: [
          set: set,
          inc: [revision: 1]
        ],
        conflict_target: conflict_target,
        returning: [:revision]
      )

    {:ok, revision}
  rescue
    _ -> {:error, :unavailable}
  end

  # A membership change is a change to the scope's revision even when the
  # scope has never been observed structurally: the row is created unknown
  # rather than lost, because "we saw a member join a scope we know nothing
  # about" is itself a fact worth keeping.
  defp bump_scope_revision(tenant_id, group_id, connect_id, scope_id, complete, observed_at) do
    row = %{
      tenant_id: tenant_id,
      group_id: group_id,
      connect_id: connect_id,
      scope_id: scope_id,
      kind: "room",
      within_scope_id: nil,
      canonical_scope_id: nil,
      display_name: nil,
      members_complete: complete == true,
      revision: 1,
      observed_at: observed_at
    }

    set =
      case complete do
        nil -> [observed_at: observed_at]
        value -> [members_complete: value, observed_at: observed_at]
      end

    {_count, [%{revision: revision}]} =
      Repo.insert_all(ScopeFact, [row],
        on_conflict: [set: set, inc: [revision: 1]],
        conflict_target: [:tenant_id, :group_id, :connect_id, :scope_id],
        returning: [:revision]
      )

    revision
  end

  defp normalize_tags(tags) when is_list(tags),
    do: tags |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq() |> Enum.sort()

  defp normalize_tags(_tags), do: []

  defp atom_list(values) when is_list(values),
    do: values |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq() |> Enum.sort()

  defp atom_list(_values), do: []

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_value), do: false

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nonblank(_value), do: nil

  defp now, do: DateTime.utc_now()
end
