defmodule SalixIM.Triage.Pipeline do
  @moduledoc """
  Context-freezing boundary for one bounded Triage evaluation.

  Runtime owns process lifecycle and capability minting. This module validates
  the configured context port, calls it once, binds an identity projection when
  required, and returns the canonical model input. It has no GenServer state,
  storage key, Slack credential, or delivery authority.
  """

  require Logger

  alias SalixIM.Triage.{
    ActivityProjection,
    CanonicalJSON,
    IdentityContract,
    IdentityFence,
    IdentityFenceHandle,
    ProductDecision,
    ReviewProjection,
    RunFence,
    SourceMode,
    URLPrivacy,
    WorkerSelection
  }

  alias SalixIM.Triage.RunFence.AuthorizedReadContext

  @identity_read_tools ~w(web.read_pages triage.slack_read_permalink triage_run.get)
  @link_read_tools ~w(web.read_pages triage.slack_read_permalink)
  # Reader-surfaced observed-read refusals and the closed terminal reason each
  # one settles as. Every value here is inside `RunFence`'s committable
  # `failed` reason set, so the operator reads the real boundary instead of an
  # internal-error catch-all. `:triage_slack_context_truncated` is the reader's
  # name for the page-budget product boundary.
  @identity_transport_reasons %{
    triage_slack_context_truncated: "page_budget_exceeded",
    chain_deadline_exceeded: "chain_deadline_exceeded",
    lease_denied: "lease_denied",
    slack_error: "slack_error",
    rate_limited: "rate_limited",
    http_error: "http_error",
    transport_error: "transport_error",
    decode_error: "decode_error"
  }

  @doc "Builds the immutable evaluation input from one closed sealed generation."
  @spec build_input(map()) :: {:ok, map()} | {:error, :invalid_identity_input}
  def build_input(%{"generation" => generation, "receipts" => [_ | _] = receipts})
      when is_binary(generation) and generation != "" do
    events = Enum.map(receipts, & &1["triage_event"])
    {input_schema, provenance_error, source_mode} = input_contract(events)

    input =
      %{
        "schema" => input_schema,
        "generation" => generation,
        "events" => events,
        "receipt_refs" => Enum.map(receipts, & &1["receipt_ref"]),
        "source_authority" => source_authority(receipts)
      }
      |> maybe_put_source_mode(source_mode)
      |> maybe_put_provenance_error(provenance_error)

    {:ok, input}
  end

  def build_input(_sealed), do: {:error, :invalid_identity_input}

  @doc "Validates the sealed input schema and its event provenance before any port call."
  @spec validate_input(map()) :: :ok | {:error, term()}
  def validate_input(
        %{
          "schema" => "comma.triage-input-snapshot.v1",
          "events" => events
        } = input
      ) do
    case IdentityContract.classify_event_provenance(events) do
      {:ok, :legacy} ->
        if Map.has_key?(input, "source_mode"),
          do: {:error, :identity_schema_mismatch},
          else: :ok

      _other ->
        {:error, :identity_schema_mismatch}
    end
  end

  def validate_input(
        %{
          "schema" => "comma.triage-input-snapshot.v2",
          "events" => events
        } = input
      ) do
    input_source_mode = input["source_mode"]

    case IdentityContract.classify_event_provenance(events) do
      {:ok, :identity_enabled} ->
        case SourceMode.resolve(events) do
          {:ok, ^input_source_mode} -> :ok
          {:ok, _different} -> {:error, :identity_source_mode_drift}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}

      {:ok, :legacy} ->
        {:error, :identity_provenance_missing}
    end
  end

  def validate_input(_input), do: {:error, :invalid_identity_input}

  @doc "Normalizes one evaluator result into the closed terminal schema."
  @spec terminal_from_result(term(), :identity | :compatibility, pos_integer()) :: map()
  def terminal_from_result(result, mode, settled_at) do
    {status, decision, evaluator} = result_parts(result, mode)

    %{
      "status" => status,
      "decision" => decision,
      "evaluator" => evaluator,
      "settled_at" => settled_at
    }
  end

  @doc "Builds a closed terminal directly from process-owned timeout state."
  @spec terminal(String.t(), map(), map(), pos_integer()) :: map()
  def terminal(status, decision, evaluator, settled_at) do
    %{
      "status" => status,
      "decision" => decision,
      "evaluator" => evaluator,
      "settled_at" => settled_at
    }
  end

  @doc "Projects evaluator results into the durable decision/proof triple."
  @spec result_parts(term(), :identity | :compatibility) :: {String.t(), map(), map()}
  def result_parts({:ok, decision, evaluator}, _mode)
      when is_map(decision) and is_map(evaluator),
      do: {"evaluated", decision, evaluator}

  def result_parts({:terminal, terminal}, _mode) when is_map(terminal),
    do: {terminal["status"], terminal["decision"], terminal["evaluator"]}

  def result_parts({:error, :identity_projection_invalid}, :identity),
    do: identity_failed_parts("identity_projection_invalid")

  def result_parts({:error, :identity_projection_privacy_rejected}, :identity),
    do: identity_failed_parts("identity_projection_privacy_rejected")

  def result_parts({:error, :identity_diagnostic_indeterminate_transport}, :identity),
    do: identity_failed_parts("identity_diagnostic_indeterminate_transport")

  def result_parts({:error, {:provider_error, _private_reason}}, :identity),
    do: identity_failed_parts("identity_diagnostic_indeterminate_transport")

  def result_parts({:error, :identity_decision_invalid}, :identity),
    do: identity_failed_parts("identity_decision_invalid")

  def result_parts({:error, :triage_worker_unavailable}, :identity),
    do: identity_failed_parts("triage_worker_unavailable")

  def result_parts({:error, :triage_source_target_unavailable}, :identity),
    do: identity_failed_parts("triage_source_target_unavailable")

  def result_parts({:error, :invalid_triage_decision}, :identity),
    do: identity_failed_parts("identity_decision_invalid")

  def result_parts({:error, :invalid_participation_decision}, :identity),
    do: identity_failed_parts("identity_decision_invalid")

  # A refused observed read is a real, operator-visible outcome — the authorized
  # scope did not fit the page budget, the chain deadline elapsed, or Slack
  # rate-limited the read. Every one of these is already a
  # committable terminal reason, so collapsing them into
  # `identity_diagnostic_internal_error` was the projection lying about a
  # working system rather than the system failing.
  def result_parts({:error, reason}, :identity)
      when is_map_key(@identity_transport_reasons, reason),
      do: identity_failed_parts(Map.fetch!(@identity_transport_reasons, reason))

  def result_parts(_result, :identity),
    do: identity_failed_parts("identity_diagnostic_internal_error")

  def result_parts({:error, reason}, :compatibility),
    do: {"failed", %{"action" => "silence", "reason" => inspect(reason)}, %{}}

  def result_parts(other, :compatibility),
    do: {"failed", %{"action" => "silence", "reason" => inspect(other)}, %{}}

  @doc "Checks the one accepted identity late-result union before persistence."
  @spec valid_identity_late_result?(term()) :: boolean()
  def valid_identity_late_result?({:ok, decision, evaluator}),
    do:
      RunFence.valid_decision?(decision) and RunFence.valid_model_proof?(evaluator) and
        RunFence.participation_result_matches?(evaluator, decision)

  def valid_identity_late_result?({:error, _reason}), do: true

  def valid_identity_late_result?({:terminal, terminal}) when is_map(terminal) do
    RunFence.valid_terminal?(terminal) or
      (exact_map_keys?(terminal, ~w(status decision evaluator settled_at)) and
         terminal["status"] == "skipped_already_answered" and
         terminal["decision"] == %{"action" => "silence"} and
         terminal["evaluator"] == %{"schema" => "comma.triage-answered-skip.v1"} and
         is_integer(terminal["settled_at"]) and terminal["settled_at"] > 0)
  end

  def valid_identity_late_result?(_result), do: false

  defp identity_failed_parts(reason),
    do: {"failed", %{"action" => "silence", "reason" => reason}, %{}}

  def validate_context_port(
        %{
          "schema" => "comma.triage-input-snapshot.v2",
          "source_mode" => source_mode
        },
        {module, opts}
      )
      when source_mode in [
             "callback",
             "clickhouse_etl",
             "historical_thread_reenactment",
             "periodic_patrol",
             "scheduled_recheck"
           ] do
    allowed_keys = [:identity_allowlist, :identity_fence_handle, :product_source, :thread_reader]
    keys = if Keyword.keyword?(opts), do: Keyword.keys(opts), else: []

    valid? =
      module == :"Elixir.BridgeForTeams.TriageContext" and Keyword.keyword?(opts) and
        length(keys) == length(Enum.uniq(keys)) and
        Enum.all?(keys, &(&1 in allowed_keys)) and
        Keyword.has_key?(opts, :identity_fence_handle) and
        match?(%IdentityFenceHandle{}, opts[:identity_fence_handle]) and
        (source_mode == "historical_thread_reenactment" or
           not Keyword.has_key?(opts, :identity_allowlist)) and
        (not Keyword.has_key?(opts, :identity_allowlist) or is_map(opts[:identity_allowlist])) and
        Keyword.get(
          opts,
          :thread_reader,
          :"Elixir.Salix.Bindings.ClickHouseTriageThreadReader"
        ) == :"Elixir.Salix.Bindings.ClickHouseTriageThreadReader" and
        Keyword.get(
          opts,
          :product_source,
          :"Elixir.BridgeForTeams.TriageContext.ProductSource"
        ) == :"Elixir.BridgeForTeams.TriageContext.ProductSource"

    if valid?, do: :ok, else: {:error, :invalid_identity_diagnostic_configuration}
  end

  def validate_context_port(_input, _context_port), do: :ok

  def authorize_model(
        %{"schema" => "comma.triage-model-input.v3"},
        %IdentityFenceHandle{} = handle
      ) do
    case IdentityFence.authorize_model(handle) do
      :proceed -> :ok
      _denied -> {:error, :identity_projection_invalid}
    end
  end

  def authorize_model(%{"schema" => "comma.triage-model-input.v3"}, _authority),
    do: {:error, :identity_projection_invalid}

  def authorize_model(_model_input, _authority), do: :ok

  @doc "Builds one closed read-tool authorization from a RunFence-authorized snapshot."
  @spec authorize_read_tool(String.t(), map()) ::
          {:proceed, map()} | {:error, :identity_fence_denied}
  def authorize_read_tool(namespace, active)
      when is_binary(namespace) and namespace != "" and is_map(active) do
    with {:ok, context} <- RunFence.authorize_read_context(namespace, active),
         {:ok, authorization} <- read_tool_authorization(namespace, context) do
      {:proceed, authorization}
    else
      _denied -> {:error, :identity_fence_denied}
    end
  end

  def authorize_read_tool(_namespace, _active),
    do: {:error, :identity_fence_denied}

  defp read_tool_authorization(
         namespace,
         %AuthorizedReadContext{
           fence: fence,
           run_id: run_id,
           raw_bundle: raw_bundle,
           alias_map: alias_map
         }
       ) do
    case read_link_target(fence, alias_map) do
      {:ok, link_target} ->
        link_read_authorization(run_id, raw_bundle, link_target)

      {:error, :identity_fence_denied} ->
        ActivityProjection.authorize(namespace, fence, run_id, raw_bundle)
    end
  end

  defp read_link_target(fence, alias_map) do
    link_refs =
      get_in(fence, [
        "input_snapshot",
        "snapshot",
        "slack_context",
        "decision_target",
        "link_refs"
      ])

    links = get_in(fence, ["input_snapshot", "snapshot", "slack_context", "links"])

    with [link_ref] when is_binary(link_ref) and link_ref != "" <- link_refs,
         links when is_list(links) <- links,
         %{"source_refs" => source_refs} <- Enum.find(links, &(&1["link_ref"] == link_ref)),
         true <- is_list(source_refs) and source_refs != [],
         %{"links" => raw_links} when is_map(raw_links) <- alias_map,
         resolved_url when is_binary(resolved_url) <-
           Enum.find_value(raw_links, fn
             {url, ^link_ref} when is_binary(url) -> url
             _other -> nil
           end),
         true <- valid_read_url?(resolved_url) do
      {:ok,
       %{
         "link_ref" => link_ref,
         "resolved_url" => resolved_url,
         "source_refs" => source_refs |> Enum.uniq() |> Enum.sort()
       }}
    else
      _invalid -> {:error, :identity_fence_denied}
    end
  end

  defp link_read_authorization(run_id, raw_bundle, link_target) do
    connect = raw_bundle["connect_identity"]
    product = raw_bundle["product_identity"]
    slack? = SalixIM.Triage.SlackPermalink.slack_url?(link_target["resolved_url"])

    authorization = %{
      "schema" => "comma.triage-read-tool-authorization.v1",
      "tool_name" => if(slack?, do: "triage.slack_read_permalink", else: "web.read_pages"),
      "agent_id" => product["salix_agent_id"],
      "session_id" => run_id,
      "tenant_id" => connect["tenant_id"],
      "group_id" => connect["group_id"],
      "role" => product["agent_role"],
      "runtime_kind" => "internal",
      "link_targets" => [link_target]
    }

    authorization =
      if slack?,
        do: Map.put(authorization, "slack_source_authority", connect),
        else: authorization

    keys =
      ~w(schema tool_name agent_id session_id tenant_id group_id role runtime_kind link_targets)

    keys = if slack?, do: ["slack_source_authority" | keys], else: keys

    valid? =
      exact_map_keys?(
        authorization,
        keys
      ) and authorization["tool_name"] in @link_read_tools and
        Enum.all?(~w(agent_id session_id tenant_id group_id role), fn key ->
          is_binary(authorization[key]) and authorization[key] != ""
        end) and authorization["runtime_kind"] == "internal"

    if valid?, do: {:ok, authorization}, else: {:error, :identity_fence_denied}
  end

  defp valid_read_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil}
      when is_binary(host) and host != "" ->
        true

      _other ->
        false
    end
  end

  @doc "Validates and durably binds one source-bound read-tool receipt."
  @spec commit_read_tool(map(), map(), map()) ::
          :ok | {:error, :identity_fence_denied}
  def commit_read_tool(active, authorization, receipt)
      when is_map(active) and is_map(authorization) and is_map(receipt) do
    with :ok <- validate_read_tool_receipt(receipt, authorization) do
      RunFence.transition(
        active,
        :commit_read_tool,
        read_tool_observation(authorization, receipt)
      )
    else
      _denied -> {:error, :identity_fence_denied}
    end
  end

  def commit_read_tool(_active, _authorization, _receipt),
    do: {:error, :identity_fence_denied}

  defp read_tool_observation(
         %{"tool_name" => tool_name, "link_targets" => [link_target]},
         receipt
       )
       when tool_name in @link_read_tools do
    %{
      "schema" => "comma.triage-read-tool-observation.v1",
      "tool_name" => tool_name,
      "link_ref" => link_target["link_ref"],
      "source_refs" => link_target["source_refs"],
      "receipt" => receipt,
      "committed_at_ms" => System.system_time(:millisecond)
    }
  end

  defp read_tool_observation(
         %{"tool_name" => "triage_run.get", "history_targets" => [target]},
         receipt
       ) do
    %{
      "schema" => "comma.triage-history-read-observation.v1",
      "tool_name" => "triage_run.get",
      "run_ref" => target["run_ref"],
      "receipt" => receipt,
      "committed_at_ms" => System.system_time(:millisecond)
    }
  end

  defp validate_read_tool_receipt(
         receipt,
         %{"tool_name" => tool_name} = authorization
       )
       when tool_name in @link_read_tools do
    [link_target] = authorization["link_targets"]
    call_bytes = receipt["canonical_call_bytes"]
    result_bytes = receipt["canonical_result_bytes"]

    with true <- exact_read_tool_receipt_shape?(receipt),
         "comma.triage-read-tool-receipt.v1" <- receipt["schema"],
         true <- nonempty?(receipt["call_id"]),
         ^tool_name <- receipt["tool_name"],
         true <- is_binary(call_bytes),
         true <- receipt["call_sha256"] == CanonicalJSON.sha256(call_bytes),
         {:ok, call} <- Jason.decode(call_bytes),
         true <- valid_link_read_call?(call, tool_name, link_target["link_ref"]),
         true <- valid_read_tool_outcome?(receipt),
         true <- is_binary(result_bytes),
         true <- receipt["result_sha256"] == CanonicalJSON.sha256(result_bytes),
         {:ok, %{"content" => content} = result} <- Jason.decode(result_bytes),
         true <- exact_map_keys?(result, ["content"]),
         true <- is_binary(content),
         # Blunt on purpose: a scheme this validator's own parser refuses to
         # read as a URL is still a redaction failure, so the durable check is
         # "no `https://` substring survives", not "no URL I can parse".
         false <- URLPrivacy.residual_https_scheme?(content) do
      :ok
    else
      _invalid -> {:error, :identity_fence_denied}
    end
  end

  defp validate_read_tool_receipt(
         receipt,
         %{"tool_name" => "triage_run.get", "history_targets" => [target]}
       ) do
    call_bytes = receipt["canonical_call_bytes"]
    result_bytes = receipt["canonical_result_bytes"]

    with true <- exact_read_tool_receipt_shape?(receipt),
         "comma.triage-read-tool-receipt.v1" <- receipt["schema"],
         true <- nonempty?(receipt["call_id"]),
         "triage_run.get" <- receipt["tool_name"],
         true <- is_binary(call_bytes),
         true <- receipt["call_sha256"] == CanonicalJSON.sha256(call_bytes),
         {:ok, %{"tool" => "triage_run.get", "params" => %{"run_ref" => run_ref}} = call} <-
           Jason.decode(call_bytes),
         true <- exact_map_keys?(call, ~w(tool params)),
         true <- exact_map_keys?(call["params"], ["run_ref"]),
         true <- run_ref == target["run_ref"],
         true <- valid_read_tool_outcome?(receipt),
         true <- is_binary(result_bytes),
         true <- receipt["result_sha256"] == CanonicalJSON.sha256(result_bytes),
         {:ok, %{"content" => content} = result} <- Jason.decode(result_bytes),
         true <- exact_map_keys?(result, ["content"]),
         {:ok, expected_content} <- CanonicalJSON.encode(target["result"]),
         true <- content == expected_content,
         false <- String.contains?(result_bytes, target["private_run_id"]) do
      :ok
    else
      _invalid -> {:error, :identity_fence_denied}
    end
  end

  defp validate_read_tool_receipt(_receipt, _authorization),
    do: {:error, :identity_fence_denied}

  defp valid_link_read_call?(call, "web.read_pages", link_ref),
    do: call == %{"tool" => "web.read_pages", "params" => %{"urls" => [link_ref]}}

  defp valid_link_read_call?(call, "triage.slack_read_permalink", link_ref),
    do: call == %{"tool" => "triage.slack_read_permalink", "params" => %{"link_ref" => link_ref}}

  defp exact_read_tool_receipt_shape?(receipt) do
    exact_map_keys?(
      receipt,
      ~w(schema call_id tool_name canonical_call_bytes call_sha256 status error error_class canonical_result_bytes result_sha256)
    )
  end

  defp valid_read_tool_outcome?(%{
         "status" => "completed",
         "error" => false,
         "error_class" => nil
       }),
       do: true

  defp valid_read_tool_outcome?(%{
         "status" => "error",
         "error" => true,
         "error_class" => error_class
       })
       when error_class in ~w(timeout transport tool_error invalid_result),
       do: true

  defp valid_read_tool_outcome?(_receipt), do: false

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  @spec run_identity(map(), term(), term(), :slack | :none | nil, IdentityFenceHandle.t()) ::
          {:ok, map(), map()} | {:terminal, map()} | {:error, term()}
  def run_identity(
        %{"schema" => "comma.triage-input-snapshot.v2"} = input,
        context_port,
        evaluator_port,
        review_projection,
        %IdentityFenceHandle{} = snapshot_authority
      ) do
    with :ok <- validate_input(input),
         :ok <- validate_context_port(input, context_port),
         {:ok, model_input} <- freeze(input, context_port),
         :ok <- bind_snapshot(snapshot_authority, model_input),
         :ok <- authorize_model(model_input, snapshot_authority) do
      case evaluate(model_input, evaluator_port) do
        {:ok, decision, proof} ->
          Logger.info("triage_pipeline_stage stage=evaluator result=ok")

          validated = validate_model_result(model_input, decision, proof, snapshot_authority)

          Logger.info(
            "triage_pipeline_stage stage=model_validation result=#{result_class(validated)}"
          )

          projected = attach_review_projection(validated, model_input, review_projection)

          Logger.info(
            "triage_pipeline_stage stage=review_projection result=#{result_class(projected)}"
          )

          projected

        {:error, _reason} = error ->
          error

        other ->
          {:error, {:invalid_model_result, other}}
      end
    end
  end

  def run_identity(_input, _context_port, _evaluator_port, _review_projection, _authority),
    do: {:error, :identity_projection_invalid}

  @doc "Runs the rolling-compatible v1 evaluation path outside Runtime."
  @spec run_compatibility(map(), term(), term(), :slack | :none | nil, term()) ::
          {:ok, map(), map()} | {:terminal, map()} | {:error, term()}
  def run_compatibility(
        %{"schema" => "comma.triage-input-snapshot.v2"} = input,
        _context_port,
        _evaluator_port,
        _review_projection,
        _snapshot_authority
      ) do
    case validate_input(input) do
      :ok -> {:error, :invalid_identity_context}
      {:error, _reason} = error -> error
    end
  end

  def run_compatibility(
        %{"schema" => "comma.triage-input-snapshot.v1"} = input,
        nil,
        evaluator_port,
        _review_projection,
        _snapshot_authority
      ) do
    with :ok <- validate_input(input) do
      evaluate(input, evaluator_port)
    end
  end

  def run_compatibility(
        %{"schema" => "comma.triage-input-snapshot.v1"} = input,
        context_port,
        evaluator_port,
        review_projection,
        snapshot_authority
      ) do
    with :ok <- validate_input(input),
         :ok <- validate_context_port(input, context_port),
         {:ok, model_input} <- freeze(input, context_port),
         :ok <- RunFence.bind_compatibility_snapshot(snapshot_authority, input, model_input),
         false <- get_in(model_input, ["snapshot", "answered_recheck", "answered"]) do
      case evaluate(model_input, evaluator_port) do
        {:ok, decision, proof} ->
          model_input
          |> validate_model_result(decision, proof, snapshot_authority)
          |> attach_review_projection(model_input, review_projection)

        {:error, _reason} = error ->
          error

        other ->
          {:error, {:invalid_model_result, other}}
      end
    else
      true ->
        {:terminal,
         %{
           "status" => "skipped_already_answered",
           "decision" => %{"action" => "silence"},
           "evaluator" => %{"schema" => "comma.triage-answered-skip.v1"},
           "settled_at" => System.system_time(:millisecond)
         }}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_context_result, other}}
    end
  end

  def run_compatibility(
        _input,
        _context_port,
        _evaluator_port,
        _review_projection,
        _snapshot_authority
      ),
      do: {:error, :invalid_identity_context}

  defp input_contract(events) do
    case IdentityContract.classify_event_provenance(events) do
      {:ok, :legacy} ->
        {"comma.triage-input-snapshot.v1", nil, nil}

      {:ok, :identity_enabled} ->
        case SourceMode.resolve(events) do
          {:ok, source_mode} -> {"comma.triage-input-snapshot.v2", nil, source_mode}
          {:error, reason} -> {"comma.triage-input-snapshot.v2", reason, nil}
        end

      {:error, reason} ->
        {"comma.triage-input-snapshot.v2", reason, nil}
    end
  end

  defp source_authority([receipt | _]) do
    event = receipt["triage_event"]
    bucket = event["bucket"]

    %{
      "connect_id" => receipt["connect_id"],
      "connect_generation" => event["connect_generation"],
      "workspace_id" => bucket["workspace_id"],
      "channel_id" => bucket["channel_id"],
      "thread_ts" => bucket["thread_ts"]
    }
    |> maybe_put_scope_kind(bucket["scope_kind"])
  end

  defp maybe_put_scope_kind(authority, "channel"),
    do: authority |> Map.put("scope_kind", "channel") |> Map.put("thread_ts", "__channel__")

  defp maybe_put_scope_kind(authority, _scope_kind), do: authority
  defp maybe_put_source_mode(input, nil), do: input
  defp maybe_put_source_mode(input, source_mode), do: Map.put(input, "source_mode", source_mode)
  defp maybe_put_provenance_error(input, nil), do: input

  defp maybe_put_provenance_error(input, reason),
    do: Map.put(input, "identity_provenance_error", Atom.to_string(reason))

  defp bind_snapshot(handle, model_input) do
    case IdentityFence.bind_snapshot(handle, model_input) do
      :ok -> :ok
      _denied -> {:error, :snapshot_freeze_lost_authority}
    end
  end

  defp evaluate(%{"snapshot" => snapshot} = input, evaluator_port) do
    if WorkerSelection.intake?(snapshot) do
      with {:ok, decision} <- WorkerSelection.assignment(input) do
        {:ok, decision, %{"schema" => "comma.triage-worker-assignment.v1"}}
      end
    else
      evaluate_provider(input, evaluator_port)
    end
  end

  defp evaluate(input, evaluator_port), do: evaluate_provider(input, evaluator_port)

  defp evaluate_provider(input, evaluator_port) do
    {mod, opts} = normalize_port(evaluator_port)

    try do
      apply(mod, :evaluate, [input, opts])
    rescue
      error -> {:error, {:exception, Exception.message(error)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp result_class({:ok, _decision, _proof}), do: "ok"
  defp result_class({:error, reason}) when is_atom(reason), do: "error_#{reason}"
  defp result_class({:error, _private}), do: "error_private"
  defp result_class(_other), do: "invalid"

  @doc false
  def validate_model_result(
        input,
        decision,
        %{"schema" => "comma.triage-worker-assignment.v1"} = metadata,
        authority
      )
      when map_size(metadata) == 1 do
    with {:ok, ^decision} <- WorkerSelection.assignment(input),
         :ok <- validate_identity_decision(input, decision, authority),
         :ok <- validate_decision_sources(decision, input["source_refs"]) do
      {:ok, decision,
       Map.merge(metadata, %{
         "canonical_snapshot_sha256" => input["canonical_snapshot_sha256"],
         "source_refs_sha256" => input["source_refs_sha256"],
         "request_count" => 0
       })}
    else
      {:ok, _different} -> {:error, :invalid_triage_worker_assignment}
      error -> error
    end
  end

  def validate_model_result(
        input,
        decision,
        %{
          "schema" => "comma.triage-model-proof.v1",
          "provider" => provider,
          "model" => model,
          "prompt_bytes" => prompt_bytes,
          "policy_bytes" => policy_bytes,
          "provider_payload_bytes" => payload_bytes,
          "observer_payload_sha256" => observer_sha256,
          "transport_payload_sha256" => transport_sha256,
          "request_count" => 1,
          "retry" => false
        } = raw_proof,
        decision_authority
      )
      when is_map(decision) and is_binary(provider) and provider != "" and is_binary(model) and
             model != "" and is_binary(prompt_bytes) and is_binary(policy_bytes) and
             is_binary(payload_bytes) do
    payload_sha256 = CanonicalJSON.sha256(payload_bytes)
    snapshot_bytes = input["canonical_snapshot_bytes"]

    with {:proof_shape, true} <-
           {:proof_shape,
            exact_map_keys?(
              raw_proof,
              ~w(schema provider model prompt_bytes policy_bytes provider_payload_bytes observer_payload_sha256 transport_payload_sha256 request_count retry)
            )},
         {:observer_payload, true} <- {:observer_payload, observer_sha256 == payload_sha256},
         {:transport_payload, true} <- {:transport_payload, transport_sha256 == payload_sha256},
         {:payload_decode, {:ok, payload}} <- {:payload_decode, Jason.decode(payload_bytes)},
         {:snapshot_binding, true} <-
           {:snapshot_binding,
            RunFence.payload_has_exact_message_content?(payload, snapshot_bytes)},
         {:tool_disclosure, true} <-
           {:tool_disclosure, RunFence.valid_read_tool_disclosure?(payload["tools"])},
         {:identity_decision, :ok} <-
           {:identity_decision, validate_identity_decision(input, decision, decision_authority)},
         {:decision_sources, :ok} <-
           {:decision_sources, validate_decision_sources(decision, input["source_refs"])} do
      proof = %{
        "schema" => "comma.triage-model-proof.v1",
        "provider" => provider,
        "model" => model,
        "provider_sha256" => CanonicalJSON.sha256(provider),
        "model_sha256" => CanonicalJSON.sha256(model),
        "prompt_sha256" => CanonicalJSON.sha256(prompt_bytes),
        "policy_sha256" => CanonicalJSON.sha256(policy_bytes),
        "provider_payload_bytes" => payload_bytes,
        "provider_payload_sha256" => payload_sha256,
        "observer_payload_sha256" => observer_sha256,
        "transport_payload_sha256" => transport_sha256,
        "request_count" => 1,
        "retry" => false,
        "canonical_snapshot_sha256" => input["canonical_snapshot_sha256"],
        "source_refs_sha256" => input["source_refs_sha256"]
      }

      {:ok, decision, proof}
    else
      {stage, false} ->
        log_model_validation_failure(:direct, stage, :invalid_result)
        {:error, :invalid_model_proof}

      {stage, {:error, :invalid_decision_sources}} ->
        log_model_validation_failure(:direct, stage, :invalid_decision_sources)
        {:error, :invalid_decision_sources}

      {stage, {:error, :invalid_identity_context}} ->
        log_model_validation_failure(:direct, stage, :invalid_identity_context)
        {:error, :invalid_identity_context}

      {stage, {:error, :invalid_identity_decision}} ->
        log_model_validation_failure(:direct, stage, :invalid_identity_decision)
        {:error, :invalid_identity_decision}

      {stage, {:error, :identity_decision_invalid}} ->
        log_model_validation_failure(:direct, stage, :identity_decision_invalid)
        {:error, :identity_decision_invalid}

      {stage, {:error, :identity_projection_invalid}} ->
        log_model_validation_failure(:direct, stage, :identity_projection_invalid)
        {:error, :identity_projection_invalid}

      {stage, {:error, :identity_projection_privacy_rejected}} ->
        log_model_validation_failure(:direct, stage, :identity_projection_privacy_rejected)
        {:error, :identity_projection_privacy_rejected}

      {stage, {:error, _reason}} ->
        log_model_validation_failure(:direct, stage, :invalid_provider_payload)
        {:error, :invalid_provider_payload}

      {stage, _other} ->
        log_model_validation_failure(:direct, stage, :invalid_result)
        {:error, :invalid_model_proof}
    end
  end

  def validate_model_result(
        input,
        decision,
        %{
          "schema" => "comma.triage-model-proof.v2",
          "provider" => provider,
          "model" => model,
          "prompt_bytes" => prompt_bytes,
          "policy_bytes" => policy_bytes,
          "provider_payload_bytes" => payload_bytes,
          "provider_payload_chain" => [_first, _second] = payload_chain,
          "observer_payload_sha256" => observer_sha256,
          "transport_payload_sha256" => transport_sha256,
          "request_count" => 2,
          "retry" => false,
          "tool_call_count" => 1,
          "tool_names" => [tool_name] = tool_names,
          "tool_receipts" => [receipt] = tool_receipts
        } = raw_proof,
        decision_authority
      )
      when tool_name in @identity_read_tools and is_map(decision) and is_binary(provider) and
             provider != "" and is_binary(model) and model != "" and is_binary(prompt_bytes) and
             is_binary(policy_bytes) and is_binary(payload_bytes) do
    payload_sha256 = CanonicalJSON.sha256(payload_bytes)
    snapshot_bytes = input["canonical_snapshot_bytes"]
    [first_payload_receipt, second_payload_receipt] = payload_chain

    with true <-
           exact_map_keys?(
             raw_proof,
             ~w(schema provider model prompt_bytes policy_bytes provider_payload_bytes provider_payload_chain observer_payload_sha256 transport_payload_sha256 request_count retry tool_call_count tool_names tool_receipts)
           ),
         true <- RunFence.valid_provider_payload_chain?(payload_chain, payload_bytes),
         true <- RunFence.valid_read_tool_receipt?(receipt),
         true <- observer_sha256 == payload_sha256,
         true <- transport_sha256 == payload_sha256,
         {:ok, first_payload} <- Jason.decode(first_payload_receipt["payload_bytes"]),
         {:ok, second_payload} <- Jason.decode(second_payload_receipt["payload_bytes"]),
         true <- RunFence.payload_has_exact_message_content?(first_payload, snapshot_bytes),
         true <- RunFence.payload_has_exact_message_content?(second_payload, snapshot_bytes),
         true <- is_list(first_payload["tools"]) and length(first_payload["tools"]) == 1,
         true <- second_payload["tools"] in [nil, []],
         {:ok, call} <- Jason.decode(receipt["canonical_call_bytes"]),
         {:ok, result} <- Jason.decode(receipt["canonical_result_bytes"]),
         true <-
           RunFence.provider_payload_has_tool_exchange?(second_payload, receipt, call, result),
         :ok <- validate_identity_decision(input, decision, decision_authority),
         :ok <- validate_decision_sources(decision, input["source_refs"]) do
      proof = %{
        "schema" => "comma.triage-model-proof.v2",
        "provider" => provider,
        "model" => model,
        "provider_sha256" => CanonicalJSON.sha256(provider),
        "model_sha256" => CanonicalJSON.sha256(model),
        "prompt_sha256" => CanonicalJSON.sha256(prompt_bytes),
        "policy_sha256" => CanonicalJSON.sha256(policy_bytes),
        "provider_payload_bytes" => payload_bytes,
        "provider_payload_sha256" => payload_sha256,
        "provider_payload_chain" => payload_chain,
        "observer_payload_sha256" => observer_sha256,
        "transport_payload_sha256" => transport_sha256,
        "request_count" => 2,
        "retry" => false,
        "canonical_snapshot_sha256" => input["canonical_snapshot_sha256"],
        "source_refs_sha256" => input["source_refs_sha256"],
        "tool_call_count" => 1,
        "tool_names" => tool_names,
        "tool_receipts" => tool_receipts
      }

      {:ok, decision, proof}
    else
      {:error, :invalid_decision_sources} ->
        {:error, :invalid_decision_sources}

      {:error, :invalid_identity_context} ->
        {:error, :invalid_identity_context}

      {:error, :invalid_identity_decision} ->
        {:error, :invalid_identity_decision}

      {:error, :identity_decision_invalid} ->
        {:error, :identity_decision_invalid}

      {:error, :identity_projection_invalid} ->
        {:error, :identity_projection_invalid}

      {:error, :identity_projection_privacy_rejected} ->
        {:error, :identity_projection_privacy_rejected}

      _invalid ->
        {:error, :invalid_model_proof}
    end
  end

  def validate_model_result(
        input,
        decision,
        %{"schema" => "comma.triage-model-proof.v3"} = raw_proof,
        decision_authority
      ) do
    base_keys =
      ~w(schema provider model prompt_bytes policy_bytes provider_payload_bytes observer_payload_sha256 transport_payload_sha256 request_count retry)

    phase_keys =
      ~w(provider_payload_chain tool_call_count tool_names tool_receipts participation_decision)

    # Reuse the existing final-request and decision checks. Retain and validate
    # the real v3 request count and phase evidence before returning any proof.
    final_request =
      raw_proof
      |> Map.take(base_keys)
      |> Map.put("schema", "comma.triage-model-proof.v1")
      |> Map.put("request_count", 1)

    with true <- exact_map_keys?(raw_proof, base_keys ++ phase_keys),
         true <- RunFence.valid_participation_payloads?(raw_proof),
         true <-
           RunFence.participation_snapshot_matches?(raw_proof, input["canonical_snapshot_bytes"]),
         true <- RunFence.participation_result_matches?(raw_proof, decision),
         {:ok, decision, header} <-
           validate_model_result(input, decision, final_request, decision_authority) do
      proof =
        header
        |> Map.merge(Map.take(raw_proof, phase_keys ++ ~w(schema request_count)))

      {:ok, decision, proof}
    else
      false -> {:error, :invalid_model_proof}
      {:error, _reason} = error -> error
    end
  end

  def validate_model_result(_input, _decision, _proof, _decision_authority),
    do: {:error, :invalid_model_proof}

  defp log_model_validation_failure(proof_kind, stage, reason)
       when proof_kind in [:direct, :tool] and is_atom(stage) and is_atom(reason) do
    Logger.warning(
      "triage_model_validation_failed proof=#{proof_kind} stage=#{stage} reason=#{reason}"
    )
  end

  @doc false
  def attach_review_projection({:ok, decision, proof}, input, :slack) do
    with {:ok, artifact} <- ReviewProjection.slack(input, decision),
         {:ok, bytes} <- CanonicalJSON.encode(artifact) do
      {:ok, decision,
       proof
       |> Map.put("review_artifact", artifact)
       |> Map.put("review_artifact_sha256", CanonicalJSON.sha256(bytes))}
    end
  end

  def attach_review_projection({:ok, _decision, _proof}, _input, projection)
      when projection not in [:none, nil],
      do: {:error, :invalid_triage_review_projection}

  def attach_review_projection(result, _input, _projection), do: result

  defp validate_decision_sources(
         %{"schema" => schema} = decision,
         allowed_refs
       )
       when schema in ["comma.triage-product-decision.v1", "comma.triage-product-decision.v2"] and
              is_list(allowed_refs) do
    refs = ProductDecision.source_refs(decision)

    if ProductDecision.structurally_valid?(decision) and
         Enum.all?(refs, &(&1 in allowed_refs)),
       do: :ok,
       else: {:error, :invalid_decision_sources}
  end

  defp validate_decision_sources(%{"action" => action} = decision, allowed_refs)
       when action in ["silence", "reply", "react", "delegate", "remember"] and
              is_list(allowed_refs) do
    refs = decision["source_refs"]

    cond do
      action in ["reply", "delegate", "remember"] and (not is_list(refs) or refs == []) ->
        {:error, :invalid_decision_sources}

      is_nil(refs) ->
        :ok

      is_list(refs) and
          Enum.all?(refs, &(is_binary(&1) and &1 != "" and &1 in allowed_refs)) ->
        :ok

      true ->
        {:error, :invalid_decision_sources}
    end
  end

  defp validate_decision_sources(_decision, _allowed_refs),
    do: {:error, :invalid_decision_sources}

  defp validate_identity_decision(
         %{
           "schema" => "comma.triage-model-input.v2",
           "snapshot" => %{"identity_context" => identity_context}
         },
         decision,
         _decision_authority
       ),
       do: IdentityContract.validate_decision(decision, identity_context)

  defp validate_identity_decision(
         %{"schema" => "comma.triage-model-input.v3"},
         decision,
         %IdentityFenceHandle{} = handle
       ),
       do: IdentityFence.validate_model_decision(handle, decision)

  defp validate_identity_decision(
         %{"schema" => "comma.triage-model-input.v1"},
         _decision,
         _decision_authority
       ),
       do: :ok

  defp validate_identity_decision(_input, _decision, _decision_authority),
    do: {:error, :invalid_identity_context}

  defp exact_map_keys?(map, keys),
    do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)

  def freeze(input, context_port) do
    {mod, opts} = normalize_port(context_port)

    case call_context(mod, input, opts) do
      {:ok, frozen, private_projection} ->
        freeze_identity_model_input(input, frozen, private_projection, opts)

      {:ok, frozen} ->
        freeze_legacy_model_input(input, frozen)

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :invalid_frozen_context}
    end
  end

  defp freeze_legacy_model_input(input, frozen) do
    with :ok <- validate_frozen_context(frozen, input),
         snapshot = build_context_snapshot(input, frozen),
         {:ok, snapshot_bytes} <- CanonicalJSON.encode(snapshot),
         source_refs = collect_source_refs(frozen),
         {:ok, source_refs_bytes} <- CanonicalJSON.encode(source_refs) do
      {:ok,
       input
       |> Map.put("schema", model_input_schema(input))
       |> Map.put("snapshot", snapshot)
       |> Map.put("canonical_snapshot_bytes", snapshot_bytes)
       |> Map.put("canonical_snapshot_sha256", CanonicalJSON.sha256(snapshot_bytes))
       |> Map.put("source_refs", source_refs)
       |> Map.put("source_refs_canonical_bytes", source_refs_bytes)
       |> Map.put("source_refs_sha256", CanonicalJSON.sha256(source_refs_bytes))}
    end
  end

  defp freeze_identity_model_input(
         %{"schema" => "comma.triage-input-snapshot.v2"} = input,
         frozen,
         private_projection,
         opts
       ) do
    with {:fence_handle, %IdentityFenceHandle{} = handle} <-
           {:fence_handle, opts[:identity_fence_handle]},
         {:frozen_context, :ok} <-
           {:frozen_context, validate_projected_frozen_context(frozen)},
         {:projected_encoding, {:ok, projected_context_bytes}} <-
           {:projected_encoding, CanonicalJSON.encode(frozen)},
         projected_context_sha256 = CanonicalJSON.sha256(projected_context_bytes),
         {:projection_hash, true} <-
           {:projection_hash,
            private_projection["projected_context_sha256"] == projected_context_sha256},
         {:projection_recompute,
          {:ok,
           %{
             projected_context: ^frozen,
             canonical_bytes: ^projected_context_bytes,
             sha256: ^projected_context_sha256
           }}} <-
           {:projection_recompute,
            IdentityContract.recompute_projected_context(private_projection)},
         {:projection_bind, :ok} <-
           {:projection_bind,
            bind_identity_projection(handle, private_projection, projected_context_sha256)},
         snapshot = build_identity_context_snapshot(input, frozen, private_projection),
         {:snapshot_encoding, {:ok, snapshot_bytes}} <-
           {:snapshot_encoding, CanonicalJSON.encode(snapshot)},
         source_refs = get_in(snapshot, ["decision_contract", "source_refs"]),
         {:source_refs, true} <- {:source_refs, is_list(source_refs)},
         {:source_refs_encoding, {:ok, source_refs_bytes}} <-
           {:source_refs_encoding, CanonicalJSON.encode(source_refs)} do
      {:ok,
       %{
         "schema" => "comma.triage-model-input.v3",
         "snapshot" => snapshot,
         "canonical_snapshot_bytes" => snapshot_bytes,
         "canonical_snapshot_sha256" => CanonicalJSON.sha256(snapshot_bytes),
         "source_refs" => source_refs,
         "source_refs_canonical_bytes" => source_refs_bytes,
         "source_refs_sha256" => CanonicalJSON.sha256(source_refs_bytes)
       }}
    else
      {stage, {:error, reason} = error} when is_atom(reason) ->
        log_identity_freeze_failure(stage, reason)
        error

      {stage, _other} ->
        log_identity_freeze_failure(stage, :invalid_result)
        {:error, :identity_projection_invalid}
    end
  end

  defp freeze_identity_model_input(_input, _frozen, _private_projection, _opts),
    do: {:error, :identity_projection_invalid}

  defp bind_identity_projection(handle, private_projection, projected_context_sha256) do
    case IdentityFence.bind_projection(handle, private_projection, projected_context_sha256) do
      :ok -> :ok
      _denied -> {:error, :identity_projection_invalid}
    end
  end

  defp validate_projected_frozen_context(frozen) when is_map(frozen) do
    keys = ~w(
      slack_context
      identity_context
      team_project_memory
      decision_contract
    )

    # Old immutable snapshots retain the activity flag. New snapshots leave
    # completion to the evaluator; IdentityFence verifies the versioned shape.
    keys =
      if Map.has_key?(frozen, "answered_recheck"), do: keys ++ ["answered_recheck"], else: keys

    valid? =
      Map.keys(frozen) |> Enum.sort() == Enum.sort(keys) and
        Enum.all?(keys, &is_map(frozen[&1])) and
        (not Map.has_key?(frozen, "answered_recheck") or
           (is_boolean(get_in(frozen, ["answered_recheck", "answered"])) and
              Map.keys(frozen["answered_recheck"]) == ["answered"]))

    if valid?, do: :ok, else: {:error, :identity_projection_invalid}
  end

  defp validate_projected_frozen_context(_frozen),
    do: {:error, :identity_projection_invalid}

  defp build_identity_context_snapshot(input, frozen, private_projection) do
    base = RunFence.base_projection(input)

    %{
      "schema" => identity_context_snapshot_schema(frozen, private_projection),
      "generation_ref" => "generation://run/current",
      "events" => base["events"],
      "receipt_refs" => base["receipt_refs"],
      "source_authority" => base["source_authority"],
      "slack_context" => frozen["slack_context"],
      "identity_context" => frozen["identity_context"],
      "team_project_memory" => frozen["team_project_memory"],
      "decision_contract" => frozen["decision_contract"]
    }
    |> Map.merge(Map.take(frozen, ["answered_recheck"]))
  end

  defp identity_context_snapshot_schema(
         %{"slack_context" => %{"expression_context" => expression_context}},
         %{"raw_source_bundle_bytes" => raw_bundle_bytes}
       )
       when is_map(expression_context) do
    case Jason.decode(raw_bundle_bytes) do
      {:ok, %{"schema" => "comma.triage-private-source-bundle.v7"}} ->
        "comma.triage-context-snapshot.v9"

      {:ok, %{"schema" => "comma.triage-private-source-bundle.v8"}} ->
        "comma.triage-context-snapshot.v10"

      {:ok, %{"schema" => "comma.triage-private-source-bundle.v6"}} ->
        "comma.triage-context-snapshot.v8"

      {:ok, %{"schema" => "comma.triage-private-source-bundle.v5"}} ->
        "comma.triage-context-snapshot.v7"

      _other ->
        "comma.triage-context-snapshot.v6"
    end
  end

  defp identity_context_snapshot_schema(_frozen, _private_projection),
    do: "comma.triage-context-snapshot.v5"

  defp call_context(mod, input, opts) do
    apply(mod, :freeze, [input, opts])
  rescue
    error ->
      Logger.warning(
        "triage_identity_freeze_stage_failed stage=context_exception class=#{inspect(error.__struct__)}"
      )

      {:error, {:context_exception, Exception.message(error)}}
  catch
    kind, reason ->
      Logger.warning(
        "triage_identity_freeze_stage_failed stage=context_throw class=#{inspect(kind)}"
      )

      {:error, {:context_throw, kind, reason}}
  end

  defp log_identity_freeze_failure(stage, reason) when is_atom(stage) and is_atom(reason) do
    Logger.warning("triage_identity_freeze_stage_failed stage=#{stage} reason=#{reason}")
  end

  defp validate_frozen_context(
         %{
           "slack_context" => slack_context,
           "team_project_memory" => team_project_memory,
           "answered_recheck" => %{"answered" => answered} = recheck
         } = frozen,
         %{"schema" => "comma.triage-input-snapshot.v1"}
       )
       when is_map(slack_context) and is_map(team_project_memory) and is_boolean(answered) and
              is_map(recheck),
       do:
         if(is_nil(frozen["identity_context"]), do: :ok, else: {:error, :invalid_frozen_context})

  defp validate_frozen_context(
         %{
           "slack_context" => slack_context,
           "team_project_memory" => team_project_memory,
           "answered_recheck" => %{"answered" => answered} = recheck,
           "identity_context" => identity_context
         },
         %{"schema" => "comma.triage-input-snapshot.v2"}
       )
       when is_map(slack_context) and is_map(team_project_memory) and is_boolean(answered) and
              is_map(recheck) and is_map(identity_context),
       do: IdentityContract.validate_context(identity_context)

  defp validate_frozen_context(_frozen, _input), do: {:error, :invalid_frozen_context}

  defp build_context_snapshot(input, frozen) do
    snapshot = %{
      "schema" => context_snapshot_schema(input),
      "generation" => input["generation"],
      "events" => input["events"],
      "receipt_refs" => input["receipt_refs"],
      "source_authority" => input["source_authority"],
      "slack_context" => frozen["slack_context"],
      "team_project_memory" => frozen["team_project_memory"],
      "answered_recheck" => frozen["answered_recheck"]
    }

    if input["schema"] == "comma.triage-input-snapshot.v2" do
      Map.put(snapshot, "identity_context", frozen["identity_context"])
    else
      snapshot
    end
  end

  defp collect_source_refs(value) do
    value
    |> do_collect_source_refs([])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp do_collect_source_refs(value, refs) when is_map(value) do
    Enum.reduce(value, refs, fn
      {"source_ref", source_ref}, refs -> [source_ref | refs]
      {"source_refs", source_refs}, refs when is_list(source_refs) -> source_refs ++ refs
      {_key, child}, refs -> do_collect_source_refs(child, refs)
    end)
  end

  defp do_collect_source_refs(value, refs) when is_list(value) do
    Enum.reduce(value, refs, &do_collect_source_refs/2)
  end

  defp do_collect_source_refs(_value, refs), do: refs

  defp model_input_schema(%{"schema" => "comma.triage-input-snapshot.v2"}),
    do: "comma.triage-model-input.v2"

  defp model_input_schema(_input), do: "comma.triage-model-input.v1"

  defp context_snapshot_schema(%{"schema" => "comma.triage-input-snapshot.v2"}),
    do: "comma.triage-context-snapshot.v2"

  defp context_snapshot_schema(_input), do: "comma.triage-context-snapshot.v1"

  defp normalize_port({mod, opts}) when is_atom(mod) and is_list(opts), do: {mod, opts}
  defp normalize_port(mod) when is_atom(mod), do: {mod, []}
end
