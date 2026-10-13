defmodule Helmsman.Links.Link do
  @moduledoc """
  A directed link between two tasks of one workspace (designs/07 §1):
  `replaces` (`from` takes over `to`) or `depends_on` (`from` waits for
  `to`). The primary key is `(from_task_id, to_task_id, type)`; written
  only by `Helmsman.Links`.
  """

  use Ecto.Schema

  alias Helmsman.Actors.Actor
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Workspace

  @type type :: :replaces | :depends_on
  @type t :: %__MODULE__{}

  @types [:depends_on, :replaces]

  @primary_key false
  schema "task_links" do
    belongs_to :workspace, Workspace
    belongs_to :from_task, Task, primary_key: true
    belongs_to :to_task, Task, primary_key: true
    field :type, Ecto.Enum, values: @types, primary_key: true
    belongs_to :actor, Actor
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end

  @doc "Both link types, in the order links are listed (`depends_on` first)."
  @spec types() :: [type()]
  def types, do: @types
end
