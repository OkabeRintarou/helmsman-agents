defmodule Helmsman.TaskSpecs.Delegation do
  @moduledoc """
  The spec roles of `delegate` (`add-spec-workflow` decision 9;
  `spec-dispatch`「规格委派」), used by `Helmsman.Squads.Delegate` after it
  locked the squad's rows and the task row.

  `check/3` locks the spec row and checks, before the squad checks:
  `revise` / `review` need a version (`no_version`) and an open spec
  (`closed`); `review` also a spec not waiting for approval
  (`pending_approval`), a member who is not the latest version's author
  (`own_version`) and has no `requested` request on it (`review_pending`:
  a request belongs to one trigger only).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Repo
  alias Helmsman.Tasks.Task
  alias Helmsman.TaskSpecs.{Reviews, Spec, Store}

  @roles ~w(draft review revise)

  @doc "The role parameter: nil or one of `draft`, `review`, `revise`."
  @spec role(term()) :: {:ok, String.t() | nil} | {:error, term()}
  def role(nil), do: {:ok, nil}
  def role(role) when is_atom(role), do: role(Atom.to_string(role))
  def role(role) when role in @roles, do: {:ok, role}

  def role(_role),
    do:
      {:error,
       {:spec, :invalid_params, %{field: :spec, message: "must be draft, review or revise"}}}

  @doc "See the module documentation. Returns the locked spec (nil: none, or no role)."
  @spec check(String.t() | nil, Task.t(), String.t()) :: {:ok, Spec.t() | nil} | {:error, term()}
  def check(nil, _task, _to), do: {:ok, nil}

  def check(role, %Task{} = task, to) do
    spec = Store.lock(task)

    with :ok <- check_role(role, spec, task, to), do: {:ok, spec}
  end

  defp check_role("draft", _spec, _task, _to), do: :ok

  defp check_role(_role, nil, _task, _to), do: {:error, {:spec, :no_version}}
  defp check_role(_role, %Spec{latest_version: 0}, _task, _to), do: {:error, {:spec, :no_version}}

  defp check_role(_role, %Spec{status: status}, _task, _to)
       when status in [:finalized, :abandoned],
       do: {:error, {:spec, :closed, status}}

  defp check_role("revise", _spec, _task, _to), do: :ok

  defp check_role("review", %Spec{status: :pending_approval}, _task, _to),
    do: {:error, {:spec, :pending_approval}}

  defp check_role("review", spec, task, to) do
    name = to |> String.trim() |> String.downcase()
    version = Reviews.latest_version(spec)

    case Repo.one(
           from(a in Actor, where: a.workspace_id == ^task.workspace_id and a.name == ^name)
         ) do
      nil ->
        :ok

      %Actor{id: id} when id == version.author_id ->
        {:error, {:spec, :own_version, name}}

      actor ->
        case Reviews.pending_by_reviewer(spec.id, version.id)[actor.id] do
          nil ->
            :ok

          request ->
            requested_by = Repo.get!(Actor, request.requested_by_id).name

            {:error,
             {:spec, :review_pending,
              %{
                reviewer: name,
                request: request.number,
                version: version.number,
                requested_by: requested_by
              }}}
        end
    end
  end

  @doc """
  The trigger fields of the role: `"spec_role"`, and for `review` the
  number the request will get and the version.
  """
  @spec trigger_extra(String.t() | nil, Spec.t() | nil) :: map()
  def trigger_extra(nil, _spec), do: %{}

  def trigger_extra("review", %Spec{} = spec) do
    %{
      "spec_role" => "review",
      "spec_request" => spec.request_seq + 1,
      "spec_version" => spec.latest_version
    }
  end

  def trigger_extra(role, _spec), do: %{"spec_role" => role}

  @doc """
  After the member's run was queued or merged: the review request
  (`review`) by the leader's run; its number, nil for other roles.
  """
  @spec request_member(Scope.t(), Task.t(), Spec.t() | nil, String.t() | nil, Actor.t()) ::
          pos_integer() | nil
  def request_member(scope, task, %Spec{} = spec, "review", actor),
    do: request(scope, task, spec, actor)

  def request_member(_scope, _task, _spec, _role, _actor), do: nil

  @doc "A review request for a person member, without a run."
  @spec request_person(Scope.t(), Task.t(), Spec.t(), Actor.t()) :: map()
  def request_person(scope, task, spec, actor) do
    n = request(scope, task, spec, actor)
    %{result: :requested, reviewer: actor.name, request: n}
  end

  defp request(scope, task, spec, actor) do
    version = Reviews.latest_version(spec)

    {ctx, n} =
      task
      |> Store.context(spec)
      |> Reviews.insert_request(scope, version, actor, nil, scope.run.id)

    Store.persist(ctx)
    n
  end
end
