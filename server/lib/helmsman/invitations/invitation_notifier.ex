defmodule Helmsman.Invitations.InvitationNotifier do
  @moduledoc """
  Delivers invitation emails.
  """

  import Swoosh.Email

  alias Helmsman.Invitations.Invitation
  alias Helmsman.Mailer

  @doc """
  Delivers the invitation to its bound email address.

  `invitation` must have `workspace` and `invited_by` loaded; `url` is the
  invitation link.
  """
  @spec deliver_invitation(Invitation.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_invitation(%Invitation{email: email} = invitation, url) when is_binary(email) do
    workspace_name = invitation.workspace.name
    inviter = invitation.invited_by.display_name
    expires_at = Calendar.strftime(invitation.expires_at, "%Y-%m-%d %H:%M UTC")

    message =
      new()
      |> to(email)
      |> from(Application.fetch_env!(:helmsman, :mailer_from))
      |> subject("#{inviter} invited you to #{workspace_name} on Helmsman")
      |> text_body("""

      ==============================

      Hi #{email},

      #{inviter} invited you to join the workspace "#{workspace_name}" as #{invitation.role}.

      Accept the invitation by visiting the URL below:

      #{url}

      The link expires at #{expires_at}.

      If you were not expecting this invitation, please ignore this email.

      ==============================
      """)

    with {:ok, _metadata} <- Mailer.deliver(message) do
      {:ok, message}
    end
  end
end
