defmodule SalixIM.Ports.TriageFollowUpThreadReader do
  @moduledoc """
  Read-only port used by a due Triage follow-up to inspect its original Slack thread.

  The implementation lives in the Salix composition root so the domain keeps
  provider credentials and HTTP details outside the durable Schedule receiver.
  """

  @callback read(authority :: map(), connect :: map(), target :: map()) ::
              {:ok, map()} | {:error, term()}

  def read(authority, connect, target), do: impl().read(authority, connect, target)

  defp impl do
    Application.get_env(
      :salix_im,
      :triage_follow_up_thread_reader_mod,
      __MODULE__.Unconfigured
    )
  end

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.TriageFollowUpThreadReader

    @impl true
    def read(_authority, _connect, _target),
      do: {:error, :triage_follow_up_thread_reader_not_configured}
  end
end
