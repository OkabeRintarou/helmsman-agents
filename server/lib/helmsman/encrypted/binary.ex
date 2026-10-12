defmodule Helmsman.Encrypted.Binary do
  @moduledoc "An Ecto type for binaries stored encrypted with `Helmsman.Vault`."

  use Cloak.Ecto.Binary, vault: Helmsman.Vault
end
