defmodule Helmsman.GitHub.Workers.SyncRepositories do
  @moduledoc """
  Syncs the repositories an installation can access (design decision 8).

  Reads the installation outside any transaction (unknown or disconnected
  → done), fetches every page of `GET /installation/repositories` with an
  installation token, then applies the list with
  `Helmsman.GitHub.Installations.apply_repositories/3`, which drops it if
  the installation was disconnected meanwhile or a later list was applied.
  Rate limits snooze the job until GitHub's reset time.
  """

  use Oban.Worker,
    queue: :github_sync,
    max_attempts: 10,
    unique: [keys: [:installation_id], states: [:available, :scheduled]]

  alias Helmsman.GitHub.Client
  alias Helmsman.GitHub.Installation
  alias Helmsman.GitHub.Installations
  alias Helmsman.GitHub.Tokens
  alias Helmsman.GitHub.Workers.RefreshInstallation

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"installation_id" => installation_id}}) do
    case Installations.get_by_github_id(installation_id) do
      %Installation{disconnected_at: nil} -> sync(installation_id)
      _unknown_or_disconnected -> :ok
    end
  end

  defp sync(installation_id) do
    fetched_at = DateTime.utc_now()

    with {:ok, %{token: token}} <- Tokens.get(installation_id),
         {:ok, repositories} <-
           Client.paginate("/installation/repositories",
             auth: {:token, token},
             key: "repositories"
           ),
         {:ok, _outcome} <-
           Installations.apply_repositories(installation_id, repositories, fetched_at) do
      :ok
    else
      error -> handle_error(error, installation_id)
    end
  end

  @doc false
  @spec handle_error({:error, term()}, integer()) ::
          :ok | {:snooze, pos_integer()} | {:error, term()}
  def handle_error({:error, {:rate_limited, retry_at}}, _installation_id),
    do: {:snooze, max(DateTime.diff(retry_at, DateTime.utc_now()), 1)}

  # No token for the installation: GitHub no longer knows it, so let a
  # refresh find out and disconnect it.
  def handle_error({:error, :not_found}, installation_id) do
    {:ok, _job} = Oban.insert(RefreshInstallation.new(%{installation_id: installation_id}))
    :ok
  end

  def handle_error({:error, _reason} = error, _installation_id), do: error
end
