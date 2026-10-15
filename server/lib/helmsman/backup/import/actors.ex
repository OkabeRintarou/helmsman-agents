defmodule Helmsman.Backup.Import.Actors do
  @moduledoc "Maps portable identities without changing any existing identity."
  import Ecto.Query
  alias Helmsman.Actors.Actor
  alias Helmsman.Backup.Format
  alias Helmsman.Repo

  def map(scope, data, rename) do
    local =
      Repo.all(from(a in Actor, where: a.workspace_id == ^scope.workspace.id))
      |> Map.new(&{String.downcase(&1.name), &1})

    Enum.reduce_while(Enum.with_index(data["actors"]), {:ok, %{}, []}, fn {row, index},
                                                                          {:ok, mapping, report} ->
      name = Map.get(rename, row["name"], row["name"])
      kind = String.to_existing_atom(row["kind"])

      case local[String.downcase(name)] ||
             Enum.find(Map.values(mapping), &(String.downcase(&1.name) == String.downcase(name))) do
        %Actor{kind: ^kind} = actor ->
          {:cont,
           {:ok, Map.put(mapping, row["name"], actor),
            report ++ [%{from: row["name"], to: actor.name, action: "existing"}]}}

        %Actor{} ->
          {:halt,
           {:error,
            {:actor_kind_conflict,
             %{path: "actors[#{index}]", message: "name has another kind; use rename"}}}}

        nil ->
          actor =
            Repo.insert!(%Actor{
              workspace_id: scope.workspace.id,
              name: name,
              kind: kind,
              owner_id: if(kind == :agent, do: scope.user.id),
              disabled_at: if(row["disabled"] or kind == :squad, do: DateTime.utc_now(:second))
            })

          {:cont,
           {:ok, Map.put(mapping, row["name"], actor),
            report ++
              [
                %{
                  from: row["name"],
                  to: actor.name,
                  action: if(kind == :human, do: "unclaimed", else: "created")
                }
              ]}}
      end
    end)
  end

  def normalize(data, mapping) do
    name = fn value -> if value, do: Map.fetch!(mapping, value).name, else: nil end

    data
    |> Map.update!("actors", &Enum.map(&1, fn r -> Map.put(r, "name", name.(r["name"])) end))
    |> Map.update!(
      "tasks",
      &Enum.map(&1, fn r ->
        r |> Map.update!("created_by", name) |> Map.update!("assignee", name)
      end)
    )
    |> Map.update!(
      "task_events",
      &Enum.map(&1, fn r ->
        r
        |> Map.update!("actor", name)
        |> Map.update!("assignee_side", fn values -> Enum.map(values, name) end)
      end)
    )
    |> Map.update!(
      "feedback",
      &Enum.map(&1, fn r ->
        r
        |> Map.update!("author", name)
        |> Map.update!("mentions", fn values -> Enum.map(values, name) end)
      end)
    )
    |> Map.update!("links", &Enum.map(&1, fn r -> Map.update!(r, "actor", name) end))
    |> normalize_specs(name)
  end

  defp normalize_specs(data, name) do
    Enum.reduce(Format.spec_collections(), data, fn collection, data ->
      Map.update!(data, collection, &Enum.map(&1, fn row -> normalize_spec_row(row, name) end))
    end)
  end

  defp normalize_spec_row(row, name) do
    row =
      Enum.reduce(~w(author actor reviewer requested_by created_by), row, fn field, row ->
        if Map.has_key?(row, field), do: Map.update!(row, field, name), else: row
      end)

    row =
      if row["proposal"],
        do: Map.update!(row, "proposal", &Map.update!(&1, "by", name)),
        else: row

    if row["data"] && row["data"]["reviewer"],
      do: Map.update!(row, "data", &Map.update!(&1, "reviewer", name)),
      else: row
  end
end
