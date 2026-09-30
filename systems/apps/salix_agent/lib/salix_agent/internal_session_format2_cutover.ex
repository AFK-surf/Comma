defmodule SalixAgent.InternalSessionFormat2Cutover do
  @moduledoc """
  Historical format-2 completion metadata retained for old backup cleanup.
  The old writer is retired; current conversion is InternalSessionFormat3Cutover.
  """
  alias SalixStore.Repo
  @marker_name "internal_session_format2_v1"
  # Immutable historical release migrations still call this entrypoint.
  # Current readers accept legacy data; retirement neither rewrites it nor
  # asserts the old migration completed by manufacturing a marker.
  def run, do: :ok

  @doc "True once the cutover marker exists; false when absent or unreadable."
  @spec marker_present?() :: boolean()
  def marker_present?, do: marker_status() == :present

  @doc "Marker completion time, for the backup retention clock."
  @spec marker_completed_at() :: {:ok, DateTime.t()} | {:error, term()}
  def marker_completed_at do
    case Repo.query("SELECT completed_at FROM salix_cutover_markers WHERE name = $1", [
           @marker_name
         ]) do
      {:ok, %{rows: [[completed_at]]}} -> {:ok, completed_at}
      {:ok, %{rows: []}} -> {:error, :marker_absent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp marker_status do
    case Repo.query("SELECT 1 FROM salix_cutover_markers WHERE name = $1", [@marker_name]) do
      {:ok, %{rows: [[1]]}} -> :present
      {:ok, %{rows: []}} -> :absent
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end
end
