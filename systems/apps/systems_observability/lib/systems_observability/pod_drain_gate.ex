defmodule SystemsObservability.PodDrainGate do
  @moduledoc """
  Rejects new non-health HTTP work after the launcher begins pod drain.

  The lifecycle state remains owned by `Comma.PodLifecycle`; this common plug is
  only a leaf adapter usable by all three HTTP applications without adding a
  compile-time dependency on the launcher.
  """

  import Plug.Conn

  @health_paths ~w(/live /ready /health)

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: path} = conn, _opts) when path in @health_paths,
    do: conn

  def call(conn, _opts) do
    if accepting_requests?() do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, ~s({"error":"pod_draining"}))
      |> halt()
    end
  end

  defp accepting_requests? do
    lifecycle = Module.concat([Comma, PodLifecycle])

    not Code.ensure_loaded?(lifecycle) or
      not function_exported?(lifecycle, :accepting_requests?, 0) or
      apply(lifecycle, :accepting_requests?, [])
  end
end
