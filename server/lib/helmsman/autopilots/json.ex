defmodule Helmsman.Autopilots.Json do
  @moduledoc """
  Any JSON value in a `jsonb` column (a webhook payload may be an array or
  a scalar, not only an object): passed through as decoded by Jason.
  """

  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(value), do: {:ok, value}

  @impl true
  def load(value), do: {:ok, value}

  @impl true
  def dump(value), do: {:ok, value}

  @impl true
  def embed_as(_format), do: :dump

  @impl true
  def equal?(a, b), do: a == b
end
