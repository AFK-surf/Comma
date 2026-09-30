defmodule SalixLlm.ProviderConfig do
  @moduledoc """
  Per-call provider configuration, mirroring willow's `llm.ProviderConfig` +
  `ResolveAgentProviderConfig`: the agent's template carries `model` /
  `protocol` / `base_url` / `api_key` (or `api_key_env`) /
  `auth_token` (or `auth_token_env`) / `default_headers` / `max_tokens`,
  resolved live per agent at activation.

  There is **no cluster-wide fallback** (willow parity): the template (or, for
  agents without a control record, the journaled `llm_config` state) is the
  sole source of provider configuration. Missing fields stay empty and the
  request fails at the provider — never a silent call to a default provider.

  `protocol` selects the wire protocol (same strings as willow):

    * `"anthropic"` — Anthropic Messages; auth via `x-api-key` +
      `anthropic-version`, or `Authorization: Bearer` when `auth_token` is
      explicitly configured by the template.
    * `"responses"` — OpenAI Responses (`{base}/responses`); `Authorization: Bearer`
    * `""` / `"chat_completions"` — OpenAI Chat Completions
      (`{base}/chat/completions`); `Authorization: Bearer` (willow's default)

  `max_tokens` is optional; the Anthropic client defaults it to 4096 (the API
  requires the field — same default as willow's `chatRequestToAnthropic`), the
  OpenAI clients omit it when unset (willow's `omitempty`).

  `prompt_caching` (Anthropic only, default `true`) controls automatic
  `cache_control` placement — see `SalixLlm.CacheBreakpoints`. Set it to `false`
  for a caller whose prompt prefix is never reused, where the ~1.25x cache-write
  premium would have nothing to read it back.

  `prompt_cache_key` (OpenAI protocols only) is sent verbatim on Responses and
  Chat Completions requests. `SalixAgent.LLM` derives one stable key per
  session so that every round of a conversation lands on the same provider
  prompt cache; the compact endpoint never carries it.

  Override keys may be atoms or strings (they arrive from the template's
  string-keyed `provider_config` / the journaled `llm_config` state).
  """

  @type t :: %{
          protocol: String.t(),
          model: String.t(),
          api_key: String.t(),
          auth_token: String.t(),
          base_url: String.t(),
          max_tokens: pos_integer() | nil,
          prompt_caching: boolean(),
          store: boolean() | nil,
          include: [String.t()] | nil,
          context_management: [map()] | nil,
          reasoning: map() | nil,
          thinking: map() | nil,
          response_format: map() | nil,
          prompt_cache_key: String.t() | nil,
          default_headers: %{optional(String.t()) => String.t()}
        }

  @spec resolve(map() | keyword() | nil) :: t()
  def resolve(overrides \\ nil) do
    o = normalize(overrides)

    data = Map.take(o, ~w(protocol model base_url max_tokens prompt_caching store include
      context_management reasoning reasoning_effort thinking response_format prompt_cache_key
      default_headers))

    SalixVerifiedKernel.Provider.call(:config, {data, resolve_key(o), resolve_auth_token(o)})
    |> Map.put(:transport, if(is_function(o["transport"], 2), do: o["transport"]))
  end

  @doc """
  The optional `on_tool_delta` streaming callback threaded through `llm_opts`
  (a 1-arg fn receiving `%{index, id, name, fragment}` per tool-call argument
  fragment). Carried alongside provider config so `resolve/1` ignores it.
  """
  @spec tool_delta(map() | keyword() | nil) :: (map() -> any()) | nil
  def tool_delta(opts) when is_list(opts), do: Keyword.get(opts, :on_tool_delta)

  def tool_delta(opts) when is_map(opts),
    do: Map.get(opts, :on_tool_delta) || Map.get(opts, "on_tool_delta")

  def tool_delta(_), do: nil

  @doc """
  The optional `on_reasoning_delta` streaming callback threaded through
  `llm_opts`. The 1-arg callback receives a provider-classified
  `SalixAgent.LLM.ReasoningDelta`: Anthropic `thinking_delta` and
  chat-completions `reasoning_content`/`reasoning` are private raw reasoning;
  Responses-API `response.reasoning_summary_text.delta` is a public summary.
  Carried alongside provider config so `resolve/1` ignores it.
  """
  @spec reasoning_delta(map() | keyword() | nil) ::
          SalixAgent.LLM.on_reasoning_delta() | nil
  def reasoning_delta(opts) when is_list(opts), do: Keyword.get(opts, :on_reasoning_delta)

  def reasoning_delta(opts) when is_map(opts),
    do: Map.get(opts, :on_reasoning_delta) || Map.get(opts, "on_reasoning_delta")

  def reasoning_delta(_), do: nil

  @doc """
  Optional fail-closed observer for the exact encoded blocking request body.

  The callback runs before the HTTP transport and must return `:ok` to permit
  the request. It is kept outside `resolve/1` because it is request-scoped
  behavior, not serializable provider configuration.
  """
  @spec before_send(map() | keyword() | nil) :: (binary() -> term()) | nil
  def before_send(opts) when is_list(opts), do: Keyword.get(opts, :before_send)

  def before_send(opts) when is_map(opts),
    do: Map.get(opts, :before_send) || Map.get(opts, "before_send")

  def before_send(_), do: nil

  @doc """
  Request-scoped Req retry policy for blocking provider calls.

  Existing callers retain transient retries; callers that require one provider
  attempt can explicitly pass `transport_retry: false`.
  """
  @spec transport_retry(map() | keyword() | nil) :: :transient | false
  def transport_retry(opts) when is_list(opts),
    do: Keyword.get(opts, :transport_retry, :transient)

  def transport_retry(opts) when is_map(opts),
    do: Map.get(opts, :transport_retry, Map.get(opts, "transport_retry", :transient))

  def transport_retry(_), do: :transient

  # api_key directly, else api_key_env names the OS variable (willow's
  # APIKey/APIKeyEnv pair — resolveAPIKey in internal/llm/client.go).
  defp resolve_key(o) do
    cond do
      key = o["api_key"] -> key
      var = o["api_key_env"] -> System.get_env(var, "")
      true -> ""
    end
  end

  defp resolve_auth_token(o) do
    cond do
      token = o["auth_token"] -> token
      var = o["auth_token_env"] -> System.get_env(var, "")
      true -> ""
    end
  end

  defp normalize(nil), do: %{}

  defp normalize(overrides) when is_list(overrides) or is_map(overrides) do
    Map.new(overrides, fn {k, v} -> {to_string(k), v} end)
  end
end
