defmodule SalixAgent.LiveLlmTestSupport do
  @moduledoc false

  @base_url "https://opencode.ai/zen/go/v1"
  @preflight_key {__MODULE__, :preflight}
  @model "deepseek-v4-flash"
  @protocol "chat_completions"

  defmodule OAuthStubStore do
    @moduledoc false
    @behaviour SalixAgent.OAuthStore

    @impl true
    def agent_oauth_context(agent_id) do
      group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
      {:ok, %{tenant: SalixStore.Ids.tenant_id_from_group!(group_id), group_id: group_id}}
    end

    @impl true
    def provider_app(_tenant, _provider), do: {:error, :not_configured}

    @impl true
    def bindings_for_group(_group_id), do: {:ok, []}

    @impl true
    def public_base_url, do: nil

    @impl true
    def delete_binding(_tenant, _group_id, _binding_id), do: :ok
  end

  defmodule CaptureNotifier do
    @moduledoc false
    @behaviour SalixAgent.Notifier

    @impl true
    def notify(agent_id, event) do
      if pid = Application.get_env(:salix_agent, :live_llm_test_capture_pid) do
        send(pid, {:live_llm_test_notification, agent_id, event})
      end

      :ok
    end
  end

  def llm_config! do
    key_env =
      Enum.find(["LLM_API_KEY", "SALIX_E2E_LLM_API_KEY"], fn name ->
        System.get_env(name) not in [nil, ""]
      end) || raise "SALIX_E2E_LLM_API_KEY is not set (required for :live_llm tests)"

    config = %{
      protocol: System.get_env("LLM_PROTOCOL") || @protocol,
      base_url: System.get_env("LLM_BASE_URL") || @base_url,
      api_key_env: key_env,
      model: System.get_env("LLM_MODEL") || @model,
      max_tokens: 2_000,
      default_headers: %{"x-opencode-session" => opencode_session_id()}
    }

    preflight!(config)
    config
  end

  # OpenCode Go rejects requests without a stable `x-opencode-session` id
  # (HTTP 400 `MissingSessionID`, enforced since 2026-09-21 — every main run's
  # live shards failed on it). One id per test-run VM: stable across the whole
  # shard, so its requests share one routing/prompt-cache lane, and distinct
  # between runs. `default_headers` rides the existing `ProviderConfig` field
  # all the way into the kernel's request headers, so both the preflight and
  # the agent traffic configured via `configure!/3` carry it.
  defp opencode_session_id do
    key = {__MODULE__, :opencode_session_id}

    case :persistent_term.get(key, nil) do
      nil ->
        id = "salix-live-llm-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        :persistent_term.put(key, id)
        id

      id ->
        id
    end
  end

  @doc """
  One real, minimal request before a shard runs its tests.

  A dead provider is indistinguishable from a product failure once the suite
  starts: no turn is ever produced, so every test spends its whole
  `eventually/2` budget and raises the same generic timeout, and the longer
  shards are killed by the job timeout first and read as "cancelled". That is
  what happened for the two days in #945 — an OpenCode monthly usage limit
  answering 429 to every request looked like a Task-semantics regression, and
  cost a full triage round to tell apart.

  So ask once, up front, and fail in seconds with the provider's own words.
  A retryable answer is retried once (a single 5xx or a transport blip should
  not fail a shard); anything still failing raises with the status and the
  provider's message body.
  """
  def preflight!(llm) do
    case :persistent_term.get(@preflight_key, nil) do
      :ok -> :ok
      nil -> run_preflight!(llm, 1)
    end
  end

  defp run_preflight!(llm, retries_left) do
    llm_opts =
      llm
      |> stringify_keys()
      |> Map.drop(["max_tokens"])
      |> Map.put("max_tokens", 16)

    # `SalixLlm.Provider` is the runtime seam, not a compile-time dependency of
    # salix_agent (`install_runtime!/0` installs it by atom for the same
    # reason), so call it through apply/3 rather than adding an umbrella dep
    # just for a test preflight.
    case apply(SalixLlm.Provider, :complete, [[%{role: "user", content: "ping"}], [], llm_opts]) do
      {:error, %{"retryable" => true} = error} when retries_left > 0 ->
        Process.sleep(1_000)
        _ = error
        run_preflight!(llm, retries_left - 1)

      {:error, error} ->
        raise preflight_message(llm, error)

      _reachable ->
        :persistent_term.put(@preflight_key, :ok)
        :ok
    end
  end

  # The provider's own body is the useful part: OpenCode's quota 429 names the
  # limit, the reset date, and the workspace to top up. Keep it verbatim rather
  # than folding it into a house error string.
  defp preflight_message(llm, error) do
    status = error["status"]

    headline =
      cond do
        status == 429 -> "live LLM provider is out of quota (HTTP 429)"
        status in [401, 403] -> "live LLM credential was rejected (HTTP #{status})"
        is_integer(status) -> "live LLM provider returned HTTP #{status}"
        true -> "live LLM provider is unreachable"
      end

    """
    #{headline} — no :live_llm test can pass, failing the shard here instead of \
    letting each test wait out its eventually/2 budget.

      model:    #{llm.model}
      base_url: #{llm.base_url}
      key from: $#{llm.api_key_env}
      class:    #{error["error_class"]}
      provider: #{error["body"] || error["reason"] || error["details"]}
    """
  end

  def install_runtime! do
    previous =
      Map.new(
        [
          :llm,
          :summarizer,
          :oauth_store_mod,
          :im_provider_mod,
          :group_context_mod,
          :notifier,
          :live_llm_test_capture_pid
        ],
        &{&1, Application.get_env(:salix_agent, &1)}
      )

    previous_task_create = Application.get_env(:salix_im, :task_create_mod)

    Application.put_env(:salix_agent, :llm, SalixLlm.Provider)
    Application.delete_env(:salix_agent, :summarizer)
    Application.put_env(:salix_agent, :oauth_store_mod, OAuthStubStore)

    Application.put_env(
      :salix_im,
      :task_create_mod,
      Module.concat(["Salix", "Bindings", "AgentConversations"])
    )

    Application.put_env(:salix_agent, :im_provider_mod, SalixIM.Provider)
    Application.put_env(:salix_agent, :notifier, CaptureNotifier)
    Application.put_env(:salix_agent, :live_llm_test_capture_pid, self())

    fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:salix_agent, key)
        {key, value} -> Application.put_env(:salix_agent, key, value)
      end)

      case previous_task_create do
        nil -> Application.delete_env(:salix_im, :task_create_mod)
        value -> Application.put_env(:salix_im, :task_create_mod, value)
      end
    end
  end

  def configure!(agent_id, llm, agent_config \\ %{}) do
    llm = stringify_keys(llm)
    agent_config = stringify_keys(agent_config)
    provider_config = Map.drop(llm, ["model", "max_tokens"])

    SalixAgent.TestSupport.create_control_agent!(
      agent_id,
      Map.merge(agent_config, %{
        "model" => llm["model"],
        "provider" => provider_config["protocol"] || "openai",
        "provider_config" => provider_config,
        "max_tokens" => llm["max_tokens"]
      })
    )

    SalixAgent.Server.info(agent_id)
    :ok
  end

  def seed_group!(tenant_id, group_id) do
    SalixAgent.TestSupport.create_control_group!(group_id, %{
      "tenant_id" => tenant_id,
      "name" => "Live LLM group #{group_id}"
    })

    :ok
  end

  def eventually(fun, timeout_ms \\ 180_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_eventually(fun, deadline)
  end

  defp await_eventually(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) > deadline, do: raise("eventually: timed out")
        Process.sleep(1_000)
        await_eventually(fun, deadline)
    end
  end

  def flush_notifications! do
    receive do
      {:live_llm_test_notification, _, _} -> flush_notifications!()
    after
      0 -> :ok
    end
  end

  def await_session_settled!(agent_id, session_id, timeout_ms \\ 180_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_session_update(agent_id, session_id, deadline, nil, :settled)
  end

  def await_session_quiescent!(agent_id, session_id, timeout_ms \\ 180_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_session_update(agent_id, session_id, deadline, nil, :quiescent)
  end

  defp await_session_update(agent_id, session_id, deadline, last_seen, expected_state) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:live_llm_test_notification, ^agent_id, {:session_updated, ^session_id}} ->
        case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
          {:ok, session} ->
            if session_reached?(session, expected_state) do
              session
            else
              await_session_update(
                agent_id,
                session_id,
                deadline,
                session_summary(session),
                expected_state
              )
            end

          {:error, :not_found} ->
            await_session_update(agent_id, session_id, deadline, last_seen, expected_state)

          {:error, reason} ->
            raise "session read failed: #{inspect(reason)}"
        end
    after
      remaining ->
        raise "session #{agent_id}/#{session_id} did not reach #{expected_state}; " <>
                "last=#{inspect(last_seen)}"
    end
  end

  defp session_reached?(session, :settled) do
    session.status == :idle and session.work_index_reasons == []
  end

  defp session_reached?(session, :quiescent) do
    session_reached?(session, :settled) or session_reached?(session, :waiting_for_input)
  end

  defp session_reached?(session, :waiting_for_input) do
    session.status == :idle and get_in(session.wait, ["source"]) == "wait_for" and
      map_size(session.async_tool_calls || %{}) == 0 and
      "stable_input_pending" in session.work_index_reasons
  end

  def session_summary(session) do
    %{
      status: session.status,
      wait: session.wait,
      async_tool_calls: Map.keys(session.async_tool_calls || %{}),
      work_index_reasons: session.work_index_reasons
    }
  end

  def router_session_id!(agent_id) do
    {:ok, record} = SalixAgent.AgentControl.get_record(agent_id)
    {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(record)
    session_id
  end

  def text_content(content) when is_binary(content), do: content

  def text_content(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("\n", &to_string(&1["text"] || ""))
  end

  def text_content(_content), do: ""

  def conversation_ref_ids(messages) do
    for message <- messages,
        block <- List.wrap(message["content"]),
        is_map(block),
        block["type"] == "conversation_ref",
        is_binary(block["conversation_id"]),
        do: block["conversation_id"]
  end

  def inline_task_ref_ids(messages) do
    for message <- messages,
        block <- List.wrap(message["content"]),
        is_map(block),
        block["type"] == "conversation_ref",
        block["kind"] == "agent_task",
        block["presentation"] == "inline",
        is_binary(block["conversation_id"]),
        do: block["conversation_id"]
  end

  def unique_suffix, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  def restore_env(key, nil), do: Application.delete_env(:salix_agent, key)
  def restore_env(key, value), do: Application.put_env(:salix_agent, key, value)

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
