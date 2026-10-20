defmodule SalixMeetNative.RpcRequest do
  @moduledoc false

  @enforce_keys [:url, :headers, :body, :user_agent]
  defstruct [:url, :headers, :body, :user_agent, cookie: ""]

  @type t :: %__MODULE__{
          url: String.t(),
          headers: %{String.t() => String.t()},
          body: binary(),
          user_agent: String.t(),
          cookie: String.t()
        }

  @spec from_json(map()) :: {:ok, t()} | :error
  def from_json(%{"url" => url, "bodyB64" => body_b64} = json) when is_binary(url) do
    with {:ok, body} <- Base.decode64(body_b64 || "") do
      {:ok,
       %__MODULE__{
         url: url,
         headers: string_map(json["headers"]),
         body: body,
         user_agent: json["userAgent"] || "",
         cookie: json["cookie"] || ""
       }}
    end
  end

  def from_json(_), do: :error

  defp string_map(%{} = map) do
    for {k, v} <- map, is_binary(k) and is_binary(v), into: %{}, do: {k, v}
  end

  defp string_map(_), do: %{}
end
