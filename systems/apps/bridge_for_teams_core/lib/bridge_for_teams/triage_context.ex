defmodule BridgeForTeams.TriageContext do
  @moduledoc """
  Team/Project Memory projection for the native Triage port.

  Prepare the domain-owned Worker before freezing the read-only product snapshot.

  The sealed receipt authority is the only lookup key. Product project/member
  and meeting facts stay authoritative in BFT; this adapter merely freezes a
  source-referenced snapshot and never writes product Memory or the Triage
  ledger. The identity path pins its current connect and Slack reader to the
  production owners; ordinary fixture mode may still inject its closed ports.
  """

  require Logger

  alias BridgeForTeams.{Agents, Meetings, Memberships, Projects}
  alias BridgeForTeams.SourcedContext.Grounding
  alias SalixIM.ProviderConnects
  alias SalixIM.Provider.Slack.Addressee

  alias SalixIM.Triage.{
    CanonicalJSON,
    ExpressionContext,
    FileAttachments,
    IdentityContract,
    IdentityFenceHandle
  }

  @required_authority ~w(connect_id connect_generation workspace_id channel_id thread_ts)
  @identity_option_keys ~w(
    identity_allowlist
    identity_fence_handle
    product_source
    thread_reader
  )a
  @identity_product_source __MODULE__.ProductSource
  @identity_thread_reader Salix.Bindings.ClickHouseTriageThreadReader
  @sourced_context_fact_limit 20
  @identity_allowlist_fields ~w(
    schema
    provider
    operation
    tenant_id
    group_id
    connect_id
    connect_generation
    workspace_id
    approved_channel_id
    root_ts
    inbound_agent_id
    app_id
    bot_user_id
    bot_id
    endpoint_revision_sha256
    project_id
    project_status
    agent_id
    agent_role
    agent_name
    self_agent_identity_revision_sha256
    source_origin_sha256
  )
  alias SalixIM.Triage.ChannelBatch

  @sha256 ~r/\A[0-9a-f]{64}\z/
  @raw_uri ~r/\b[a-z][a-z0-9+.-]*:\/\/[^\s<>"']+/i
  @slack_mrkdwn_link ~r/<(https?:\/\/[^>|]+)(?:\|[^>]*)?>/i

  @spec freeze(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def freeze(%{"source_authority" => authority} = input, opts) when is_map(authority) do
    with :ok <- validate_identity_configuration(opts),
         :ok <- validate_identity_allowlist(opts) do
      do_freeze(input, authority, opts)
    end
  end

  def freeze(_input, _opts), do: {:error, :invalid_triage_input}

  defp do_freeze(input, authority, opts) do
    product_source = Keyword.get(opts, :product_source, @identity_product_source)

    with :ok <- validate_identity_preflight(input, opts),
         :ok <- validate_authority(authority),
         {:ok, connect} <- resolve_connect(product_source, authority, opts),
         :ok <- validate_connect(connect, authority),
         :ok <- validate_identity_connect_allowlist(connect, authority, opts),
         {:ok, identity_revision_status} <- validate_identity_input(input, connect),
         {:ok, product} <-
           load_product(
             product_source,
             connect,
             opts
             |> Keyword.put(:knowledge_query, knowledge_query(input))
             |> Keyword.put(:recheck_context_refs, recheck_context_refs(input))
             |> Keyword.put(
               :trajectory_target,
               authority |> ChannelBatch.target(input["events"]) |> Map.take(@required_authority)
             )
           ),
         :ok <- validate_identity_product_members(product, opts),
         {:ok, identity_base} <-
           identity_base(input, connect, product, identity_revision_status),
         :ok <- validate_identity_product_allowlist(product, identity_base, opts),
         {:ok, identity_profile} <-
           identity_profile(authority, connect, product, identity_base, opts),
         :ok <- validate_derived_identity_profile(identity_profile, opts),
         {:ok, thread} <- read_thread(authority, connect, identity_profile, input, opts),
         {:ok, full_slack_context} <- slack_context(thread, authority),
         {:ok, slack_context} <-
           expression_slack_context(full_slack_context, authority, connect, opts),
         {:ok, recheck} <- compatibility_recheck(input, thread, full_slack_context, connect, opts),
         {:ok, identity_context} <-
           identity_context(identity_base, input, thread, authority),
         {:ok, product} <-
           prepare_worker(
             product_source,
             product,
             connect,
             input,
             slack_context,
             identity_context
           ) do
      context = %{
        "slack_context" => slack_context,
        "team_project_memory" => team_project_memory(product, input, authority, connect, opts)
      }

      context = if recheck, do: Map.put(context, "answered_recheck", recheck), else: context

      finish_context(
        maybe_put_identity_context(context, identity_context),
        input,
        authority,
        connect,
        product,
        thread,
        opts
      )
    end
  end

  defp finish_context(context, input, authority, connect, product, thread, opts) do
    if identity_mode?(opts) do
      project_identity_context(context, input, authority, connect, product, thread, opts)
    else
      {:ok, context}
    end
  end

  defp validate_identity_preflight(input, opts) do
    if identity_mode?(opts) do
      case {input["schema"],
            IdentityContract.classify_event_provenance(List.wrap(input["events"])),
            input["source_mode"]} do
        {"comma.triage-input-snapshot.v2", {:ok, :identity_enabled}, source_mode}
        when source_mode in [
               "callback",
               "clickhouse_etl",
               "historical_thread_reenactment",
               "periodic_patrol",
               "scheduled_recheck"
             ] ->
          :ok

        {"comma.triage-input-snapshot.v2", {:ok, :identity_enabled}, _other} ->
          {:error, :invalid_identity_source_mode}

        {"comma.triage-input-snapshot.v2", {:ok, :legacy}, _source_mode} ->
          {:error, :identity_provenance_missing}

        {"comma.triage-input-snapshot.v2", {:error, reason}, _source_mode} ->
          {:error, reason}

        {_schema, _provenance, _source_mode} ->
          {:error, :identity_schema_mismatch}
      end
    else
      :ok
    end
  end

  defp validate_identity_configuration(opts) do
    cond do
      identity_mode?(opts) ->
        keys = Keyword.keys(opts)

        valid? =
          Keyword.keyword?(opts) and length(keys) == length(Enum.uniq(keys)) and
            Enum.all?(keys, &(&1 in @identity_option_keys)) and
            match?(%IdentityFenceHandle{}, opts[:identity_fence_handle]) and
            Keyword.get(opts, :product_source, @identity_product_source) ==
              @identity_product_source and
            Keyword.get(opts, :thread_reader, @identity_thread_reader) == @identity_thread_reader

        if valid?, do: :ok, else: {:error, :invalid_identity_diagnostic_configuration}

      Keyword.has_key?(opts, :identity_allowlist) ->
        {:error, :invalid_identity_diagnostic_configuration}

      true ->
        :ok
    end
  end

  defp validate_identity_allowlist(opts) do
    case Keyword.fetch(opts, :identity_allowlist) do
      :error ->
        :ok

      {:ok, allowlist} when is_map(allowlist) ->
        hashes =
          ~w(endpoint_revision_sha256 self_agent_identity_revision_sha256 source_origin_sha256)

        valid? =
          Map.keys(allowlist) |> Enum.sort() == Enum.sort(@identity_allowlist_fields) and
            Enum.all?(@identity_allowlist_fields, &present?(allowlist[&1])) and
            allowlist["schema"] == "comma.triage-identity-selector.v2" and
            allowlist["provider"] == "slack" and
            allowlist["operation"] in ~w(clickhouse.thread_current clickhouse.channel_current) and
            allowlist["project_status"] == "active" and
            allowlist["agent_role"] in ["router", "worker"] and
            Enum.all?(hashes, &Regex.match?(@sha256, allowlist[&1]))

        if valid?, do: :ok, else: {:error, :invalid_identity_allowlist}

      {:ok, _other} ->
        {:error, :invalid_identity_allowlist}
    end
  end

  defp resolve_connect(source, authority, opts) do
    safe_apply(source, :resolve_connect, [authority, opts], :product_connect_source)
  end

  defp prepare_worker(@identity_product_source, product, connect, input, slack, identity) do
    if input["source_mode"] in ~w(callback clickhouse_etl periodic_patrol) do
      with {:ok, target} <- raw_decision_target(slack["messages"], identity, input) do
        context = %{
          "identity_context" => identity,
          "slack_context" => Map.put(slack, "decision_target", target)
        }

        if SalixIM.Triage.WorkerSelection.intake?(context),
          do: prepare_intake_worker(product, connect),
          else: {:ok, product}
      end
    else
      {:ok, product}
    end
  end

  defp prepare_worker(_fixture_source, product, _connect, _input, _slack, _identity),
    do: {:ok, product}

  defp prepare_intake_worker(product, connect) do
    with %{status: "active"} = project <- product.project,
         {:ok, router} <- Agents.current_router(project),
         true <- router.salix_agent_id == connect["inbound_agent_id"],
         {:ok, worker_id} <-
           BridgeForTeams.Salix.Client.impl().ensure_triage_worker(
             connect["group_id"],
             router.salix_agent_id
           ),
         {:ok, %{role: "worker"} = worker} <- Agents.get_project_agent(project.id, worker_id),
         true <- BridgeForTeams.Schema.Agent.active?(worker) do
      {:ok, Map.put(product, :investigation_workers, [worker])}
    else
      _ -> {:error, :triage_worker_unavailable}
    end
  end

  defp load_product(source, connect, opts),
    do: safe_apply(source, :load_product, [connect, opts], :product_fact_source)

  defp knowledge_query(input) do
    input
    |> Map.get("events", [])
    |> List.wrap()
    |> Enum.take(-20)
    |> Enum.reverse()
    |> Enum.map(&(trim(&1["text"]) |> String.replace(~r/\s+/u, " ")))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(8)
    |> Enum.map(&(&1 |> String.codepoints() |> Enum.take(64) |> Enum.join()))
    |> Enum.join(" ")
    |> String.codepoints()
    |> Enum.take(512)
    |> Enum.join()
  end

  defp recheck_context_refs(input) do
    input
    |> Map.get("events", [])
    |> Enum.flat_map(fn
      %{"source_mode" => "scheduled_recheck", "recheck_context_ref" => ref}
      when is_binary(ref) ->
        [ref]

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp read_thread(authority, connect, identity_profile, input, opts) do
    if identity_mode?(opts) do
      with {:ok, reader_opts, source_observation} <-
             identity_thread_reader_opts(authority, identity_profile, input, opts),
           {:ok, thread} <-
             safe_apply(
               @identity_thread_reader,
               :read,
               [authority, connect, reader_opts],
               :thread_reader
             ) do
        {:ok,
         thread
         |> Map.put("identity_profile", identity_profile)
         |> Map.put("identity_source_observation", source_observation)}
      end
    else
      case Keyword.fetch(opts, :thread_reader) do
        {:ok, configured} ->
          {source, source_opts} = normalize_source(configured)
          safe_apply(source, :read, [authority, connect, source_opts], :thread_reader)

        :error ->
          {:error, :triage_thread_reader_not_configured}
      end
    end
  end

  defp identity_thread_reader_opts(authority, identity_profile, input, opts) do
    selector = ChannelBatch.selector(authority, identity_profile, input["events"])

    with {:ok, profile_bytes} <- CanonicalJSON.encode(identity_profile),
         {:ok, selector_bytes} <- CanonicalJSON.encode(selector),
         {:ok, source_observation, source_observation_sha256} <- source_observation() do
      {:ok,
       [
         identity_fence_handle: Keyword.fetch!(opts, :identity_fence_handle),
         identity_profile_sha256: CanonicalJSON.sha256(profile_bytes),
         request_selector_sha256: CanonicalJSON.sha256(selector_bytes),
         source_origin_sha256: identity_profile["source_origin_sha256"],
         source_observation_sha256: source_observation_sha256
       ]
       |> then(fn reader_opts ->
         if ChannelBatch.channel?(authority),
           do: Keyword.put(reader_opts, :source_window, selector["source_window"]),
           else: reader_opts
       end), source_observation}
    end
  end

  defp identity_profile(authority, connect, product, identity_base, opts) do
    if identity_mode?(opts) do
      build_identity_profile(authority, connect, product, identity_base)
    else
      {:ok, nil}
    end
  end

  defp build_identity_profile(authority, connect, product, identity_base) do
    operation = ChannelBatch.operation(authority)

    with {:ok, endpoint_revision} <- IdentityContract.endpoint_revision_sha256(connect),
         {:ok, source_origin_sha256} <- source_origin_sha256() do
      {:ok,
       %{
         "schema" => "comma.triage-identity-selector.v2",
         "provider" => connect["provider"],
         "operation" => operation,
         "tenant_id" => connect["tenant_id"],
         "group_id" => connect["group_id"],
         "connect_id" => connect["connect_id"],
         "connect_generation" => connect["connect_generation"],
         "workspace_id" => connect["workspace_id"],
         "approved_channel_id" => connect["approved_channel_id"],
         "root_ts" => authority["thread_ts"],
         "inbound_agent_id" => connect["inbound_agent_id"],
         "app_id" => connect["app_id"],
         "bot_user_id" => connect["bot_user_id"],
         "bot_id" => connect["bot_id"],
         "endpoint_revision_sha256" => endpoint_revision,
         "project_id" => product.project.id,
         "project_status" => product.project.status,
         "agent_id" => product.agent.salix_agent_id,
         "agent_role" => product.agent.role,
         "agent_name" => String.trim(product.agent.salix["name"]),
         "self_agent_identity_revision_sha256" =>
           get_in(identity_base, ["self_agent", "identity_revision_sha256"]),
         "source_origin_sha256" => source_origin_sha256
       }}
    end
  end

  defp source_origin_sha256 do
    apply(@identity_thread_reader, :observed_read_origin_sha256, [])
  rescue
    _exception -> {:error, :clickhouse_read_origin_unavailable}
  catch
    _kind, _reason -> {:error, :clickhouse_read_origin_unavailable}
  end

  defp validate_derived_identity_profile(nil, opts) do
    if identity_mode?(opts),
      do: {:error, :invalid_identity_profile},
      else: :ok
  end

  defp validate_derived_identity_profile(profile, opts) when is_map(profile) do
    configured = opts[:identity_allowlist]

    valid? =
      Map.keys(profile) |> Enum.sort() == Enum.sort(@identity_allowlist_fields) and
        Enum.all?(@identity_allowlist_fields, &present?(profile[&1])) and
        profile["schema"] == "comma.triage-identity-selector.v2" and
        profile["provider"] == "slack" and
        profile["operation"] in ~w(clickhouse.thread_current clickhouse.channel_current) and
        profile["project_status"] == "active" and profile["agent_role"] in ["router", "worker"] and
        Enum.all?(
          ~w(endpoint_revision_sha256 self_agent_identity_revision_sha256 source_origin_sha256),
          &Regex.match?(@sha256, profile[&1])
        ) and (is_nil(configured) or configured == profile)

    if valid?, do: :ok, else: {:error, :invalid_identity_profile}
  end

  defp source_observation do
    [
      __MODULE__,
      @identity_product_source,
      SalixIM.ProviderConnects,
      SalixIM.Triage.ExpressionContext,
      @identity_thread_reader
    ]
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, observations} ->
      case :code.get_object_code(module) do
        {^module, object_code, _path} when is_binary(object_code) ->
          observation = %{
            "module" => Atom.to_string(module),
            "object_code_sha256" => CanonicalJSON.sha256(object_code)
          }

          {:cont, {:ok, [observation | observations]}}

        _other ->
          {:halt, {:error, :identity_source_observation_unavailable}}
      end
    end)
    |> case do
      {:ok, observations} ->
        observation = %{
          "schema" => "comma.triage-source-observation.v1",
          "modules" => Enum.reverse(observations)
        }

        observation
        |> CanonicalJSON.encode()
        |> case do
          {:ok, bytes} -> {:ok, observation, CanonicalJSON.sha256(bytes)}
          {:error, _reason} -> {:error, :identity_source_observation_unavailable}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp safe_apply(source, function, args, boundary) do
    apply(source, function, args)
  rescue
    error -> {:error, {boundary, :exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {boundary, kind, reason}}
  end

  defp validate_authority(authority) do
    if Enum.all?(@required_authority, &present?(authority[&1])),
      do: :ok,
      else: {:error, :invalid_source_authority}
  end

  defp validate_connect(connect, authority) when is_map(connect) do
    exact? =
      connect["provider"] == "slack" and
        connect["connect_id"] == authority["connect_id"] and
        connect["connect_generation"] == authority["connect_generation"] and
        connect["workspace_id"] == authority["workspace_id"] and
        connect["approved_channel_id"] == authority["channel_id"] and
        present?(connect["group_id"])

    if exact?, do: :ok, else: {:error, :stale_source_authority}
  end

  defp validate_connect(_connect, _authority), do: {:error, :stale_source_authority}

  defp validate_identity_connect_allowlist(connect, authority, opts) do
    case Keyword.fetch(opts, :identity_allowlist) do
      :error ->
        :ok

      {:ok, allowlist} ->
        with {:ok, endpoint_revision} <- IdentityContract.endpoint_revision_sha256(connect) do
          expected = %{
            "provider" => connect["provider"],
            "tenant_id" => connect["tenant_id"],
            "group_id" => connect["group_id"],
            "connect_id" => connect["connect_id"],
            "connect_generation" => connect["connect_generation"],
            "workspace_id" => connect["workspace_id"],
            "approved_channel_id" => connect["approved_channel_id"],
            "root_ts" => authority["thread_ts"],
            "inbound_agent_id" => connect["inbound_agent_id"],
            "app_id" => connect["app_id"],
            "bot_user_id" => connect["bot_user_id"],
            "bot_id" => connect["bot_id"],
            "endpoint_revision_sha256" => endpoint_revision
          }

          if Enum.all?(expected, fn {key, value} -> allowlist[key] == value end),
            do: :ok,
            else: {:error, :identity_allowlist_connect_drift}
        end
    end
  end

  defp validate_identity_product_allowlist(product, identity_base, opts) do
    case Keyword.fetch(opts, :identity_allowlist) do
      :error ->
        :ok

      {:ok, allowlist} ->
        expected = %{
          "project_id" => product.project.id,
          "project_status" => product.project.status,
          "agent_id" => product.agent.salix_agent_id,
          "agent_role" => product.agent.role,
          "agent_name" => String.trim(product.agent.salix["name"]),
          "self_agent_identity_revision_sha256" =>
            get_in(identity_base, ["self_agent", "identity_revision_sha256"])
        }

        if Enum.all?(expected, fn {key, value} -> allowlist[key] == value end),
          do: :ok,
          else: {:error, :identity_allowlist_product_drift}
    end
  end

  defp validate_identity_product_members(product, opts) do
    if identity_mode?(opts) do
      display_names =
        product.members
        |> Enum.map(fn membership ->
          product.project
          |> member_fact(membership)
          |> Map.fetch!("display_name")
          |> String.trim()
          |> String.normalize(:nfc)
        end)

      if length(display_names) == MapSet.size(MapSet.new(display_names)),
        do: :ok,
        else: {:error, :ambiguous_project_member_identity}
    else
      :ok
    end
  end

  defp validate_identity_input(input, connect) do
    events = List.wrap(input["events"])

    case {
      IdentityContract.classify_event_provenance(events),
      input["schema"],
      input["source_mode"]
    } do
      {{:ok, :legacy}, "comma.triage-input-snapshot.v2", _source_mode} ->
        {:error, :identity_provenance_missing}

      {{:ok, :legacy}, _schema, _source_mode} ->
        {:ok, :legacy}

      {{:ok, :identity_enabled}, _schema, source_mode}
      when source_mode in [
             "callback",
             "clickhouse_etl",
             "historical_thread_reenactment",
             "periodic_patrol",
             "scheduled_recheck"
           ] ->
        events
        |> Enum.map(& &1["endpoint_provenance"])
        |> validate_identity_provenances(connect)

      {{:ok, :identity_enabled}, _schema, _source_mode} ->
        {:error, :invalid_identity_source_mode}

      {{:error, reason}, _schema, _source_mode} ->
        {:error, reason}
    end
  end

  defp validate_identity_provenances([], _connect), do: {:error, :identity_provenance_missing}

  defp validate_identity_provenances(provenances, connect) do
    if Enum.all?(provenances, &is_map/1) do
      Enum.reduce_while(provenances, {:ok, nil}, fn provenance, {:ok, status} ->
        case validate_identity_provenance(provenance, connect) do
          {:ok, current} -> {:cont, {:ok, merge_revision_status(status, current)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, :identity_provenance_missing}
    end
  end

  defp validate_identity_provenance(
         %{"schema" => "comma.slack-clickhouse-etl-provenance.v1"} = provenance,
         _connect
       ) do
    valid? =
      Map.keys(provenance) |> Enum.sort() ==
        Enum.sort(~w(schema table message_ts_us observed_version ingest_at cursor_revision)) and
        provenance["table"] == "slack_messages" and
        is_integer(provenance["message_ts_us"]) and provenance["message_ts_us"] >= 0 and
        is_integer(provenance["observed_version"]) and provenance["observed_version"] >= 0 and
        is_integer(provenance["cursor_revision"]) and provenance["cursor_revision"] >= 0 and
        match?({:ok, _, _}, DateTime.from_iso8601(provenance["ingest_at"] || ""))

    if valid?, do: {:ok, :exact}, else: {:error, :identity_provenance_drift}
  end

  defp validate_identity_provenance(provenance, connect) do
    with true <- provenance["schema"] == "comma.slack-endpoint-provenance.v1",
         true <- is_integer(provenance["captured_at_ms"]) and provenance["captured_at_ms"] > 0,
         true <- provenance["callback_api_app_id"] == connect["app_id"],
         {:ok, current_revision} <- IdentityContract.endpoint_revision_sha256(connect) do
      cond do
        provenance["fast_path_bot_user_id"] == connect["bot_user_id"] and
            provenance["endpoint_revision_sha256"] == current_revision ->
          {:ok, :exact}

        sanctioned_bot_identity_backfill?(provenance, connect) ->
          {:ok, :sanctioned_bot_identity_backfill}

        true ->
          {:error, :identity_provenance_drift}
      end
    else
      false -> {:error, :identity_provenance_drift}
      {:error, _reason} = error -> error
    end
  end

  defp sanctioned_bot_identity_backfill?(provenance, connect) do
    resolved_at = connect["bot_identity_resolved_at"]

    provenance["fast_path_bot_user_id"] == "" and present?(connect["bot_user_id"]) and
      is_integer(resolved_at) and resolved_at > provenance["captured_at_ms"] and
      case IdentityContract.endpoint_revision_sha256(Map.put(connect, "bot_user_id", "")) do
        {:ok, prior_revision} -> provenance["endpoint_revision_sha256"] == prior_revision
        {:error, _reason} -> false
      end
  end

  defp merge_revision_status(nil, current), do: current

  defp merge_revision_status(:sanctioned_bot_identity_backfill, _current),
    do: :sanctioned_bot_identity_backfill

  defp merge_revision_status(_current, :sanctioned_bot_identity_backfill),
    do: :sanctioned_bot_identity_backfill

  defp merge_revision_status(_current, :exact), do: :exact

  defp identity_base(_input, _connect, _product, :legacy),
    do: {:ok, nil}

  defp identity_base(input, connect, product, revision_status) do
    with {:ok, self_agent} <- self_agent(product, connect),
         {:ok, endpoint_revision} <- IdentityContract.endpoint_revision_sha256(connect) do
      self_endpoint = self_endpoint(connect, self_agent, endpoint_revision, revision_status)

      {:ok,
       %{
         "schema" => "comma.triage-identity-context.v1",
         "source_mode" => input["source_mode"],
         "self_agent" => self_agent,
         "self_endpoint" => self_endpoint,
         "observed_principals" => [],
         "mention_evidence" => []
       }}
    end
  end

  defp identity_context(nil, _input, _thread, _authority), do: {:ok, nil}

  defp identity_context(base, input, %{"messages" => messages}, authority)
       when is_map(base) and is_list(messages) do
    with {:ok, target_key} <- latest_event_key(input),
         pre_target = pre_target_messages(messages, target_key),
         {:ok, mentions} <- mention_evidence(pre_target, authority, base),
         :ok <- validate_mention_limit(mentions),
         {:ok, principals} <- observed_principals(mentions, pre_target, authority, base) do
      base
      |> Map.put("mention_evidence", mentions)
      |> Map.put("observed_principals", principals)
      |> finalize_identity_context()
    end
  end

  defp identity_context(_base, _input, _thread, _authority),
    do: {:error, :invalid_identity_thread}

  defp latest_event_key(input) do
    with {:ok, keys} <- event_ts_keys(input["events"] || []),
         false <- keys == [] do
      {:ok, Enum.max(keys)}
    else
      true -> {:error, :invalid_triage_input_timestamps}
      {:error, _reason} = error -> error
    end
  end

  defp pre_target_messages(messages, target_key) do
    messages
    |> Enum.filter(&(slack_ts_key!(&1["ts"] || &1["message_ts"]) <= target_key))
    |> Enum.sort_by(&slack_ts_key!(&1["ts"] || &1["message_ts"]))
  end

  defp mention_evidence(messages, authority, base) do
    evidence =
      Enum.flat_map(messages, fn message ->
        message_ts = trim(message["ts"] || message["message_ts"])

        message_source_ref =
          slack_ref(ChannelBatch.physical_authority(authority, message), message_ts)

        message
        |> mention_selectors()
        |> Enum.sort_by(fn {provider_user_id, _selectors} -> provider_user_id end)
        |> Enum.map(fn {provider_user_id, selectors} ->
          principal_ref = provider_principal_ref(provider_user_id, base)

          %{
            "principal_ref" => principal_ref,
            "provider_user_id" => provider_user_id,
            "message_source_ref" => message_source_ref,
            "selectors" => selectors |> MapSet.to_list() |> Enum.sort(),
            "source_ref" => "#{message_source_ref}/mentions/#{provider_user_id}",
            "source_refs" => [message_source_ref]
          }
        end)
      end)

    {:ok, evidence}
  end

  defp mention_selectors(message) do
    message
    |> Addressee.mention_selectors()
    |> Map.filter(fn {provider_user_id, _selectors} ->
      valid_provider_user_id?(provider_user_id)
    end)
  end

  defp validate_mention_limit(mentions) do
    unique_count = mentions |> Enum.map(& &1["provider_user_id"]) |> Enum.uniq() |> length()
    if unique_count <= 16, do: :ok, else: {:error, :identity_mention_limit_exceeded}
  end

  # The thread's principal registry: every party this run can name.
  #
  # Being MENTIONED makes you a principal — somebody addressed you by id, which
  # is the strongest evidence there is that you are a party here. So does
  # AUTHORING as an agent: another bot in the thread is a member of the
  # conversation whether or not anyone happened to @ it, and a decision that
  # has to reason about "the review bot already said X" needs a ref to say it
  # with. Human authors are deliberately NOT promoted this way — an unmentioned
  # person stays a pseudonymous `participant://run/uNN` in the projected
  # transcript, which is the privacy posture this projection already had.
  #
  # Both sources are derived from material this run already froze (the mention
  # evidence and the pinned Slack page), so the projection verifier recomputes
  # this list rather than trusting it. Sibling connects of our own group are
  # NOT read here: that would add a product source the identity fence cannot
  # recompute from the pinned bundle. A sibling that posts in the approved
  # channel is already registered by the authorship clause below, as an opaque
  # agent with its bot_profile display name.
  defp observed_principals(mentions, messages, authority, base) do
    mentioned = Enum.group_by(mentions, & &1["provider_user_id"])

    authoring_agents =
      messages
      |> Enum.filter(&slack_bot_message?/1)
      |> Enum.map(&message_actor_id/1)
      |> Enum.reject(&(&1 == "" or Map.has_key?(mentioned, &1)))
      |> Enum.filter(&valid_provider_user_id?/1)
      |> Enum.uniq()
      |> Map.new(&{&1, []})

    mentioned
    |> Map.merge(authoring_agents)
    |> Enum.sort_by(fn {provider_user_id, _evidence} ->
      {if(provider_user_id == base["self_endpoint"]["bot_user_id"], do: 0, else: 1),
       provider_user_id}
    end)
    |> Enum.reduce_while({:ok, []}, fn {provider_user_id, mention_rows}, {:ok, acc} ->
      case observed_principal(provider_user_id, mention_rows, messages, authority, base) do
        {:ok, principal} -> {:cont, {:ok, [principal | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, principals} -> {:ok, Enum.reverse(principals)}
      {:error, _reason} = error -> error
    end
  end

  defp observed_principal(provider_user_id, mentions, messages, authority, base) do
    authored =
      messages
      |> Enum.filter(&(message_actor_id(&1) == provider_user_id))
      |> Enum.map(&authorship_evidence(&1, authority))
      |> Enum.reject(&is_nil/1)

    kinds = authored |> Enum.map(& &1.kind) |> Enum.uniq()

    cond do
      "agent" in kinds and "human" in kinds ->
        {:error, :conflicting_principal_evidence}

      provider_user_id == base["self_endpoint"]["bot_user_id"] and "human" in kinds ->
        {:error, :conflicting_principal_evidence}

      provider_user_id == base["self_endpoint"]["bot_user_id"] ->
        {:ok,
         observed_principal_map(
           base["self_agent"]["principal_ref"],
           "agent",
           "self",
           base["self_endpoint"]["display_aliases"],
           "self_endpoint",
           [base["self_endpoint"]["source_ref"]]
         )}

      "agent" in kinds ->
        {:ok,
         observed_principal_map(
           provider_principal_ref(provider_user_id, base),
           "agent",
           "other",
           authored |> Enum.flat_map(& &1.aliases) |> canonical_strings(),
           "thread_authorship",
           authored |> Enum.map(& &1.source_ref) |> canonical_strings()
         )}

      "human" in kinds ->
        {:ok,
         observed_principal_map(
           provider_principal_ref(provider_user_id, base),
           "human",
           "other",
           [],
           "thread_authorship",
           authored |> Enum.map(& &1.source_ref) |> canonical_strings()
         )}

      true ->
        {:ok,
         observed_principal_map(
           provider_principal_ref(provider_user_id, base),
           "unknown",
           "unknown",
           [],
           "unresolved",
           mentions |> Enum.map(& &1["source_ref"]) |> canonical_strings()
         )}
    end
  end

  defp observed_principal_map(principal_ref, kind, relation, aliases, tier, source_refs) do
    %{
      "principal_ref" => principal_ref,
      "provider" => "slack",
      "kind" => kind,
      "relation_to_self" => relation,
      "display_aliases" => aliases,
      "evidence_tier" => tier,
      "source_refs" => source_refs
    }
  end

  defp authorship_evidence(message, authority) do
    kind =
      cond do
        slack_bot_message?(message) -> "agent"
        message["actor_kind"] == "human" -> "human"
        is_nil(message["actor_kind"]) and not present?(message["subtype"]) -> "human"
        true -> nil
      end

    if kind do
      message_ts = trim(message["ts"] || message["message_ts"])

      %{
        kind: kind,
        aliases: if(kind == "agent", do: bot_aliases(message), else: []),
        source_ref: slack_ref(ChannelBatch.physical_authority(authority, message), message_ts)
      }
    end
  end

  defp slack_bot_message?(%{"actor_kind" => "human"}), do: false
  defp slack_bot_message?(%{"actor_kind" => "agent"}), do: true

  defp slack_bot_message?(message) do
    present?(message["bot_id"]) or is_map(message["bot_profile"]) or
      present?(message["bot_profile_name"])
  end

  defp bot_aliases(message) do
    profile = if is_map(message["bot_profile"]), do: message["bot_profile"], else: %{}

    [
      message["username"],
      message["bot_profile_name"],
      profile["name"],
      profile["display_name"]
    ]
    |> Enum.map(&trim/1)
    |> Enum.reject(&(&1 == "" or sensitive_alias?(&1)))
    |> canonical_strings()
  end

  defp provider_principal_ref(provider_user_id, base) do
    if provider_user_id == base["self_endpoint"]["bot_user_id"] do
      base["self_agent"]["principal_ref"]
    else
      "slack-principal://#{base["self_endpoint"]["workspace_id"]}/#{provider_user_id}"
    end
  end

  # The same derivation as `provider_principal_ref/2`, reached from the frozen
  # identity context rather than from the in-flight base. The projection
  # registry runs after the freeze, where `base` is gone but the context it
  # produced still names the same self endpoint.
  defp raw_provider_principal_ref(provider_user_id, raw_identity, connect) do
    if provider_user_id == connect["bot_user_id"] do
      get_in(raw_identity, ["self_agent", "principal_ref"])
    else
      "slack-principal://#{get_in(raw_identity, ["self_endpoint", "workspace_id"])}/#{provider_user_id}"
    end
  end

  defp valid_provider_user_id?(value),
    do: Addressee.valid_provider_user_id?(value)

  defp finalize_identity_context(identity) do
    identity =
      identity
      |> Map.put("principal_refs", IdentityContract.principal_refs(identity))
      |> Map.put(
        "remember_forbidden_source_refs",
        IdentityContract.remember_forbidden_source_refs(identity)
      )
      |> Map.put("source_refs", IdentityContract.source_refs(identity))

    case IdentityContract.validate_context(identity) do
      :ok -> {:ok, identity}
      {:error, _reason} = error -> error
    end
  end

  defp canonical_strings(values) do
    values
    |> Enum.filter(&present?/1)
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp self_agent(%{project: project, agent: agent}, connect) do
    with :ok <- validate_identity_lifecycle(project, agent),
         true <- agent.project_id == project.id,
         true <- project.salix_group_id == connect["group_id"],
         true <- agent.salix_agent_id == connect["inbound_agent_id"],
         true <- present?(agent.id) and present?(agent.salix_agent_id),
         true <- agent.role in ["router", "worker"],
         true <- present?(agent.salix["name"]),
         {:ok, persona_bytes} <- persona_revision_bytes(agent) do
      identity = %{
        "principal_ref" => "comma-agent://#{agent.salix_agent_id}",
        "source_ref" => "bft://projects/#{project.id}/agents/#{agent.id}",
        "agent_id" => agent.salix_agent_id,
        "role" => agent.role,
        "display_name" => String.trim(agent.salix["name"]),
        "persona_revision_sha256" => CanonicalJSON.sha256(persona_bytes)
      }

      with {:ok, revision} <- IdentityContract.identity_revision_sha256(identity) do
        {:ok, Map.put(identity, "identity_revision_sha256", revision)}
      end
    else
      {:error, _reason} = error -> error
      false -> {:error, :stale_self_agent_identity}
    end
  end

  defp self_agent(_product, _connect), do: {:error, :self_agent_not_found}

  defp validate_identity_lifecycle(nil, _agent), do: {:error, :self_agent_not_found}
  defp validate_identity_lifecycle(_project, nil), do: {:error, :self_agent_not_found}

  defp validate_identity_lifecycle(project, agent) do
    if project.status == "active" and is_nil(project.archived_at) and
         BridgeForTeams.Schema.Agent.active?(agent),
       do: :ok,
       else: {:error, :inactive_self_agent_identity}
  end

  defp persona_revision_bytes(agent) do
    CanonicalJSON.encode(%{
      "llm_config" => agent.salix["llm_config"] || %{},
      "system_prompt" => agent.salix["system_prompt"] || "",
      "template_id" => agent.salix["template_id"] || ""
    })
  end

  defp self_endpoint(connect, self_agent, revision, revision_status) do
    %{
      "source_ref" =>
        "slack-endpoint://#{connect["workspace_id"]}/#{connect["connect_id"]}@#{connect["connect_generation"]}",
      "provider" => "slack",
      "workspace_id" => connect["workspace_id"],
      "connect_id" => connect["connect_id"],
      "connect_generation" => connect["connect_generation"],
      "provider_app_id" => connect["app_id"],
      "bot_user_id" => connect["bot_user_id"],
      "bot_id" => trim(connect["bot_id"]),
      "display_aliases" => endpoint_aliases(connect),
      "represents_principal_ref" => self_agent["principal_ref"],
      "revision_sha256" => revision,
      "revision_status" => Atom.to_string(revision_status)
    }
  end

  defp endpoint_aliases(connect) do
    [connect["bot_username"], connect["app_name"]]
    |> Enum.map(&trim/1)
    |> Enum.reject(&(&1 == "" or sensitive_alias?(&1)))
    |> Enum.uniq()
  end

  defp sensitive_alias?(value) do
    String.contains?(value, ["@", "://", "/", "\\"])
  end

  defp maybe_put_identity_context(context, nil), do: context

  defp maybe_put_identity_context(context, identity),
    do: Map.put(context, "identity_context", identity)

  defp project_identity_context(context, input, authority, connect, product, thread, opts) do
    raw_identity = context["identity_context"]
    raw_slack = context["slack_context"]
    raw_memory = context["team_project_memory"]

    with {:identity_inputs, true} <-
           {:identity_inputs, is_map(raw_identity) and is_map(raw_slack) and is_map(raw_memory)},
         {:projection_registry, {:ok, registry}} <-
           {:projection_registry,
            projection_registry(raw_identity, raw_slack, raw_memory, connect)},
         {:slack_context, {:ok, projected_slack}} <-
           {:slack_context, project_slack_context(raw_slack, raw_identity, input, registry)},
         {:model_identity, {:ok, projected_identity}} <-
           {:model_identity, project_model_identity(raw_identity, registry)},
         {:team_memory, {:ok, projected_memory}} <-
           {:team_memory, project_team_memory(raw_memory, registry)},
         projected = %{
           "slack_context" => projected_slack,
           "identity_context" => projected_identity,
           "team_project_memory" => projected_memory,
           "decision_contract" => %{
             "source_refs" =>
               (projected_slack["source_refs"] ++
                  projected_identity["source_refs"] ++ projected_memory["source_refs"])
               |> Enum.uniq()
               |> Enum.sort(),
             "principal_refs" => projected_identity["principal_refs"],
             "remember_forbidden_source_refs" =>
               projected_identity["remember_forbidden_source_refs"]
           }
         },
         {:projected_encoding, {:ok, projected_bytes}} <-
           {:projected_encoding, CanonicalJSON.encode(projected)},
         {:private_projection, {:ok, private_projection}} <-
           {:private_projection,
            private_projection(
              context,
              input,
              authority,
              connect,
              product,
              thread,
              opts,
              registry,
              projected_bytes
            )} do
      {:ok, projected, private_projection}
    else
      {stage, false} ->
        log_identity_projection_failure(stage, :invalid_shape)
        {:error, :identity_projection_invalid}

      {stage, {:error, reason} = error} when is_atom(reason) ->
        log_identity_projection_failure(stage, reason)
        error

      {stage, _other} ->
        log_identity_projection_failure(stage, :invalid_result)
        {:error, :identity_projection_invalid}
    end
  end

  defp log_identity_projection_failure(stage, reason)
       when is_atom(stage) and is_atom(reason) do
    Logger.warning("triage_identity_projection_stage_failed stage=#{stage} reason=#{reason}")
  end

  defp projection_registry(raw_identity, raw_slack, raw_memory, connect) do
    self_ref = get_in(raw_identity, ["self_agent", "principal_ref"])

    with true <- present?(self_ref) do
      other_principals =
        raw_identity
        |> Map.get("principal_refs", [])
        |> Enum.reject(&(&1 == self_ref))
        |> Enum.uniq()
        |> Enum.sort()

      principals =
        other_principals
        |> Enum.with_index(1)
        |> Map.new(fn {raw, index} -> {raw, "principal://run/p#{pad_ordinal(index)}"} end)
        |> Map.put(self_ref, "principal://run/self")

      # Every provider id the registry can name, so the transcript renders it
      # as a principal instead of minting a second pseudonym for it. An agent
      # author is a principal even when nobody mentioned it (see
      # `observed_principals/4`), so its id has to arrive here too, or the same
      # bot would appear as `@agent:pNN` in the identity context and as
      # `participant://run/uNN` two lines later in the transcript.
      agent_author_principals =
        raw_slack
        |> Map.get("messages", [])
        |> Enum.filter(&(&1["actor_kind"] == "agent" and present?(&1["actor_id"])))
        |> Map.new(fn message ->
          {message["actor_id"],
           principals[raw_provider_principal_ref(message["actor_id"], raw_identity, connect)]}
        end)
        |> Enum.reject(fn {_provider_user_id, projected_ref} -> is_nil(projected_ref) end)
        |> Map.new()

      provider_principals =
        raw_identity
        |> Map.get("mention_evidence", [])
        |> Map.new(fn mention ->
          {mention["provider_user_id"], principals[mention["principal_ref"]]}
        end)
        |> Map.merge(agent_author_principals)
        |> Map.put(connect["bot_user_id"], "principal://run/self")

      participants =
        raw_slack
        |> Map.get("messages", [])
        |> Enum.map(& &1["actor_id"])
        |> Enum.filter(&present?/1)
        |> Enum.reject(&Map.has_key?(provider_principals, &1))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.with_index(1)
        |> Map.new(fn {raw, index} -> {raw, "participant://run/u#{pad_ordinal(index)}"} end)

      source_refs =
        [raw_slack, raw_identity, raw_memory]
        |> collect_raw_source_refs()
        |> Enum.uniq()
        |> Enum.sort()

      sources =
        source_refs
        |> Enum.with_index(1)
        |> Map.new(fn {raw, index} -> {raw, "source://run/s#{pad_ordinal(index)}"} end)

      message_refs =
        raw_slack
        |> Map.get("messages", [])
        |> Enum.with_index(1)
        |> Map.new(fn {message, index} ->
          {message["source_ref"], "message://run/m#{pad_ordinal(index)}"}
        end)

      members =
        raw_memory
        |> Map.get("members", [])
        |> Enum.sort_by(& &1["source_ref"])
        |> Enum.with_index(1)
        |> Map.new(fn {member, index} ->
          {member["source_ref"], "member://run/m#{pad_ordinal(index)}"}
        end)

      links =
        raw_slack
        |> Map.get("messages", [])
        |> raw_message_links()
        |> Enum.with_index(1)
        |> Map.new(fn {raw, index} -> {raw, "link://run/l#{pad_ordinal(index)}"} end)

      {:ok,
       %{
         self_raw_ref: self_ref,
         principals: principals,
         provider_principals: provider_principals,
         participants: participants,
         sources: sources,
         message_refs: message_refs,
         members: members,
         links: links,
         project_ref: get_in(raw_memory, ["project", "source_ref"]),
         project_alias: "project://run/p001"
       }}
    else
      false -> {:error, :identity_projection_invalid}
    end
  end

  defp project_slack_context(
         %{"messages" => messages, "expression_context" => expression_context},
         raw_identity,
         input,
         registry
       )
       when is_list(messages) and is_map(raw_identity) and is_map(input) do
    projected =
      messages
      |> Enum.with_index(1)
      |> Enum.map(fn {message, index} ->
        actor_id = message["actor_id"]
        source_ref = message["source_ref"]

        %{
          "ordinal" => index,
          "actor_ref" =>
            registry.provider_principals[actor_id] || registry.participants[actor_id] ||
              "participant://run/u000",
          "actor_kind" => message["actor_kind"],
          "message_ref" => registry.message_refs[source_ref],
          "text" => project_provider_safe_text(message["text"], registry),
          "file_attachments" =>
            FileAttachments.project(
              message["file_attachments"],
              &project_provider_safe_text(&1, registry)
            ),
          "source_ref" => registry.sources[source_ref],
          "observed_reactions" =>
            Enum.map(message["reactions"], fn reaction ->
              %{"emoji" => reaction["name"], "count" => reaction["count"]}
            end)
        }
        |> ChannelBatch.project_thread(message, messages)
      end)

    with true <- ExpressionContext.valid?(expression_context),
         true <- Enum.all?(projected, &valid_projected_message?/1),
         {:ok, decision_target} <-
           project_decision_target(messages, projected, raw_identity, input, registry) do
      {:ok,
       %{
         "messages" => projected,
         "source_refs" => Enum.map(projected, & &1["source_ref"]),
         "links" => project_links(messages, projected, registry),
         "decision_target" => decision_target,
         "expression_context" => expression_context
       }}
    else
      {:error, :triage_source_target_unavailable} = error -> error
      _other -> {:error, :identity_projection_invalid}
    end
  end

  defp project_slack_context(_raw_slack, _raw_identity, _input, _registry),
    do: {:error, :identity_projection_invalid}

  defp raw_decision_target(messages, raw_identity, input) do
    with {:ok, target_key} <- latest_event_key(input),
         {raw_target, index} <-
           messages
           |> Enum.with_index(1)
           |> Enum.find(fn {message, _} ->
             slack_ts_key!(message["message_ts"]) == target_key
           end),
         addressee when addressee in ~w(self other mixed none) <-
           syntactic_addressee(raw_target["source_ref"], raw_identity) do
      {:ok,
       %{
         "ordinal" => index,
         "source_ref" => raw_target["source_ref"],
         "syntactic_addressee" => addressee
       }}
    else
      nil -> {:error, :triage_source_target_unavailable}
      _ -> {:error, :identity_projection_invalid}
    end
  end

  defp project_decision_target(messages, projected, raw_identity, input, registry) do
    with {:ok, target} <- raw_decision_target(messages, raw_identity, input),
         index = target["ordinal"] - 1,
         projected_target when is_map(projected_target) <- Enum.at(projected, index) do
      {:ok,
       target
       |> Map.put("message_ref", projected_target["message_ref"])
       |> Map.put("source_ref", projected_target["source_ref"])
       |> Map.put("link_refs", project_link_refs(Enum.at(messages, index)["text"], registry))}
    else
      {:error, :triage_source_target_unavailable} = error -> error
      _ -> {:error, :identity_projection_invalid}
    end
  end

  defp syntactic_addressee(target_source_ref, raw_identity) do
    self_ref = get_in(raw_identity, ["self_agent", "principal_ref"])

    mentioned_refs =
      raw_identity
      |> Map.get("mention_evidence", [])
      |> Enum.filter(&(&1["message_source_ref"] == target_source_ref))
      |> Enum.map(& &1["principal_ref"])
      |> Enum.filter(&present?/1)
      |> Enum.uniq()

    mentions_self? = self_ref in mentioned_refs
    mentions_other? = Enum.any?(mentioned_refs, &(&1 != self_ref))

    case {mentions_self?, mentions_other?} do
      {true, true} -> "mixed"
      {true, false} -> "self"
      {false, true} -> "other"
      {false, false} -> "none"
    end
  end

  defp valid_projected_message?(message) do
    is_integer(message["ordinal"]) and present?(message["actor_ref"]) and
      message["actor_kind"] in ["agent", "system", "human", "unknown"] and
      present?(message["message_ref"]) and is_binary(message["text"]) and
      present?(message["source_ref"]) and
      valid_projected_reactions?(message["observed_reactions"]) and
      FileAttachments.valid_projected?(message["file_attachments"])
  end

  defp valid_projected_reactions?(reactions) when is_list(reactions) do
    length(reactions) <= 64 and
      Enum.all?(reactions, fn reaction ->
        is_map(reaction) and Enum.sort(Map.keys(reaction)) == ~w(count emoji) and
          present?(reaction["emoji"]) and is_integer(reaction["count"]) and
          reaction["count"] in 1..10_000
      end)
  end

  defp valid_projected_reactions?(_reactions), do: false

  defp project_provider_safe_text(text, _registry), do: trim(text)

  defp project_links(messages, projected, registry) do
    registry.links
    |> Enum.sort_by(fn {_raw, ref} -> ref end)
    |> Enum.map(fn {raw, ref} ->
      occurrences =
        messages
        |> Enum.with_index()
        |> Enum.filter(fn {message, _index} -> raw in extract_raw_links(message["text"]) end)
        |> Enum.map(fn {_message, index} -> Enum.at(projected, index) end)

      %{
        "link_ref" => ref,
        "display_alias" => link_display_alias(ref),
        "message_refs" => occurrences |> Enum.map(& &1["message_ref"]) |> Enum.uniq(),
        "source_refs" => occurrences |> Enum.map(& &1["source_ref"]) |> Enum.uniq()
      }
    end)
  end

  defp project_link_refs(text, registry) do
    text
    |> extract_raw_links()
    |> Enum.map(&registry.links[&1])
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp raw_message_links(messages) do
    messages
    |> Enum.flat_map(&extract_raw_links(&1["text"]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp extract_raw_links(text) when is_binary(text) do
    slack_links =
      @slack_mrkdwn_link
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.map(&hd/1)

    generic_links =
      Regex.replace(@slack_mrkdwn_link, text, " ")
      |> then(&Regex.scan(@raw_uri, &1, capture: :first))
      |> Enum.map(&hd/1)

    (slack_links ++ generic_links)
    |> Enum.map(&String.replace(&1, ~r/[.,;:!?\)\]\}]+$/, ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_raw_links(_text), do: []

  defp link_display_alias("link://run/" <> suffix), do: "@link:#{suffix}"
  defp link_display_alias(_ref), do: "@link:l000"

  defp nonempty_or("", fallback), do: fallback
  defp nonempty_or(value, _fallback), do: value

  defp project_model_identity(raw, registry) do
    self_agent = raw["self_agent"]
    self_endpoint = raw["self_endpoint"]

    observed =
      raw
      |> Map.get("observed_principals", [])
      |> Enum.map(fn principal ->
        projected_ref = registry.principals[principal["principal_ref"]]
        primary = principal_display_alias(principal, projected_ref)

        %{
          "principal_ref" => projected_ref,
          "provider" => principal["provider"],
          "kind" => principal["kind"],
          "relation_to_self" => principal["relation_to_self"],
          "display_aliases" => projected_display_aliases(primary, principal["display_aliases"]),
          "evidence_tier" => principal["evidence_tier"],
          "source_refs" => project_refs(principal["source_refs"], registry.sources)
        }
      end)
      |> Enum.sort_by(& &1["principal_ref"])

    mentions =
      raw
      |> Map.get("mention_evidence", [])
      |> Enum.map(fn mention ->
        %{
          "principal_ref" => registry.principals[mention["principal_ref"]],
          "message_ref" => registry.message_refs[mention["message_source_ref"]],
          "message_source_ref" => registry.sources[mention["message_source_ref"]],
          "selectors" => mention["selectors"],
          "source_ref" => registry.sources[mention["source_ref"]],
          "source_refs" => project_refs(mention["source_refs"], registry.sources)
        }
      end)
      |> Enum.sort_by(&{&1["message_ref"], &1["principal_ref"]})

    identity = %{
      "schema" => "comma.triage-identity-model-context.v1",
      "source_mode" => raw["source_mode"],
      "self_agent" => %{
        "principal_ref" => "principal://run/self",
        "display_alias" => "@self",
        "role" => self_agent["role"],
        "source_ref" => registry.sources[self_agent["source_ref"]]
      },
      "self_endpoint" => %{
        "endpoint_ref" => "endpoint://run/self",
        "provider" => self_endpoint["provider"],
        "display_aliases" => projected_display_aliases("@self", self_endpoint["display_aliases"]),
        "represents_principal_ref" => "principal://run/self",
        "revision_status" => self_endpoint["revision_status"],
        "source_ref" => registry.sources[self_endpoint["source_ref"]]
      },
      "observed_principals" => observed,
      "mention_evidence" => mentions
    }

    principal_refs =
      ["principal://run/self" | Enum.map(observed, & &1["principal_ref"])]
      |> Enum.uniq()

    identity =
      identity
      |> Map.put("principal_refs", principal_refs)
      |> Map.put(
        "remember_forbidden_source_refs",
        projected_identity_forbidden_refs(identity, principal_refs)
      )
      |> Map.put("source_refs", projected_identity_source_refs(identity))

    {:ok, identity}
  end

  defp principal_display_alias(%{"relation_to_self" => "self"}, _ref), do: "@self"

  defp principal_display_alias(principal, principal_ref) do
    suffix = String.replace_prefix(principal_ref, "principal://run/", "")

    case principal["kind"] do
      "agent" -> "@agent:#{suffix}"
      "human" -> "@human:#{suffix}"
      _ -> "@unknown:#{suffix}"
    end
  end

  defp safe_identity_label?(value) do
    is_binary(value) and String.length(value) in 1..64 and
      Regex.match?(~r/\A[\p{L}\p{N} ._-]+\z/u, value)
  end

  defp projected_display_aliases(primary, labels) do
    tails =
      labels
      |> Enum.filter(&safe_identity_label?/1)
      |> Enum.reject(&(&1 == primary))
      |> Enum.uniq()
      |> Enum.sort()

    [primary | tails]
  end

  defp projected_identity_forbidden_refs(identity, principal_refs) do
    ([
       get_in(identity, ["self_agent", "source_ref"]),
       get_in(identity, ["self_endpoint", "source_ref"])
     ] ++
       principal_refs ++
       Enum.map(identity["mention_evidence"], & &1["source_ref"]))
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp projected_identity_source_refs(identity) do
    ([
       get_in(identity, ["self_agent", "source_ref"]),
       get_in(identity, ["self_endpoint", "source_ref"])
     ] ++
       Enum.flat_map(identity["observed_principals"], & &1["source_refs"]) ++
       Enum.flat_map(identity["mention_evidence"], fn mention ->
         [mention["source_ref"] | mention["source_refs"]]
       end))
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp project_team_memory(raw, registry) do
    members =
      raw
      |> Map.get("members", [])
      |> Enum.sort_by(& &1["source_ref"])
      |> Enum.with_index(1)
      |> Enum.map(fn {member, index} ->
        %{
          "entity_ref" => registry.members[member["source_ref"]],
          "display_alias" =>
            trim(member["display_name"]) |> nonempty_or("@member:m#{pad_ordinal(index)}"),
          "rbac_role" => member["rbac_role"],
          "source_ref" => registry.sources[member["source_ref"]]
        }
      end)

    member_owner_refs =
      raw
      |> Map.get("members", [])
      |> Map.new(fn member ->
        {trim(member["display_name"]), registry.members[member["source_ref"]]}
      end)

    facts =
      raw
      |> Map.get("facts", [])
      |> Enum.sort_by(& &1["source_ref"])
      |> Enum.map(fn fact ->
        %{
          "kind" => fact["kind"],
          "text" => project_provider_safe_text(fact["text"], registry),
          "owner_ref" => member_owner_refs[trim(fact["owner"])],
          "deadline" => normalized_deadline(fact["deadline"]),
          "source_ref" => registry.sources[fact["source_ref"]]
        }
      end)

    project_source_ref = get_in(raw, ["project", "source_ref"])

    projected = %{
      "project" => %{
        "entity_ref" => registry.project_alias,
        "display_alias" => trim(get_in(raw, ["project", "name"])) |> nonempty_or("@project:p001"),
        "status" => get_in(raw, ["project", "status"]),
        "source_ref" => registry.sources[project_source_ref]
      },
      "members" => members,
      "member_roster" => raw["member_roster"],
      "facts" => facts,
      "source_refs" =>
        [registry.sources[project_source_ref]] ++
          Enum.map(members, & &1["source_ref"]) ++ Enum.map(facts, & &1["source_ref"])
    }

    {:ok, projected}
  end

  defp normalized_deadline(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> Date.to_iso8601(date)
      {:error, _reason} -> nil
    end
  end

  defp normalized_deadline(_value), do: nil

  defp private_projection(
         context,
         input,
         authority,
         connect,
         product,
         thread,
         _opts,
         registry,
         projected_bytes
       ) do
    observation = thread["identity_private_observation"] || %{}

    raw_bundle = %{
      "schema" =>
        if(ChannelBatch.channel?(authority),
          do: "comma.triage-private-source-bundle.v8",
          else: "comma.triage-private-source-bundle.v7"
        ),
      "sealed_events" => input["events"],
      "source_snapshot" => observation["source_snapshot"],
      "source_authority" => Map.take(authority, @required_authority ++ ["scope_kind"]),
      "root_ts" => authority["thread_ts"],
      "source_observation" => thread["identity_source_observation"],
      "connect_identity" =>
        Map.take(connect, [
          "provider",
          "tenant_id",
          "group_id",
          "connect_id",
          "connect_generation",
          "workspace_id",
          "approved_channel_id",
          "inbound_agent_id",
          "app_id",
          "bot_user_id",
          "bot_id"
        ]),
      "product_identity" => %{
        "project_id" => product.project.id,
        "project_status" => product.project.status,
        "project_archived_at" => product.project.archived_at,
        "project_salix_group_id" => product.project.salix_group_id,
        "agent_id" => product.agent.id,
        "agent_project_id" => product.agent.project_id,
        "salix_agent_id" => product.agent.salix_agent_id,
        "agent_status" => BridgeForTeams.Schema.Agent.lifecycle(product.agent),
        "agent_archived_at" => product.agent.salix["archived_at"],
        "agent_role" => product.agent.role,
        "agent_name" => product.agent.salix["name"]
      },
      "product_context" => context["team_project_memory"],
      "raw_context" => context,
      "raw_identity_context" => context["identity_context"],
      "target_cutoff" => %{
        "event_message_timestamps" => Enum.map(input["events"], & &1["message_ts"])
      }
    }

    alias_map = %{
      "principals" => registry.principals,
      "provider_principals" => registry.provider_principals,
      "participants" => registry.participants,
      "sources" => registry.sources,
      "messages" => registry.message_refs,
      "members" => registry.members,
      "links" => registry.links,
      "project" => %{registry.project_ref => registry.project_alias}
    }

    with {:ok, raw_bundle_bytes} <- CanonicalJSON.encode(raw_bundle),
         {:ok, raw_context_bytes} <- CanonicalJSON.encode(context),
         {:ok, alias_map_bytes} <- CanonicalJSON.encode(alias_map),
         {:ok, policy_bytes} <-
           CanonicalJSON.encode(%{
             "schema" => "comma.triage-identity-projection-policy.v2",
             "target" => "authorized_source_context"
           }) do
      {:ok,
       %{
         "schema" => "comma.triage-private-projection-control.v1",
         "raw_source_bundle_bytes" => raw_bundle_bytes,
         "raw_source_bundle_sha256" => CanonicalJSON.sha256(raw_bundle_bytes),
         "raw_context_sha256" => CanonicalJSON.sha256(raw_context_bytes),
         "alias_map_bytes" => alias_map_bytes,
         "alias_map_sha256" => CanonicalJSON.sha256(alias_map_bytes),
         "projection_policy_sha256" => CanonicalJSON.sha256(policy_bytes),
         "projected_context_sha256" => CanonicalJSON.sha256(projected_bytes)
       }}
    end
  end

  defp collect_raw_source_refs(values) when is_list(values) do
    Enum.flat_map(values, &collect_raw_source_refs/1)
  end

  defp collect_raw_source_refs(value) when is_map(value) do
    Enum.flat_map(value, fn
      {"source_ref", source_ref} when is_binary(source_ref) -> [source_ref]
      {"source_refs", source_refs} when is_list(source_refs) -> source_refs
      {_key, child} -> collect_raw_source_refs(child)
    end)
  end

  defp collect_raw_source_refs(_value), do: []

  defp project_refs(refs, source_registry) do
    refs
    |> List.wrap()
    |> Enum.map(&source_registry[&1])
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp pad_ordinal(index), do: index |> Integer.to_string() |> String.pad_leading(3, "0")

  defp slack_context(%{"messages" => messages}, authority) when is_list(messages) do
    with {:ok, normalized} <- normalize_slack_messages(messages, authority) do
      normalized = Enum.sort_by(normalized, &slack_ts_key!(&1["message_ts"]))

      {:ok,
       %{
         "messages" => normalized,
         "source_refs" => Enum.map(normalized, & &1["source_ref"])
       }}
    end
  end

  defp slack_context(_thread, _authority), do: {:error, :invalid_slack_context}

  defp expression_slack_context(slack_context, authority, connect, opts) do
    catalog_context =
      if not identity_mode?(opts) and Keyword.has_key?(opts, :product_source) do
        ExpressionContext.build("project", {:error, :fixture_catalog_unavailable})
      else
        ProviderConnects.triage_slack_expression_context(
          connect["tenant_id"],
          connect["group_id"],
          connect["connect_id"],
          authority["channel_id"],
          connect["connect_generation"]
        )
      end

    with {:ok, expression_context} <-
           catalog_context,
         {:ok, expression_context} <-
           ExpressionContext.with_observed_reactions(
             expression_context,
             slack_context["messages"]
           ) do
      {:ok, Map.put(slack_context, "expression_context", expression_context)}
    else
      {:error, reason}
      when reason in [
             :slack_triage_authority_ineligible,
             :slack_triage_authority_stale,
             :slack_triage_authority_unavailable
           ] ->
        {:error, reason}

      _unavailable ->
        {:error, :triage_expression_context_unavailable}
    end
  end

  defp normalize_slack_messages(messages, authority) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
      case normalize_slack_message(message, authority) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_slack_message(message, authority) when is_map(message) do
    message_ts = trim(message["ts"] || message["message_ts"])

    with {:ok, _key} <- slack_ts_key(message_ts),
         {:ok, reactions} <- normalize_reactions(message["reactions"] || []) do
      normalized = %{
        "actor_id" => message_actor_id(message),
        "actor_kind" => actor_kind(message),
        "message_ts" => message_ts,
        "text" => trim(message["text"]),
        "source_ref" =>
          slack_ref(ChannelBatch.physical_authority(authority, message), message_ts),
        "file_attachments" =>
          message["file_attachments"] || FileAttachments.from_slack(message["files"]),
        "reactions" => reactions
      }

      maybe_put_source_state(ChannelBatch.retain_root(normalized, message), message)
    end
  end

  defp normalize_slack_message(_message, _authority), do: {:error, :invalid_slack_context}

  defp normalize_reactions(reactions) when is_list(reactions) and length(reactions) <= 64 do
    reactions
    |> Enum.reduce_while({:ok, []}, fn reaction, {:ok, normalized} ->
      name = reaction["name"]
      count = reaction["count"]

      if is_binary(name) and byte_size(name) in 1..100 and
           Regex.match?(~r/\A[a-z0-9_+\-:]+\z/, name) and is_integer(count) and
           count in 1..10_000 do
        {:cont, {:ok, [%{"name" => name, "count" => count} | normalized]}}
      else
        {:halt, {:error, :invalid_slack_context}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_reactions(_reactions), do: {:error, :invalid_slack_context}

  # CH projections keep the provider-specific `user` field present but empty
  # for bot/app rows. Empty strings are truthy in Elixir, so `||` would discard
  # the stable normalized actor id.
  defp message_actor_id(message),
    do: present_value(message["user"]) || trim(message["actor_id"])

  defp maybe_put_source_state(normalized, message) do
    case {message["message_ts_us"], message["observed_version"]} do
      {message_ts_us, observed_version}
      when is_integer(message_ts_us) and message_ts_us >= 0 and is_integer(observed_version) and
             observed_version >= 0 ->
        {:ok,
         normalized
         |> Map.put("message_ts_us", message_ts_us)
         |> Map.put("observed_version", observed_version)}

      {nil, nil} ->
        {:ok, normalized}

      _invalid ->
        {:error, :invalid_slack_context}
    end
  end

  # The retired v1 compatibility port retains its historical activity flag.
  # Native identity runs use v6 bundles: no speaker-based completion inference.
  defp compatibility_recheck(input, thread, slack_context, connect, opts) do
    if identity_mode?(opts),
      do: {:ok, nil},
      else: answered_recheck(input, thread, slack_context, connect)
  end

  defp answered_recheck(input, thread, slack_context, connect) do
    with {:ok, input_keys} <- event_ts_keys(input["events"] || []),
         false <- input_keys == [] do
      input_key_set = MapSet.new(input_keys)
      latest_input_key = Enum.max(input_keys)

      answer =
        slack_context["messages"]
        |> Enum.reject(&MapSet.member?(input_key_set, slack_ts_key!(&1["message_ts"])))
        |> Enum.filter(&(slack_ts_key!(&1["message_ts"]) > latest_input_key))
        |> Enum.filter(&IdentityContract.answering_participant?(&1, connect))
        |> Enum.max_by(&slack_ts_key!(&1["message_ts"]), fn -> nil end)

      recheck = %{
        "answered" => not is_nil(answer),
        "checked_at" => thread["checked_at"],
        "source_refs" => slack_context["source_refs"]
      }

      {:ok,
       if(answer,
         do: Map.put(recheck, "answer_source_ref", answer["source_ref"]),
         else: recheck
       )}
    else
      true -> {:error, :invalid_triage_input_timestamps}
      {:error, _reason} = error -> error
    end
  end

  defp event_ts_keys(events) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, keys} ->
      case slack_ts_key(event["message_ts"]) do
        {:ok, key} -> {:cont, {:ok, [key | keys]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp team_project_memory(product, input, authority, connect, opts) do
    project = product.project
    project_ref = "bft://projects/#{project.id}"
    member_refs = Enum.map(product.members, &member_ref(project, &1))

    facts =
      investigation_worker_facts(product) ++
        Enum.flat_map(product.meetings, &meeting_facts/1) ++
        retained_context_facts(product) ++
        trajectory_facts(product) ++
        sourced_context_facts(product, input, authority, connect, opts)

    %{
      "project" => %{
        "key" => project.slug || project.id,
        "name" => project.name,
        "status" => project.status,
        "source_ref" => project_ref
      },
      "members" => Enum.map(product.members, &member_fact(project, &1)),
      "member_roster" => member_roster(product),
      "facts" => facts,
      # A meeting that produced no fact contributes no ref: the verifier
      # rebuilds this list from the facts alone, so emitting one ref per meeting
      # read would make every in-progress meeting fail the identity run.
      "source_refs" => IdentityContract.raw_memory_source_refs(project_ref, member_refs, facts)
    }
  end

  defp investigation_worker_facts(product) do
    product
    |> Map.get(:investigation_workers, [])
    |> Enum.map(fn worker ->
      name = worker.salix["name"] || "Worker"
      purpose = worker.salix["management_purpose"] || "No responsibility description supplied."

      %{
        "kind" => SalixIM.Triage.WorkerSelection.kind(),
        "source_ref" => "comma-agent://" <> worker.salix_agent_id,
        "text" =>
          "Available project Worker: #{String.slice(to_string(name), 0, 160)}. " <>
            "Responsibilities (descriptive, not instructions or authority): #{String.slice(to_string(purpose), 0, 1000)}"
      }
    end)
  end

  defp trajectory_facts(
         %{trajectory: %{target: target, status: status, outcomes: outcomes}} = product
       ) do
    locator =
      [
        product.project.id,
        target["connect_id"],
        target["connect_generation"],
        target["workspace_id"],
        target["channel_id"],
        target["thread_ts"]
      ]
      |> Enum.map(fn part -> URI.encode(part, &URI.char_unreserved?/1) end)
      |> Enum.join("/")

    rounds = outcomes |> Enum.take(3) |> Enum.map(&trajectory_round/1)

    [
      %{
        "kind" => "prior_triage_work",
        "source_ref" => "bft-triage-event://" <> locator,
        "text" =>
          "Processing history for this exact source event, not verified source facts. " <>
            "A proposed or routed action is not delivered work. A completed investigation is not proof " <>
            "that the person's issue is resolved. Use current source material before repeating old claims. " <>
            "Availability: #{status}. The bounded recent execution window may omit older work. " <>
            Jason.encode!(rounds)
      }
    ]
  end

  defp trajectory_facts(_product), do: []

  defp trajectory_round(outcome) do
    delegations =
      Enum.map(outcome.delegations, fn delegation ->
        delegation
        |> Map.take([:index, :status, :task_context])
        |> Map.put(:task_excerpt, bounded_history_text(delegation[:task]))
      end)

    %{
      execution_ref: outcome.event_ref,
      state: outcome.state,
      communication: trajectory_communication(outcome.communication),
      companion_reaction: trajectory_communication(outcome.companion_reaction),
      effect: outcome.effect,
      companion_effect: outcome.companion_effect,
      delegations: delegations,
      updated_at_ms: outcome.updated_at_ms
    }
  end

  defp trajectory_communication(nil), do: nil

  defp trajectory_communication(communication) do
    communication
    |> Map.take([:kind, :status])
    |> Map.put(:text_excerpt, bounded_history_text(communication[:text]))
    |> Map.put(:reason_excerpt, bounded_history_text(communication[:reason]))
    |> Map.put(:emoji, bounded_history_text(communication[:emoji]))
  end

  defp bounded_history_text(text) when is_binary(text),
    do: text |> String.codepoints() |> Enum.take(128) |> Enum.join()

  defp bounded_history_text(_text), do: nil

  # Read the existing project-shared Knowledge projection once per freeze,
  # bounded to twenty active entries (at most 40 KB of retained values). This
  # neither scans per source/agent nor copies facts into a second store.
  defp retained_context_facts(%{retained_context: entries}) when is_list(entries) do
    Enum.flat_map(entries, fn
      %{
        state: :active,
        kind: kind,
        subject: subject,
        value: value,
        source_ref: source_ref,
        source_count: count
      } = entry
      when kind in ~w(project_fact decision follow_up) and is_binary(subject) and
             is_binary(value) and is_binary(source_ref) and count > 0 ->
        [
          %{
            "kind" => "retained_#{kind}",
            "text" => retained_context_text(kind, subject, value, entry),
            "source_ref" => source_ref
          }
        ]

      _unavailable ->
        []
    end)
  end

  defp retained_context_facts(_product), do: []

  defp retained_context_text("follow_up", subject, value, entry) do
    wakeup =
      if entry[:current_wakeup],
        do:
          " This follow-up triggered the current scheduled recheck. Do not postpone this occurrence based on the next check time; it may already name a future retry.",
        else: ""

    "#{subject}: #{value}\nFollow-up basis: #{entry[:follow_up_basis] || "legacy_unclassified"}. Next check at #{entry[:next_check_at_ms]}.#{wakeup}"
  end

  defp retained_context_text(kind, subject, value, entry) do
    scope = entry[:knowledge_scope] || "unknown"
    owner = get_in(entry, [:scope_owner, "id"]) || "unknown"

    attribution =
      (entry[:source_attribution] || [])
      |> Enum.map(&Map.take(&1, ["actor_id", "message_ts"]))
      |> Jason.encode!()

    "#{subject}: #{value}\nRecorded #{kind}, scope #{scope}, about #{owner}. Source attribution: #{attribution}. " <>
      "Personal statements are not team rules. Explicit team rules take precedence over conflicting personal preferences. " <>
      "Source time is not a freshness guarantee; preserve estimates and status limits."
  end

  defp sourced_context_facts(
         %{project: project, agent: agent},
         input,
         authority,
         connect,
         opts
       ) do
    grounder = Keyword.get(opts, :sourced_context_grounder, Grounding)
    product_source = Keyword.get(opts, :product_source, @identity_product_source)

    with true <- sourced_context_grounding_available?(grounder, project),
         question when is_binary(question) and question != "" <- grounding_question(input),
         {:ok, audience} <-
           grounding_audience(product_source, project, input, authority, connect, opts),
         capability <- grounding_capability(project, agent, audience),
         {:ok, %{status: :resolved, facts: facts}} when is_list(facts) <-
           safe_apply(
             grounder,
             :ground_for_triage,
             [agent.id, question, capability],
             :sourced_context_grounding
           ) do
      facts
      |> Enum.flat_map(&sourced_context_memory_fact/1)
      |> Enum.uniq_by(& &1["source_ref"])
      |> Enum.sort_by(& &1["source_ref"])
      |> Enum.take(@sourced_context_fact_limit)
    else
      _unavailable_or_irrelevant -> []
    end
  end

  defp sourced_context_facts(_product, _input, _authority, _connect, _opts), do: []

  # The local preflight is only an external-call optimization; Grounding still
  # rechecks the active publication under the lifecycle read barrier. Alternate
  # grounders are a closed fixture seam in non-identity tests.
  defp sourced_context_grounding_available?(Grounding, project) do
    Grounding.project_context_available?(project.id)
  end

  defp sourced_context_grounding_available?(_fixture_grounder, _project), do: true

  defp grounding_audience(source, project, input, authority, connect, opts) do
    with {:ok, source_authority} <-
           safe_apply(
             source,
             :read_sourced_context_authority,
             [project, connect, authority, opts],
             :sourced_context_authority
           ),
         channel when is_map(channel) <- field(source_authority, :channel),
         true <-
           trim(field(source_authority, :tenant_id)) == trim(connect["tenant_id"]) and
             trim(field(source_authority, :group_id)) == trim(project.salix_group_id) and
             trim(field(source_authority, :connect_id)) == trim(connect["connect_id"]) and
             trim(field(source_authority, :connect_generation)) ==
               trim(connect["installation_generation"]) and
             trim(field(source_authority, :workspace_id)) == trim(connect["workspace_id"]) and
             trim(field(source_authority, :app_id)) == trim(connect["app_id"]) and
             trim(field(channel, :id)) == trim(authority["channel_id"]) and
             trim(field(channel, :visibility)) == "public" and
             field(channel, :is_member) == true and
             Regex.match?(@sha256, trim(field(channel, :authority_revision))) and
             input["source_mode"] in [
               "callback",
               "clickhouse_etl",
               "historical_thread_reenactment",
               "periodic_patrol",
               "scheduled_recheck"
             ] do
      {:ok,
       %{
         "scope" => "project-public-channels:v1",
         "provider" => "slack",
         "tenant_id" => trim(field(source_authority, :tenant_id)),
         "group_id" => trim(field(source_authority, :group_id)),
         "connect_id" => trim(field(source_authority, :connect_id)),
         "connect_generation" => trim(field(source_authority, :connect_generation)),
         "triage_authority_generation" => trim(connect["connect_generation"]),
         "workspace_id" => trim(field(source_authority, :workspace_id)),
         "app_id" => trim(field(source_authority, :app_id)),
         "channel_id" => trim(field(channel, :id)),
         "visibility" => "public",
         # A successful SlackHistoryReader authority response is issued only
         # after is_shared/is_ext_shared/is_org_shared all recheck false.
         "shared" => false,
         "authority_revision" => trim(field(channel, :authority_revision)),
         "source_mode" => input["source_mode"]
       }}
    else
      _unverified -> {:error, :sourced_context_audience_unverified}
    end
  end

  defp grounding_capability(project, agent, audience) do
    %{
      "schema" => "comma.bft-sourced-context-request.v1",
      "org_id" => project.org_id,
      "project_id" => project.id,
      "caller" => %{
        "kind" => "salix_agent",
        "agent_id" => agent.id,
        "salix_agent_id" => agent.salix_agent_id
      },
      "audience" => audience
    }
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_other, _key), do: nil

  defp grounding_question(%{"events" => events}) when is_list(events) do
    events
    |> Enum.reduce(nil, fn event, current ->
      with text when is_binary(text) and text != "" <- event["text"],
           {:ok, timestamp} <- slack_ts_key(event["message_ts"]) do
        case current do
          nil -> {timestamp, text}
          {current_timestamp, _text} when timestamp > current_timestamp -> {timestamp, text}
          current -> current
        end
      else
        _invalid -> current
      end
    end)
    |> case do
      {_timestamp, text} -> text |> String.trim() |> String.slice(0, 4_000)
      nil -> ""
    end
  end

  defp grounding_question(_input), do: ""

  defp sourced_context_memory_fact(%{
         id: fact_id,
         kind: kind,
         content: content,
         source_refs: source_refs
       })
       when kind in [:decision, :fact] and is_binary(fact_id) and is_binary(content) and
              is_list(source_refs) do
    case Enum.find(source_refs, fn source ->
           source[:type] == "sourced_context_publication" and present?(source[:ref])
         end) do
      %{ref: publication_id} ->
        [
          %{
            "kind" =>
              if(kind == :decision,
                do: "slack_history_decision",
                else: "slack_history_context"
              ),
            "text" => content,
            "source_ref" => "sourced-context://publications/#{publication_id}/facts/#{fact_id}"
          }
        ]

      nil ->
        []
    end
  end

  defp sourced_context_memory_fact(_fact), do: []

  defp member_roster(product) do
    roster = Map.get(product, :member_roster, %{})

    completeness =
      case Map.get(roster, :completeness, Map.get(roster, "completeness", :complete)) do
        value when value in [:truncated, "truncated"] -> "truncated"
        _other -> "complete"
      end

    %{
      "completeness" => completeness,
      "truncated" =>
        Map.get(roster, :truncated, Map.get(roster, "truncated", completeness == "truncated")),
      "limit" => Map.get(roster, :limit, Map.get(roster, "limit", 25)),
      "returned_count" =>
        Map.get(
          roster,
          :returned_count,
          Map.get(roster, "returned_count", length(product.members))
        )
    }
  end

  defp member_fact(project, membership) do
    user = membership.user

    %{
      "key" => user.id,
      "display_name" => present_value(user.name) || present_value(user.email) || user.id,
      "rbac_role" => membership.role,
      "source_ref" => member_ref(project, membership)
    }
  end

  defp member_ref(project, membership),
    do: "bft://projects/#{project.id}/members/#{membership.user_id}"

  defp meeting_facts(meeting) do
    if Meetings.summarized?(meeting) do
      summary = meeting["summary"] || %{}

      key_points =
        summary
        |> Map.get("key_points")
        |> List.wrap()
        |> Enum.with_index()
        |> Enum.flat_map(fn {text, index} ->
          case trim(text) do
            "" ->
              []

            text ->
              [
                %{
                  "kind" => "meeting_key_point",
                  "text" => text,
                  "source_ref" => "#{meeting_ref(meeting)}/key-point/#{index}"
                }
              ]
          end
        end)

      action_items =
        meeting
        |> Meetings.action_items()
        |> Enum.with_index()
        |> Enum.map(fn {item, index} ->
          %{
            "kind" => "meeting_action_item",
            "text" => item["description"],
            "owner" => item["owner"],
            "deadline" => item["deadline"],
            "source_ref" => "#{meeting_ref(meeting)}/action-item/#{index}"
          }
        end)

      key_points ++ action_items
    else
      []
    end
  end

  defp meeting_ref(meeting), do: "meeting://#{meeting["meeting_id"]}"

  defp slack_ref(authority, message_ts) do
    scope =
      if authority["scope_kind"] == "channel",
        do: "channel",
        else: authority["thread_ts"]

    "slack://#{authority["workspace_id"]}/#{authority["channel_id"]}/#{scope}/#{message_ts}"
  end

  defp slack_ts_key(value) do
    case Regex.run(~r/^(\d+)(?:\.(\d{1,6}))?$/, trim(value)) do
      [_, seconds, fraction] -> {:ok, {String.to_integer(seconds), micros(fraction)}}
      [_, seconds] -> {:ok, {String.to_integer(seconds), 0}}
      _other -> {:error, :invalid_slack_timestamp}
    end
  end

  defp slack_ts_key!(value) do
    {:ok, key} = slack_ts_key(value)
    key
  end

  defp micros(fraction) do
    fraction
    |> String.slice(0, 6)
    |> String.pad_trailing(6, "0")
    |> String.to_integer()
  end

  defp normalize_source({source, source_opts}) when is_atom(source) and is_list(source_opts),
    do: {source, source_opts}

  defp normalize_source(source) when is_atom(source), do: {source, []}

  # A kind the reader already classified is carried through unchanged; anything
  # this layer has to derive itself goes through the one shared rule, so the
  # freeze cannot disagree with the reader or the recompute about the same
  # message. See `SalixIM.Triage.IdentityContract.actor_kind/2`.
  defp actor_kind(%{"actor_kind" => kind}) when kind in ["human", "agent", "system"], do: kind
  defp actor_kind(message), do: SalixIM.Triage.IdentityContract.actor_kind(message, %{})

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp identity_mode?(opts), do: match?(%IdentityFenceHandle{}, opts[:identity_fence_handle])
  defp present_value(value), do: if(present?(value), do: String.trim(value))
  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defmodule ProductSource do
    @moduledoc false

    @active_connect_reader SalixIM.ProviderConnects
    @member_limit 25
    @agent_limit 64
    @agent_page_limit 4

    alias BridgeForTeams.Salix.Client

    @spec resolve_connect(map(), keyword()) :: {:ok, map()} | {:error, term()}
    def resolve_connect(authority, _opts), do: active_connect(authority)

    @spec load_product(map(), keyword()) :: {:ok, map()} | {:error, term()}
    def load_product(connect, opts) do
      with {:ok, project} <- Projects.get_project_by_salix_group(connect["group_id"]),
           {:ok, agent} <- Agents.get_project_agent(project.id, connect["inbound_agent_id"]),
           {:ok, %{members: members, completeness: completeness, truncated: truncated}}
           when completeness in [:complete, :truncated] and is_boolean(truncated) and
                  truncated == (completeness == :truncated) <-
             Memberships.list_project_members_bounded(project.id, @member_limit) do
        # Meetings are optional enrichment for Slack Triage, not activation
        # authority. Keep the bounded Meeting API fail-closed and preserve its
        # finite availability class internally, but do not let an unready
        # projection discard otherwise valid Slack/project/member context.
        {meetings, meeting_source_status} = load_optional_meetings(project)
        retained_context = load_retained_context(project, agent, opts)

        {:ok,
         %{
           project: project,
           agent: agent,
           investigation_workers: load_investigation_workers(project),
           members: members,
           member_roster: %{
             completeness: completeness,
             truncated: truncated,
             limit: @member_limit,
             returned_count: length(members)
           },
           meetings: meetings,
           retained_context: retained_context,
           trajectory: load_trajectory(project, agent, opts),
           meeting_source_status: meeting_source_status
         }}
      else
        {:error, _reason} = error -> error
        _invalid -> {:error, :triage_project_member_source_invalid}
      end
    end

    defp load_investigation_workers(project) do
      # Storage pages include records filtered out of the visible roster. Read
      # at most four pages (256 storage entries), retaining at most 64 visible
      # Agents. Never treat a partial roster as a complete candidate set.
      case load_agent_pages(project, nil, @agent_page_limit, []) do
        {:ok, agents} ->
          agents
          |> Enum.filter(&(&1.role == "worker" and BridgeForTeams.Schema.Agent.active?(&1)))
          |> Enum.sort_by(& &1.salix_agent_id)

        :unavailable ->
          []
      end
    end

    defp load_agent_pages(_project, _cursor, 0, _agents), do: :unavailable

    defp load_agent_pages(project, cursor, pages_left, agents) do
      opts = [limit: @agent_limit, cursor: cursor]

      case Agents.page_agents(project, opts) do
        {:ok, %{items: page, next_cursor: next}}
        when length(agents) + length(page) <= @agent_limit ->
          combined = agents ++ page

          cond do
            is_nil(next) -> {:ok, combined}
            next == cursor -> :unavailable
            true -> load_agent_pages(project, next, pages_left - 1, combined)
          end

        _ ->
          :unavailable
      end
    end

    defp load_trajectory(project, agent, opts) do
      case Keyword.get(opts, :trajectory_target) do
        %{} = target ->
          case Client.impl().triage_product_activity(project.id, project.salix_group_id, agent.id,
                 limit: 3,
                 context_limit: 0,
                 include_task_context: true,
                 target: target
               ) do
            {:ok, %{outcomes: outcomes}} when is_list(outcomes) ->
              %{target: target, status: :available, outcomes: outcomes}

            _unavailable ->
              %{target: target, status: :unavailable, outcomes: []}
          end

        nil ->
          nil
      end
    end

    defp load_retained_context(project, agent, opts) do
      refs = Keyword.get(opts, :recheck_context_refs, [])

      entry_ids =
        Enum.flat_map(refs, fn
          "triage-context://" <> id -> [id]
          _ -> []
        end)

      case Client.impl().triage_knowledge_context(project.id, project.salix_group_id, agent.id,
             limit: 20,
             query: opts[:knowledge_query],
             entry_ids: entry_ids
           ) do
        {:ok, %{items: items}} when is_list(items) ->
          Enum.map(items, &Map.put(&1, :current_wakeup, &1[:source_ref] in refs))

        _unavailable ->
          []
      end
    end

    defp load_optional_meetings(project) do
      # The nested deadline budget remains owned by `BridgeForTeams.Meetings`;
      # naming a tighter one here would only mask its typed refusals.
      case Meetings.list_triage_meetings(project, limit: 25) do
        {:ok, meetings} -> {meetings, :available}
        {:error, :meeting_source_unsealed} -> {[], :not_ready}
        {:error, :triage_meeting_source_timeout} -> {[], :timeout}
        {:error, {:triage_meeting_source_unavailable, :truncated}} -> {[], :truncated}
        {:error, :triage_meeting_source_invalid} -> {[], :invalid}
        {:error, _closed_or_remote_reason} -> {[], :unavailable}
      end
    end

    @spec read_sourced_context_authority(map(), map(), map(), keyword()) ::
            {:ok, map()} | {:error, term()}
    def read_sourced_context_authority(project, connect, authority, _opts) do
      Client.impl().slack_history_source_authority(%{
        tenant_id: connect["tenant_id"],
        group_id: project.salix_group_id,
        connect_id: connect["connect_id"],
        channel_id: authority["channel_id"]
      })
    end

    defp active_connect(authority) do
      with {:ok, connect} <-
             apply(@active_connect_reader, :find_active_im_connect_by_id, [
               authority["connect_id"]
             ]),
           {:ok, channel_authority} <-
             apply(@active_connect_reader, :get_slack_triage_authority, [
               connect["tenant_id"],
               connect["group_id"],
               connect["connect_id"],
               authority["channel_id"]
             ]) do
        installation_generation = connect["connect_generation"]

        {:ok,
         connect
         |> Map.put("installation_generation", installation_generation)
         |> Map.put("connect_generation", channel_authority["connect_generation"])
         |> Map.put("approved_channel_id", channel_authority["approved_channel_id"])
         |> Map.put("inbound_agent_id", channel_authority["inbound_agent_id"])}
      end
    rescue
      _error -> {:error, :triage_active_connect_reader_unavailable}
    catch
      _kind, _reason -> {:error, :triage_active_connect_reader_unavailable}
    end
  end
end
