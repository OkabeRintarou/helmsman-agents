defmodule Helmsman.Daemons.DeviceAuth do
  @moduledoc false
  import Ecto.Query
  import Bitwise

  alias Helmsman.Daemons
  alias Helmsman.Daemons.Daemon
  alias Helmsman.Daemons.DeviceCode
  alias Helmsman.Daemons.Locking
  alias Helmsman.Events
  alias Helmsman.Locks
  alias Helmsman.RateLimit
  alias Helmsman.Repo
  alias Helmsman.Tx
  alias HelmsmanProtocol.DeviceAuth.TokenResponse
  alias HelmsmanProtocol.DeviceAuth.Workspace

  # Advisory lock ids must stay below 2^48 (Helmsman.Locks).
  @max_lock_id 1 <<< 48

  def start_device_auth(request), do: insert_code(request, 5)
  defp insert_code(_request, 0), do: {:error, :busy}

  defp insert_code(request, remaining) do
    device_code = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    result =
      Tx.run(fn ->
        Repo.update_all(
          from(c in DeviceCode,
            where: c.status in ["pending", "approved"] and c.expires_at <= ^Daemons.now()
          ),
          set: [status: "expired"]
        )

        changeset =
          Ecto.Changeset.change(%DeviceCode{},
            device_code_hash: Daemons.hash(device_code),
            user_code: user_code(),
            machine: HelmsmanProtocol.Machine.to_wire(request.machine),
            protocol_version: request.protocol,
            expires_at: DateTime.add(Daemons.now(), 600)
          )
          |> Ecto.Changeset.unique_constraint(:user_code,
            name: :device_codes_active_user_code_index
          )

        case Repo.insert(changeset) do
          {:ok, code} ->
            {:ok,
             %{device_code: device_code, user_code: code.user_code, expires_in: 600, interval: 5}}

          error ->
            error
        end
      end)

    case result do
      {:error, %Ecto.Changeset{}} -> insert_code(request, remaining - 1)
      result -> result
    end
  end

  defp user_code do
    case Application.get_env(:helmsman, :daemon_user_code_generator) do
      fun when is_function(fun, 0) ->
        fun.()

      _ ->
        alphabet = HelmsmanProtocol.DeviceAuth.user_code_alphabet() |> String.codepoints()

        code =
          Enum.map_join(1..8, fn _ ->
            Enum.at(alphabet, :crypto.strong_rand_range(length(alphabet)))
          end)

        String.slice(code, 0, 4) <> "-" <> String.slice(code, 4, 4)
    end
  end

  defp normalize(code) do
    code = code |> String.replace(~r/[\s-]/, "") |> String.upcase()
    String.slice(code, 0, 4) <> "-" <> String.slice(code, 4, 4)
  end

  defp pending(code),
    do:
      from(c in DeviceCode,
        where:
          c.user_code == ^normalize(code) and c.status == "pending" and
            c.expires_at > ^Daemons.now()
      )

  defp rate(scope) do
    case RateLimit.check(:daemon_device_user, scope.user.id) do
      :ok -> :ok
      _ -> {:error, {:rate_limited, 60}}
    end
  end

  def get_device_auth(scope, code) do
    with :ok <- rate(scope) do
      case Repo.one(pending(code)) do
        nil -> {:error, :not_found}
        code -> {:ok, Map.take(code, [:user_code, :machine, :expires_at])}
      end
    end
  end

  def approve_device(scope, code, ids) do
    with :ok <- rate(scope),
         {:ok, ids} <- workspace_ids(ids) do
      Tx.run(fn -> approve_locked(scope, code, ids) end)
    end
  end

  # Decision 19: device code row → maintenance locks → member rows, then
  # the roles are checked under the locks.
  defp approve_locked(scope, code, ids) do
    device = Repo.one(lock(pending(code), "FOR UPDATE"))
    Enum.each(ids, &Locks.maint_shared!/1)
    Locking.lock_members(scope.user.id, ids)

    with %DeviceCode{} <- device || {:error, :not_found},
         :ok <- Daemons.valid_workspaces(scope.user.id, ids) do
      device
      |> Ecto.Changeset.change(status: "approved", user_id: scope.user.id, workspace_ids: ids)
      |> Repo.update()
    end
  end

  # Sorted, unique ids that can be lock keys; anything else is refused as
  # invalid before any lock is taken.
  defp workspace_ids(ids) when is_list(ids) do
    case Enum.reject(ids, &(is_integer(&1) and &1 > 0 and &1 < @max_lock_id)) do
      [] -> {:ok, ids |> Enum.uniq() |> Enum.sort()}
      invalid -> {:error, {:invalid_workspaces, invalid}}
    end
  end

  defp workspace_ids(_ids), do: {:error, {:invalid_workspaces, []}}

  def deny_device(scope, code) do
    with :ok <- rate(scope) do
      Tx.run(fn -> deny_locked(scope, code) end)
    end
  end

  defp deny_locked(scope, code) do
    case Repo.one(lock(pending(code), "FOR UPDATE")) do
      nil ->
        {:error, :not_found}

      device ->
        Repo.update(Ecto.Changeset.change(device, status: "denied", user_id: scope.user.id))
    end
  end

  def exchange_device_code(code), do: exchange(code, 3)
  defp exchange(_code, 0), do: {:pending, :authorization_pending}

  defp exchange(code, attempts) do
    result =
      Tx.run(fn ->
        device =
          Repo.one(
            from c in DeviceCode,
              where: c.device_code_hash == ^Daemons.hash(code),
              lock: "FOR UPDATE"
          )

        case device do
          nil -> {:ok, {:error, :expired_token}}
          device -> poll(device)
        end
      end)

    case result do
      {:ok, reply} -> reply
      {:error, :daemon_lock_set_changed} -> exchange(code, attempts - 1)
      {:error, :busy} -> {:pending, :authorization_pending}
      error -> error
    end
  end

  defp poll(device) do
    time = Daemons.now()

    cond do
      device.status in ["used", "expired"] or DateTime.compare(time, device.expires_at) != :lt ->
        Repo.update!(Ecto.Changeset.change(device, status: "expired", last_polled_at: time))
        {:ok, {:error, :expired_token}}

      device.status == "denied" ->
        Repo.update!(Ecto.Changeset.change(device, last_polled_at: time))
        {:ok, {:error, :access_denied}}

      device.status == "approved" ->
        issue(device)

      device.last_polled_at && DateTime.diff(time, device.last_polled_at) < device.interval ->
        Repo.update!(
          Ecto.Changeset.change(device, interval: device.interval + 5, last_polled_at: time)
        )

        {:ok, {:pending, :slow_down}}

      true ->
        Repo.update!(Ecto.Changeset.change(device, last_polled_at: time))
        {:ok, {:pending, :authorization_pending}}
    end
  end

  defp issue(device) do
    machine_id = device.machine["machine_id"]

    daemon =
      Repo.one(
        from d in Daemon, where: d.user_id == ^device.user_id and d.machine_id == ^machine_id
      )

    if daemon do
      Daemons.locked(daemon.id, [members: true, workspace_ids: device.workspace_ids], fn daemon,
                                                                                         ids ->
        issue_locked(device, daemon, ids)
      end)
    else
      Enum.each(Enum.sort(device.workspace_ids), &Locks.maint_shared!/1)
      Locking.lock_members(device.user_id, device.workspace_ids)

      daemon = %Daemon{
        user_id: device.user_id,
        machine_id: machine_id,
        name: Daemons.initial_name(device.machine["name"]),
        token_hash: Daemons.hash(Daemons.new_token())
      }

      changeset =
        Ecto.Changeset.change(daemon)
        |> Ecto.Changeset.unique_constraint(:machine_id, name: :daemons_user_id_machine_id_index)

      case Repo.insert(changeset) do
        {:ok, daemon} -> issue_locked(device, daemon, device.workspace_ids, false)
        {:error, _} -> Repo.rollback(:daemon_lock_set_changed)
      end
    end
  end

  defp issue_locked(device, daemon, ids, existing \\ true) do
    token = Daemons.new_token()

    daemon =
      Repo.update!(
        Ecto.Changeset.change(daemon,
          token_hash: Daemons.hash(token),
          token_issued_at: Daemons.now(),
          previous_token_hash: nil,
          previous_token_expires_at: nil,
          revoked_at: nil,
          auth_epoch: daemon.auth_epoch + if(existing, do: 1, else: 0),
          os: device.machine["os"],
          arch: device.machine["arch"],
          version: device.machine["daemon_version"],
          protocol_version: device.protocol_version
        )
      )

    valid = Daemons.member_workspace_ids(device.user_id, device.workspace_ids)
    Daemons.replace_workspaces(daemon, valid, ids)
    Repo.update!(Ecto.Changeset.change(device, status: "used", last_polled_at: Daemons.now()))

    if existing, do: Events.after_commit(Events.topic(:daemon, daemon.id), {:daemon_reauthorized})

    Daemons.changed(daemon)

    workspaces =
      Repo.all(
        from w in Helmsman.Workspaces.Workspace,
          where: w.id in ^valid,
          order_by: w.id,
          select: %{id: w.id, slug: w.slug, name: w.name}
      )
      |> Enum.map(&struct!(Workspace, &1))

    {:ok, {:ok, %TokenResponse{token: token, daemon_id: daemon.id, workspaces: workspaces}}}
  end
end
