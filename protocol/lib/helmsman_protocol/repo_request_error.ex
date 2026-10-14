defmodule HelmsmanProtocol.RepoRequestError do
  @moduledoc """
  Error codes of `repo_browse_result` and `repo_change_result` (protocol 7).

  The daemon is the authority: every code is decided on the machine.
  """
  @codes ~w(disabled busy root_not_allowed invalid_path outside_root missing not_a_repository
    inside_daemon_home invalid_name name_taken already_registered invalid_workspaces
    not_configured config_error)a

  @type t ::
          :disabled
          | :busy
          | :root_not_allowed
          | :invalid_path
          | :outside_root
          | :missing
          | :not_a_repository
          | :inside_daemon_home
          | :invalid_name
          | :name_taken
          | :already_registered
          | :invalid_workspaces
          | :not_configured
          | :config_error

  @spec all() :: [t()]
  def all, do: @codes
end
