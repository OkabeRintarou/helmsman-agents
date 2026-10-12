defmodule Helmsman.GitHub.Webhooks.PullRequests do
  @moduledoc """
  Entry point for pull request and check events (`pull_request`,
  `check_suite`, `check_run`, `status`). Implemented by
  `add-pr-reconcile-merge`; for now the events are only logged.
  """

  require Logger

  @doc "Handles a pull request or check event."
  @spec handle(String.t(), map()) :: :ok
  def handle(event, payload) do
    Logger.debug("GitHub #{event} event (#{payload["action"] || "no action"}) not handled yet")
    :ok
  end
end
