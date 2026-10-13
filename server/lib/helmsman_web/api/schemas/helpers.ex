defmodule HelmsmanWeb.API.Schemas.Helpers do
  @moduledoc false

  alias OpenApiSpex.Schema

  @doc false
  def nullable(%Schema{} = schema), do: %{schema | nullable: true}

  @doc false
  def string(description \\ nil), do: %Schema{type: :string, description: description}

  @doc false
  def time(description \\ nil),
    do: %Schema{type: :string, format: :"date-time", description: description}

  @doc false
  def strings, do: %Schema{type: :array, items: %Schema{type: :string}}

  @summary_properties %{
    id: %Schema{type: :string, description: "Task ID (e.g. BOS-12)."},
    project_key: %Schema{type: :string},
    title: %Schema{type: :string},
    status: %Schema{
      type: :string,
      enum: ~w(NEW IN_PROGRESS DONE VERIFIED REJECTED CANCELLED)
    },
    priority: %Schema{type: :string},
    labels: %Schema{type: :array, items: %Schema{type: :string}},
    created_by: HelmsmanWeb.API.Schemas.ActorRef,
    assignee: HelmsmanWeb.API.Schemas.ActorRef,
    commits: %Schema{type: :array, items: %Schema{type: :string}},
    feedback_count: %Schema{type: :integer},
    open_question: %Schema{type: :boolean},
    blocked: %Schema{type: :boolean},
    lock_version: %Schema{type: :integer},
    kind: %Schema{type: :string, enum: ["task", "epic"]},
    epic: %Schema{type: :string, nullable: true},
    progress: HelmsmanWeb.API.Schemas.Progress,
    created_at: %Schema{type: :string, format: :"date-time"},
    updated_at: %Schema{type: :string, format: :"date-time"}
  }

  @summary_required [
    :id,
    :project_key,
    :title,
    :status,
    :priority,
    :labels,
    :lock_version,
    :kind,
    :blocked,
    :created_at,
    :updated_at
  ]

  @doc false
  def summary_properties, do: @summary_properties

  @doc false
  def summary_required, do: @summary_required
end
