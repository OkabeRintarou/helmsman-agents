defmodule Helmsman.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  A scope always carries the `user`. Inside a workspace it also carries the
  `workspace`, the user's `role` there and the `actor` the request runs as
  (the user's human identity, or an agent). `via` tells the entry point
  (`:web`, `:mcp`, `:api` or `:run`) and `run` the agent run, if any.

  Domain functions take the scope as their first argument and authorize
  with `Helmsman.Policy`.
  """

  alias Helmsman.Accounts.User
  alias Helmsman.Actors.Actor
  alias Helmsman.Workspaces.{Membership, Workspace}

  @type via :: :web | :mcp | :api | :run

  @type t :: %__MODULE__{
          user: User.t() | nil,
          workspace: Workspace.t() | nil,
          role: Membership.role() | nil,
          actor: Actor.t() | nil,
          via: via() | nil,
          run: term()
        }

  defstruct user: nil, workspace: nil, role: nil, actor: nil, via: nil, run: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  @spec for_user(User.t() | nil) :: t() | nil
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  Puts the workspace, the membership's role and the acting actor in the
  scope.
  """
  @spec put_workspace(t(), Workspace.t(), Membership.t(), Actor.t()) :: t()
  def put_workspace(
        %__MODULE__{} = scope,
        %Workspace{} = workspace,
        %Membership{} = membership,
        %Actor{} = actor
      ) do
    %{scope | workspace: workspace, role: membership.role, actor: actor}
  end
end
