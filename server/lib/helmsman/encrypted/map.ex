defmodule Helmsman.Encrypted.Map do
  @moduledoc "Encrypted map field."
  use Cloak.Ecto.Map, vault: Helmsman.Vault
end
