defmodule Helmsman.Runtimes do
  @moduledoc "Owner-scoped runtime discovery and workspace administration."
  import Ecto.Query
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Daemons.{Daemon, Runtime}
  alias Helmsman.{Events, Policy, Repo, Runs, Workspaces}
  alias Helmsman.Runs.Run

  def list(scope, opts \\ []) do
    all = Keyword.get(opts, :all, false)

    with :ok <- Policy.authorize(scope, if(all, do: :list_all_runtimes, else: :manage_runtimes)) do
      query =
        from r in Runtime,
          join: d in Daemon,
          on: r.daemon_id == d.id,
          where: r.workspace_id == ^scope.workspace.id,
          order_by: [d.name, r.provider],
          select: {r, d}

      query = if all, do: query, else: where(query, [r, d], d.user_id == ^scope.user.id)
      {:ok, Enum.map(Repo.all(query), &view/1)}
    end
  end

  def list_bindable(scope, provider \\ nil) do
    with :ok <- Policy.authorize(scope, :manage_runtimes) do
      query =
        from r in Runtime,
          join: d in Daemon,
          on: r.daemon_id == d.id,
          where:
            r.workspace_id == ^scope.workspace.id and d.user_id == ^scope.user.id and
              is_nil(r.disabled_at),
          select: {r, d}

      query = if provider, do: where(query, [r], r.provider == ^to_string(provider)), else: query
      {:ok, Enum.map(Repo.all(query), &view/1)}
    end
  end

  def disable(scope, id), do: set_disabled(scope, id, true)
  def enable(scope, id), do: set_disabled(scope, id, false)

  defp set_disabled(scope, id, disabled) do
    Workspaces.write_transaction(scope, :manage_runtimes, nil, fn scope ->
      row =
        Repo.one(
          from r in Runtime,
            join: d in Daemon,
            on: d.id == r.daemon_id,
            where: r.id == ^id and r.workspace_id == ^scope.workspace.id,
            lock: fragment("FOR UPDATE OF ?", r),
            select: {r, d.user_id}
        )

      case row do
        nil ->
          {:error, :not_found}

        {runtime, user_id} ->
          update_disabled(scope, runtime, user_id, disabled)
      end
    end)
  end

  defp update_disabled(scope, runtime, user_id, disabled) do
    with :ok <- Policy.authorize(scope, :disable_runtime, %{user_id: user_id}),
         {:ok, runtime} <-
           runtime
           |> Ecto.Changeset.change(disabled_at: if(disabled, do: DateTime.utc_now(:second)))
           |> Repo.update() do
      # Lock order: runtime row, runs (designs/01 §4). A disabled runtime is
      # never claimed from: its queued runs would wait for ever.
      if disabled,
        do: Runs.cancel_pending(from(r in Run, where: r.runtime_id == ^runtime.id), :obsolete)

      Events.after_commit(Events.topic(:workspace, runtime.workspace_id), {:runtimes_changed})
      Events.after_commit(Events.topic(:daemon, runtime.daemon_id), {:daemon_config_changed})
      {:ok, runtime}
    end
  end

  defp view({runtime, daemon}) do
    user = Repo.get!(Helmsman.Accounts.User, daemon.user_id)

    agents =
      Repo.all(
        from p in AgentProfile,
          join: a in Actor,
          on: a.id == p.actor_id,
          where: p.runtime_id == ^runtime.id,
          order_by: a.name,
          select: a.name
      )

    runtime
    |> Map.take(~w(id provider cli_version models efforts status unavailable_reason)a)
    |> Map.merge(%{
      disabled: not is_nil(runtime.disabled_at),
      agents: agents,
      daemon:
        Map.take(daemon, ~w(id name os arch version)a)
        |> Map.put(:user, %{id: user.id, name: user.display_name})
    })
  end
end
