defmodule Helmsman.Accounts.SignupGate do
  @moduledoc """
  Decides whether a registration may proceed when the instance already has
  users and the signup mode is `:invite`.
  """

  @doc """
  Checks whether a registration with the given `opts` is allowed.

  This is the extension point for invitation-based signup: for now it always
  returns `{:error, :signup_closed}`. The invitations feature replaces it with
  a check of `opts[:invitation_token]` (validate only; the invitation is
  consumed when the user accepts it after logging in).
  """
  @spec allow?(keyword()) :: :ok | {:error, :signup_closed}
  def allow?(_opts), do: {:error, :signup_closed}
end
