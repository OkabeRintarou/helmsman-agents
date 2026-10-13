defmodule HelmsmanWeb.API.Schemas.ImportRecord do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "ImportRecord",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        mode: %Schema{type: :string},
        dry_run: %Schema{type: :boolean},
        source: %Schema{type: :string},
        file_sha256: %Schema{type: :string, nullable: true},
        file_name: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string},
        report: %Schema{type: :object},
        errors: %Schema{type: :array, items: %Schema{type: :object}},
        started_at: %Schema{type: :string, nullable: true, format: :"date-time"},
        finished_at: %Schema{type: :string, nullable: true, format: :"date-time"},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :mode,
        :dry_run,
        :source,
        :file_sha256,
        :file_name,
        :status,
        :report,
        :errors,
        :started_at,
        :finished_at,
        :inserted_at,
        :updated_at
      ]
    },
    struct?: false,
    derive?: false
  )
end
