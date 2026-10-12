defmodule Helmsman.GitHub.Delivery do
  @moduledoc "A received webhook delivery, kept 7 days to drop duplicates."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:delivery_id, :string, autogenerate: false}
  schema "github_deliveries" do
    field :event, :string
    field :received_at, :utc_datetime
  end
end
