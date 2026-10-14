defmodule Helmsman.Daemons do
  @moduledoc "Device authorization, daemon credentials and runtime registration."
  import Ecto.Query

  alias Helmsman.Daemons.Daemon
  alias Helmsman.Daemons.DaemonWorkspace
  alias Helmsman.Daemons.Locking
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Events
  alias Helmsman.LocalRepositories
  alias Helmsman.Repo
  alias Helmsman.Tx
  alias Helmsman.Workspaces.Membership
  alias Helmsman.Workspaces.Workspace

  @max_concurrency 32
  @online_threshold_seconds 120

  defdelegate start_device_auth(request), to: Helmsman.Daemons.DeviceAuth
  defdelegate get_device_auth(scope, code), to: Helmsman.Daemons.DeviceAuth
  defdelegate approve_device(scope, code, workspaces), to: Helmsman.Daemons.DeviceAuth
  defdelegate deny_device(scope, code), to: Helmsman.Daemons.DeviceAuth
  defdelegate exchange_device_code(code), to: Helmsman.Daemons.DeviceAuth
  defdelegate locked(id, opts, fun), to: Locking, as: :run

  @doc """
  How long a daemon may stay silent and still count as online: the one
  definition behind `list_own/1` and `Helmsman.Daemons.Workers.MarkOffline`.
  """
  @spec online_threshold_seconds() :: pos_integer()
  def online_threshold_seconds, do: @online_threshold_seconds

  def now do
    case Application.get_env(:helmsman, :daemon_clock) do
      clock when is_function(clock, 0) -> clock.() |> DateTime.truncate(:second)
      _ -> DateTime.utc_now(:second)
    end
  end

  def new_token,
    do: "hmd_" <> Base.encode32(:crypto.strong_rand_bytes(32), case: :lower, padding: false)

  def hash(token), do: :crypto.hash(:sha256, token)

  def authenticate("hmd_" <> suffix = token) when byte_size(suffix) == 52 do
    if Regex.match?(~r/^[a-z2-7]{52}$/, suffix) do
      hashed = hash(token)
      time = now()

      daemon =
        Repo.one(
          from d in Daemon,
            where: is_nil(d.revoked_at),
            where:
              d.token_hash == ^hashed or
                (d.previous_token_hash == ^hashed and d.previous_token_expires_at > ^time)
        )

      if daemon, do: {:ok, daemon}, else: {:error, :unauthorized}
    else
      {:error, :unauthorized}
    end
  end

  def authenticate(_), do: {:error, :unauthorized}

  def authorized(%Daemon{revoked_at: revoked}, _epoch) when not is_nil(revoked),
    do: {:error, :revoked}

  def authorized(%Daemon{auth_epoch: epoch}, epoch), do: :ok
  def authorized(%Daemon{}, _), do: {:error, :reauthorized}
  def authorized(nil, _), do: {:error, :not_found}

  def rotate_token(id, epoch) do
    Tx.run(fn ->
      daemon = Repo.one(from d in Daemon, where: d.id == ^id, lock: "FOR UPDATE")

      with :ok <- authorized(daemon, epoch) do
        token = new_token()

        Repo.update!(
          Ecto.Changeset.change(daemon,
            token_hash: hash(token),
            token_issued_at: now(),
            previous_token_hash: daemon.token_hash,
            previous_token_expires_at: DateTime.add(now(), 86_400)
          )
        )

        {:ok, token}
      end
    end)
  end

  def heartbeat(id, epoch) do
    Tx.run(fn ->
      daemon = Repo.one(from d in Daemon, where: d.id == ^id, lock: "FOR UPDATE")

      with :ok <- authorized(daemon, epoch) do
        touch_last_seen(daemon)
        {:ok, :ok}
      end
    end)
  end

  # Writes `last_seen_at` only when the last write is over 15 seconds old.
  defp touch_last_seen(%Daemon{last_seen_at: nil} = daemon),
    do: Repo.update!(Ecto.Changeset.change(daemon, last_seen_at: now()))

  defp touch_last_seen(daemon) do
    if DateTime.diff(now(), daemon.last_seen_at) > 15,
      do: Repo.update!(Ecto.Changeset.change(daemon, last_seen_at: now())),
      else: daemon
  end

  def revoke(scope, id) do
    locked(id, [], fn daemon, ids ->
      if daemon.user_id == scope.user.id,
        do: revoke_locked(daemon, ids),
        else: {:error, :not_found}
    end)
  end

  def logout(token) do
    with {:ok, authenticated} <- authenticate(token) do
      Locking.hook(:daemon_logout_authenticated)

      locked(authenticated.id, [], &logout_locked(&1, &2, authenticated.auth_epoch, hash(token)))
    end
  end

  defp logout_locked(daemon, ids, epoch, hashed) do
    if same_authorization?(daemon, epoch, hashed),
      do: revoke_locked(daemon, ids),
      else: {:error, :unauthorized}
  end

  # Decision 23: the token still belongs to the locked row's current
  # authorization (current hash, or the previous one within its grace period).
  defp same_authorization?(daemon, epoch, hashed) do
    is_nil(daemon.revoked_at) and daemon.auth_epoch == epoch and
      (daemon.token_hash == hashed or previous_token?(daemon, hashed))
  end

  defp previous_token?(%Daemon{previous_token_expires_at: nil}, _hashed), do: false

  defp previous_token?(daemon, hashed) do
    daemon.previous_token_hash == hashed and
      DateTime.compare(daemon.previous_token_expires_at, now()) == :gt
  end

  defp revoke_locked(daemon, ids) do
    daemon =
      Repo.update!(
        Ecto.Changeset.change(daemon, revoked_at: now(), auth_epoch: daemon.auth_epoch + 1)
      )

    offline(daemon.id, ids)
    Events.after_commit(Events.topic(:daemon, daemon.id), {:daemon_revoked})
    changed(daemon)
    {:ok, daemon}
  end

  def rename(scope, id, name) do
    Tx.run(fn ->
      daemon =
        Repo.one(
          from d in Daemon, where: d.id == ^id and d.user_id == ^scope.user.id, lock: "FOR UPDATE"
        )

      case daemon do
        nil -> {:error, :not_found}
        daemon -> daemon |> name_changeset(name) |> Repo.update() |> notify_changed()
      end
    end)
  end

  defp name_changeset(daemon, name) do
    daemon
    |> Ecto.Changeset.cast(%{name: name}, [:name])
    |> Ecto.Changeset.update_change(:name, &trim_name/1)
    |> Ecto.Changeset.validate_required([:name])
    |> Ecto.Changeset.validate_length(:name, min: 1, max: 64)
    |> Ecto.Changeset.check_constraint(:name, name: :daemons_name_length)
  end

  # `cast` turns a blank name into a nil change, which must reach validate_required.
  defp trim_name(name) when is_binary(name), do: String.trim(name)
  defp trim_name(name), do: name

  defp notify_changed({:ok, daemon} = result) do
    changed(daemon)
    result
  end

  defp notify_changed(error), do: error

  @doc """
  The name of a daemon created at its first login: the reported host name,
  trimmed and cut to 64 characters; `"daemon"` when it is empty.
  """
  @spec initial_name(term()) :: String.t()
  def initial_name(name) when is_binary(name) do
    case name |> String.trim() |> String.slice(0, 64) do
      "" -> "daemon"
      name -> name
    end
  end

  def initial_name(_name), do: "daemon"

  def set_workspaces(scope, id, ids) when is_list(ids) do
    ids = Enum.uniq(ids)

    locked(id, [workspace_ids: ids, members: true], fn daemon, locked_ids ->
      with true <- daemon.user_id == scope.user.id,
           :ok <- authorized(daemon, daemon.auth_epoch),
           :ok <- member_of_all(daemon.user_id, ids) do
        replace_workspaces(daemon, ids, locked_ids)
        Events.after_commit(Events.topic(:daemon, id), {:daemon_config_changed})
        changed(daemon)
        {:ok, daemon}
      else
        false -> {:error, :not_found}
        error -> error
      end
    end)
  end

  @doc """
  Device approval (decision 8): `ids` is not empty and the user is a member
  or above of each.
  """
  def valid_workspaces(_user_id, []), do: {:error, {:invalid_workspaces, []}}
  def valid_workspaces(user_id, ids), do: member_of_all(user_id, ids)

  # `set_workspaces` (decision 13) may clear the list: the daemon then
  # serves no workspace and all its runtimes go offline.
  defp member_of_all(user_id, ids) do
    case ids -- member_workspace_ids(user_id, ids) do
      [] -> :ok
      invalid -> {:error, {:invalid_workspaces, invalid}}
    end
  end

  def member_workspace_ids(user_id, ids),
    do:
      Repo.all(
        from m in Membership,
          where:
            m.user_id == ^user_id and m.workspace_id in ^ids and
              m.role in [:member, :admin, :owner],
          select: m.workspace_id
      )

  def replace_workspaces(daemon, ids, locked_ids) do
    Repo.delete_all(from w in DaemonWorkspace, where: w.daemon_id == ^daemon.id)

    Repo.insert_all(
      DaemonWorkspace,
      Enum.map(ids, &%{daemon_id: daemon.id, workspace_id: &1, inserted_at: now()})
    )

    offline(daemon.id, locked_ids -- ids)
  end

  @doc """
  The number of daemons online on the instance: not revoked and seen
  within `online_threshold_seconds/0` (the metric `helmsman.daemons.online.count`).
  """
  @spec count_online() :: non_neg_integer()
  def count_online do
    cutoff = DateTime.add(now(), -@online_threshold_seconds)

    Repo.aggregate(
      from(d in Daemon, where: is_nil(d.revoked_at) and d.last_seen_at > ^cutoff),
      :count
    )
  end

  # `online`: not revoked and seen within `online_threshold_seconds/0`.
  def list_own(scope) do
    cutoff = DateTime.add(now(), -@online_threshold_seconds)

    Repo.all(
      from d in Daemon,
        where: d.user_id == ^scope.user.id,
        order_by: [desc_nulls_last: d.last_seen_at, desc: d.id]
    )
    |> Enum.map(fn d ->
      workspaces =
        Repo.all(
          from w in Workspace,
            join: dw in DaemonWorkspace,
            on: dw.workspace_id == w.id,
            where: dw.daemon_id == ^d.id,
            select: %{id: w.id, slug: w.slug, name: w.name}
        )

      Map.take(d, ~w(id name os arch version max_concurrency last_seen_at)a)
      |> Map.merge(%{
        revoked: not is_nil(d.revoked_at),
        online: online?(d, cutoff),
        workspaces: workspaces
      })
    end)
  end

  defp online?(%Daemon{revoked_at: nil, last_seen_at: %DateTime{} = seen}, cutoff),
    do: DateTime.after?(seen, cutoff)

  defp online?(_daemon, _cutoff), do: false

  def register(id, epoch, report) do
    locked(id, [members: true], fn daemon, ids ->
      with :ok <- authorized(daemon, epoch),
           :ok <- check_concurrency(report) do
        daemon = Repo.update!(Ecto.Changeset.change(daemon, report_attrs(report)))
        valid = valid_served(daemon)
        before = runtime_states(id)

        offline(id, ids -- valid, notify: false)
        upsert_runtimes(id, valid, report.clis)
        LocalRepositories.register_locked(id, valid, local_repositories(report))

        # One {:runtimes_changed} per workspace whose runtimes changed,
        # including the ones the daemon no longer serves.
        after_states = runtime_states(id)

        ids
        |> Enum.filter(&(Map.get(before, &1) != Map.get(after_states, &1)))
        |> Enum.each(&notify_runtime/1)

        changed(daemon)
        {:ok, available_runtimes(id, valid)}
      end
    end)
  end

  # Protocol 1–2 joins carry no local repositories: those rows stay as
  # they are (`add-local-repositories` decision 4). The channel clears the
  # field of `sync` reports on such connections.
  defp local_repositories(%{protocol: protocol})
       when protocol < 3,
       do: nil

  defp local_repositories(report), do: Map.get(report, :local_repositories)

  defp check_concurrency(%{max_concurrency: n}) when is_integer(n) and n in 1..@max_concurrency,
    do: :ok

  defp check_concurrency(_report), do: {:error, :invalid_payload}

  defp report_attrs(report) do
    attrs = %{
      os: report.machine.os,
      arch: report.machine.arch,
      version: report.machine.daemon_version,
      max_concurrency: report.max_concurrency,
      last_seen_at: now()
    }

    case report do
      %{protocol: protocol} -> Map.put(attrs, :protocol_version, protocol)
      _sync -> attrs
    end
  end

  # Served workspaces where the user (member rows locked) is still a member
  # or above.
  defp valid_served(daemon) do
    served =
      Repo.all(
        from w in DaemonWorkspace, where: w.daemon_id == ^daemon.id, select: w.workspace_id
      )

    member_workspace_ids(daemon.user_id, served)
  end

  defp upsert_runtimes(id, valid, clis) do
    providers = Enum.map(clis, &to_string(&1.provider))
    time = now()

    Repo.update_all(
      from(r in Runtime,
        where: r.daemon_id == ^id and r.workspace_id in ^valid and r.provider not in ^providers
      ),
      set: [status: "offline", unavailable_reason: "not detected", updated_at: time]
    )

    rows = for workspace_id <- valid, cli <- clis, do: runtime_row(id, workspace_id, cli, time)

    if rows != [] do
      Repo.insert_all(Runtime, rows,
        conflict_target: [:workspace_id, :daemon_id, :provider],
        on_conflict:
          {:replace,
           [:cli_version, :models, :efforts, :status, :unavailable_reason, :vendor, :updated_at]}
      )
    end
  end

  defp runtime_row(id, workspace_id, cli, time) do
    %{
      workspace_id: workspace_id,
      daemon_id: id,
      provider: to_string(cli.provider),
      cli_version: cli.version,
      models: cli.models,
      efforts: cli.efforts,
      status: if(cli.available, do: "online", else: "offline"),
      unavailable_reason: if(cli.available, do: nil, else: cli.unavailable_reason),
      vendor: vendor(cli),
      inserted_at: time,
      updated_at: time
    }
  end

  # `update-actor-icons` D10: only a known vendor of an available CLI is
  # kept. PLACEHOLDER(update-actor-icons): `Map.get/2` and `Helmsman.Vendor`
  # until `HelmsmanProtocol.CLI` has `vendor` (group 1).
  defp vendor(%{available: true} = cli) do
    vendor = Map.get(cli, :vendor)
    if Helmsman.Vendor.valid?(vendor), do: vendor
  end

  defp vendor(_cli), do: nil

  defp available_runtimes(id, valid) do
    Repo.all(
      from r in Runtime,
        join: w in Workspace,
        on: w.id == r.workspace_id,
        where:
          r.daemon_id == ^id and r.workspace_id in ^valid and r.status == "online" and
            is_nil(r.disabled_at),
        order_by: [r.workspace_id, r.provider],
        select: %{
          workspace_id: r.workspace_id,
          workspace_slug: w.slug,
          provider: r.provider,
          runtime_id: r.id
        }
    )
    |> Enum.map(fn row ->
      struct!(HelmsmanProtocol.Runtime, Map.update!(row, :provider, &String.to_existing_atom/1))
    end)
  end

  defp runtime_states(id),
    do:
      Repo.all(
        from r in Runtime,
          where: r.daemon_id == ^id,
          order_by: r.id,
          select:
            {r.workspace_id, r.id, r.status, r.unavailable_reason, r.cli_version, r.models,
             r.efforts, r.vendor}
      )
      |> Enum.group_by(&elem(&1, 0))

  @doc """
  Sets the daemon's online runtimes in `ids` offline and returns the
  workspaces where one changed. Each of them gets `{:runtimes_changed}`
  after the commit unless `notify: false` (the caller notifies itself).
  Its online local repositories there go offline too, after the runtimes
  (`Helmsman.LocalRepositories.offline/2`, which always notifies).
  """
  def offline(id, ids, opts \\ []) do
    changed_ids =
      Repo.all(
        from r in Runtime,
          where: r.daemon_id == ^id and r.workspace_id in ^ids and r.status == "online",
          select: r.workspace_id,
          distinct: true
      )

    Repo.update_all(
      from(r in Runtime,
        where: r.daemon_id == ^id and r.workspace_id in ^ids and r.status == "online"
      ),
      set: [status: "offline", updated_at: now()]
    )

    LocalRepositories.offline(id, ids)
    if Keyword.get(opts, :notify, true), do: Enum.each(changed_ids, &notify_runtime/1)
    changed_ids
  end

  def notify_runtime(id),
    do: Events.after_commit(Events.topic(:workspace, id), {:runtimes_changed})

  def changed(daemon),
    do: Events.after_commit(Events.topic(:user, daemon.user_id), {:daemons_changed})

  def cascade_member(workspace_id, user_id, removed) do
    daemons =
      Repo.all(from d in Daemon, where: d.user_id == ^user_id, order_by: d.id, lock: "FOR UPDATE")

    for daemon <- daemons do
      if removed, do: unserve(daemon.id, workspace_id)
      offline(daemon.id, [workspace_id])
      Events.after_commit(Events.topic(:daemon, daemon.id), {:daemon_config_changed})
    end

    :ok
  end

  defp unserve(daemon_id, workspace_id) do
    Repo.delete_all(
      from w in DaemonWorkspace,
        where: w.daemon_id == ^daemon_id and w.workspace_id == ^workspace_id
    )
  end
end
