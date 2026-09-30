defmodule SystemsObservability.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test

  test "metrics endpoint is internal and predictable" do
    CommaProduct.Telemetry.emit_backlog_sample(:comma_external, 1, 0)
    conn = SystemsObservability.Router.call(conn(:get, "/metrics"), [])
    assert conn.status == 200
    assert conn.resp_body =~ ~s(comma_product_backlog_depth{queue="comma_external"} 1)
  end

  test "other paths do not expose an application surface" do
    assert SystemsObservability.Router.call(conn(:get, "/health"), []).status == 404
  end
end
