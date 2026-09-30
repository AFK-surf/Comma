defmodule BridgeForTeams.ContextLifecycle do
  @moduledoc """
  Source-neutral registration boundary for product-owned context lifecycle.

  Source adapters register immutable bundle identity, classification, policy,
  and a bounded subject index. Retention policy, erasure, legal hold, and
  physical deletion belong to this shared ownership boundary; a Slack
  disconnect is not a lifecycle event. This slice implements explicit deletion
  and erasure, pre-purge restore, retry, and source-adapter purge. It does not
  yet schedule retention periods or implement legal holds.

  Lifecycle requests, recovery, leases, retries, and content-free completion
  evidence all use the same bundle identity. Source adapters only know how to
  purge their storage layout; they do not decide retention policy.
  """

  import Ecto.Query

  alias BridgeForTeams.Repo
  alias BridgeForTeams.ContextLifecycle.Operations

  alias BridgeForTeams.Schema.{
    ContextBundle,
    ContextBundleSubject,
    Organization,
    Project
  }

  @max_subjects 100

  @spec register_bundle(map()) :: {:ok, ContextBundle.t()} | {:error, term()}
  def register_bundle(attrs) when is_map(attrs) do
    registration = registration_attrs(attrs)

    with {:ok, subjects} <- normalize_subjects(value(attrs, :subjects)),
         :ok <- validate_scope(registration) do
      case Repo.transaction(fn -> persist_registration(registration, subjects) end) do
        {:ok, %ContextBundle{} = bundle} -> {:ok, bundle}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def register_bundle(_attrs), do: {:error, :invalid_registration}

  @spec get_bundle(Ecto.UUID.t()) :: {:ok, ContextBundle.t()} | {:error, :not_found}
  def get_bundle(id) do
    case Repo.get(ContextBundle, id) do
      nil -> {:error, :not_found}
      bundle -> {:ok, preload_subjects(bundle)}
    end
  end

  @doc "Add newly observed subjects without changing a bundle's immutable source identity."
  @spec add_subjects(Ecto.UUID.t(), [map()]) :: {:ok, ContextBundle.t()} | {:error, term()}
  def add_subjects(bundle_id, subjects) do
    with {:ok, subjects} <- normalize_subjects(subjects) do
      case Repo.transaction(fn -> persist_added_subjects(bundle_id, subjects) end) do
        {:ok, %ContextBundle{} = bundle} -> {:ok, bundle}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Request an explicit full-bundle deletion through the shared lifecycle owner."
  defdelegate request_deletion(bundle_id, attrs), to: Operations, as: :request_deletion

  @doc "Request an explicit full-bundle erasure through the shared lifecycle owner."
  defdelegate request_erasure(bundle_id, attrs), to: Operations, as: :request_erasure

  @doc "Cancel a pending/retryable lifecycle request before any purge commits."
  defdelegate restore(bundle_id, attrs), to: Operations, as: :restore

  @doc "Claim a lifecycle request with a durable fenced lease."
  defdelegate claim(request_id, worker_id), to: Operations, as: :claim

  @doc "Run a claimed source-layout purge inside the lifecycle transaction."
  defdelegate run_claim(claim, opts \\ []), to: Operations, as: :run_claim

  @doc "Read an authorized lifecycle request and its content-free completion evidence."
  defdelegate get_request(request_id, user_id), to: Operations, as: :get_request

  @doc "Find the bounded bundles covered by one subject for shared privacy orchestration."
  defdelegate list_bundles_for_subject(org_id, kind, ref, user_id, opts \\ []),
    to: Operations,
    as: :list_bundles_for_subject

  defp persist_added_subjects(bundle_id, subjects) do
    bundle =
      Repo.one(
        from(bundle in ContextBundle,
          where: bundle.id == ^bundle_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:not_found)

    if bundle.lifecycle_state != "registered" do
      Repo.rollback(:bundle_not_writable)
    end

    existing_count =
      Repo.aggregate(
        from(subject in ContextBundleSubject, where: subject.bundle_id == ^bundle.id),
        :count
      )

    existing_keys =
      Repo.all(
        from(subject in ContextBundleSubject,
          where: subject.bundle_id == ^bundle.id,
          select: {subject.kind, subject.ref}
        )
      )
      |> MapSet.new()

    additions = Enum.reject(subjects, &MapSet.member?(existing_keys, {&1.kind, &1.ref}))

    if existing_count + length(additions) > @max_subjects do
      Repo.rollback(:too_many_subjects)
    end

    Enum.each(additions, fn subject ->
      %ContextBundleSubject{}
      |> ContextBundleSubject.changeset(Map.put(subject, :bundle_id, bundle.id))
      |> Repo.insert!()
    end)

    preload_subjects(bundle)
  end

  defp persist_registration(registration, subjects) do
    lock_idempotency_key(registration)

    case find_idempotent_registration(registration) do
      nil -> insert_registration(registration, subjects)
      existing -> validate_idempotent_registration(existing, registration, subjects)
    end
  end

  defp insert_registration(registration, subjects) do
    case %ContextBundle{}
         |> ContextBundle.registration_changeset(registration)
         |> Repo.insert() do
      {:ok, bundle} ->
        Enum.each(subjects, fn subject ->
          %ContextBundleSubject{}
          |> ContextBundleSubject.changeset(Map.put(subject, :bundle_id, bundle.id))
          |> Repo.insert!()
        end)

        bundle
        |> ContextBundle.lifecycle_changeset(%{
          lifecycle_state: "registered",
          subject_index_state: "complete",
          lifecycle_revision: 0
        })
        |> Repo.update!()
        |> preload_subjects()

      {:error, %Ecto.Changeset{} = changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp find_idempotent_registration(registration) do
    Repo.one(
      from(bundle in ContextBundle,
        where:
          bundle.org_id == ^registration.org_id and
            bundle.source_type == ^registration.source_type and
            bundle.source_ref == ^registration.source_ref
      )
    )
  end

  defp validate_idempotent_registration(existing, registration, subjects) do
    existing = preload_subjects(existing)

    if same_registration?(existing, registration, subjects) do
      existing
    else
      Repo.rollback(:idempotency_conflict)
    end
  end

  defp lock_idempotency_key(registration) do
    key =
      Enum.join(
        [
          "context_bundle",
          registration.org_id,
          registration.source_type,
          registration.source_ref
        ],
        ":"
      )

    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
  end

  defp same_registration?(bundle, registration, subjects) do
    bundle.project_id == registration.project_id and
      bundle.classification == registration.classification and
      bundle.policy_ref == registration.policy_ref and
      bundle.lifecycle_state == "registered" and
      bundle.subject_index_state == "complete" and
      MapSet.subset?(
        MapSet.new(subject_keys(subjects)),
        MapSet.new(subject_keys(bundle.subjects))
      )
  end

  defp preload_subjects(bundle) do
    query = from(subject in ContextBundleSubject, order_by: [asc: subject.kind, asc: subject.ref])
    Repo.preload(bundle, subjects: query)
  end

  defp subject_keys(subjects), do: Enum.map(subjects, &{&1.kind, &1.ref}) |> Enum.sort()

  defp registration_attrs(attrs) do
    %{
      org_id: value(attrs, :org_id),
      project_id: value(attrs, :project_id),
      source_type: normalize_string(value(attrs, :source_type)),
      source_ref: normalize_string(value(attrs, :source_ref)),
      classification: normalize_string(value(attrs, :classification)),
      policy_ref: normalize_string(value(attrs, :policy_ref))
    }
  end

  defp normalize_subjects(subjects) when is_list(subjects) do
    if subjects == [] or length(subjects) > @max_subjects do
      {:error, :invalid_subjects}
    else
      subjects
      |> Enum.reduce_while({:ok, []}, fn subject, {:ok, acc} ->
        normalized = %{
          kind: normalize_string(value(subject, :kind)),
          ref: normalize_string(value(subject, :ref))
        }

        if normalized.kind == "" or normalized.ref == "" do
          {:halt, {:error, :invalid_subjects}}
        else
          {:cont, {:ok, [normalized | acc]}}
        end
      end)
      |> case do
        {:ok, normalized} ->
          {:ok, normalized |> Enum.uniq() |> Enum.sort_by(&{&1.kind, &1.ref})}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp normalize_subjects(_subjects), do: {:error, :invalid_subjects}

  defp validate_scope(%{org_id: org_id, project_id: project_id}) do
    case {Repo.get(Organization, org_id), project_id && Repo.get(Project, project_id)} do
      {%Organization{status: "active"}, nil} when is_nil(project_id) ->
        :ok

      {%Organization{status: "active"}, nil} ->
        {:error, :project_not_found}

      {%Organization{status: "active", id: org_id}, %Project{org_id: org_id, archived_at: nil}} ->
        :ok

      {nil, _project} ->
        {:error, :org_not_found}

      {%Organization{}, _project} ->
        {:error, :org_inactive}

      {_org, %Project{}} ->
        {:error, :project_outside_org}
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(_value), do: ""
end
