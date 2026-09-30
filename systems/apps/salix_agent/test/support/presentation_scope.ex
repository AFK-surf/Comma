defmodule SalixAgent.TestSupport.PresentationScope do
  def with_identity(scope) do
    {:ok,
     Map.put_new_lazy(scope, "response_identity", fn ->
       "rsp_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
     end)}
  end
end
