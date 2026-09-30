defmodule SalixMeet.Ports.PersonalPreparation do
  @moduledoc false

  @callback roster(map()) :: {:ok, [String.t()]} | {:error, term()}
  @callback expand_groups(map(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  @callback recipients(map(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  @callback current_recipients(map(), [map()]) :: {:ok, [map()]} | {:error, term()}
  @callback authorize_report(map(), map(), [String.t()]) :: :ok | {:error, term()}
  @callback open_dm(map(), map()) :: {:ok, String.t()} | {:error, term()}

  def roster(plan), do: impl().roster(plan)
  def expand_groups(plan, emails), do: impl().expand_groups(plan, emails)
  def recipients(plan, emails), do: impl().recipients(plan, emails)
  def current_recipients(plan, pending), do: impl().current_recipients(plan, pending)

  def authorize_report(plan, recipient, labels),
    do: impl().authorize_report(plan, recipient, labels)

  def open_dm(plan, recipient), do: impl().open_dm(plan, recipient)

  defp impl, do: Application.get_env(:salix_meet, :personal_preparation_mod, __MODULE__.None)

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.PersonalPreparation

    def roster(_plan), do: {:ok, []}
    def expand_groups(_plan, _emails), do: {:ok, []}
    def recipients(_plan, _emails), do: {:ok, []}
    def current_recipients(_plan, _pending), do: {:ok, []}

    def authorize_report(_plan, _recipient, _labels),
      do: {:error, :personal_preparation_not_configured}

    def open_dm(_plan, _recipient), do: {:error, :personal_preparation_not_configured}
  end
end
