# Multi-node tests start BEAM distribution for the whole umbrella VM. Running
# them in the default suite changes Node.self/0 after earlier applications have
# created owner records as :nonode@nohost, so keep them in the dedicated CI
# integration stage.
ExUnit.start(exclude: [:multinode, :live_llm])

Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, :manual)
