defmodule Helmsman.Vault do
  @moduledoc """
  Field encryption (`cloak_ecto`), AES-256-GCM tagged `AES.GCM.V1`.

  The cipher comes from `config :helmsman, Helmsman.Vault, ciphers: ...`: in
  production `config/runtime.exs` builds it from `HELMSMAN_VAULT_KEY`
  (base64 of 32 bytes) and refuses to start without it; dev and test use a
  fixed key from their config files.
  """

  use Cloak.Vault, otp_app: :helmsman
end
