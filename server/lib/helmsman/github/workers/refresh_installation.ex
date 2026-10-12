defmodule Helmsman.GitHub.Workers.RefreshInstallation do
  @moduledoc """
  Reads an installation's current details from GitHub and applies them
  (design decision 10): 404 disconnects it, suspension follows GitHub.
  Results fetched before the last applied one are dropped
  (`Helmsman.GitHub.Installations.apply_refresh/3`).
  """

  use Oban.Worker,
    queue: :github,
    max_attempts: 20,
    unique: [keys: [:installation_id], states: [:available, :scheduled]]

  alias Helmsman.GitHub.Installation
  alias Helmsman.GitHub.Installations

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"installation_id" => installation_id}}) do
    case Installations.get_by_github_id(installation_id) do
      %Installation{disconnected_at: nil} -> refresh(installation_id)
      _unknown_or_disconnected -> :ok
    end
  end

  defp refresh(installation_id) do
    fetched_at = DateTime.utc_now()

    case Installations.fetch_details(installation_id) do
      {:error, {:rate_limited, retry_at}} ->
        {:snooze, max(DateTime.diff(retry_at, DateTime.utc_now()), 1)}

      {:error, _reason} = error ->
        error

      result ->
        with {:ok, _outcome} <- Installations.apply_refresh(installation_id, result, fetched_at),
             do: :ok
    end
  end
end
