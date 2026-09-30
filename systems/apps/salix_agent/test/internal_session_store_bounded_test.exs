defmodule SalixAgent.InternalSessionStoreBoundedTest do
  use ExUnit.Case, async: false

  alias SalixAgent.InternalSessionStore
  alias SalixStore.{Keys, S3}

  test "bounded session folds stop at the object budget and report an incomplete prefix" do
    agent_id = "bounded-scan-#{System.unique_integer([:positive])}"
    prefix = Keys.agent_internal_runtime_sessions_prefix(agent_id)

    for suffix <- ~w(a b c) do
      assert {:ok, _etag} = S3.put(prefix <> suffix <> ".metadata", suffix, if_none_match: "*")
    end

    :ok = S3.Fake.reset_read_log()

    assert {:ok, :none_loaded, false} =
             InternalSessionStore.reduce_sessions_bounded(
               agent_id,
               :none_loaded,
               fn _session, _acc -> flunk("metadata objects must not be loaded as sessions") end,
               page_size: 1,
               max_objects: 2,
               max_pages: 2
             )

    assert [
             {:list, ^prefix, [max_keys: 1]},
             {:list, ^prefix, second_page_opts}
           ] = S3.Fake.read_log(self())

    assert second_page_opts[:max_keys] == 1
    assert is_binary(second_page_opts[:continuation_token])
  end
end
