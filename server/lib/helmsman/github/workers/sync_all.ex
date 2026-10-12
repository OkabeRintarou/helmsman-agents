defmodule Helmsman.GitHub.Workers.SyncAll do
  @moduledoc "Daily: enqueues a repository sync for every connected installation."

  use Oban.Worker, queue: :github_sync, max_attempts: 3

  alias Helmsman.GitHub.Installations
  alias Helmsman.GitHub.Workers.SyncRepositories

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    for installation <- Installations.list_connected() do
      {:ok, _job} =
        Oban.insert(SyncRepositories.new(%{installation_id: installation.installation_id}))
    end

    :ok
  end
end
