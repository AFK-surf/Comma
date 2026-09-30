defmodule KernelAgent.LLM do
  @moduledoc """
  The model call. The kernel builds the request (`provider_dispatch`), the
  endpoint, and parses the response or classifies the error. This module only
  moves bytes over HTTP.

  Two backends:

    * `{:script, pid}`: `KernelAgent.LLM.Script`, which receives the neutral
      message list and returns scripted responses. For tests.
    * `{:http, config}`: a provider over HTTP. `config` holds `"protocol"`
      (`"anthropic"` or `"chat"`), `"model"`, `"base_url"`, `"api_key"`, and
      optionally `"max_tokens"`.
  """

  alias SalixVerifiedKernel.Provider

  @doc "The kernel's request-build arguments for this backend: `{protocol, cfg}`."
  def protocol({:script, _pid}), do: {:neutral, %{}}

  def protocol({:http, config}) do
    overrides = Map.drop(config, ["api_key"])
    {config["protocol"], Provider.call(:config, {overrides, config["api_key"], ""})}
  end

  @doc """
  Sends the request the kernel built and returns the kernel's response term:
  `{:assistant, ...}`, `{:final, ...}`, or `{:error, meta}`.
  """
  def complete({:script, pid}, messages), do: KernelAgent.LLM.Script.next(pid, messages)

  def complete({:http, config} = llm, body) when is_binary(body) do
    {protocol, cfg} = protocol(llm)
    {url, headers} = Provider.call(:endpoint, {protocol, cfg, "complete"})

    headers =
      for {k, v} <- headers, String.downcase(k) != "content-type", do: {~c"#{k}", ~c"#{v}"}

    request = {~c"#{url}", headers, ~c"application/json", body}
    options = [timeout: Map.get(config, "timeout_ms", 600_000), ssl: ssl_options()]

    case :httpc.request(:post, request, options, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, response}} ->
        Provider.call(
          :complete,
          {protocol, Provider.call(:normalize, response), cfg.model, false}
        )

      {:ok, {{_, status, _}, _headers, response}} ->
        Provider.call(:http_error, {protocol, status, response})

      {:error, reason} ->
        Provider.call(:transport_error, {protocol, inspect(reason)})
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end

defmodule KernelAgent.LLM.Script do
  @moduledoc """
  A scripted model. Each step is a response term, or a function from the
  neutral request messages to one. An exhausted script ends the turn.
  """
  use Agent

  def start_link(steps), do: Agent.start_link(fn -> %{steps: steps, requests: []} end)

  def push(pid, steps), do: Agent.update(pid, &%{&1 | steps: &1.steps ++ steps})

  @doc "Every request the model saw, oldest first."
  def requests(pid), do: Agent.get(pid, &Enum.reverse(&1.requests))

  @doc "The next response. A function step runs in the caller's process."
  def next(pid, messages) do
    step =
      Agent.get_and_update(pid, fn %{steps: steps, requests: requests} = state ->
        {step, rest} =
          case steps do
            [] -> {end_turn(), []}
            [step | rest] -> {step, rest}
          end

        {step, %{state | steps: rest, requests: [messages | requests]}}
      end)

    if is_function(step, 1), do: step.(messages), else: step
  end

  @doc "`end_turn` with outcome `done`, optionally carrying a reply."
  def end_turn(reply \\ nil) do
    args = if reply, do: %{"outcome" => "done", "reply" => reply}, else: %{"outcome" => "done"}

    {:assistant, "",
     [%{id: "call-#{System.unique_integer([:positive])}", name: "end_turn", args: args}]}
  end

  @doc "One `call` tool invocation."
  def call(tool, params) do
    {:assistant, "",
     [
       %{
         id: "call-#{System.unique_integer([:positive])}",
         name: "call",
         args: %{"tool" => tool, "params" => params}
       }
     ]}
  end
end
