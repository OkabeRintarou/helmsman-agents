defmodule Helmsman.Backup.Format do
  @moduledoc "The portable v1 snapshot field list and deterministic JSON encoding."
  @fields %{
    "root" =>
      ~w(actors exported_at feedback format links projects saved_filters source task_events tasks version workspace),
    "source" => ~w(app_version host),
    "workspace" => ~w(name slug),
    "actors" => ~w(disabled kind name owner),
    "projects" => ~w(archived_at created_at description key name task_seq updated_at),
    "tasks" =>
      ~w(assignee created_at created_by description epic id kind labels priority project seq status title updated_at),
    "task_events" =>
      ~w(actor assignee_side at auto auto_reason comment commits feedback from n task tests to verified_sha),
    "feedback" =>
      ~w(at author content fallback id kind mentions status superseded_by supersedes thread),
    "links" => ~w(actor at from to type),
    "saved_filters" => ~w(bql name owner)
  }
  def fields, do: @fields
  def collections, do: ~w(actors projects tasks task_events feedback links saved_filters)

  def encode(value), do: value |> encode_iodata() |> IO.iodata_to_binary()
  def decode(json), do: Jason.decode(json)

  def encode_iodata(value) when is_map(value) and not is_struct(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _} -> to_string(key) end)
      |> Enum.map(fn {key, val} -> [Jason.encode!(to_string(key)), ":", encode_iodata(val)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  def encode_iodata(values) when is_list(values),
    do: ["[", Enum.intersperse(Enum.map(values, &encode_iodata/1), ","), "]"]

  def encode_iodata(%DateTime{} = value), do: value |> time() |> Jason.encode!()
  def encode_iodata(value), do: Jason.encode_to_iodata!(value)

  def time(nil), do: nil

  def time(%DateTime{} = value) do
    value
    |> DateTime.shift_zone!("Etc/UTC")
    |> Map.put(:microsecond, {elem(value.microsecond, 0), 6})
    |> DateTime.to_iso8601()
  end
end
