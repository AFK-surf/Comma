defmodule SalixAgent.TrajectoryEval.JudgeProviders do
  @moduledoc """
  Server-side allowlist of selectable LLM-judge models.

  The judge model is **not** free-typed in the dashboard. A tenant picks a
  provider by NAME from this allowlist; the endpoint and credential are
  resolved server-side and never touch the browser or the tenant's stored
  config. Each entry references its key by `api_key_env` (an OS env var name
  read at call time) or — server config only — a literal `api_key`. This keeps
  provider secrets out of the plaintext per-tenant control record.

  Configured via app env, seeded from `config.exs` and overridable via
  `config.json` (`trajectory_eval.judge_providers`) without a code deploy:

      config :salix_agent,
        trajectory_eval_judge_providers: %{
          "haiku" => %{
            label: "Claude Haiku",
            protocol: "anthropic",
            base_url: "https://api.anthropic.com",
            model: "claude-haiku-4-5-20251001",
            api_key_env: "SALIX_JUDGE_HAIKU_KEY"
          }
        }

  Entry keys and field keys may be atoms (`config.exs`) or strings
  (`config.json`); both are tolerated. An entry whose credential can't be
  resolved yields `{:error, {:no_key, key}}` at `llm_opts/1` so the caller
  skips the judge rather than calling a provider with an empty key (which
  `SalixLlm.ProviderConfig` would turn into a silent 401).
  """

  @field_keys ~w(label protocol base_url model api_key api_key_env max_tokens reasoning_effort)a

  @default_protocol "chat_completions"

  @doc """
  All configured providers as `{key, entry}` (string keys), label-sorted.

  Entries under a key that isn't name-like are dropped rather than crashing the
  page: the allowlist is ops-authored JSON, so a malformed one must degrade to
  "that provider isn't selectable", never to a 500.
  """
  @spec all() :: [{String.t(), map()}]
  def all do
    config()
    |> Enum.flat_map(fn {key, entry} ->
      case name(key) do
        nil -> []
        key -> [{key, normalize(entry)}]
      end
    end)
    |> Enum.sort_by(fn {key, entry} -> entry["label"] || key end)
  end

  @doc "Dropdown options `[{label, key}]` for the dashboard, label-sorted."
  @spec options() :: [{String.t(), String.t()}]
  def options do
    for {key, entry} <- all(), do: {entry["label"] || key, key}
  end

  @doc """
  True when `key` names a configured provider.

  Takes any term: the key reaches here straight from a persisted per-tenant
  JSON value, so a number/map/list must answer `false`, not raise.
  """
  @spec known?(term()) :: boolean()
  def known?(key) do
    case name(key) do
      nil -> false
      key -> Map.has_key?(index(), key)
    end
  end

  @typedoc """
  The effective judge-model selection, resolved from the tenant's stored pick
  and the deployment default. This is THE contract the Runner gates paid calls
  on and the dashboard renders — both call `resolve_selection/2` so they can
  never disagree about which of these states the tenant is in.

    * `nil` — nothing selected anywhere: inherit the template analyze model.
    * `{:ok, key, :tenant | :global}` — a known allowlist key, and whose
      choice it was.
    * `{:invalid, :tenant | :global, value}` — something IS selected but no
      longer resolves (revoked, renamed, or malformed). The runtime skips the
      paid judge; the UI must say so, not claim a default that isn't running.
  """
  @type selection ::
          nil | {:ok, String.t(), :tenant | :global} | {:invalid, :tenant | :global, term()}

  @doc """
  Resolve the effective selection from the tenant's stored value and the
  deployment default (`:salix_agent, :trajectory_eval` `judge_provider`).

  A tenant pick shadows the global default even when the pick is invalid —
  quietly serving the deployment's model against an explicit tenant choice is
  the substitution this contract exists to prevent. `nil` and `""` read as
  "not selected" (the dashboard writes `""` to mean "use the default", and a
  persisted null must not read as a broken pick).
  """
  @spec resolve_selection(term(), term()) :: selection()
  def resolve_selection(tenant_value, global_default) do
    cond do
      selected?(tenant_value) -> validate(tenant_value, :tenant)
      selected?(global_default) -> validate(global_default, :global)
      true -> nil
    end
  end

  defp validate(value, source) do
    if known?(value), do: {:ok, to_string(value), source}, else: {:invalid, source, value}
  end

  defp selected?(nil), do: false
  defp selected?(""), do: false
  defp selected?(_value), do: true

  @doc """
  Resolve a provider key to string-keyed `llm_opts` ready for `LLM.complete`,
  or `{:error, reason}`. The credential is resolved here (never stored): a
  provider whose key can't be resolved returns `{:error, {:no_key, key}}`.
  """
  @spec llm_opts(term()) :: {:ok, map()} | {:error, term()}
  def llm_opts(key) do
    with name when is_binary(name) <- name(key),
         {:ok, entry} <- Map.fetch(index(), name) do
      build_opts(name, entry)
    else
      _ -> {:error, {:unknown_judge_provider, key}}
    end
  end

  # A provider key is a name: only binaries and atoms are one. Anything else
  # (a map, a list, a number — whatever was persisted) has no name and is
  # therefore not a known provider.
  defp name(key) when is_binary(key), do: key
  defp name(key) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
  defp name(_key), do: nil

  defp build_opts(key, entry) do
    case resolve_key(entry) do
      "" ->
        {:error, {:no_key, key}}

      api_key ->
        opts =
          %{
            "model" => to_string(entry["model"] || ""),
            "protocol" => to_string(entry["protocol"] || @default_protocol),
            "base_url" => to_string(entry["base_url"] || ""),
            "api_key" => api_key
          }
          |> put_present("max_tokens", entry["max_tokens"])
          # Reasoning-model cost cap: `SalixLlm.ProviderConfig` normalizes this
          # into the Responses-API `reasoning` param. The judge is a
          # high-frequency, narrow-rubric call — a reasoning model judging at
          # full effort spends latency and money the verdicts don't need, so
          # ops can pin e.g. "low" per allowlist entry. Ignored by protocols
          # that don't take it.
          |> put_present("reasoning_effort", entry["reasoning_effort"])

        {:ok, opts}
    end
  end

  # api_key (literal, server config) wins over api_key_env (OS var name read at
  # call time). Neither resolvable → "" so build_opts fails closed.
  defp resolve_key(entry) do
    cond do
      is_binary(entry["api_key"]) and entry["api_key"] != "" ->
        entry["api_key"]

      is_binary(entry["api_key_env"]) and entry["api_key_env"] != "" ->
        System.get_env(entry["api_key_env"], "")

      true ->
        ""
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp index, do: all() |> Map.new()

  defp normalize(entry) when is_map(entry) do
    Map.new(@field_keys, fn key -> {to_string(key), entry[key] || entry[to_string(key)]} end)
  end

  defp normalize(_entry), do: %{}

  defp config do
    case Application.get_env(:salix_agent, :trajectory_eval_judge_providers, %{}) do
      %{} = providers -> providers
      _ -> %{}
    end
  end
end
