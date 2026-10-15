defmodule HelmsmanWeb.LocalRepoRegistration do
  @moduledoc """
  The runtimes page's access to `Helmsman.LocalRepositories.WebRegistration`
  (add-local-repo-web-registration D8, D11): registering and removing local repositories
  on the requester's own machines from the web, and the record of those requests.

  Calls go to `Helmsman.LocalRepositories.WebRegistration` unless
  `config :helmsman, HelmsmanWeb.LocalRepoRegistration, impl: …` names a test double
  with the same functions (the page tests use one to inject error codes and short
  timeouts).

  Results reach the calling process as `{:local_repo_result, request_id, daemon_id,
  outcome}`; the caller checks both ids and calls `forget/1` when it stops waiting.
  """

  @default Helmsman.LocalRepositories.WebRegistration

  @doc "The requester's machines serving the current workspace, with their eligibility."
  def machines(scope), do: impl().machines(scope)

  @doc "Asks the daemon to list candidate repositories: `{:ok, request_id}` or `{:error, code}`."
  def browse(scope, daemon_id), do: impl().browse(scope, daemon_id)

  @doc "Asks the daemon to register a candidate: `{:ok, request_id}` or an error."
  def register(scope, daemon_id, attrs), do: impl().register(scope, daemon_id, attrs)

  @doc "Asks the daemon to remove a local repository: `{:ok, request_id}` or an error."
  def remove(scope, local_repository_id), do: impl().remove(scope, local_repository_id)

  @doc """
  The workspaces (`[%{id, slug, name}]`) where removing local repository
  `local_repository_id` makes it unavailable, for the confirmation dialog.
  """
  def remove_workspaces(scope, local_repository_id),
    do: impl().remove_workspaces(scope, local_repository_id)

  @doc "Stops waiting for `request_id`."
  def forget(request_id), do: impl().forget(request_id)

  @doc "The web requests involving the current workspace (`:mine` or `:all`)."
  def list_changes(scope, view), do: impl().list_changes(scope, view)

  @doc "How long the page waits for a browse result."
  def browse_timeout_ms, do: impl().browse_timeout_ms()

  @doc "How long the page waits for a register / remove result."
  def change_timeout_ms, do: impl().change_timeout_ms()

  defp impl, do: Application.get_env(:helmsman, __MODULE__, [])[:impl] || @default
end
