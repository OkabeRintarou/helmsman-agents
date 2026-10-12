defmodule Helmsman.GitHub.Workers.HandleWebhook do
  @moduledoc """
  Handles a verified webhook delivery (design decision 10).

  Installation and repository events are only wake-up signals: they
  enqueue a refresh of the installation or a repository sync, and the
  payload's values are never applied. Pull request and check events go to
  `Helmsman.GitHub.Webhooks.PullRequests.handle/2`. Events of installations
  that are not linked to a workspace, or disconnected, are ignored, as are
  other events.
  """

  use Oban.Worker, queue: :github, max_attempts: 20

  alias Helmsman.GitHub.Installation
  alias Helmsman.GitHub.Installations
  alias Helmsman.GitHub.Webhooks.PullRequests
  alias Helmsman.GitHub.Workers.RefreshInstallation
  alias Helmsman.GitHub.Workers.SyncRepositories

  @pull_request_events ~w(pull_request check_suite check_run status)
  @sync_events ~w(installation_repositories repository)
  # `installation` actions after which the repository list may have changed.
  @resync_actions ~w(new_permissions_accepted unsuspend)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event" => event, "payload" => payload}}) do
    with true <- handled?(event),
         %Installation{disconnected_at: nil} = installation <- installation(payload) do
      route(event, payload, installation.installation_id)
    else
      _ignored -> :ok
    end
  end

  defp handled?(event),
    do: event == "installation" or event in @sync_events or event in @pull_request_events

  defp installation(%{"installation" => %{"id" => id}}) when is_integer(id),
    do: Installations.get_by_github_id(id)

  defp installation(_payload), do: nil

  defp route("installation", %{"action" => "created"}, _installation_id), do: :ok

  defp route("installation", payload, installation_id) do
    {:ok, _job} = Oban.insert(RefreshInstallation.new(%{installation_id: installation_id}))

    if payload["action"] in @resync_actions, do: enqueue_sync(installation_id)
    :ok
  end

  defp route(event, _payload, installation_id) when event in @sync_events do
    enqueue_sync(installation_id)
    :ok
  end

  defp route(event, payload, _installation_id) when event in @pull_request_events,
    do: PullRequests.handle(event, payload)

  defp enqueue_sync(installation_id) do
    {:ok, _job} = Oban.insert(SyncRepositories.new(%{installation_id: installation_id}))
  end
end
