defmodule SalixIM.TestSupport.BanditServer do
  @moduledoc false

  @first_port 20_000
  @last_port 39_999
  @port_state_key {__MODULE__, :next_port}

  # Req pools connections by destination. Reusing a port after a per-test
  # Bandit exits can route a later request through that stale local pool.
  # Keep every mock destination unique for the lifetime of the test BEAM.
  def start!(spec_fun) when is_function(spec_fun, 1) do
    port = next_port!()

    {Bandit, opts} = spec_fun.(port)
    # Bind the same address used by test requests. On macOS a wildcard bind can
    # coexist with another listener on loopback and send requests to that daemon.
    spec = {Bandit, Keyword.put(opts, :ip, {127, 0, 0, 1})}

    case ExUnit.Callbacks.start_supervised(spec, id: {:bandit, port}) do
      {:ok, _pid} ->
        port

      {:error, {{:shutdown, {:failed_to_start_child, :listener, :eaddrinuse}}, _child}} ->
        # An unrelated local daemon may hold one port inside the range
        # (observed: cloudflared listening on 20307). Skip it and keep
        # allocating; the counter never reuses the skipped port.
        start!(spec_fun)

      {:error, reason} ->
        raise "could not bind test Bandit on port #{port}: #{inspect(reason)}"
    end
  end

  defp next_port! do
    lock_id = {@port_state_key, self()}

    case :global.trans(lock_id, fn ->
           port = :persistent_term.get(@port_state_key, @first_port)

           if port > @last_port do
             raise "test Bandit port range #{@first_port}..#{@last_port} exhausted"
           end

           :persistent_term.put(@port_state_key, port + 1)
           port
         end) do
      :aborted -> raise "test Bandit port allocation lock aborted"
      port -> port
    end
  end
end
