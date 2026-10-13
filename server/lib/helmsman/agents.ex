defmodule Helmsman.Agents do
  @moduledoc "Managed and external agents, with owner-only execution settings."
  import Ecto.Query
  alias Helmsman.Accounts.User
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.{AgentProfile, TriggerRule}
  alias Helmsman.Daemons.{Daemon, Runtime}
  alias Helmsman.{Events, Policy, ProviderAccounts, Repo, Runs, Workspaces}
  alias Helmsman.ProviderAccounts.ProviderAccount
  alias Helmsman.Runs.Run

  @execution_fields ~w(provider runtime_id provider_account_id model effort instructions custom_args env extra_mcp_servers capabilities access access_member_ids wake_on_requested)
  @view_fields ~w(provider model effort instructions description access access_member_ids capabilities max_concurrency timeout_minutes idle_timeout_minutes custom_args wake_on_requested inserted_at updated_at)a

  @doc false
  @spec execution_config(pos_integer() | Actor.t()) ::
          {:ok, AgentProfile.t()}
          | {:error, :not_found | :not_managed | :agent_archived | :agent_disabled}
  def execution_config(%Actor{id: id}), do: execution_config(id)

  def execution_config(id) when is_integer(id) and id > 0 do
    case Repo.get(Actor, id) do
      %Actor{kind: :agent} = actor -> execution_profile(actor)
      %Actor{} -> {:error, :not_managed}
      _ -> {:error, :not_found}
    end
  end

  defp execution_profile(actor) do
    profile = Repo.get_by(AgentProfile, actor_id: actor.id, workspace_id: actor.workspace_id)

    with :ok <- managed(profile),
         :ok <- active(profile),
         true <- is_nil(actor.disabled_at) do
      {:ok, profile}
    else
      false -> {:error, :agent_disabled}
      error -> error
    end
  end

  # The views carry `active_runs`, `queued_runs` and `last_run_at`, read for
  # every agent at once (`Helmsman.Runs.counts/1`); the number of queries
  # does not depend on the number of agents.
  def list(scope) do
    with :ok <- Policy.authorize(scope, :view_agents) do
      actors =
        Repo.all(
          from a in Actor,
            where: a.workspace_id == ^scope.workspace.id and a.kind == :agent,
            order_by: a.name
        )

      {:ok, views(actors)}
    end
  end

  def get(scope, name) do
    with :ok <- Policy.authorize(scope, :view_agents),
         %Actor{} = actor <- find_actor(scope, name) do
      {:ok, hd(views([actor]))}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def create(scope, attrs) do
    result =
      Workspaces.write_transaction(scope, :manage_agents, nil, fn scope ->
        actor = %Actor{workspace_id: scope.workspace.id, kind: :agent, owner_id: scope.user.id}

        with {:ok, actor} <-
               actor
               |> Actor.create_changeset(Map.take(string_keys(attrs), ["name"]))
               |> Repo.insert(),
             {:ok, profile} <-
               %AgentProfile{workspace_id: actor.workspace_id, actor_id: actor.id}
               |> AgentProfile.changeset(attrs, actor)
               |> Repo.insert() do
          notify_accounts(actor, nil, profile.provider_account_id)
          notify(actor)
          {:ok, hd(views([actor]))}
        end
      end)

    scrub_result(result)
  end

  def update(scope, name, attrs) do
    action =
      if Enum.any?(Map.keys(attrs), &(to_string(&1) in @execution_fields)),
        do: :configure_agent,
        else: :administer_agent

    mutate(scope, name, action, fn actor, profile ->
      with :ok <- managed(profile),
           :ok <- active(profile),
           {:ok, updated} <- profile |> AgentProfile.changeset(attrs, actor) |> Repo.update() do
        move_pending_runs(actor, profile.runtime_id, updated.runtime_id)
        notify_accounts(actor, profile.provider_account_id, updated.provider_account_id)

        {:ok, actor}
      end
    end)
  end

  # Rebinding moves the agent's queued runs to the new runtime (bound and
  # locked FOR SHARE by the changeset); unbinding cancels them.
  defp move_pending_runs(_actor, same, same), do: :ok

  defp move_pending_runs(actor, _old, nil),
    do: Runs.cancel_pending(from(r in Run, where: r.agent_id == ^actor.id), :obsolete)

  defp move_pending_runs(actor, _old, runtime_id), do: Runs.rebind_pending(actor.id, runtime_id)

  def disable(scope, name), do: set_disabled(scope, name, true)
  def enable(scope, name), do: set_disabled(scope, name, false)

  defp set_disabled(scope, name, disabled) do
    action = if disabled, do: :administer_agent, else: :configure_agent

    mutate(scope, name, action, fn actor, profile ->
      with :ok <- active(profile), do: update_disabled(actor, disabled)
    end)
  end

  defp update_disabled(actor, disabled) do
    with {:ok, actor} <-
           actor
           |> Ecto.Changeset.change(disabled_at: if(disabled, do: DateTime.utc_now(:second)))
           |> Repo.update() do
      if disabled, do: cancel_pending_runs(actor)
      {:ok, actor}
    end
  end

  def archive(scope, name) do
    mutate(scope, name, :administer_agent, fn actor, profile ->
      with :ok <- managed(profile),
           :ok <- active(profile),
           {:ok, _} <-
             profile
             |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
             |> Repo.update(),
           {:ok, actor} <-
             actor
             |> Ecto.Changeset.change(disabled_at: actor.disabled_at || DateTime.utc_now(:second))
             |> Repo.update() do
        cancel_pending_runs(actor)
        notify_accounts(actor, profile.provider_account_id, nil)
        {:ok, actor}
      end
    end)
  end

  # Lock order: actor, profile (`mutate/4`), runs (designs/01 §4). Queued
  # runs are cancelled, claimed and running ones stopped.
  defp cancel_pending_runs(actor) do
    query = from(r in Run, where: r.agent_id == ^actor.id)
    Runs.cancel_pending(query, :obsolete)
    Runs.stop_active(query)
  end

  defp mutate(scope, name, action, fun) do
    Workspaces.write_transaction(scope, :view_agents, nil, fn scope ->
      actor = find_actor(scope, name, "FOR UPDATE")

      with %Actor{} <- actor, :ok <- Policy.authorize(scope, action, actor) do
        profile =
          Repo.one(from p in AgentProfile, where: p.actor_id == ^actor.id, lock: "FOR UPDATE")

        finish_mutation(fun.(actor, profile))
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end)
    |> scrub_result()
  end

  defp finish_mutation({:ok, actor}) do
    notify(actor)
    {:ok, hd(views([actor]))}
  end

  defp finish_mutation(error), do: error

  defp managed(nil), do: {:error, :not_managed}
  defp managed(_), do: :ok

  defp active(%AgentProfile{archived_at: archived}) when not is_nil(archived),
    do: {:error, :agent_archived}

  defp active(_), do: :ok
  defp scrub_result({:error, %Ecto.Changeset{} = cs}), do: {:error, AgentProfile.scrub(cs)}
  defp scrub_result(result), do: result
  defp string_keys(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  defp find_actor(scope, name, row_lock \\ nil) do
    query =
      from a in Actor,
        where: a.workspace_id == ^scope.workspace.id and a.name == ^name and a.kind == :agent

    Repo.one(if row_lock, do: lock(query, "FOR UPDATE"), else: query)
  end

  # Five queries whatever the number of actors: profiles, owners, runtimes,
  # provider accounts and run counts.
  defp views(actors) do
    ids = Enum.map(actors, & &1.id)

    profiles =
      Map.new(Repo.all(from p in AgentProfile, where: p.actor_id in ^ids), &{&1.actor_id, &1})

    owner_ids = actors |> Enum.map(& &1.owner_id) |> Enum.uniq()

    owners =
      Map.new(Repo.all(from u in User, where: u.id in ^owner_ids, select: {u.id, u.display_name}))

    runtimes =
      profiles
      |> Map.values()
      |> Enum.map(& &1.runtime_id)
      |> Enum.reject(&is_nil/1)
      |> runtime_summaries()

    accounts =
      profiles
      |> Map.values()
      |> Enum.map(& &1.provider_account_id)
      |> Enum.reject(&is_nil/1)
      |> account_summaries()

    counts = Runs.counts(ids)

    Enum.map(actors, fn actor ->
      view(actor, profiles[actor.id], owners, {runtimes, accounts}, counts[actor.id] || %{})
    end)
  end

  defp view(actor, profile, owners, {runtimes, accounts}, counts) do
    base = %{
      name: actor.name,
      kind: if(profile, do: "managed", else: "external"),
      workspace_id: actor.workspace_id,
      actor_id: actor.id,
      owner: %{id: actor.owner_id, name: owners[actor.owner_id]},
      disabled: not is_nil(actor.disabled_at),
      archived: (profile && not is_nil(profile.archived_at)) || false,
      active_runs: Map.get(counts, :active, 0),
      queued_runs: Map.get(counts, :queued, 0),
      last_run_at: Map.get(counts, :last_run_at)
    }

    config =
      if profile, do: Map.take(profile, @view_fields), else: Map.new(@view_fields, &{&1, nil})

    Map.merge(base, config)
    |> Map.merge(%{
      runtime: profile && profile.runtime_id && runtimes[profile.runtime_id],
      provider_account:
        profile && profile.provider_account_id && accounts[profile.provider_account_id],
      env_names: names(profile, :env),
      extra_mcp_server_names: names(profile, :extra_mcp_servers)
    })
  end

  defp names(nil, _field), do: nil
  defp names(profile, field), do: (Map.get(profile, field) || %{}) |> Map.keys() |> Enum.sort()

  defp runtime_summaries(ids) do
    Repo.all(
      from r in Runtime,
        join: d in Daemon,
        on: r.daemon_id == d.id,
        where: r.id in ^ids,
        select:
          {r.id,
           %{
             id: r.id,
             daemon_name: d.name,
             provider: r.provider,
             status: r.status,
             disabled: not is_nil(r.disabled_at)
           }}
    )
    |> Map.new()
  end

  # The account summary any reader of the agent sees (decision 14): never
  # the key or the full address.
  defp account_summaries([]), do: %{}

  defp account_summaries(ids) do
    Repo.all(
      from a in ProviderAccount,
        where: a.id in ^ids,
        select: {a.id, %{id: a.id, name: a.name, cli: a.cli, base_url: a.base_url}}
    )
    |> Map.new(fn {id, account} ->
      {id, account |> Map.delete(:base_url) |> Map.put(:host, URI.parse(account.base_url).host)}
    end)
  end

  # The owner's accounts page shows which agents use an account: notified
  # when the agent's binding changes from `old` to `new`.
  defp notify_accounts(_actor, same, same), do: :ok

  defp notify_accounts(actor, _old, _new),
    do: Events.after_commit(ProviderAccounts.topic(actor.owner_id), {:provider_accounts_changed})

  defp notify(actor),
    do: Events.after_commit(Events.topic(:workspace, actor.workspace_id), {:agents_changed})

  def trigger_check(workspace_id, user_id, %Actor{} = actor) do
    profile =
      Repo.one(
        from p in AgentProfile, where: p.actor_id == ^actor.id and p.workspace_id == ^workspace_id
      )

    role =
      Repo.one(
        from m in Helmsman.Workspaces.Membership,
          where: m.workspace_id == ^workspace_id and m.user_id == ^user_id,
          select: m.role
      )

    TriggerRule.check(profile, actor, {user_id, role})
  end

  @doc """
  Whether `user_id`, whose role in the agent's workspace is `role` (nil:
  not a member), may trigger the managed agent `actor` with `profile`,
  ignoring whether the agent is disabled or archived: the rule of
  `trigger_check/3` on rows the caller has read (and locked) itself.
  """
  @spec may_trigger?(AgentProfile.t() | nil, Actor.t(), pos_integer() | nil, atom() | nil) ::
          boolean()
  defdelegate may_trigger?(profile, actor, user_id, role), to: TriggerRule

  @doc """
  What `scope` may do with the agent of `view` (`list/1`, `get/2`):
  `configure` (`:configure_agent`) and `administer` (`:administer_agent`),
  by `Helmsman.Policy.authorize/3` itself on the agent the view describes.
  A view of another workspace's agent, or a run scope, gets neither. Pure.
  """
  @spec permissions(Helmsman.Accounts.Scope.t(), map()) :: %{
          configure: boolean(),
          administer: boolean()
        }
  def permissions(scope, %{actor_id: actor_id, workspace_id: workspace_id, owner: %{id: owner_id}}) do
    actor = %Actor{id: actor_id, kind: :agent, workspace_id: workspace_id, owner_id: owner_id}

    %{
      configure: Policy.authorize(scope, :configure_agent, actor) == :ok,
      administer: Policy.authorize(scope, :administer_agent, actor) == :ok
    }
  end
end
