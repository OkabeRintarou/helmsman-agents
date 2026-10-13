defmodule Helmsman do
  use Boundary,
    deps: [],
    exports: [
      Repo,
      RateLimit,
      Vault,
      Agents,
      Agents.AgentProfile,
      Daemons,
      Daemons.Daemon,
      Daemons.DeviceCode,
      Daemons.Runtime,
      Daemons.DaemonWorkspace,
      Runtimes,
      ProviderAccounts,
      ProviderAccounts.ProviderAccount,
      Runs,
      Runs.Run,
      Runs.Outcome,
      Runs.RunTokens,
      Dispatch,
      Accounts,
      Accounts.Scope,
      Accounts.User,
      Workspaces,
      Workspaces.Workspace,
      Workspaces.Membership,
      Actors,
      Actors.Actor,
      Invitations,
      Invitations.Invitation,
      Members,
      ApiTokens,
      ApiTokens.ApiToken,
      Projects,
      Projects.Project,
      Tasks,
      Tasks.Task,
      Tasks.Ident,
      Tasks.StateMachine,
      Feedback,
      Feedback.Entry,
      Feedback.Mentions,
      GitHub,
      GitHub.Installation,
      GitHub.Repository,
      Policy,
      Events,
      Presence,
      Bootstrap
    ]

  @moduledoc """
  Helmsman keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """
end
