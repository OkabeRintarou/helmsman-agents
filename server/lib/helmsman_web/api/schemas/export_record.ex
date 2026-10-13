defmodule HelmsmanWeb.API.Schemas.ExportRecord do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "ExportRecord",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        status: %Schema{type: :string},
        size: %Schema{type: :integer, nullable: true},
        sha256: %Schema{type: :string, nullable: true},
        counts: %Schema{type: :object},
        error: %Schema{type: :string, nullable: true},
        expires_at: %Schema{type: :string, nullable: true, format: :"date-time"},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :status,
        :size,
        :sha256,
        :counts,
        :error,
        :expires_at,
        :inserted_at,
        :updated_at
      ]
    },
    struct?: false,
    derive?: false
  )
end
