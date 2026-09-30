defmodule Salix.Control.SignalRegistration do
  @moduledoc """
  Operator registration of a Signal number as a new primary device
  (docs/messaging-voice.md), for the Salix dashboard page `/dash/signal/register`.

  The flow follows the verification session of a captcha-only client
  (CRS-02 §2.7), then registers (CRS-02 §3):

  1. `start/2` checks the number, environment and scope, and creates a
     verification session. The service asks for a captcha.
  2. `submit_captcha/3` sends the solved captcha from the registration
     captcha page of the environment (`captcha_page/1`).
  3. `request_code/3` asks for a code by SMS or voice call.
  4. `submit_code/3` sends the code.
  5. `register/2` registers the verified number and starts the account's
     owner process, so the account can serve at once.

  Each step returns the updated `Flow` with the session state the service
  returned. A failed step returns `{:error, reason, flow}`; `message/1`
  turns the reason into a short operator instruction.

  One number has at most one account per environment that Comma works on.
  An `active` account refuses a new registration: registering again would
  sign out its running device (CRS-02 §3.5). A `registering` account left
  by a failed registration is resumed with its stored keys
  (`SalixSignal.Accounts.resume_registration/4`) instead of a second
  account for the number.

  The verification code, the captcha, the device password and the keys never
  enter a returned value, a log line or telemetry.

  Options of every function: `:transport`, a function from the environment
  to a `SalixSignal.Account.Transport` (default: HTTPS to the environment's
  chat host with a 15-second response bound), and `:start`, the function that
  starts an account's owner (default `SalixSignal.Accounts.ensure_started/1`).
  """

  alias Salix.Control.Tenants
  alias SalixSignal.Account.{Transport, Verification}
  alias SalixSignal.Accounts

  @e164 ~r/\A\+[1-9]\d{6,14}\z/
  @receive_timeout_ms 15_000

  defmodule Flow do
    @moduledoc """
    One registration in progress. `session` is the last verification
    session object (its ID is never shown), `fetched_at` the time it was
    received, `account_id` the stored account that `register/2` completes
    (set when a `registering` account is resumed or a registration
    failed), and `account` the summary after success.
    """
    @enforce_keys [:number, :environment, :scope]
    defstruct number: nil,
              environment: nil,
              scope: nil,
              session: nil,
              fetched_at: nil,
              code_requested?: false,
              account_id: nil,
              resumed?: false,
              account: nil,
              owner: nil

    @type t :: %__MODULE__{
            number: String.t(),
            environment: :production | :staging,
            scope: :platform | {:organization, String.t()},
            session: Verification.Session.t() | nil,
            fetched_at: DateTime.t() | nil,
            code_requested?: boolean(),
            account_id: String.t() | nil,
            resumed?: boolean(),
            account: map() | nil,
            owner: :started | {:error, term()} | nil
          }

    defimpl Inspect do
      def inspect(flow, _opts),
        do: "#Salix.Control.SignalRegistration.Flow<#{flow.number} #{flow.environment}>"
    end
  end

  @type result :: {:ok, Flow.t()} | {:error, term(), Flow.t() | nil}

  @doc "The page where an operator solves the registration captcha."
  @spec captcha_page(:production | :staging) :: String.t()
  defdelegate captcha_page(environment), to: Verification

  @doc """
  Checks the inputs and creates a verification session. `params`:
  `"number"` (E.164), `"environment"` (`"production"` or `"staging"`),
  `"scope"` (`"platform"` or `"organization"`) and, for an organization,
  `"tenant_id"` (the Salix tenant ID, the key that
  `SalixSignal.Settings` matches for a tenant's own number).
  """
  @spec start(map(), keyword()) :: result()
  def start(params, opts \\ []) when is_map(params) do
    with {:ok, number} <- number(params["number"]),
         {:ok, environment} <- environment(params["environment"]),
         {:ok, scope} <- scope(params["scope"], params["tenant_id"]),
         flow = %Flow{number: number, environment: environment, scope: scope},
         {:ok, flow} <- pending(flow) do
      opts
      |> transport(environment)
      |> Verification.create(number)
      |> session_result(flow, :create)
    else
      {:error, reason} -> {:error, reason, nil}
    end
  end

  @doc "Reads the session state again."
  @spec refresh(Flow.t(), keyword()) :: result()
  def refresh(%Flow{session: %{id: id}} = flow, opts \\ []) do
    opts |> transport(flow.environment) |> Verification.fetch(id) |> session_result(flow, :fetch)
  end

  @doc """
  Sends the solved captcha: the `signalcaptcha://` link from the captcha
  page, or the text after that prefix.
  """
  @spec submit_captcha(Flow.t(), String.t(), keyword()) :: result()
  def submit_captcha(%Flow{session: %{id: id}} = flow, captcha, opts \\ []) do
    case String.trim(captcha || "") do
      "" ->
        {:error, :captcha_missing, flow}

      captcha ->
        opts
        |> transport(flow.environment)
        |> Verification.submit_captcha(id, captcha)
        |> session_result(flow, :captcha)
    end
  end

  @doc "Asks the service to send a code by `:sms` or `:voice`."
  @spec request_code(Flow.t(), :sms | :voice, keyword()) :: result()
  def request_code(%Flow{session: %{id: id}} = flow, channel, opts \\ [])
      when channel in [:sms, :voice] do
    case opts |> transport(flow.environment) |> Verification.request_code(id, channel) do
      {:ok, session} -> {:ok, %{put_session(flow, session) | code_requested?: true}}
      error -> session_result(error, flow, :request_code)
    end
  end

  @doc """
  Sends the received code. A wrong code answers `{:error, :wrong_code,
  flow}`; a correct one leaves the session `verified`.
  """
  @spec submit_code(Flow.t(), String.t(), keyword()) :: result()
  def submit_code(%Flow{session: %{id: id}} = flow, code, opts \\ []) do
    case String.replace(code || "", ~r/[\s-]/, "") do
      "" ->
        {:error, :code_missing, flow}

      code ->
        case opts |> transport(flow.environment) |> Verification.submit_code(id, code) do
          {:ok, %{verified: false} = session} ->
            {:error, :wrong_code, put_session(flow, session)}

          result ->
            session_result(result, flow, :code)
        end
    end
  end

  @doc """
  Registers the number with the verified session, or resumes the stored
  `registering` account of the flow with the same keys. On success the
  account is `active`, and its owner process is started on its ring owner
  node; if that start fails, the account keeper starts it on its next pass
  and `flow.owner` holds the error.
  """
  @spec register(Flow.t(), keyword()) :: result()
  def register(flow, opts \\ [])

  def register(%Flow{session: %{id: id, verified: true}} = flow, opts) do
    registration_opts = [
      transport: transport(opts, flow.environment),
      scope: flow.scope,
      environment: flow.environment
    ]

    result =
      if flow.account_id,
        do: Accounts.resume_registration(flow.account_id, {:session, id}, %{}, registration_opts),
        else: Accounts.register(flow.number, {:session, id}, %{}, registration_opts)

    case result do
      {:ok, account_id} ->
        start = Keyword.get(opts, :start, &Accounts.ensure_started/1)

        owner =
          case start.(account_id) do
            {:ok, _pid} -> :started
            {:error, reason} -> {:error, reason}
          end

        account =
          case Accounts.get(account_id) do
            {:ok, summary} -> summary
            {:error, _reason} -> %{id: account_id, state: :active}
          end

        {:ok, %{flow | account_id: account_id, account: account, owner: owner}}

      {:error, reason, account_id} ->
        {:error, reason, %{flow | account_id: account_id || flow.account_id}}
    end
  end

  def register(%Flow{} = flow, _opts), do: {:error, :not_verified, flow}

  # ---- messages ----

  @doc "A short, actionable operator message for an error reason."
  @spec message(term()) :: String.t()
  def message({:bad_request, text}), do: text
  def message(:tenant_not_found), do: "No tenant has this ID. Copy the ID from the tenant page."

  def message({:already_active, _id}),
    do:
      "This number already has an active account in this environment. " <>
        "Registering again would sign it out; use the existing account."

  def message({:pending_scope, scope}),
    do:
      "A failed registration of this number is stored with owner #{scope_label(scope)}. " <>
        "Choose that owner to resume it."

  def message({:invalid_number, normalized}) when is_binary(normalized),
    do: "The service refused the number format. Enter it as #{normalized}."

  def message({:invalid_number, _}),
    do: "The service refused this number. Check the country code and the digits."

  def message(:obsolete_number_format),
    do: "The number format is obsolete for its region. Enter the current format."

  def message(:captcha_missing), do: "Paste the signalcaptcha:// link from the captcha page."

  def message(:invalid_captcha),
    do: "The captcha link is malformed. Copy the full signalcaptcha:// link again."

  def message({:captcha_rejected, _}),
    do: "The captcha was rejected. Solve a new captcha and paste the new link."

  def message(:code_missing), do: "Enter the code from the SMS or voice call."
  def message(:wrong_code), do: "The code is wrong. Check it and enter it again."
  def message(:invalid_code), do: "The code is malformed. Enter only its digits."

  def message({:rate_limited, seconds, _session}), do: message({:rate_limited, seconds})

  def message({:rate_limited, seconds}) when is_integer(seconds),
    do: "Rate limited. Try again in #{wait(seconds)}."

  def message({:rate_limited, _}),
    do: "Rate limited. Wait before you try again, or start over with a new session."

  def message({:transport_unavailable, _}),
    do: "This delivery method is not available for the number now. Try the other method."

  def message({:provider_refused, %{permanent: true}}),
    do: "The SMS and voice provider refused this number permanently. Use another number."

  def message({:provider_refused, _}),
    do:
      "The SMS or voice provider could not send the code. Try again later or use the other method."

  def message({:not_ready, _}),
    do: "The session is not ready for this step. Refresh the session state."

  def message(reason) when reason in [:unknown_session, :invalid_session_id],
    do: "The verification session expired or is unknown. Start over."

  def message(:not_verified), do: "Verify the number with a code before you register it."

  def message(:session_not_verified),
    do: "The service does not accept the session as verified. Start over with a new session."

  def message({:registration_locked, %{time_remaining_ms: ms}}) when is_integer(ms),
    do:
      "The number has a registration lock. Register it again after the lock expires in #{wait(div(ms, 1000))}."

  def message({:registration_locked, _}),
    do: "The number has a registration lock. Register it again after the lock expires."

  def message(:second_factor_required),
    do: "The existing account on this number needs a second factor that Comma cannot give."

  def message(:device_transfer_available),
    do: "The service offers a device transfer for this number. Try again later."

  def message(:invalid_request),
    do: "The service refused the request as invalid. Start over with a new session."

  def message(:client_deprecated),
    do: "The service requires a newer Signal client. Update Comma before you register."

  def message(:kem_unsupported),
    do: "This node cannot make Signal keys: it needs OpenSSL 3.5. Use a production node."

  def message(:storage_key_missing),
    do: "The Signal storage key is missing on this node. Configure the storage key first."

  def message(:not_registering),
    do:
      "The stored registration is no longer pending. Reload the Signal page and check the account."

  def message({:challenge_required, _}),
    do: "The service asks for an abuse challenge. Try again later."

  def message({:unavailable, _}), do: "The Signal service is unavailable. Try again later."
  def message({:transport, _}), do: "The Signal service did not answer in time. Try again."

  def message({:http_error, status}),
    do: "Unexpected service answer (HTTP #{status}). Start over."

  def message(_reason), do: "The step failed. Try again, or start over."

  defp wait(seconds) when seconds < 120, do: "#{seconds} seconds"
  defp wait(seconds) when seconds < 7_200, do: "#{div(seconds + 59, 60)} minutes"
  defp wait(seconds) when seconds < 172_800, do: "#{div(seconds + 3_599, 3_600)} hours"
  defp wait(seconds), do: "#{div(seconds + 86_399, 86_400)} days"

  @doc "The owner label of a scope."
  @spec scope_label(:platform | {:organization, String.t()}) :: String.t()
  def scope_label(:platform), do: "platform"
  def scope_label({:organization, id}), do: "tenant #{id}"

  # ---- inputs ----

  defp number(number) when is_binary(number) do
    number = String.replace(number, ~r/[\s().-]/, "")

    if Regex.match?(@e164, number),
      do: {:ok, number},
      else: {:error, {:bad_request, "Enter the number in E.164 form, such as +15551234567."}}
  end

  defp number(_number), do: number("")

  defp environment("production"), do: {:ok, :production}
  defp environment("staging"), do: {:ok, :staging}
  defp environment(_), do: {:error, {:bad_request, "Choose the production or staging service."}}

  defp scope("platform", _tenant_id), do: {:ok, :platform}

  defp scope("organization", tenant_id) when is_binary(tenant_id) do
    case String.trim(tenant_id) do
      "" ->
        {:error, {:bad_request, "Enter the tenant ID of the organization."}}

      tenant_id ->
        case Tenants.get(tenant_id) do
          {:ok, _tenant} -> {:ok, {:organization, tenant_id}}
          {:error, :not_found} -> {:error, :tenant_not_found}
          {:error, reason} -> {:error, {:unavailable, reason}}
        end
    end
  end

  defp scope("organization", _), do: scope("organization", "")
  defp scope(_, _), do: {:error, {:bad_request, "Choose the platform or an organization."}}

  # The stored accounts of the number in the flow's environment decide
  # between a new registration, a resumed one, and a refusal.
  defp pending(%Flow{} = flow) do
    case Accounts.list_by_number(flow.number) do
      {:ok, accounts} ->
        accounts = Enum.filter(accounts, &(&1.environment == flow.environment))

        cond do
          active = Enum.find(accounts, &(&1.state == :active)) ->
            {:error, {:already_active, active.id}}

          pending = Enum.find(accounts, &(&1.state == :registering)) ->
            if pending.scope == flow.scope,
              do: {:ok, %{flow | account_id: pending.id, resumed?: true}},
              else: {:error, {:pending_scope, pending.scope}}

          true ->
            {:ok, flow}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- results ----

  defp session_result({:ok, session}, flow, _step), do: {:ok, put_session(flow, session)}

  defp session_result({:error, reason}, flow, step) do
    flow =
      case reason do
        {_kind, %Verification.Session{} = session} -> put_session(flow, session)
        {:rate_limited, _seconds, %Verification.Session{} = session} -> put_session(flow, session)
        _ -> flow
      end

    {:error, step_reason(reason, step), flow}
  end

  # A 400 on the captcha step is a malformed captcha; on the code step a
  # malformed code (CRS-02 §2.4, §2.6).
  defp step_reason(:invalid_request, :captcha), do: :invalid_captcha
  defp step_reason(:invalid_request, :code), do: :invalid_code
  defp step_reason(reason, _step), do: reason

  defp put_session(flow, session),
    do: %{flow | session: session, fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)}

  defp transport(opts, environment) do
    case Keyword.get(opts, :transport) do
      nil -> Transport.http(environment, receive_timeout: @receive_timeout_ms)
      fun when is_function(fun, 1) -> fun.(environment)
    end
  end
end
