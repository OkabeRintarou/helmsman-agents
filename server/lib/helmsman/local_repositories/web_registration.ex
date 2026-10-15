defmodule Helmsman.LocalRepositories.WebRegistration do
  @moduledoc """
  Registering and removing local repositories from the web
  (`add-local-repo-web-registration` D8–D10).

  Only the daemon's own user, through a web session, may ask their daemon
  to list candidate repositories under its allowed roots (`browse/2`), to
  register one (`register/3`) or to remove an entry (`remove/2`). The
  daemon decides everything again; the checks here only give hints and
  defence in depth. Requests go to the daemon's channel on its topic as
  `{:local_repo_request, push}`; results come back through `deliver/2`
  and reach the requesting process on the request's result topic as
  `{:local_repo_result, request_id, daemon_id, outcome}`:

    * `{:ok, %{roots, repositories, truncated}}` (browse) or
      `{:ok, %{action, name}}` (register / remove);
    * `{:error, code, message}`: `code` a `HelmsmanProtocol.RepoRequestError`
      atom or `:daemon_outdated`, `message` a string or nil.

  The caller MUST check that `request_id` and `daemon_id` are its own.

  Registrations and removals are recorded in `local_repository_changes`
  (`list_changes/2`). Roots, paths and browse results are never logged.

  Lock order (designs/01 §4): maintenance locks → membership rows →
  daemon row → `daemon_workspaces` → `local_repository_changes` row.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.Daemons
  alias Helmsman.Daemons.{Daemon, DaemonWorkspace, Locking}
  alias Helmsman.Events
  alias Helmsman.LocalRepositories.{Change, LocalRepository}
  alias Helmsman.Repo
  alias Helmsman.Tx
  alias Helmsman.Workspaces.{Membership, Workspace}
  alias HelmsmanProtocol.{Push, RepoField, RepoRequestError, Report}

  @member_roles [:owner, :admin, :member]
  @browse_timeout_ms 15_000
  @change_timeout_ms 20_000
  @busy_seconds 30
  @no_reply_seconds 60
  @max_changes 20
  @not_configured "not configured on the machine"

  @max_workspaces 50

  # The daemon's codes (protocol 7), and the one the server adds itself.
  @error_codes RepoRequestError.all() ++ [:daemon_outdated]

  @type eligibility ::
          :ok | :not_found | :daemon_outdated | :registration_disabled | :daemon_offline
  @type outcome :: {:ok, map()} | {:error, atom(), String.t() | nil}

  @doc "How long the page waits for a browse result."
  @spec browse_timeout_ms() :: pos_integer()
  def browse_timeout_ms, do: @browse_timeout_ms

  @doc "How long the page waits for a register / remove result."
  @spec change_timeout_ms() :: pos_integer()
  def change_timeout_ms, do: @change_timeout_ms

  @doc "The result topic of a request."
  @spec topic(String.t()) :: String.t()
  def topic(request_id) when is_binary(request_id),
    do: Events.topic(:local_repo_request, request_id)

  ## Machines

  @doc """
  The requester's daemons that are not revoked and serve the current
  workspace, by name: `%{daemon_id, name, eligibility, workspaces}`.
  `eligibility` is `:ok` or why no request can be sent now;
  `workspaces` (`%{id, slug, name}`, by ID) the ones the daemon serves
  where the requester is a member or above — what a registration may be
  shared with. `{:error, :forbidden}` unless the scope is a person's web
  session as a member or above.
  """
  @spec machines(Scope.t()) :: {:ok, [map()]} | {:error, :forbidden}
  def machines(%Scope{} = scope) do
    with :ok <- person(scope) do
      now = Daemons.now()

      machines =
        scope
        |> own_daemons_query()
        |> order_by([d], [d.name, d.id])
        |> Repo.all()
        |> Enum.map(fn daemon ->
          %{
            daemon_id: daemon.id,
            name: daemon.name,
            eligibility: state(daemon, now),
            workspaces: shareable_workspaces(daemon.id, scope.user.id)
          }
        end)

      {:ok, machines}
    end
  end

  defp own_daemons_query(%Scope{user: %User{id: user_id}, workspace: %Workspace{id: ws}}) do
    from(d in Daemon,
      join: dw in DaemonWorkspace,
      on: dw.daemon_id == d.id and dw.workspace_id == ^ws,
      where: d.user_id == ^user_id and is_nil(d.revoked_at)
    )
  end

  defp shareable_workspaces(daemon_id, user_id) do
    Repo.all(
      from(w in Workspace,
        join: dw in DaemonWorkspace,
        on: dw.workspace_id == w.id and dw.daemon_id == ^daemon_id,
        join: m in Membership,
        on: m.workspace_id == w.id and m.user_id == ^user_id,
        where: m.role in ^@member_roles,
        order_by: w.id,
        select: %{id: w.id, slug: w.slug, name: w.name}
      )
    )
  end

  ## Eligibility (D8, checked in this order)

  # 1. A person's web session, member or above in the current workspace.
  defp person(%Scope{
         via: :web,
         user: %User{},
         actor: %Actor{kind: :human},
         workspace: %Workspace{},
         role: role
       })
       when role in @member_roles,
       do: :ok

  defp person(_scope), do: {:error, :forbidden}

  # 2. Their own daemon, not revoked, serving the current workspace.
  defp own_daemon(scope, daemon_id) when is_integer(daemon_id) do
    case Repo.one(scope |> own_daemons_query() |> where([d], d.id == ^daemon_id)) do
      nil -> {:error, :not_found}
      daemon -> {:ok, daemon}
    end
  end

  defp own_daemon(_scope, _daemon_id), do: {:error, :not_found}

  # 3.–5.
  defp state(daemon, now) do
    cond do
      outdated?(daemon) -> :daemon_outdated
      not daemon.repo_registration -> :registration_disabled
      offline?(daemon, now) -> :daemon_offline
      true -> :ok
    end
  end

  defp outdated?(%Daemon{protocol_version: version}),
    do: not is_integer(version) or version < HelmsmanProtocol.repo_registration_version()

  defp offline?(%Daemon{last_seen_at: nil}, _now), do: true

  defp offline?(%Daemon{last_seen_at: seen}, now),
    do: DateTime.before?(seen, DateTime.add(now, -Daemons.online_threshold_seconds()))

  defp eligible(scope, daemon_id) do
    with :ok <- person(scope),
         {:ok, daemon} <- own_daemon(scope, daemon_id) do
      case state(daemon, Daemons.now()) do
        :ok -> {:ok, daemon}
        reason -> {:error, reason}
      end
    end
  end

  ## Browse

  @doc """
  Asks daemon `daemon_id` to list the candidate repositories under its
  allowed roots. The caller is subscribed to the result topic before the
  request goes out; nothing is written. Returns `{:ok, request_id}` or the
  first failed eligibility reason (`:forbidden`, `:not_found`,
  `:daemon_outdated`, `:registration_disabled`, `:daemon_offline`).
  """
  @spec browse(Scope.t(), term()) :: {:ok, String.t()} | {:error, atom()}
  def browse(%Scope{} = scope, daemon_id) do
    with {:ok, daemon} <- eligible(scope, daemon_id) do
      request_id = new_request_id()
      :ok = Events.subscribe(topic(request_id))

      Events.broadcast(
        Events.topic(:daemon, daemon.id),
        {:local_repo_request, %Push.RepoBrowse{request_id: request_id}}
      )

      log(:browse, request_id, daemon.id, scope.user.id, :requested)
      {:ok, request_id}
    end
  end

  ## Register / remove

  @doc """
  Asks daemon `daemon_id` to register the candidate `root` / `path` as
  `name`, shared with `workspace_ids` (string or atom keys). Eligibility
  first (any other user's daemon is `:not_found`), then the fields
  (`{:error, changeset}`; `workspace_ids` must be a non-empty subset of
  the machine's `workspaces` in `machines/1`), then, with the daemon row
  locked, everything again: `{:error, {:invalid_workspaces, ids}}` when a
  chosen workspace no longer qualifies, `{:error, :busy}` when another
  request to the daemon is pending since less than 30 seconds.
  Returns `{:ok, request_id}`; the caller is subscribed to its result.
  """
  @spec register(Scope.t(), term(), map()) ::
          {:ok, String.t()} | {:error, atom() | Ecto.Changeset.t() | {atom(), [pos_integer()]}}
  def register(%Scope{} = scope, daemon_id, attrs) when is_map(attrs) do
    with {:ok, daemon} <- eligible(scope, daemon_id),
         {:ok, fields} <- validate(attrs, shareable_workspaces(daemon.id, scope.user.id)) do
      ids = Enum.uniq([scope.workspace.id | fields.workspace_ids])
      write(scope, daemon.id, ids, {:register, fields})
    end
  end

  @doc """
  Asks the daemon of local repository `local_repository_id` (of the
  current workspace, not removed, on the requester's own daemon; else
  `:not_found`) to remove its entry. `{:error, :not_configured}` for a
  row whose entry is already gone from the machine; otherwise as
  `register/3`.
  """
  @spec remove(Scope.t(), term()) :: {:ok, String.t()} | {:error, atom()}
  def remove(%Scope{} = scope, local_repository_id) do
    with :ok <- person(scope),
         {:ok, repo} <- current_repository(scope, local_repository_id),
         {:ok, daemon} <- eligible(scope, repo.daemon_id),
         :ok <- configured(repo) do
      write(scope, daemon.id, [scope.workspace.id], {:remove, repo.id})
    end
  end

  @doc """
  The workspaces a removal of local repository `local_repository_id` makes
  unavailable (`%{id, slug, name}`, by ID): every workspace with a current
  row of the same daemon and name, as recorded by `remove/2`. For the
  removal dialog; only the requester's own daemon (eligibility 1–2,
  otherwise `:forbidden` / `:not_found`), whatever its state.
  """
  @spec remove_workspaces(Scope.t(), term()) :: {:ok, [map()]} | {:error, :forbidden | :not_found}
  def remove_workspaces(%Scope{} = scope, local_repository_id) do
    with :ok <- person(scope),
         {:ok, repo} <- current_repository(scope, local_repository_id),
         {:ok, daemon} <- own_daemon(scope, repo.daemon_id) do
      ids = workspaces_of(daemon.id, repo.name)

      {:ok,
       Repo.all(
         from(w in Workspace,
           where: w.id in ^ids,
           order_by: w.id,
           select: %{id: w.id, slug: w.slug, name: w.name}
         )
       )}
    end
  end

  defp current_repository(%Scope{workspace: %Workspace{id: ws}}, id) when is_integer(id) do
    case Repo.one(
           from(l in LocalRepository,
             where: l.id == ^id and l.workspace_id == ^ws and is_nil(l.removed_at)
           )
         ) do
      nil -> {:error, :not_found}
      repo -> {:ok, repo}
    end
  end

  defp current_repository(_scope, _id), do: {:error, :not_found}

  defp configured(%LocalRepository{unavailable_reason: @not_configured}),
    do: {:error, :not_configured}

  defp configured(_repo), do: :ok

  defp write(scope, daemon_id, workspace_ids, request) do
    result =
      Locking.run(daemon_id, [workspace_ids: workspace_ids, members: true], fn daemon, _ids ->
        with :ok <- recheck(scope, daemon),
             {:ok, change} <- locked_change(scope, daemon, request),
             :ok <- not_busy(daemon.id, change.inserted_at) do
          insert(scope, daemon, change)
        end
      end)

    case result do
      {:ok, {request_id, action}} ->
        log(action, request_id, daemon_id, scope.user.id, :requested)
        {:ok, request_id}

      error ->
        error
    end
  end

  # Eligibility 1–4 against the locked membership and daemon rows; being
  # online is only a hint and not checked again.
  defp recheck(%Scope{user: %User{id: user_id}, workspace: %Workspace{id: ws}}, daemon) do
    cond do
      ws not in Daemons.member_workspace_ids(user_id, [ws]) -> {:error, :forbidden}
      daemon.user_id != user_id or not is_nil(daemon.revoked_at) -> {:error, :not_found}
      ws not in served(daemon.id) -> {:error, :not_found}
      outdated?(daemon) -> {:error, :daemon_outdated}
      not daemon.repo_registration -> {:error, :registration_disabled}
      true -> :ok
    end
  end

  defp served(daemon_id),
    do:
      Repo.all(
        from(w in DaemonWorkspace, where: w.daemon_id == ^daemon_id, select: w.workspace_id)
      )

  # The change to record; `inserted_at` is taken here, after the daemon
  # row is locked (never SQL `now()`, the transaction's start).
  defp locked_change(%Scope{user: user}, daemon, {:register, fields}) do
    allowed = MapSet.new(Daemons.member_workspace_ids(user.id, fields.workspace_ids))
    served = MapSet.new(served(daemon.id))

    case Enum.reject(fields.workspace_ids, &(&1 in allowed and &1 in served)) do
      [] ->
        {:ok,
         %{
           action: "register",
           name: fields.name,
           root: fields.root,
           path: fields.path,
           workspace_ids: fields.workspace_ids,
           inserted_at: DateTime.utc_now()
         }}

      invalid ->
        {:error, {:invalid_workspaces, invalid}}
    end
  end

  defp locked_change(%Scope{workspace: %Workspace{id: ws}}, daemon, {:remove, id}) do
    repo =
      Repo.one(
        from(l in LocalRepository,
          where:
            l.id == ^id and l.workspace_id == ^ws and l.daemon_id == ^daemon.id and
              is_nil(l.removed_at)
        )
      )

    case repo do
      nil ->
        {:error, :not_found}

      %LocalRepository{unavailable_reason: @not_configured} ->
        {:error, :not_configured}

      repo ->
        {:ok,
         %{
           action: "remove",
           name: repo.name,
           root: nil,
           path: nil,
           workspace_ids: workspaces_of(daemon.id, repo.name),
           inserted_at: DateTime.utc_now()
         }}
    end
  end

  # Every workspace with a row of the daemon's entry `name`: the ones the
  # removal makes unavailable. Those rows are only written under the
  # daemon row's lock, which is held.
  defp workspaces_of(daemon_id, name),
    do:
      Repo.all(
        from(l in LocalRepository,
          where: l.daemon_id == ^daemon_id and l.name == ^name and is_nil(l.removed_at),
          select: l.workspace_id,
          distinct: true,
          order_by: l.workspace_id
        )
      )

  defp not_busy(daemon_id, now) do
    since = DateTime.add(now, -@busy_seconds)

    pending =
      Repo.exists?(
        from(c in Change,
          where: c.daemon_id == ^daemon_id and c.status == "pending" and c.inserted_at >= ^since
        )
      )

    if pending, do: {:error, :busy}, else: :ok
  end

  defp insert(scope, daemon, change) do
    request_id = new_request_id()

    record =
      Repo.insert!(
        struct!(
          Change,
          Map.merge(change, %{
            daemon_id: daemon.id,
            user_id: scope.user.id,
            workspace_id: scope.workspace.id,
            request_id: request_id,
            status: "pending"
          })
        ),
        # Even debug query logs must not carry the root or path.
        log: false
      )

    # Subscribed before the request goes out; on a rollback the extra
    # subscription is harmless (`forget/1` or the process exit drops it).
    :ok = Events.subscribe(topic(request_id))
    Events.after_commit(Events.topic(:daemon, daemon.id), {:local_repo_request, push(record)})
    notify_changes(record)
    {:ok, {request_id, String.to_existing_atom(record.action)}}
  end

  defp push(%Change{action: "register"} = c),
    do: %Push.RepoRegister{
      request_id: c.request_id,
      root: c.root,
      path: c.path,
      name: c.name,
      workspaces: c.workspace_ids
    }

  defp push(%Change{action: "remove"} = c),
    do: %Push.RepoRemove{request_id: c.request_id, name: c.name}

  defp notify_changes(%Change{} = change) do
    [change.workspace_id | change.workspace_ids]
    |> Enum.uniq()
    |> Enum.each(fn id ->
      Events.after_commit_once(
        {:local_repository_changes_changed, id},
        Events.topic(:workspace, id),
        {:local_repository_changes_changed}
      )
    end)
  end

  ## Field validation (the protocol's formats, D7: `HelmsmanProtocol.RepoField`)

  @types %{root: :string, path: :string, name: :string, workspace_ids: {:array, :integer}}

  defp validate(attrs, shareable) do
    shareable_ids = Enum.map(shareable, & &1.id)

    {%{}, @types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@types), empty_values: [])
    |> Ecto.Changeset.validate_required(Map.keys(@types))
    |> validate_field(:root, &RepoField.root?/1)
    |> validate_field(:path, &RepoField.path?/1)
    |> validate_field(:name, &RepoField.name?/1, "has invalid format")
    |> Ecto.Changeset.validate_change(:workspace_ids, &check_workspaces(&1, &2, shareable_ids))
    |> Ecto.Changeset.apply_action(:validate)
  end

  defp validate_field(changeset, field, valid?, message \\ "is invalid") do
    Ecto.Changeset.validate_change(changeset, field, fn ^field, value ->
      if valid?.(value), do: [], else: [{field, message}]
    end)
  end

  defp check_workspaces(:workspace_ids, ids, shareable_ids) do
    cond do
      ids == [] -> [workspace_ids: "can't be blank"]
      length(ids) > @max_workspaces -> [workspace_ids: "is invalid"]
      Enum.uniq(ids) != ids -> [workspace_ids: "is invalid"]
      Enum.any?(ids, &(&1 not in shareable_ids)) -> [workspace_ids: "is invalid"]
      true -> []
    end
  end

  ## Results (D8 `deliver/2`)

  @doc """
  Called by the daemon channel with a result report. A browse result
  (already matched to a request of this connection, D9) is broadcast to
  its result topic and nothing else. A register / remove result is
  recorded on its pending change of the daemon `ctx.daemon_id` with the
  same action and name, then broadcast; otherwise it is ignored (`:ok`,
  nothing broadcast). `{:error, :not_found}` when the connection's
  authorization is stale.
  """
  @spec deliver(map(), struct()) :: :ok | {:error, :not_found}
  def deliver(%{daemon_id: daemon_id}, %Report.RepoBrowseResult{} = report) do
    Events.broadcast(
      topic(report.request_id),
      {:local_repo_result, report.request_id, daemon_id, browse_outcome(report)}
    )

    :ok
  end

  def deliver(%{daemon_id: daemon_id, auth_epoch: epoch}, %Report.RepoChangeResult{} = report) do
    Tx.run(fn ->
      daemon = Repo.one(from(d in Daemon, where: d.id == ^daemon_id, lock: "FOR SHARE"))

      case Daemons.authorized(daemon, epoch) do
        :ok -> {:ok, record_result(daemon_id, report)}
        {:error, _} -> {:error, :not_found}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp record_result(daemon_id, report) do
    action = to_string(report.action)

    name = report.name

    case lock_change(report.request_id, daemon_id) do
      %Change{status: "pending", action: ^action, name: ^name} = change ->
        complete(change, code(report.error), report.message)

      _ignored ->
        :ignored
    end
  end

  defp lock_change(request_id, daemon_id),
    do:
      Repo.one(
        from(c in Change,
          where: c.request_id == ^request_id and c.daemon_id == ^daemon_id,
          lock: "FOR UPDATE"
        )
      )

  defp complete(change, error, message) do
    change =
      Repo.update!(
        Ecto.Changeset.change(change,
          status: if(is_nil(error), do: "succeeded", else: "failed"),
          error: error && Atom.to_string(error),
          message: message,
          completed_at: DateTime.utc_now()
        )
      )

    notify_changes(change)

    outcome =
      if is_nil(error),
        do: {:ok, %{action: String.to_existing_atom(change.action), name: change.name}},
        else: {:error, error, message}

    Events.after_commit(
      topic(change.request_id),
      {:local_repo_result, change.request_id, change.daemon_id, outcome}
    )

    log(
      String.to_existing_atom(change.action),
      change.request_id,
      change.daemon_id,
      change.user_id,
      error || :succeeded
    )

    :recorded
  end

  @doc """
  The channel cannot encode request `request_id` for its connection's
  protocol: as a result `daemon_outdated` from daemon `daemon_id`. A
  pending change becomes `failed`; a browse request (no record) gets the
  error right away.
  """
  @spec undeliverable(String.t(), pos_integer()) :: :ok
  def undeliverable(request_id, daemon_id) when is_binary(request_id) do
    {:ok, recorded} =
      Tx.run(fn ->
        case lock_change(request_id, daemon_id) do
          nil -> {:ok, false}
          %Change{status: "pending"} = change -> {:ok, complete(change, :daemon_outdated, nil)}
          _done -> {:ok, :ignored}
        end
      end)

    if recorded == false do
      Events.broadcast(
        topic(request_id),
        {:local_repo_result, request_id, daemon_id, {:error, :daemon_outdated, nil}}
      )

      log(:browse, request_id, daemon_id, nil, :daemon_outdated)
    end

    :ok
  end

  @doc "Unsubscribes the caller from the result topic of `request_id`."
  @spec forget(String.t()) :: :ok
  def forget(request_id) when is_binary(request_id), do: Events.unsubscribe(topic(request_id))

  defp browse_outcome(%{error: nil} = report),
    do:
      {:ok,
       %{
         roots: report.roots,
         repositories: Enum.map(report.repositories, &candidate/1),
         truncated: report.truncated
       }}

  defp browse_outcome(report), do: {:error, code(report.error), report.message}

  defp candidate(item),
    do: %{root: item.root, path: item.path, name: item.name, registered_as: item.registered_as}

  defp code(nil), do: nil
  defp code(code) when code in @error_codes, do: code

  defp code(code) when is_binary(code) do
    Enum.find(@error_codes, :config_error, &(Atom.to_string(&1) == code))
  end

  ## Changes (D10)

  @doc """
  The web requests that involve the current workspace (started in it or
  shared with it), newest first, at most #{@max_changes}: `:mine` the
  requester's own (member or above), `:all` everyone's (owner / admin);
  otherwise `{:error, :forbidden}`. Each is `%{id, action, name,
  daemon_name, operator: %{user_id, name}, root, path, state, error,
  message, inserted_at, completed_at}`; `state` is `:pending`,
  `:succeeded`, `:failed` or `:no_reply` (pending for over
  #{@no_reply_seconds} seconds); `action` and `error` are atoms; `root` /
  `path` only for the operator or an owner / admin.
  """
  @spec list_changes(Scope.t(), :mine | :all) :: {:ok, [map()]} | {:error, :forbidden}
  def list_changes(%Scope{} = scope, view) when view in [:mine, :all] do
    with :ok <- may_list(scope, view) do
      ws = scope.workspace.id

      query =
        from(c in Change,
          join: d in Daemon,
          on: d.id == c.daemon_id,
          left_join: u in User,
          on: u.id == c.user_id,
          where: c.workspace_id == ^ws or fragment("? = ANY(?)", ^ws, c.workspace_ids),
          order_by: [desc: c.inserted_at, desc: c.id],
          limit: @max_changes,
          select: {c, d.name, coalesce(u.display_name, u.email)}
        )

      query =
        if view == :mine, do: where(query, [c], c.user_id == ^scope.user.id), else: query

      no_reply_before = DateTime.add(DateTime.utc_now(), -@no_reply_seconds)
      {:ok, query |> Repo.all() |> Enum.map(&change_view(&1, scope, no_reply_before))}
    end
  end

  defp may_list(%Scope{role: role}, :all) when role in [:owner, :admin], do: :ok
  defp may_list(%Scope{role: role}, :mine) when role in @member_roles, do: :ok
  defp may_list(_scope, _view), do: {:error, :forbidden}

  defp change_view({%Change{} = c, daemon_name, operator_name}, scope, no_reply_before) do
    visible = c.user_id == scope.user.id or scope.role in [:owner, :admin]

    %{
      id: c.id,
      action: String.to_existing_atom(c.action),
      name: c.name,
      daemon_name: daemon_name,
      operator: %{user_id: c.user_id, name: operator_name},
      root: if(visible, do: c.root),
      path: if(visible, do: c.path),
      state: change_state(c, no_reply_before),
      error: c.error && code(c.error),
      message: c.message,
      inserted_at: c.inserted_at,
      completed_at: c.completed_at
    }
  end

  defp change_state(%Change{status: "pending", inserted_at: at}, no_reply_before) do
    if DateTime.before?(at, no_reply_before), do: :no_reply, else: :pending
  end

  defp change_state(%Change{status: "succeeded"}, _no_reply_before), do: :succeeded
  defp change_state(%Change{status: "failed"}, _no_reply_before), do: :failed

  ## Helpers

  # 16 random bytes, base64url without padding: 22 characters.
  defp new_request_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  # Only IDs, the action and the result code: never a root, path or
  # browse result.
  defp log(action, request_id, daemon_id, user_id, result) do
    Logger.info(
      "local repository web request #{action} #{request_id}: daemon #{daemon_id}, " <>
        "user #{inspect(user_id)}, #{result}"
    )
  end
end
