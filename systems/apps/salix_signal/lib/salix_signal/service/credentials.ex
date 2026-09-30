defmodule SalixSignal.Service.Credentials do
  @moduledoc """
  HTTP Basic credentials for the chat service (CRS-01 section 4.1).

  Authenticated requests and the authenticated chat socket send
  `Authorization: Basic base64(username ":" password)`. The username of a
  registered device is `<ACI>.<device id>`, with the ACI as a lowercase
  hyphenated UUID and a device id from 1 to 127. A new registration with a
  phone number uses the E.164 number as the username. The password is the
  device password chosen at registration.
  """

  @enforce_keys [:username, :password]
  defstruct [:username, :password]

  @type t :: %__MODULE__{username: String.t(), password: String.t()}

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @doc "Credentials of a registered device."
  @spec device(String.t(), 1..127, String.t()) :: t()
  def device(aci, device_id, password)
      when is_integer(device_id) and device_id in 1..127 and is_binary(password) do
    unless Regex.match?(@uuid, aci), do: raise(ArgumentError, "ACI must be a lowercase UUID")
    %__MODULE__{username: "#{aci}.#{device_id}", password: password}
  end

  @doc "Credentials for a new registration of the E.164 number `number`."
  @spec registration(String.t(), String.t()) :: t()
  def registration("+" <> _ = number, password) when is_binary(password) do
    %__MODULE__{username: number, password: password}
  end

  @doc "The `Authorization` header value."
  @spec authorization(t()) :: String.t()
  def authorization(%__MODULE__{username: username, password: password}) do
    "Basic " <> Base.encode64(username <> ":" <> password)
  end

  @doc """
  A new random device password: base64 of 16 random bytes without padding,
  22 characters. The server imposes no format (CRS-01 section 4.1, rule 3).
  """
  @spec new_password() :: String.t()
  def new_password, do: Base.encode64(:crypto.strong_rand_bytes(16), padding: false)

  defimpl Inspect do
    def inspect(%{username: username}, _opts),
      do: "#SalixSignal.Service.Credentials<#{username}>"
  end
end
