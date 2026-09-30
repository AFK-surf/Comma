Code.require_file("../compare_support.exs", __DIR__)

defmodule MailHarness.Providers do
  def live(config) do
    decide_config = Map.new(config["decide"], fn {k, v} -> {String.to_existing_atom(k), v} end)

    %{
      decide: fn args -> SalixAgent.Decide.Provider.request(args, decide_config) end,
      router: fn messages ->
        Process.put(:mail_wire, [])

        opts =
          Map.merge(config["llm"]["provider_config"], %{
            "model" => config["llm"]["model"],
            "max_tokens" => 1024,
            "reasoning_effort" => "low",
            "transport_retry" => false,
            "transport" => transport()
          })

        result = SalixLlm.Provider.complete(messages, [], opts)
        {result, List.first(Process.get(:mail_wire, [])) || %{}}
      end
    }
  end

  defp transport do
    capture = CompareMail.capture_transport()
    fn url, opts -> capture.(url, Keyword.put(opts, :receive_timeout, 30_000)) end
  end
end
