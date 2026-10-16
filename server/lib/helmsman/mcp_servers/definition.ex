defmodule Helmsman.McpServers.Definition do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Helmsman.McpServers.Entry
  @derive {Inspect, except: [:config]}
  schema "user_mcp_servers" do
    belongs_to :user, Helmsman.Accounts.User
    field :name, :string
    field :config, Helmsman.Encrypted.Map, redact: true
    field :type, :string
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime)
  end

  def changeset(definition, attrs) do
    cs = definition |> cast(attrs, [:name, :config]) |> validate_required([:name, :config])
    name = get_field(cs, :name)
    cs = if Entry.valid_name?(name), do: cs, else: add_error(cs, :name, "invalid server name")

    cs =
      if Map.has_key?(cs.changes, :config) do
        validate_config(cs, definition, name)
      else
        cs
      end

    cs |> unique_constraint(:name, name: :user_mcp_servers_user_id_name_index)
  end

  defp validate_config(cs, definition, name) do
    case Entry.validate(
           %{(name || "server") => get_field(cs, :config)},
           %{definition.name => definition.config},
           8_192
         ) do
      {:ok, values} ->
        cs |> put_change(:config, values[name]) |> put_change(:type, Entry.type(values[name]))

      {:error, errors} ->
        Enum.reduce(errors, cs, fn {path, message}, acc ->
          add_error(acc, :config, "%{path}: %{message}", path: path, message: message)
        end)
    end
  end

  def scrub(cs),
    do: %{
      cs
      | data: %{cs.data | config: nil},
        changes: Map.delete(cs.changes, :config),
        params: cs.params && Map.delete(cs.params, "config")
    }
end
