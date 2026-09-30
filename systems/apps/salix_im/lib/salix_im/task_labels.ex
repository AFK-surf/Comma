defmodule SalixIM.TaskLabels do
  @moduledoc """
  Group-scoped Task labels and human-owned Router approval policy.

  PostgreSQL serializes the bounded catalog, policy and immutable approval
  decision in one Group row. A create approval commits all labels together.
  Task binding then goes through ConversationServer -> ConversationActor,
  guarded by the Task label revision captured when the proposal was made.
  Approved catalog changes survive a failed Task binding; a caller may retry
  the same proposal explicitly. There is no background retry or cross-store
  transaction. Modeled in tla/salix/TaskLabelApproval.tla.
  """

  alias SalixIM.{ConversationServer, Conversations, GroupDirectory}
  alias SalixStore.Ids

  @colors ~w(gray blue indigo purple pink orange warning success error brand)
  @name_max 40
  @description_max 200
  @label_limit 64
  @pending_proposal_limit 32
  @proposal_ops ~w(create update delete apply)
  @label_fields ~w(id name color description created_at updated_at)
  @batch_limit 16
  @summary_max 500

  @default_labels [
    %{
      "name" => "Work",
      "color" => "brand",
      "description" =>
        "Add when the Task serves the user's job or team: deliverables, meetings, colleagues, clients; skip when it is a personal errand."
    },
    %{
      "name" => "Personal",
      "color" => "success",
      "description" =>
        "Add when the Task is the user's own life admin: errands, family, health, home, money outside work; skip when it is done for the job."
    },
    %{
      "name" => "Research",
      "color" => "indigo",
      "description" =>
        "Add when the Task mainly gathers or compares information before a decision: reading, digging, weighing options; skip when the Task carries out a decision already made."
    },
    %{
      "name" => "Urgent",
      "color" => "error",
      "description" =>
        "Add when the user says it must be done today, a hard deadline falls within 24 hours, or someone is blocked until it is done; skip when urgency is only implied or a later date is fine."
    }
  ]

  @type label :: %{required(String.t()) => term()}
  @type proposal :: %{required(String.t()) => term()}

  @doc "Every color a label may carry; the client owns the palette rendering."
  @spec colors() :: [String.t()]
  def colors, do: @colors

  @doc """
  Reads the Group catalog, seeding the defaults on first access so a fresh
  Group always has something to pick from.
  """
  @spec list(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def list(group_id, tenant_id \\ nil) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, aggregate} <- read_or_seed_aggregate(group_id) do
      {:ok, public(aggregate)}
    end
  end

  # Every provider input reads the catalog for its creation contract. A plain
  # read serves a seeded Group; only the first access takes the seeding lock.
  defp read_or_seed_aggregate(group_id) do
    case SalixStore.TaskLabels.get(group_id) do
      {:ok, nil} -> ensure_aggregate(group_id)
      {:ok, aggregate} -> {:ok, aggregate}
      {:error, _} = error -> error
    end
  end

  @doc "Creates one label from human input (name required, color optional)."
  @spec create(String.t(), map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def create(group_id, attrs, tenant_id \\ nil) when is_map(attrs) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, label} <- new_label(attrs),
         {:ok, aggregate} <- mutate(group_id, &insert_label(&1, label)) do
      {:ok, Map.put(public(aggregate), "label", find_label(aggregate, label["id"]))}
    end
  end

  @doc "Updates name/color/description of one label."
  @spec update(String.t(), String.t(), map(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def update(group_id, label_id, attrs, tenant_id \\ nil) when is_map(attrs) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         :ok <- require_label_id(label_id),
         {:ok, changes} <- label_changes(attrs),
         {:ok, aggregate} <- mutate(group_id, &change_label(&1, label_id, changes)) do
      {:ok, Map.put(public(aggregate), "label", find_label(aggregate, label_id))}
    end
  end

  @doc """
  Deletes one label from the catalog. Tasks that still reference the id keep
  the dangling id in their own `labels` list; the client hides unknown ids.
  """
  @spec delete(String.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def delete(group_id, label_id, tenant_id \\ nil) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         :ok <- require_label_id(label_id),
         {:ok, aggregate} <- mutate(group_id, &remove_label(&1, label_id)) do
      {:ok, public(aggregate)}
    end
  end

  @doc "Human-owned policy for future Router proposals; existing pending proposals stay pending."
  def update_policy(group_id, policy, tenant_id \\ nil) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         :ok <- validate_policy(policy),
         {:ok, aggregate} <-
           mutate(group_id, &(&1 |> Map.put("approval_policy", policy) |> touch())) do
      {:ok, public(aggregate)}
    end
  end

  @doc "Validate initial Task labels against the current bounded Group catalog."
  def validate_initial_labels(group_id, ids) do
    with :ok <- validate_label_ids(ids),
         {:ok, aggregate} <- ensure_aggregate(group_id),
         :ok <- require_known_labels(aggregate, ids) do
      {:ok, Enum.uniq(ids)}
    end
  end

  @doc "Assign existing catalog labels additively through the Task owner."
  def assign(group_id, conversation_id, label_ids) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id),
         :ok <- validate_label_ids(label_ids),
         {:ok, _target} <- task_target(group_id, conversation_id),
         {:ok, aggregate} <- ensure_aggregate(group_id),
         :ok <- require_known_labels(aggregate, label_ids) do
      ConversationServer.add_task_labels(group_id, conversation_id, Enum.uniq(label_ids))
    end
  end

  @doc """
  Proposes create/update/delete/apply. A create payload contains 1–16 `labels`
  and optionally a target `conversation_id`; a single-label payload is also
  normalized to that batch. The server's current `ask`/`auto` policy decides
  whether the change waits for a person or is approved in the same transaction.
  """
  @spec propose(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def propose(group_id, attrs, actor) when is_map(attrs) and is_map(actor) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id),
         {:ok, proposal} <- new_proposal(group_id, attrs, actor),
         {:ok, aggregate} <- mutate(group_id, &insert_proposal(&1, proposal)),
         stored <- find_request_proposal(aggregate, proposal),
         {:ok, aggregate} <- apply_task_side_effect(group_id, aggregate, stored["id"]) do
      {:ok, find_proposal(aggregate, stored["id"])}
    end
  end

  @doc "Approve/reject a proposal, or explicitly retry binding an already approved proposal."
  def resolve_proposal(group_id, proposal_id, attrs, tenant_id \\ nil) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         :ok <- require_proposal_id(proposal_id),
         {:ok, decision, auto_approve} <- normalize_resolution(attrs),
         {:ok, aggregate} <-
           mutate(group_id, &settle_proposal(&1, proposal_id, decision, auto_approve)),
         {:ok, aggregate} <- apply_task_side_effect(group_id, aggregate, proposal_id) do
      {:ok, Map.put(public(aggregate), "proposal", find_proposal(aggregate, proposal_id))}
    end
  end

  @doc "True when every id is a label in this Group's catalog."
  @spec known_label_ids?(String.t(), [String.t()]) :: boolean()
  def known_label_ids?(group_id, ids) when is_list(ids) do
    case ensure_aggregate(group_id) do
      {:ok, aggregate} ->
        known = aggregate["labels"] |> Enum.map(& &1["id"]) |> MapSet.new()
        Enum.all?(ids, &MapSet.member?(known, &1))

      {:error, _} ->
        false
    end
  end

  # ---- aggregate ----

  defp ensure_aggregate(group_id), do: mutate(group_id, & &1)

  defp mutate(group_id, fun),
    do: SalixStore.TaskLabels.update(group_id, fn -> seed_aggregate(group_id) end, fun)

  defp seed_aggregate(group_id) do
    now = now()

    labels =
      Enum.map(@default_labels, fn defaults ->
        defaults
        |> Map.merge(%{
          "id" => Ids.new_task_label_id(),
          "created_at" => now,
          "updated_at" => now
        })
        |> Map.take(@label_fields)
      end)

    %{
      "record_type" => "task_labels",
      "group_id" => group_id,
      "labels" => labels,
      "proposals" => [],
      "approval_policy" => "ask",
      "updated_at" => now
    }
  end

  defp public(aggregate) do
    %{
      "labels" => Enum.map(aggregate["labels"], &Map.take(&1, @label_fields)),
      "proposals" => Enum.map(aggregate["proposals"], &public_proposal/1),
      "colors" => @colors,
      "approval_policy" => aggregate["approval_policy"],
      "updated_at" => aggregate["updated_at"]
    }
  end

  defp public_proposal(proposal),
    do:
      Map.take(
        proposal,
        ~w(id op payload status summary proposed_by source_conversation_id created_at resolved_at application_status application_error)
      )

  defp find_label(aggregate, id),
    do:
      aggregate["labels"]
      |> Enum.find(&(&1["id"] == id))
      |> then(&(&1 && Map.take(&1, @label_fields)))

  defp find_proposal(aggregate, id),
    do:
      aggregate["proposals"] |> Enum.find(&(&1["id"] == id)) |> then(&(&1 && public_proposal(&1)))

  # ---- labels ----

  defp new_label(attrs) do
    with {:ok, name} <- label_name(attrs["name"]),
         {:ok, color} <- label_color(attrs["color"] || "gray"),
         {:ok, description} <- label_description(attrs["description"]) do
      now = now()

      {:ok,
       %{
         "id" => Ids.new_task_label_id(),
         "name" => name,
         "color" => color,
         "description" => description,
         "created_at" => now,
         "updated_at" => now
       }}
    end
  end

  defp label_changes(attrs) do
    changes = %{}

    with {:ok, changes} <- maybe_change(changes, attrs, "name", &label_name/1),
         {:ok, changes} <- maybe_change(changes, attrs, "color", &label_color/1),
         {:ok, changes} <- maybe_change(changes, attrs, "description", &label_description/1) do
      if map_size(changes) == 0,
        do: {:error, {:bad_request, "nothing to update"}},
        else: {:ok, changes}
    end
  end

  defp maybe_change(changes, attrs, key, normalize) do
    if Map.has_key?(attrs, key) do
      case normalize.(attrs[key]) do
        {:ok, value} -> {:ok, Map.put(changes, key, value)}
        {:error, _} = error -> error
      end
    else
      {:ok, changes}
    end
  end

  defp insert_label(aggregate, label) do
    cond do
      length(aggregate["labels"]) >= @label_limit ->
        {:error, {:conflict, "label limit reached"}}

      Enum.any?(aggregate["labels"], &same_name?(&1, label["name"])) ->
        {:error, {:conflict, "a label with this name already exists"}}

      true ->
        aggregate
        |> Map.update!("labels", &(&1 ++ [label]))
        |> touch()
    end
  end

  defp change_label(aggregate, label_id, changes) do
    labels = aggregate["labels"]

    cond do
      not Enum.any?(labels, &(&1["id"] == label_id)) ->
        {:error, :not_found}

      Map.has_key?(changes, "name") and
          Enum.any?(labels, &(&1["id"] != label_id and same_name?(&1, changes["name"]))) ->
        {:error, {:conflict, "a label with this name already exists"}}

      true ->
        now = now()

        aggregate
        |> Map.put(
          "labels",
          Enum.map(labels, fn label ->
            if label["id"] == label_id,
              do: label |> Map.merge(changes) |> Map.put("updated_at", now),
              else: label
          end)
        )
        |> touch()
    end
  end

  defp remove_label(aggregate, label_id) do
    if Enum.any?(aggregate["labels"], &(&1["id"] == label_id)) do
      aggregate
      |> Map.update!("labels", fn labels -> Enum.reject(labels, &(&1["id"] == label_id)) end)
      |> touch()
    else
      {:error, :not_found}
    end
  end

  defp same_name?(label, name),
    do: String.downcase(label["name"] || "") == String.downcase(name || "")

  # An agent-proposed label must carry the rule a Router applies it by; the
  # human Settings path (new_label/1, label_changes/1) keeps it optional.
  defp proposed_description(value) do
    case label_description(value) do
      {:ok, ""} ->
        {:error, {:bad_request, "description is required: state when to add this label"}}

      other ->
        other
    end
  end

  defp keep_description(payload) do
    if Map.has_key?(payload, "description") and trim(payload["description"]) == "",
      do: {:error, {:bad_request, "description cannot be blank: state when to add this label"}},
      else: :ok
  end

  # ---- proposals ----

  defp new_proposal(group_id, attrs, actor) do
    op = trim(attrs["op"])
    payload = stringify(attrs["payload"] || %{})

    with :ok <- validate_op(op),
         {:ok, summary} <- proposal_summary(attrs["summary"]),
         {:ok, payload} <- validate_payload(group_id, op, payload) do
      {:ok,
       %{
         "id" => Ids.new_task_label_proposal_id(),
         "op" => op,
         "payload" => payload,
         "status" => "pending",
         "summary" => summary,
         "proposed_by" =>
           actor
           |> stringify()
           |> Map.take(~w(agent_id session_id))
           |> reject_blank(),
         "created_at" => now(),
         "resolved_at" => nil,
         "request_identity" => request_identity(actor)
       }
       |> put_source_conversation(stringify(actor)["source_conversation_id"])}
    end
  end

  # Where the Router was asked, so that chat can offer the confirmation; only a
  # conversation id is kept, and only when the actor supplied one.
  defp put_source_conversation(proposal, conversation_id) when is_binary(conversation_id) do
    if Ids.valid_conversation_id?(conversation_id),
      do: Map.put(proposal, "source_conversation_id", conversation_id),
      else: proposal
  end

  defp put_source_conversation(proposal, _conversation_id), do: proposal

  defp validate_op(op) when op in @proposal_ops, do: :ok

  defp validate_op(_op),
    do: {:error, {:bad_request, "op must be one of #{Enum.join(@proposal_ops, ", ")}"}}

  defp validate_payload(group_id, "create", payload) do
    labels = Map.get(payload, "labels", [Map.take(payload, ~w(name color description))])

    if is_list(labels) and length(labels) in 1..@batch_limit do
      with {:ok, labels} <- normalize_proposed_labels(labels),
           {:ok, target} <- optional_task_target(group_id, payload["conversation_id"]) do
        {:ok, Map.put(target, "labels", labels)}
      end
    else
      {:error, {:bad_request, "labels must contain 1 to #{@batch_limit} labels"}}
    end
  end

  defp validate_payload(_group_id, "update", payload) do
    with :ok <- require_label_id(payload["label_id"]),
         :ok <- keep_description(payload),
         {:ok, changes} <- label_changes(Map.drop(payload, ["label_id"])) do
      {:ok, Map.put(changes, "label_id", payload["label_id"])}
    end
  end

  defp validate_payload(_group_id, "delete", payload) do
    with :ok <- require_label_id(payload["label_id"]) do
      {:ok, %{"label_id" => payload["label_id"]}}
    end
  end

  defp validate_payload(group_id, "apply", payload) do
    with :ok <- validate_label_ids(payload["label_ids"]),
         {:ok, target} <- task_target(group_id, payload["conversation_id"]) do
      {:ok, Map.put(target, "label_ids", Enum.uniq(payload["label_ids"]))}
    end
  end

  defp normalize_proposed_labels(labels) do
    Enum.reduce_while(labels, {:ok, []}, fn
      attrs, {:ok, normalized} when is_map(attrs) ->
        with {:ok, label} <- new_label(stringify(attrs)),
             {:ok, description} <- proposed_description(label["description"]) do
          label =
            label |> Map.take(~w(name color description)) |> Map.put("description", description)

          {:cont, {:ok, normalized ++ [label]}}
        else
          error -> {:halt, error}
        end

      _attrs, _acc ->
        {:halt, {:error, {:bad_request, "each label must be an object"}}}
    end)
  end

  defp optional_task_target(_group_id, nil), do: {:ok, %{}}
  defp optional_task_target(group_id, id), do: task_target(group_id, id)

  defp task_target(group_id, id) do
    if Ids.valid_conversation_id?(id) do
      case Conversations.get_group_conversation(group_id, id) do
        {:ok, %{"kind" => "agent_task"} = conversation} ->
          {:ok,
           %{
             "conversation_id" => id,
             "conversation_title" => conversation["title"],
             "expected_label_revision" => conversation["label_revision"] || 0
           }}

        {:ok, _other} ->
          {:error, {:bad_request, "labels apply only to Task Conversations"}}

        {:error, _} = error ->
          error
      end
    else
      {:error, {:bad_request, "conversation_id must be a Task Conversation id"}}
    end
  end

  defp validate_label_ids(ids) do
    if is_list(ids) and length(ids) <= @label_limit and
         Enum.all?(ids, &Ids.valid_task_label_id?/1),
       do: :ok,
       else: {:error, {:bad_request, "label_ids must contain at most #{@label_limit} label ids"}}
  end

  defp require_known_labels(aggregate, ids) do
    known = MapSet.new(aggregate["labels"], & &1["id"])

    if Enum.all?(ids, &MapSet.member?(known, &1)),
      do: :ok,
      else: {:error, {:bad_request, "unknown label id; read internal.label.list"}}
  end

  defp request_identity(actor) do
    actor = stringify(actor)
    parts = Enum.map(~w(agent_id session_id tool_call_id), &actor[&1])
    if Enum.all?(parts, &(is_binary(&1) and &1 != "")), do: parts, else: nil
  end

  defp find_request_proposal(aggregate, proposal) do
    Enum.find(aggregate["proposals"], fn candidate ->
      candidate["id"] == proposal["id"] or
        (proposal["request_identity"] != nil and
           candidate["request_identity"] == proposal["request_identity"])
    end)
  end

  defp proposal_command(proposal) do
    payload = Map.drop(proposal["payload"], ~w(conversation_title expected_label_revision))

    payload =
      if proposal["op"] == "create",
        do:
          Map.update!(
            payload,
            "labels",
            &Enum.map(&1, fn label -> Map.take(label, ~w(name color description)) end)
          ),
        else: payload

    {proposal["op"], payload}
  end

  defp insert_proposal(aggregate, proposal) do
    case find_request_proposal(aggregate, proposal) do
      nil ->
        with :ok <- proposal_capacity(aggregate),
             :ok <- validate_catalog_proposal(aggregate, proposal) do
          aggregate = aggregate |> Map.update!("proposals", &(&1 ++ [proposal])) |> touch()

          if aggregate["approval_policy"] == "auto",
            do: settle_proposal(aggregate, proposal["id"], "approve", false),
            else: aggregate
        end

      existing ->
        if proposal_command(existing) == proposal_command(proposal),
          do: aggregate,
          else: {:error, {:conflict, "tool call already proposed a different label change"}}
    end
  end

  defp proposal_capacity(aggregate) do
    if Enum.count(aggregate["proposals"], &unresolved?/1) >= @pending_proposal_limit,
      do: {:error, {:conflict, "too many pending label proposals"}},
      else: :ok
  end

  defp validate_catalog_proposal(aggregate, %{
         "op" => "create",
         "payload" => %{"labels" => labels}
       }) do
    names = Enum.map(labels, &String.downcase(&1["name"]))

    pending_labels =
      aggregate["proposals"]
      |> Enum.filter(&(&1["status"] == "pending" and &1["op"] == "create"))
      |> Enum.flat_map(& &1["payload"]["labels"])

    cond do
      length(Enum.uniq(names)) != length(names) ->
        {:error, {:conflict, "a batch cannot contain duplicate label names"}}

      length(aggregate["labels"]) + length(labels) > @label_limit ->
        {:error, {:conflict, "too many labels"}}

      Enum.any?(labels, fn label ->
        Enum.any?(aggregate["labels"], &same_name?(&1, label["name"]))
      end) ->
        {:error, {:conflict, "a label with this name already exists"}}

      Enum.any?(labels, fn label -> Enum.any?(pending_labels, &same_name?(&1, label["name"])) end) ->
        {:error, {:conflict, "a label with this name is already proposed"}}

      true ->
        :ok
    end
  end

  defp validate_catalog_proposal(aggregate, %{"op" => "apply", "payload" => payload}),
    do: require_known_labels(aggregate, payload["label_ids"])

  defp validate_catalog_proposal(aggregate, %{"payload" => %{"label_id" => id}}) do
    if find_label(aggregate, id), do: :ok, else: {:error, :not_found}
  end

  defp normalize_resolution(decision) when is_binary(decision),
    do: normalize_resolution(%{"decision" => decision})

  defp normalize_resolution(%{"decision" => decision} = attrs)
       when decision in ["approve", "reject"] do
    auto = Map.get(attrs, "auto_approve", false)

    if is_boolean(auto) and (not auto or decision == "approve"),
      do: {:ok, decision, auto},
      else:
        {:error, {:bad_request, "auto_approve must be a boolean and is only valid with approve"}}
  end

  defp normalize_resolution(_attrs),
    do: {:error, {:bad_request, "decision must be approve or reject"}}

  defp validate_policy(policy) when policy in ["ask", "auto"], do: :ok

  defp validate_policy(_policy),
    do: {:error, {:bad_request, "approval_policy must be ask or auto"}}

  # The terminal decision and catalog effect commit before any owner RPC. An
  # approved decision can only be retried; rejection cannot race a Task write.
  defp settle_proposal(aggregate, proposal_id, decision, auto_approve) do
    case Enum.find(aggregate["proposals"], &(&1["id"] == proposal_id)) do
      nil ->
        {:error, :not_found}

      %{"status" => "approved"} when decision == "approve" ->
        aggregate

      %{"status" => "rejected"} when decision == "reject" ->
        aggregate

      %{"status" => "pending"} = proposal ->
        with {:ok, aggregate, proposal} <- apply_catalog_effect(aggregate, proposal, decision) do
          proposal =
            proposal
            |> Map.merge(%{
              "status" => if(decision == "approve", do: "approved", else: "rejected"),
              "resolved_at" => now()
            })

          proposal =
            if decision == "approve" and proposal["payload"]["conversation_id"],
              do: Map.put(proposal, "application_status", "pending"),
              else: proposal

          aggregate =
            if auto_approve, do: Map.put(aggregate, "approval_policy", "auto"), else: aggregate

          aggregate |> replace_proposal(proposal) |> touch()
        end

      _resolved ->
        {:error, {:conflict, "proposal already resolved"}}
    end
  end

  defp apply_catalog_effect(aggregate, proposal, "reject"), do: {:ok, aggregate, proposal}

  defp apply_catalog_effect(aggregate, %{"op" => "create"} = proposal, "approve") do
    Enum.reduce_while(proposal["payload"]["labels"], {:ok, aggregate, []}, fn attrs,
                                                                              {:ok, current,
                                                                               labels} ->
      with {:ok, label} <- new_label(attrs),
           {:ok, current} <- wrap(insert_label(current, label)) do
        {:cont, {:ok, current, labels ++ [label]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, aggregate, labels} ->
        {:ok, aggregate, put_in(proposal, ["payload", "labels"], labels)}

      error ->
        error
    end
  end

  defp apply_catalog_effect(
         aggregate,
         %{"op" => "update", "payload" => payload} = proposal,
         "approve"
       ) do
    with {:ok, aggregate} <-
           wrap(change_label(aggregate, payload["label_id"], Map.drop(payload, ["label_id"]))),
         do: {:ok, aggregate, proposal}
  end

  defp apply_catalog_effect(
         aggregate,
         %{"op" => "delete", "payload" => payload} = proposal,
         "approve"
       ) do
    with {:ok, aggregate} <- wrap(remove_label(aggregate, payload["label_id"])),
         do: {:ok, aggregate, proposal}
  end

  defp apply_catalog_effect(
         aggregate,
         %{"op" => "apply", "payload" => payload} = proposal,
         "approve"
       ) do
    with :ok <- require_known_labels(aggregate, payload["label_ids"]),
         do: {:ok, aggregate, proposal}
  end

  defp apply_task_side_effect(group_id, aggregate, proposal_id) do
    case find_proposal(aggregate, proposal_id) do
      %{"status" => "approved", "application_status" => status} = proposal
      when status in ["pending", "conflict"] ->
        payload = proposal["payload"]

        {ids, mode} =
          if proposal["op"] == "create",
            do: {Enum.map(payload["labels"], & &1["id"]), :add},
            else: {payload["label_ids"], :replace}

        result =
          ConversationServer.apply_task_label_proposal(
            group_id,
            payload["conversation_id"],
            proposal_id,
            ids,
            payload["expected_label_revision"],
            mode
          )

        {status, error} = application_result(result)

        mutate(group_id, fn current ->
          stored = Enum.find(current["proposals"], &(&1["id"] == proposal_id))

          if stored && stored["application_status"] != "applied" do
            stored =
              stored |> Map.put("application_status", status) |> Map.delete("application_error")

            stored = if error, do: Map.put(stored, "application_error", error), else: stored
            current |> replace_proposal(stored) |> touch()
          else
            current
          end
        end)

      _other ->
        {:ok, aggregate}
    end
  end

  defp application_result({:ok, _conversation}), do: {"applied", nil}

  defp application_result({:error, {kind, reason}})
       when kind in [:conflict, :bad_request] and is_binary(reason),
       do: {"conflict", reason}

  defp application_result({:error, :not_found}),
    do:
      {"conflict",
       "The Task no longer exists. Choose a current Task before assigning these labels."}

  defp application_result({:error, _reason}),
    do:
      {"pending",
       "The label change was approved, but Task assignment failed. Retry this proposal."}

  defp replace_proposal(aggregate, proposal),
    do:
      Map.update!(aggregate, "proposals", fn proposals ->
        # A newly recorded binding result belongs in the recent-result window,
        # even when its approval happened before other completed proposals.
        proposals
        |> Enum.reject(&(&1["id"] == proposal["id"]))
        |> Kernel.++([proposal])
        |> prune_resolved()
      end)

  defp wrap({:error, _} = error), do: error
  defp wrap(aggregate) when is_map(aggregate), do: {:ok, aggregate}

  # Pending decisions and unfinished assignments consume the same bounded
  # capacity. Resolved history is not an audit log or a permanent retry ledger.
  @resolved_keep 20
  defp unresolved?(proposal),
    do:
      proposal["status"] == "pending" or
        (proposal["status"] == "approved" and proposal["application_status"] == "pending")

  defp prune_resolved(proposals) do
    {pending, resolved} = Enum.split_with(proposals, &unresolved?/1)
    pending ++ Enum.take(resolved, -@resolved_keep)
  end

  # ---- field normalization ----

  defp proposal_summary(value) do
    summary = trim(value)

    if String.length(summary) <= @summary_max,
      do: {:ok, summary},
      else: {:error, {:bad_request, "summary must contain at most #{@summary_max} characters"}}
  end

  defp label_name(value) do
    name = trim(value)

    cond do
      name == "" -> {:error, {:bad_request, "name is required"}}
      String.length(name) > @name_max -> {:error, {:bad_request, "name is too long"}}
      true -> {:ok, name}
    end
  end

  # A preset name from the palette or a custom `#rrggbb` picked in Settings.
  defp label_color(value) do
    color = value |> trim() |> String.downcase()

    cond do
      color in @colors ->
        {:ok, color}

      Regex.match?(~r/^#[0-9a-f]{6}$/, color) ->
        {:ok, color}

      true ->
        {:error, {:bad_request, "color must be #rrggbb or one of #{Enum.join(@colors, ", ")}"}}
    end
  end

  defp label_description(value) do
    description = trim(value)

    if String.length(description) > @description_max,
      do: {:error, {:bad_request, "description is too long"}},
      else: {:ok, description}
  end

  defp require_label_id(id) do
    if is_binary(id) and Ids.valid_task_label_id?(id),
      do: :ok,
      else: {:error, {:bad_request, "label_id must be a label id"}}
  end

  defp require_proposal_id(id) do
    if is_binary(id) and Ids.valid_task_label_proposal_id?(id),
      do: :ok,
      else: {:error, {:bad_request, "proposal_id must be a proposal id"}}
  end

  defp touch(aggregate), do: Map.put(aggregate, "updated_at", now())

  defp now, do: System.system_time(:millisecond)

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify(_other), do: %{}

  defp reject_blank(map),
    do: map |> Enum.reject(fn {_key, value} -> value in [nil, ""] end) |> Map.new()
end
