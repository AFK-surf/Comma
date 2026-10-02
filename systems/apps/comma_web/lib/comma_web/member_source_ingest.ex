defmodule CommaWeb.MemberSourceIngest do
  @moduledoc """
  Collects one owner's member sources into the member source item pool, then
  queues the pool's consumers when items arrived, changed or still wait.

  Collection reuses the Routine member collector and its official-API reads.
  It runs every 15 minutes, when Routine needs newer items, and when a provider
  trigger signals that one source changed (`CommaWeb.MemberSourceTriggers`).
  """
  use Oban.Worker,
    queue: :comma_external,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  require Logger
  import Ecto.Query, only: [from: 2]
  alias Comma.{MemberSourceItems, RecommendationDraft, RecommendationMemberSelection}
  alias Comma.Recommendations
  alias Comma.Data.RecommendationProfile
  alias CommaWeb.{HomeMail, MemberSourceTriggers, Proactive, ProactiveCheck, ProactiveWatch}
  alias CommaWeb.{RecommendationRuntime, RecommendationSourceCollector}

  # One collection per owner every 15 minutes: at most 96 bounded member
  # collections a day. Consumers call a model only for new or changed items.
  @interval_s 15 * 60

  def interval_s, do: @interval_s

  # Home entry starts the chain and never a second one: it joins any waiting or
  # running collection. The chain continues while the owner holds the
  # workspace; a later entry restarts a chain that stopped.
  def enqueue(user, session, group) do
    with {:ok, workspace} <- Comma.Workspaces.authorize_group(user, session, group),
         true <- workspace["owner_user_id"] == user["id"],
         {:ok, _job} <- insert(%{"group_id" => group, "user_id" => user["id"]}) do
      :ok
    else
      false -> {:error, :comma_owner_authority_required}
      error -> error
    end
  end

  @doc """
  Schedules one read of a single source at `at`, after its provider signaled
  a change. A read that already waits for the source absorbs the signal.
  """
  def enqueue_source(profile_id, source_id, at) do
    insert(%{"profile_id" => profile_id, "source_id" => source_id},
      scheduled_at: at,
      unique: [period: :infinity, fields: [:worker, :args], states: [:available, :scheduled]]
    )
  end

  @impl Oban.Worker
  def timeout(_job), do: 120_000

  @impl Oban.Worker
  def backoff(_job), do: 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id, "source_id" => source_id}}) do
    with %RecommendationProfile{} = profile <- Comma.Repo.get(RecommendationProfile, profile_id),
         {:ok, %{"status" => "active"} = user} <- Comma.Accounts.get_user(profile.user_id),
         {:ok, workspace} <- Comma.Workspaces.authorize(user, %{}, profile.workspace_id),
         true <- workspace["owner_user_id"] == profile.user_id,
         {:ok, true} <- Proactive.automatic?(workspace["default_group_id"], profile.user_id) do
      case ingest(workspace, profile.user_id, source_ids: [source_id], proactive: true) do
        {:ok, outcome} ->
          Logger.info("member_source_ingest signal outcome=#{inspect(outcome)}")

        {:error, reason} ->
          Logger.warning("member_source_ingest signal failed reason=#{inspect(reason, limit: 3)}")
      end

      :ok
    else
      # The profile or the owner's access is gone, or the owner turned
      # automatic messages off. Nothing is read.
      _ -> :ok
    end
  end

  def perform(%Oban.Job{args: %{"group_id" => group, "user_id" => owner}}) do
    with {:ok, workspace, ctx, home} <- HomeMail.context(%{"id" => owner}, %{}, group),
         true <- workspace["owner_user_id"] == owner,
         # This chain replaced the default proactive Loops; they converge here.
         :ok <- ProactiveWatch.retire_defaults(ctx, owner),
         # The chain collects for the owner's automatic messages. While they are
         # off it stops; turning them on starts it again.
         {:ok, true} <- Proactive.automatic?(group, owner) do
      # Task matters the owner already answered in the Task close here.
      CommaWeb.ProactiveTask.reconcile(ctx, home, owner)

      case ingest(workspace, owner, proactive: true) do
        {:ok, outcome} ->
          Logger.info("member_source_ingest outcome=#{inspect(outcome)}")

        {:error, reason} ->
          Logger.warning("member_source_ingest failed reason=#{inspect(reason, limit: 3)}")
          # The notebook shows the failed read.
          CommaWeb.ProactiveNotebook.enqueue(group, owner)
      end

      # The running collection is incomplete itself, so its successor is unique
      # only among scheduled collections. Two chains that meet there merge.
      with {:ok, _job} <-
             insert(%{"group_id" => group, "user_id" => owner},
               schedule_in: @interval_s,
               unique: [period: :infinity, fields: [:worker, :args], states: [:scheduled]]
             ),
           do: :ok
    else
      # The owner no longer holds this workspace or turned automatic messages
      # off. The chain stops.
      false -> :ok
      {:ok, false} -> :ok
      {:error, reason} when reason in [:forbidden, :not_found] -> :ok
      error -> error
    end
  end

  defp insert(args, opts \\ []), do: args |> new(opts) |> then(&Oban.insert(Comma.Oban, &1))

  @doc """
  Collects the member's enabled sources once and records them in the pool.
  This is the only member source read path; Routine and every consumer read
  the pool. Options: `:source_ids` reads only those enabled sources,
  `proactive: true` (the owner has automatic messages on) keeps the source
  triggers and queues the proactive consumer, and the collector's
  `:collection_timeout_ms`.
  """
  def ingest(workspace, owner, opts \\ []) do
    with {:ok, profile} <- Recommendations.get_runtime_profile(workspace["id"], owner),
         "member" <- Recommendations.relevance_mode(profile),
         enabled = MemberSourceItems.enabled_source_ids(profile),
         read = Enum.filter(enabled, &(is_nil(opts[:source_ids]) or &1 in opts[:source_ids])),
         {:ok, collection} <- read(workspace, profile, owner, read, opts),
         {:ok, counts} <- record(profile.id, pool(collection), enabled) do
      # Triggers and the proactive consumer serve the owner's automatic
      # messages. Arrivals that Routine records wait for the next chain run.
      if opts[:proactive] == true do
        MemberSourceTriggers.ensure(workspace, profile.id)
        # The notebook shows each source's latest read.
        CommaWeb.ProactiveNotebook.enqueue(workspace["default_group_id"], owner)

        if MemberSourceItems.pending?(profile.id),
          do: with({:ok, _job} <- ProactiveCheck.enqueue(profile.id), do: {:ok, counts}),
          else: {:ok, counts}
      else
        {:ok, counts}
      end
    else
      "generic" -> {:ok, :idle}
      {:error, :not_found} -> {:ok, :idle}
      {:error, _} = error -> error
    end
  end

  # Binding checks and recording share the lock used by settings and source
  # purges. A read that completed before a rebind cannot restore old evidence.
  defp record(profile_id, collection, enabled) do
    Comma.Repo.transaction(fn ->
      profile =
        Comma.Repo.one!(
          from(p in RecommendationProfile, where: p.id == ^profile_id, lock: "FOR UPDATE")
        )

      collected =
        Map.filter(collection.collected, fn {id, source} ->
          RecommendationRuntime.member_subjects_valid?(profile, %{id => source["subject"]})
        end)

      withdrawn = Map.keys(collection.collected) -- Map.keys(collected)

      :ok =
        MemberSourceItems.retain_sources(
          profile.id,
          MemberSourceItems.enabled_source_ids(profile) -- withdrawn
        )

      {:ok, counts} =
        MemberSourceItems.record(profile_id, %{collection | collected: collected}, enabled)

      counts
    end)
  end

  defp read(_workspace, _profile, _owner, [], _opts), do: {:ok, %{facts: [], failures: []}}

  defp read(workspace, profile, owner, source_ids, opts),
    do:
      RecommendationSourceCollector.collect(
        workspace,
        Enum.filter(profile.sources, &(&1["connectionId"] in source_ids)),
        opts |> Keyword.take([:collection_timeout_ms]) |> Keyword.put(:member_user_id, owner)
      )

  @doc """
  The pool's current items in the collection shape Routine consumes. Options:
  `:max_age_s` and the collector's `:collection_timeout_ms`.
  """
  def collection(workspace, profile, opts) do
    started = System.monotonic_time(:millisecond)

    with {:ok, sources} <-
           pooled(workspace, profile, MemberSourceItems.enabled_source_ids(profile), opts) do
      {:ok,
       %{
         facts: for(%{collected: true} = source <- sources, do: fact(source)),
         failures:
           for(
             %{state: %{failure: %{} = failure} = state} <- sources,
             do: Map.put(failure, "sourceId", state.source_id)
           ),
         duration_ms: System.monotonic_time(:millisecond) - started
       }}
    end
  end

  # The pool is collected again first when an enabled source was not attempted
  # within `:max_age_s` or its latest attempt failed, as every run retried
  # failed sources. Items read under an account binding the member has since
  # changed are also read again: publication would reject them.
  defp pooled(workspace, profile, enabled, opts) do
    sources = current(profile.id, enabled)

    if enabled == [] or
         (MemberSourceItems.fresh?(profile.id, enabled, opts[:max_age_s]) and
            Enum.all?(sources, & &1.collected) and
            RecommendationRuntime.member_subjects_valid?(profile, subjects(sources))) do
      {:ok, sources}
    else
      with {:ok, _} <-
             ingest(workspace, profile.user_id, Keyword.take(opts, [:collection_timeout_ms])),
           do: {:ok, current(profile.id, enabled)}
    end
  end

  defp current(profile_id, enabled),
    do: Enum.filter(MemberSourceItems.current(profile_id), &(&1.state.source_id in enabled))

  defp subjects(sources),
    do:
      for(
        %{collected: true, state: %{subject: %{} = subject} = state} <- sources,
        into: %{},
        do: {state.source_id, subject}
      )

  # One pooled source as a collected fact. Gmail keeps the mail identities the
  # mail Task projection and Routine attention items read.
  defp fact(%{state: state, items: items}) do
    %{
      "sourceId" => state.source_id,
      "appId" => state.toolkit,
      "toolkit" => state.toolkit,
      "appName" => state.app,
      "memberSubject" => state.subject,
      "bound" => state.bound,
      "items" => Enum.map(items, &candidate/1),
      "data" =>
        if(state.toolkit == "gmail",
          do: %{
            "messages" =>
              Enum.map(items, fn item ->
                %{
                  "webUrl" => item.url,
                  "threadId" => item.provider_ids["threadId"],
                  "messageId" => item.provider_ids["messageId"]
                }
              end)
          },
          else: %{}
        )
    }
  end

  defp candidate(item),
    do: %{
      "title" => item.title,
      "url" => item.url,
      "excerpt" => item.excerpt,
      "relationship" => item.relationship,
      "recipient" => item.recipient,
      "context" => item.context,
      "facts" => item.facts,
      "promptContext" => item.prompt_context,
      "sourceVersion" => item.fingerprint
    }

  @doc """
  After the mail Task projection removed handled or finished mail, the pooled
  Gmail candidates follow the mail that remains.
  """
  def keep_mail(collection) do
    facts =
      Enum.map(collection.facts, fn
        %{"toolkit" => "gmail", "items" => items, "data" => data} = fact ->
          urls = MapSet.new(data["messages"] || [], & &1["webUrl"])
          Map.put(fact, "items", Enum.filter(items, &MapSet.member?(urls, &1["url"])))

        fact ->
          fact
      end)

    %{collection | facts: facts}
  end

  @doc """
  The member context of a pooled collection. As in collection, an item is a
  candidate only when the run admitted its URL as evidence of its source.
  """
  def context(collection, evidence),
    do:
      RecommendationDraft.prepare_pool(
        Enum.map(collection.facts, fn fact ->
          admitted = MapSet.new(evidence[fact["sourceId"]] || [])

          %{
            source: Map.take(fact, ~w(sourceId toolkit appName)),
            items: Enum.filter(fact["items"] || [], &MapSet.member?(admitted, &1["url"]))
          }
        end)
      )

  # The pool's view of one collection: each collected source with its
  # normalized candidates and any partial-read warning, and each failed source.
  defp pool(collection) do
    failures =
      Map.new(collection.failures, &{&1["sourceId"], Map.take(&1, ~w(appId class message))})

    items = items(collection.facts)

    collected =
      Map.new(collection.facts, fn fact ->
        {fact["sourceId"],
         %{
           "toolkit" => fact["toolkit"],
           "app" => fact["appName"],
           "subject" => fact["memberSubject"],
           "bound" => fact["bound"],
           "warning" => failures[fact["sourceId"]],
           "items" => items[fact["sourceId"]] || []
         }}
      end)

    %{collected: collected, failed: Map.drop(failures, Map.keys(collected))}
  end

  # Every admitted member candidate of each collected source, normalized once.
  defp items(facts) do
    context = RecommendationDraft.prepare(facts, Recommendations.source_evidence(facts), "member")

    context
    |> RecommendationMemberSelection.candidates()
    |> Enum.flat_map(fn candidate ->
      fact = context.sources[candidate["source"]]

      if is_binary(fact["sourceId"]) and is_binary(candidate["url"]),
        do: [{fact["sourceId"], item(candidate, fact)}],
        else: []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp item(candidate, fact) do
    prompt_context = RecommendationDraft.prompt_context(candidate)

    mail =
      if fact["toolkit"] == "gmail",
        do:
          Enum.find(
            mail_data(fact["data"])["messages"] || [],
            &(&1["webUrl"] == candidate["url"])
          ) || %{},
        else: %{}

    %{
      "item_key" => digest(candidate["url"]),
      "toolkit" => fact["toolkit"],
      "app" => fact["appName"],
      "url" => candidate["url"],
      "title" => candidate["title"],
      "excerpt" => candidate["excerpt"],
      "context" => candidate["context"],
      "prompt_context" => prompt_context,
      "relationship" => candidate["relationship"],
      "recipient" => candidate["recipient"],
      "facts" => candidate["facts"] || %{},
      "provider_ids" => Map.take(mail, ~w(threadId messageId))
    }
  end

  # A bounded collection wraps large source data; the mail list is inside.
  defp mail_data(%{"_comma" => %{}, "value" => %{} = value}), do: value
  defp mail_data(%{} = data), do: data
  defp mail_data(_data), do: %{}

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
