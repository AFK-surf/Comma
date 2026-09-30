defmodule Mix.Tasks.KernelAgent.Chat do
  @shortdoc "Chat with the local kernel agent"
  @moduledoc """
  Runs the agent on a local directory and reads input lines from stdin.
  Each line is `conversation> text`. Replies print as they arrive.

      KERNEL_AGENT_API_KEY=... mix kernel_agent.chat --root ./agent-data

  Options: `--root` (default `./kernel-agent-data`), `--protocol`
  (`anthropic` or `chat`), `--model`, `--base-url`, `--max-tokens`. The API
  key comes from `KERNEL_AGENT_API_KEY`.
  """
  use Mix.Task

  @switches [
    root: :string,
    protocol: :string,
    model: :string,
    base_url: :string,
    max_tokens: :integer
  ]

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    protocol = opts[:protocol] || "anthropic"
    root = Path.expand(opts[:root] || "kernel-agent-data")

    llm =
      {:http,
       %{
         "protocol" => protocol,
         "model" => opts[:model] || "claude-sonnet-5",
         "base_url" => opts[:base_url] || default_base_url(protocol),
         "max_tokens" => opts[:max_tokens] || 4096,
         "api_key" =>
           System.get_env("KERNEL_AGENT_API_KEY") || Mix.raise("set KERNEL_AGENT_API_KEY")
       }}

    {:ok, agent} = KernelAgent.start_link(root: root, llm: llm)
    Mix.shell().info("root #{root}; type `conversation> message`, or an empty line to quit")
    loop(agent, root, %{})
  end

  defp loop(agent, root, seen) do
    case IO.gets("") do
      line when line in [:eof, "\n"] ->
        :ok

      line ->
        seen =
          case String.split(String.trim(line), ">", parts: 2) do
            [conversation, text] ->
              conversation = String.trim(conversation)
              KernelAgent.send(agent, conversation, String.trim(text))
              :ok = KernelAgent.await_idle(agent)
              print_new(root, conversation, seen)

            _ ->
              Mix.shell().error("expected `conversation> message`")
              seen
          end

        loop(agent, root, seen)
    end
  end

  defp print_new(root, conversation, seen) do
    messages = KernelAgent.messages(root, conversation)
    shown = Map.get(seen, conversation, 0)

    messages
    |> Enum.drop(shown)
    |> Enum.each(&Mix.shell().info("#{conversation} < #{&1["text"]}"))

    Map.put(seen, conversation, length(messages))
  end

  defp default_base_url("anthropic"), do: "https://api.anthropic.com"
  defp default_base_url(_protocol), do: "https://api.openai.com/v1"
end
