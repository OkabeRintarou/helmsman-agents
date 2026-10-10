defmodule Helmsman.Accounts.SignupGate do
  @moduledoc """
  Decides whether a registration may proceed when the instance already has
  users and the signup mode is `:invite`.
  """

  alias Helmsman.Invitations

  @doc """
  Checks whether a registration with the given `opts` is allowed.

  Allowed when `opts[:invitation_token]` is a valid invitation that is
  either a generic link or bound to `opts[:email]` (the normalized
  registration email, set by `Helmsman.Accounts.register_user/2`). The
  invitation is only checked, not consumed: the user accepts it after
  logging in.
  """
  @spec allow?(keyword()) :: :ok | {:error, :signup_closed}
  def allow?(opts) do
    with token when is_binary(token) <- opts[:invitation_token],
         email when is_binary(email) <- opts[:email],
         :ok <- Invitations.check_signup(token, email) do
      :ok
    else
      _ -> {:error, :signup_closed}
    end
  end
end
