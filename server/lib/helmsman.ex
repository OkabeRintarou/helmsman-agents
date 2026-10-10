defmodule Helmsman do
  use Boundary,
    deps: [],
    exports: [
      Repo,
      Accounts,
      Accounts.Scope,
      Accounts.User,
      Workspaces,
      Workspaces.Workspace,
      Workspaces.Membership,
      Actors,
      Actors.Actor,
      Policy,
      Events,
      Bootstrap
    ]

  @moduledoc """
  Helmsman keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """
end
