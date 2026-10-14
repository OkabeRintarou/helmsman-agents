defmodule Helmsman.Feedback.Replies do
  @moduledoc "Stable reply references and current target summaries (`add-feedback-replies`)."
  import Ecto.Query
  alias Ecto.Changeset
  alias Helmsman.Feedback.{Entry, Id}
  alias Helmsman.Repo
  alias Helmsman.Tasks.Task

  @doc "Resolves a same-task target under the task write lock."
  @spec resolve(Task.t(), map()) :: {:ok, map()} | {:error, Changeset.t()}
  def resolve(task, input) do
    case input[:reply_to] do
      nil ->
        {:ok, input}

      id ->
        with {:ok, ident, seq} <- Id.parse(id),
             true <- ident == task.ident,
             %Entry{} = target <- current(task.id, seq) do
          {:ok,
           Map.merge(input, %{
             reply_to_seq: seq,
             reply_root_seq: target.reply_root_seq || target.thread_seq
           })}
        else
          _ -> {:error, error("must reference existing feedback in this task")}
        end
    end
  end

  @doc "Current version of the physical target sequence, restricted to its task."
  @spec current(pos_integer(), pos_integer()) :: Entry.t() | nil
  def current(task_id, seq) do
    Repo.one(
      from original in Entry,
        join: current in Entry,
        on:
          current.task_id == original.task_id and current.thread_seq == original.thread_seq and
            current.status == :active,
        where: original.task_id == ^task_id and original.seq == ^seq,
        select: current
    )
  end

  @doc "One batched query for all current targets, including their authors."
  @spec targets([Entry.t()], String.t()) :: map()
  def targets(entries, ident) do
    refs =
      entries
      |> Enum.filter(& &1.reply_to_seq)
      |> Enum.map(&{&1.task_id, &1.reply_to_seq})
      |> Enum.uniq()

    if refs == [] do
      %{}
    else
      task_ids = Enum.map(refs, &elem(&1, 0)) |> Enum.uniq()
      seqs = Enum.map(refs, &elem(&1, 1)) |> Enum.uniq()

      Repo.all(
        from original in Entry,
          join: current in Entry,
          on:
            current.task_id == original.task_id and current.thread_seq == original.thread_seq and
              current.status == :active,
          join: author in assoc(current, :author),
          where: original.task_id in ^task_ids and original.seq in ^seqs,
          select:
            {original.task_id, original.seq, original.status, current.seq, current.content,
             author.name, author.kind}
      )
      |> Map.new(fn {task, original, status, seq, content, name, kind} ->
        {{task, original},
         %{
           id: Id.build(ident, seq),
           seq: seq,
           author: %{name: name, kind: Atom.to_string(kind)},
           summary: summary(content),
           status: Atom.to_string(status)
         }}
      end)
    end
  end

  defp summary(content),
    do: content |> String.split(~r/\r?\n/, parts: 2) |> hd() |> String.slice(0, 160)

  @doc "Reply label for the feedback lists and quotes sent to agents."
  @spec label(map()) :: String.t()
  def label(%{target: %{seq: seq, author: %{name: name}}}), do: "回复 ##{seq} @#{name}"
  def label(_entry), do: ""

  @doc false
  def error(message), do: Changeset.add_error(Changeset.change(%Entry{}), :reply_to, message)
end
