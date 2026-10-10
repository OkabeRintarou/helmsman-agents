defmodule Helmsman.Repo do
  use Ecto.Repo,
    otp_app: :helmsman,
    adapter: Ecto.Adapters.Postgres
end
