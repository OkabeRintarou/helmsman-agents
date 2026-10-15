defmodule Helmsman.Backup.Format do
  @moduledoc "The portable v2 snapshot field list and deterministic JSON encoding."
  @fields %{
    "root" =>
      ~w(actors exported_at feedback format links projects saved_filters source spec_events spec_issue_notes spec_issues spec_review_requests spec_reviews spec_versions specs task_events tasks version workspace),
    "source" => ~w(app_version host),
    "workspace" => ~w(name slug),
    "actors" => ~w(disabled kind name owner),
    "projects" =>
      ~w(archived_at created_at description key name spec_finalize task_seq updated_at),
    "tasks" =>
      ~w(assignee created_at created_by description epic id kind labels priority project seq status title updated_at),
    "task_events" =>
      ~w(actor assignee_side at auto auto_reason comment commits feedback from n task tests to verified_sha),
    "feedback" =>
      ~w(at author content fallback id kind mentions reply_root reply_to status superseded_by supersedes thread),
    "links" => ~w(actor at from to type),
    "saved_filters" => ~w(bql name owner),
    "specs" =>
      ~w(change_id created_at created_by final_version latest_version proposal status task),
    "spec_versions" => ~w(at author files n note task),
    "spec_review_requests" =>
      ~w(at close_reason closed_at n note requested_by review reviewer status task version),
    "spec_reviews" => ~w(at n reviewer summary task verdict version),
    "spec_issues" => ~w(anchor body file line n review severity suggestion task),
    "spec_issue_notes" => ~w(at author body fixed_in_version issue kind n resolution review task),
    "spec_events" => ~w(action actor at data n task version)
  }
  def fields, do: @fields

  def spec_collections,
    do:
      ~w(specs spec_versions spec_review_requests spec_reviews spec_issues spec_issue_notes spec_events)

  def collections(version \\ 2)
  def collections(1), do: ~w(actors projects tasks task_events feedback links saved_filters)
  def collections(2), do: collections(1) ++ spec_collections()

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
