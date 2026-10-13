defmodule Helmsman.AgentDesigns do
  @moduledoc """
  Creation conversations (`add-agent-conversation`): a person designs new
  managed agents by talking with one of the managed agents they may
  trigger (the helper) and confirms the resulting draft.

  Every user message is a turn: a design run of the helper (no task,
  trigger `design` with the conversation's ID, priority 3, capabilities
  `read` and `design`), settled into a reply after it ends
  (`Helmsman.AgentDesigns.SettleTurn`). The helper only writes the draft,
  with the draft tools (`describe/1`, `propose_agent/2`,
  `withdraw_agent/2`, run tokens only); the agents are created only by
  `confirm/3`, in the user's own web session.

  Web side (first argument a web scope, `:design_agents`): `helpers/1`,
  `current/1`, `get/2`, `start/2`, `send/3`, `stop_turn/2`, `discard/2`,
  `change_helper/3`, `put_agent/4`, `remove_agent/4`, `confirm/3`. A
  conversation is only ever its user's: anybody else gets `:not_found`.

  Locks (decision 10): the conversation row first (`FOR UPDATE`), then the
  helper's actor and profile, its runtime, then runs. The run side
  (claiming, starting, ending) only reads conversations.

  Every change notifies `agent_design:<id>` with `{:agent_design, id}`
  after the commit.
  """

  import Ecto.Query

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.AgentDesigns.{AgentDesign, AgentDesignMessage, Draft, Options, Prompt}
  alias Helmsman.Agents
  alias Helmsman.Agents.{AgentProfile, TriggerRule}
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Dispatch
  alias Helmsman.Events
  alias Helmsman.Locks
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Origin, Run, RunTokens, Stop}
  alias Helmsman.Tx
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.{Membership, Workspace}

  @max_user_messages 40
  @max_message_bytes 8192
  @queue_timeout_seconds 600
  @idle_days 7
  @retention_days 30
  @member_roles [:owner, :admin, :member]

  @type view :: map()
  @type dispatch_error ::
          :not_managed
          | :unauthorized
          | :agent_disabled
          | :agent_archived
          | :no_runtime
          | :runtime_disabled

  @doc "The most agents of a draft."
  @spec max_agents() :: pos_integer()
  def max_agents, do: Draft.max_agents()

  @doc "The most user messages of a conversation."
  @spec max_user_messages() :: pos_integer()
  def max_user_messages, do: @max_user_messages

  @doc "The most bytes of a user message."
  @spec max_message_bytes() :: pos_integer()
  def max_message_bytes, do: @max_message_bytes

  @doc "The topic of the conversation `id`: `{:agent_design, id}` after each change."
  @spec topic(pos_integer()) :: String.t()
  def topic(id), do: Events.topic(:agent_design, id)

  ## Reading

  @doc """
  The managed, unarchived agents of the workspace `scope.user` may
  trigger, by name: `%{name, provider, owner: %{user_id, name},
  dispatchability: :ok | {:skipped, reason}}` (`Helmsman.Dispatch.availability/1`).
  """
  @spec helpers(Scope.t()) :: {:ok, [map()]} | {:error, :forbidden}
  def helpers(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, :design_agents),
         {:ok, availability} <- Dispatch.availability(scope) do
      rows =
        Repo.all(
          from(a in Actor,
            join: p in AgentProfile,
            on: p.actor_id == a.id,
            join: u in User,
            on: u.id == a.owner_id,
            where:
              a.workspace_id == ^scope.workspace.id and a.kind == :agent and
                is_nil(p.archived_at),
            order_by: a.name,
            select: {a, p, u.display_name}
          )
        )

      {:ok,
       for {actor, profile, owner_name} <- rows,
           TriggerRule.may_trigger?(profile, actor, scope.user.id, scope.role) do
         helper_view(actor, profile, owner_name, availability)
       end}
    end
  end

  defp helper_view(actor, profile, owner_name, availability) do
    %{
      name: actor.name,
      provider: profile && profile.provider,
      owner: %{user_id: actor.owner_id, name: owner_name},
      dispatchability:
        case availability[actor.name] do
          %{result: result} -> result
          nil -> {:skipped, if(profile, do: :agent_archived, else: :not_managed)}
        end
    }
  end

  @doc "The user's `open` conversation in the workspace, or nil."
  @spec current(Scope.t()) :: {:ok, view() | nil} | {:error, :forbidden}
  def current(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, :design_agents) do
      case Repo.one(own(scope) |> where([d], d.status == :open)) do
        nil -> {:ok, nil}
        design -> {:ok, view(scope, design)}
      end
    end
  end

  @doc "The user's conversation `id`; anybody else's is `:not_found`."
  @spec get(Scope.t(), term()) :: {:ok, view()} | {:error, :forbidden | :not_found}
  def get(%Scope{} = scope, id) do
    with :ok <- Policy.authorize(scope, :design_agents),
         {:ok, id} <- parse_id(id),
         %AgentDesign{} = design <- Repo.one(own(scope) |> where([d], d.id == ^id)) do
      {:ok, view(scope, design)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp own(%Scope{workspace: %Workspace{id: ws}, user: %User{id: user_id}}),
    do: from(d in AgentDesign, where: d.workspace_id == ^ws and d.user_id == ^user_id)

  defp parse_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, n}
      _other -> {:error, :not_found}
    end
  end

  defp parse_id(_id), do: {:error, :not_found}

  ## Starting and turns

  @doc """
  Starts a conversation with the helper `helper` (a name) and its first
  message `message` (decision 4): the conversation and its first turn in
  one transaction. Errors: `:forbidden`, a message changeset (`:message`),
  `{:design_open, id}` (the user already has one), `:not_found`,
  `:not_managed` and the reasons the helper cannot be dispatched
  (`unauthorized`, `agent_disabled`, `agent_archived`, `no_runtime`,
  `runtime_disabled`); nothing is written then.
  """
  @spec start(Scope.t(), map()) :: {:ok, view()} | {:error, term()}
  def start(%Scope{} = scope, attrs) when is_map(attrs) do
    helper = attrs[:helper] || attrs["helper"]
    message = attrs[:message] || attrs["message"]

    with {:ok, text} <- check_message(message) do
      Workspaces.write_transaction(scope, :design_agents, nil, &start_locked(&1, helper, text))
    end
  end

  defp start_locked(scope, helper, text) do
    with nil <- open_id(scope),
         _ = test_hook(:design_start_checked),
         {:ok, agent, profile} <- lock_helper(scope.workspace.id, name: helper),
         {:ok, design} <- insert_design(scope, agent),
         {:ok, design} <- turn(scope, design, agent, profile, text) do
      {:ok, view(scope, design)}
    else
      id when is_integer(id) -> {:error, {:design_open, id}}
      error -> error
    end
  end

  defp open_id(scope),
    do: Repo.one(own(scope) |> where([d], d.status == :open) |> select([d], d.id))

  # The partial unique index keeps one `open` conversation per user and
  # workspace: a concurrent start that committed first wins, and this one
  # reads its ID.
  defp insert_design(scope, agent) do
    now = DateTime.utc_now()

    {:ok, design} =
      Repo.insert(
        %AgentDesign{
          workspace_id: scope.workspace.id,
          user_id: scope.user.id,
          helper_agent_id: agent.id,
          last_activity_at: now
        },
        on_conflict: :nothing,
        conflict_target: {:unsafe_fragment, "(workspace_id, user_id) WHERE status = 'open'"}
      )

    case design.id do
      nil -> {:error, {:design_open, open_id(scope)}}
      _id -> {:ok, design}
    end
  end

  @doc """
  Sends `text` in the conversation `id`: a new turn (decision 11). Errors:
  `:forbidden`, `:not_found`, a message changeset, `:design_closed`,
  `:turn_running`, `:turn_limit` and the helper's dispatch reasons;
  nothing is written then.
  """
  @spec send(Scope.t(), term(), term()) :: {:ok, view()} | {:error, term()}
  def send(%Scope{} = scope, id, text) do
    with {:ok, text} <- check_message(text) do
      locked_open(scope, id, &send_locked(&1, &2, text))
    end
  end

  defp send_locked(scope, design, text) do
    with :ok <- no_turn(design),
         :ok <- under_limit(design),
         {:ok, agent, profile} <- lock_helper(scope.workspace.id, id: design.helper_agent_id),
         {:ok, design} <- turn(scope, design, agent, profile, text) do
      {:ok, view(scope, design)}
    end
  end

  defp under_limit(%AgentDesign{user_messages: n}) when n >= @max_user_messages,
    do: {:error, :turn_limit}

  defp under_limit(_design), do: :ok

  defp check_message(text) do
    cs =
      {%{}, %{message: :string}}
      |> Ecto.Changeset.cast(%{message: text}, [:message])
      |> Ecto.Changeset.validate_required([:message])
      |> Ecto.Changeset.validate_length(:message, max: @max_message_bytes, count: :bytes)

    if cs.valid?,
      do: {:ok, Ecto.Changeset.get_field(cs, :message)},
      else: {:error, cs}
  end

  # The helper's actor and profile `FOR SHARE` (what `Runs.enqueue/3`
  # needs); a person or an external agent cannot be a helper.
  defp lock_helper(workspace_id, by) do
    query = helper_query(workspace_id, by)

    case query && Repo.one(lock(query, "FOR SHARE")) do
      %Actor{kind: :agent} = agent ->
        profile =
          Repo.one(from(p in AgentProfile, where: p.actor_id == ^agent.id, lock: "FOR SHARE"))

        if profile, do: {:ok, agent, profile}, else: {:error, :not_managed}

      %Actor{} ->
        {:error, :not_managed}

      nil ->
        {:error, :not_found}
    end
  end

  defp helper_query(workspace_id, name: name) when is_binary(name),
    do: from(a in Actor, where: a.workspace_id == ^workspace_id and a.name == ^name)

  defp helper_query(workspace_id, id: id),
    do: from(a in Actor, where: a.workspace_id == ^workspace_id and a.id == ^id)

  defp helper_query(_workspace_id, _by), do: nil

  # One turn (decisions 3, 11, 16): the design run, then the user message
  # with the pending edits as its snapshot, and the conversation pointing
  # at the run.
  defp turn(scope, design, agent, profile, text) do
    {:ok, outcome} =
      Runs.enqueue(
        Origin.from_scope(scope),
        %{agent: agent, profile: profile, task: nil, lane: :work},
        %{kind: :design, instructions: nil, extra: %{"design_id" => design.id}}
      )

    case outcome do
      %{result: :skipped, reason: reason} ->
        {:error, reason}

      %{run_id: run_id} ->
        append!(design, %{
          role: :user,
          content: text,
          edits: design.pending_edits,
          run_id: run_id
        })

        design =
          update!(design,
            current_run_id: run_id,
            pending_edits: [],
            user_messages: design.user_messages + 1
          )

        {:ok, design}
    end
  end

  ## Stopping, discarding, changing the helper

  @doc """
  Stops the current turn (decision 10): its run is stopped as by
  `Helmsman.Runs.cancel/2`, without the run's cancel permission, and the
  conversation gets the `stopped` message and no current turn at once.
  Without a current turn: unchanged.
  """
  @spec stop_turn(Scope.t(), term()) :: {:ok, view()} | {:error, term()}
  def stop_turn(%Scope{} = scope, id) do
    locked_open(scope, id, fn scope, design ->
      case design.current_run_id do
        nil ->
          {:ok, view(scope, design)}

        run_id ->
          stop_run(run_id, scope.actor && scope.actor.id)
          append!(design, %{role: :system, code: "stopped", run_id: run_id})
          {:ok, view(scope, update!(design, current_run_id: nil))}
      end
    end)
  end

  @doc "Discards the conversation (decision 10): its turn stopped, `discarded`."
  @spec discard(Scope.t(), term()) :: {:ok, view()} | {:error, term()}
  def discard(%Scope{} = scope, id) do
    locked_open(scope, id, fn scope, design ->
      if design.current_run_id, do: stop_run(design.current_run_id, scope.actor && scope.actor.id)
      {:ok, view(scope, close!(design, :discarded))}
    end)
  end

  defp stop_run(run_id, actor_id) do
    case Repo.one(from(r in Run, where: r.id == ^run_id, lock: "FOR UPDATE")) do
      nil -> :ok
      run -> Stop.stop_locked(run, actor_id)
    end

    :ok
  end

  defp close!(design, status) do
    update!(design, status: status, current_run_id: nil, closed_at: DateTime.utc_now())
  end

  @doc """
  Makes the managed agent `name` the helper (no current turn); the
  conversation keeps its messages and draft and gets a `helper_changed`
  message. Errors as `send/3` for the new helper (`:not_found` when there
  is no such agent).
  """
  @spec change_helper(Scope.t(), term(), term()) :: {:ok, view()} | {:error, term()}
  def change_helper(%Scope{} = scope, id, name) do
    locked_open(scope, id, fn scope, design ->
      with :ok <- no_turn(design),
           {:ok, agent, profile} <- lock_helper(scope.workspace.id, name: name),
           :ok <- dispatchable(scope, agent, profile) do
        append!(design, %{role: :system, code: "helper_changed", detail: agent.name})
        {:ok, view(scope, update!(design, helper_agent_id: agent.id))}
      end
    end)
  end

  # Steps 1–2 of `Runs.enqueue/3` on the locked rows.
  defp dispatchable(scope, agent, profile) do
    with :ok <- Agents.trigger_check(scope.workspace.id, scope.user.id, agent) do
      case profile.runtime_id &&
             Repo.one(from(r in Runtime, where: r.id == ^profile.runtime_id, lock: "FOR SHARE")) do
        nil -> {:error, :no_runtime}
        %Runtime{disabled_at: nil} -> :ok
        %Runtime{} -> {:error, :runtime_disabled}
      end
    end
  end

  ## The user's draft edits

  @doc """
  Adds or changes one draft agent as the user (decision 7, 16): `attrs`
  as `propose_agent/2` (with `previous_name` to rename), `version` the
  draft version the user saw. Errors: `:turn_running`, `:stale`,
  `:draft_full`, a changeset of field errors, and those of a locked
  conversation.
  """
  @spec put_agent(Scope.t(), term(), integer(), map()) :: {:ok, view()} | {:error, term()}
  def put_agent(%Scope{} = scope, id, version, attrs) when is_map(attrs) do
    locked_open(scope, id, fn scope, design ->
      with :ok <- no_turn(design),
           :ok <- same_version(design, version),
           {:ok, draft, _entry, edit} <- Draft.put(design.draft, attrs, scope, "user") do
        previous = attrs[:previous_name] || attrs["previous_name"]
        pending = Draft.merge_edit(design.pending_edits, edit, previous)
        {:ok, view(scope, write_draft!(design, draft, pending_edits: pending))}
      end
    end)
  end

  @doc "Removes the draft agent `name` as the user; see `put_agent/4`."
  @spec remove_agent(Scope.t(), term(), integer(), term()) :: {:ok, view()} | {:error, term()}
  def remove_agent(%Scope{} = scope, id, version, name) do
    locked_open(scope, id, fn scope, design ->
      with :ok <- no_turn(design),
           :ok <- same_version(design, version),
           {:ok, draft, entry} <- Draft.remove(design.draft, name) do
        pending = Draft.merge_removal(design.pending_edits, entry["name"])
        {:ok, view(scope, write_draft!(design, draft, pending_edits: pending))}
      end
    end)
  end

  defp same_version(%AgentDesign{draft_version: version}, version), do: :ok
  defp same_version(_design, _version), do: {:error, :stale}

  defp write_draft!(design, draft, changes) do
    update!(design, [draft: draft, draft_version: design.draft_version + 1] ++ changes)
  end

  ## Confirming

  @doc """
  Creates every agent of the draft, owned by the user (decision 12), in
  one transaction: all of them or none. `{:ok, %{design: view, agents:
  [agent_view]}}`; `{:error, {:invalid, %{name => changeset}}}` with the
  errors of every invalid agent; `:empty_draft`, `:turn_running`,
  `:stale` and those of a locked conversation.
  """
  @spec confirm(Scope.t(), term(), integer()) :: {:ok, map()} | {:error, term()}
  def confirm(%Scope{} = scope, id, version),
    do: locked_open(scope, id, &confirm_locked(&1, &2, version))

  defp confirm_locked(scope, design, version) do
    agents = Draft.agents(design.draft)

    with :ok <- no_turn(design),
         :ok <- same_version(design, version),
         :ok <- if(agents == [], do: {:error, :empty_draft}, else: :ok),
         :ok <- validate_all(scope, agents),
         _ = test_hook(:confirm_validated),
         {:ok, created} <- create_all(scope, agents) do
      design =
        design
        |> close!(:confirmed)
        |> update!(created_actor_ids: Enum.map(created, & &1.actor_id))

      {:ok, %{design: view(scope, design), agents: created}}
    end
  end

  defp validate_all(scope, agents) do
    errors =
      Enum.reduce(agents, %{}, fn entry, acc ->
        case Agents.validate_new(scope, Draft.create_attrs(entry)) do
          :ok -> acc
          {:error, cs} -> Map.put(acc, entry["name"], cs)
        end
      end)

    if errors == %{}, do: :ok, else: {:error, {:invalid, errors}}
  end

  # A name taken since the check aborts the transaction: that agent's
  # errors are returned and everything rolls back.
  defp create_all(scope, agents) do
    Enum.reduce_while(agents, {:ok, []}, fn entry, {:ok, created} ->
      case Agents.insert_new(scope, Draft.create_attrs(entry)) do
        {:ok, view} ->
          {:cont, {:ok, created ++ [view]}}

        {:error, cs} ->
          {:halt, {:error, {:invalid, %{entry["name"] => AgentProfile.scrub(cs)}}}}
      end
    end)
  end

  ## Shared by the web functions

  # The write transaction of a web function on the user's own conversation
  # `id`, locked `FOR UPDATE` and `open`; notifies it after the commit.
  defp locked_open(scope, id, fun) do
    with {:ok, id} <- parse_id(id) do
      Workspaces.write_transaction(scope, :design_agents, nil, &with_open(&1, id, fun))
    end
  end

  defp with_open(scope, id, fun) do
    case Repo.one(own(scope) |> where([d], d.id == ^id) |> lock("FOR UPDATE")) do
      nil -> {:error, :not_found}
      %AgentDesign{status: :open} = design -> fun.(scope, design)
      %AgentDesign{} -> {:error, :design_closed}
    end
  end

  defp no_turn(%AgentDesign{current_run_id: nil}), do: :ok
  defp no_turn(_design), do: {:error, :turn_running}

  # Every change of a conversation goes through here: the activity time
  # and the notification after the commit.
  defp update!(%AgentDesign{id: id}, changes) do
    now = DateTime.utc_now()

    {1, [design]} =
      Repo.update_all(
        from(d in AgentDesign, where: d.id == ^id, select: d),
        set: changes ++ [last_activity_at: now, updated_at: now]
      )

    notify(id)
    design
  end

  defp append!(%AgentDesign{id: id} = design, attrs) do
    seq =
      (Repo.one(from(m in AgentDesignMessage, where: m.design_id == ^id, select: max(m.seq))) ||
         0) + 1

    message =
      struct!(
        AgentDesignMessage,
        Map.merge(attrs, %{design_id: design.id, seq: seq, inserted_at: DateTime.utc_now()})
      )

    {:ok, message} =
      Repo.insert(message,
        on_conflict: :nothing,
        conflict_target: {:unsafe_fragment, "(run_id) WHERE role <> 'user'"}
      )

    notify(id)
    message
  end

  defp notify(id),
    do: Events.after_commit_once({:agent_design, id}, topic(id), {:agent_design, id})

  ## The view

  @doc false
  # The external form (decision 4, domain-request-1 R3).
  @spec view(Scope.t(), AgentDesign.t()) :: view()
  def view(%Scope{} = scope, %AgentDesign{} = design) do
    messages =
      Repo.all(from(m in AgentDesignMessage, where: m.design_id == ^design.id, order_by: m.seq))

    run_ids = for %{role: :user, run_id: id} <- messages, is_integer(id), do: id

    current_run =
      design.current_run_id &&
        Repo.one(
          from(r in Run,
            where: r.id == ^design.current_run_id,
            select: %{id: r.id, status: r.status}
          )
        )

    created =
      Repo.all(
        from(a in Actor,
          where: a.id in ^design.created_actor_ids,
          order_by: a.name,
          select: %{name: a.name}
        )
      )

    %{
      id: design.id,
      kind: design.kind,
      status: design.status,
      helper: helper_of(scope, design.helper_agent_id),
      messages: Enum.map(messages, &message_view/1),
      current_run: current_run,
      draft: design.draft,
      draft_version: design.draft_version,
      pending_edits: design.pending_edits,
      user_messages: design.user_messages,
      usage: usage(run_ids),
      created_agents: created,
      inserted_at: design.inserted_at,
      last_activity_at: design.last_activity_at
    }
  end

  defp helper_of(scope, actor_id) do
    {actor, profile, owner_name} =
      Repo.one!(
        from(a in Actor,
          left_join: p in AgentProfile,
          on: p.actor_id == a.id,
          join: u in User,
          on: u.id == a.owner_id,
          where: a.id == ^actor_id,
          select: {a, p, u.display_name}
        )
      )

    availability =
      case Dispatch.availability(scope) do
        {:ok, map} -> map
        _forbidden -> %{}
      end

    helper_view(actor, profile, owner_name, availability)
  end

  defp message_view(%AgentDesignMessage{} = m) do
    %{
      seq: m.seq,
      role: m.role,
      content: m.content,
      edits: m.edits,
      code: m.code,
      detail: m.detail,
      run_id: m.run_id,
      inserted_at: m.inserted_at
    }
  end

  # The sum over the conversation's design runs (each user message keeps
  # its run).
  defp usage(run_ids) do
    usages = Repo.all(from(r in Run, where: r.id in ^run_ids, select: r.usage))

    Enum.reduce(
      usages,
      %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cost: 0},
      fn
        usage, acc when is_map(usage) ->
          %{
            input_tokens: acc.input_tokens + (usage["input_tokens"] || 0),
            output_tokens: acc.output_tokens + (usage["output_tokens"] || 0),
            cache_read_tokens: acc.cache_read_tokens + (usage["cache_read_tokens"] || 0),
            cost: acc.cost + (usage["cost_usd"] || 0)
          }

        _none, acc ->
          acc
      end
    )
  end

  ## The draft tools (run tokens of design runs)

  @doc """
  What `get_design` returns to the design run of `scope` (decision 7): the
  conversation's kind, user and helper, the draft and its version, the
  edits recorded with this turn's user message, the full options
  (runtimes, provider accounts, the workspace's agents) and the limits.
  Never a key or an environment value. `{:error, {:design, :not_design_run
  | :turn_ended}}` otherwise.
  """
  @spec describe(Scope.t()) :: {:ok, map()} | {:error, {:design, atom()}}
  def describe(%Scope{} = scope) do
    with :ok <- design_gate(scope),
         {:ok, design} <- design_of_run(scope.run) do
      user = Repo.get!(User, design.user_id)
      helper = Repo.get!(Actor, design.helper_agent_id)

      edits =
        Repo.one(
          from(m in AgentDesignMessage,
            where: m.design_id == ^design.id and m.role == :user and m.run_id == ^scope.run.id,
            select: m.edits
          )
        )

      {:ok,
       %{
         kind: Atom.to_string(design.kind),
         user: user.display_name,
         helper: helper.name,
         draft: design.draft,
         draft_version: design.draft_version,
         user_edits: edits || [],
         user_edits_text: Prompt.edits_text(edits),
         options: %{
           runtimes: Options.runtimes(design.workspace_id, design.user_id),
           provider_accounts: Options.accounts(design.user_id),
           agents: Options.agents(design.workspace_id)
         },
         limits: %{max_agents: Draft.max_agents(), field_rules: Options.rules()}
       }}
    end
  end

  @doc """
  The draft tool `propose_agent` (decision 7): adds or patches one agent
  as `Draft.put/4` does, written by the helper, checked for the
  conversation's user. The conversation is locked and checked again
  (still `open`, still this run's turn) in the transaction of the write.
  `{:ok, %{agent: entry, draft_version: n, warnings: [text]}}` (a warning
  when the bound runtime is offline). Errors: `{:design, …}`,
  `:draft_full`, `{:invalid_agent, name, changeset}`, `:run_ended`.
  """
  @spec propose_agent(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def propose_agent(%Scope{} = scope, attrs) when is_map(attrs) do
    draft_write(scope, fn design, user_scope ->
      case Draft.put(design.draft, attrs, user_scope, "ai") do
        {:ok, draft, entry, _edit} ->
          {:ok, design, draft, %{agent: entry, warnings: warnings(entry)}}

        {:error, %Ecto.Changeset{} = cs} ->
          {:error, {:invalid_agent, attrs["name"] || attrs[:name], cs}}

        error ->
          error
      end
    end)
  end

  @doc """
  The draft tool `withdraw_agent` (decision 7): removes the agent `name`
  from the draft. `{:ok, %{removed: name, draft_version: n}}`; `{:error,
  {:not_in_draft, name}}` and the errors of `propose_agent/2`.
  """
  @spec withdraw_agent(Scope.t(), term()) :: {:ok, map()} | {:error, term()}
  def withdraw_agent(%Scope{} = scope, name) do
    draft_write(scope, fn design, _user_scope ->
      case Draft.remove(design.draft, name) do
        {:ok, draft, entry} -> {:ok, design, draft, %{removed: entry["name"]}}
        {:error, :not_found} -> {:error, {:not_in_draft, name}}
      end
    end)
  end

  # The entry check, then the write's own check under the conversation's
  # lock: a request that passed the first while the turn was stopped,
  # discarded or replaced is refused by the second (decision 7).
  defp draft_write(scope, fun) do
    with :ok <- design_gate(scope),
         {:ok, snapshot} <- design_of_run(scope.run) do
      test_hook(:design_entry_checked)
      Tx.run(fn -> draft_write_locked(scope, snapshot, fun) end)
    end
  end

  defp draft_write_locked(scope, snapshot, fun) do
    Locks.maint_shared!(snapshot.workspace_id)
    design = Repo.one!(from(d in AgentDesign, where: d.id == ^snapshot.id, lock: "FOR UPDATE"))

    with :ok <- still_turn(design, scope.run),
         {:ok, design, draft, result} <- fun.(design, user_scope(design)),
         :ok <- RunTokens.lock_active(scope) do
      design = update!(design, draft: draft, draft_version: design.draft_version + 1)
      {:ok, Map.put(result, :draft_version, design.draft_version)}
    end
  end

  defp design_gate(scope) do
    case Policy.authorize(scope, :design) do
      :ok -> :ok
      {:error, :forbidden} -> {:error, {:design, :not_design_run}}
    end
  end

  defp design_of_run(%Run{id: run_id}) do
    case Repo.one(
           from(d in AgentDesign, where: d.current_run_id == ^run_id and d.status == :open)
         ) do
      nil -> {:error, {:design, :turn_ended}}
      design -> {:ok, design}
    end
  end

  defp still_turn(%AgentDesign{status: :open, current_run_id: id}, %Run{id: id}), do: :ok
  defp still_turn(_design, _run), do: {:error, {:design, :turn_ended}}

  # The conversation's user, for the checks of `Agents.validate_new/2`.
  defp user_scope(design) do
    %Scope{
      user: Repo.get!(User, design.user_id),
      workspace: Repo.get!(Workspace, design.workspace_id),
      via: :web
    }
  end

  defp warnings(%{"runtime_id" => id}) when is_integer(id) do
    case Repo.one(
           from(r in Runtime,
             join: d in assoc(r, :daemon),
             where: r.id == ^id,
             select: {r.status, d.name}
           )
         ) do
      {"online", _name} ->
        []

      {_status, name} ->
        ["runtime #{id} (#{name}) is offline; runs will queue until it is online"]

      nil ->
        []
    end
  end

  defp warnings(_entry), do: []

  ## The run side

  @doc """
  Whether the design run `run` is still the turn of an open conversation,
  read without a lock (decision 10): `:current` or `:ended`; nil for any
  other run. Claiming and starting refuse an `:ended` one as obsolete.
  """
  @spec turn_state(Run.t()) :: :current | :ended | nil
  def turn_state(%Run{} = run) do
    case Runs.design_run?(run) && Runs.design_id(run) do
      false ->
        nil

      nil ->
        :ended

      design_id ->
        current? =
          Repo.exists?(
            from(d in AgentDesign,
              where: d.id == ^design_id and d.status == :open and d.current_run_id == ^run.id
            )
          )

        if current?, do: :current, else: :ended
    end
  end

  @doc """
  Settles the ended design run `run_id` (decision 9): when it is still
  the turn of its conversation, the reply (its last output), or a system
  message (`no_reply`, `failed` with its reason, `cancelled`), and no
  current turn. Idempotent. Returns `{:ok, :settled | :skipped}`.
  """
  @spec settle(pos_integer()) :: {:ok, :settled | :skipped}
  def settle(run_id) do
    Tx.run(fn ->
      design =
        Repo.one(from(d in AgentDesign, where: d.current_run_id == ^run_id, lock: "FOR UPDATE"))

      run = design && Repo.get(Run, run_id)

      if run && run.status in Run.ended_statuses() do
        append!(design, settled_message(run))
        update!(design, current_run_id: nil)
        {:ok, :settled}
      else
        {:ok, :skipped}
      end
    end)
  end

  defp settled_message(%Run{id: id, status: :succeeded, summary: summary}) do
    if is_binary(summary) and String.trim(summary) != "",
      do: %{role: :assistant, content: summary, run_id: id},
      else: %{role: :system, code: "no_reply", run_id: id}
  end

  defp settled_message(%Run{id: id, status: :failed, failure_reason: reason}),
    do: %{role: :system, code: "failed", detail: reason && Atom.to_string(reason), run_id: id}

  defp settled_message(%Run{id: id, failure_reason: reason}),
    do: %{role: :system, code: "cancelled", detail: reason && Atom.to_string(reason), run_id: id}

  @doc """
  The minute check (decision 10): the turns still `queued`
  #{@queue_timeout_seconds} seconds after their run was created are
  cancelled (`obsolete`) with a `queue_timeout` message. Returns how many.
  """
  @spec sweep_queued() :: non_neg_integer()
  def sweep_queued do
    cutoff = DateTime.add(DateTime.utc_now(), -@queue_timeout_seconds, :second)

    from(d in AgentDesign,
      join: r in Run,
      on: r.id == d.current_run_id,
      where: d.status == :open and r.status == :queued and r.inserted_at < ^cutoff,
      select: {d.id, r.id}
    )
    |> Repo.all()
    |> Enum.count(fn {design_id, run_id} -> queue_timeout(design_id, run_id) end)
  end

  defp queue_timeout(design_id, run_id) do
    {:ok, done?} =
      Tx.run(fn ->
        design =
          Repo.one(
            from(d in AgentDesign,
              where: d.id == ^design_id and d.current_run_id == ^run_id and d.status == :open,
              lock: "FOR UPDATE"
            )
          )

        with %AgentDesign{} <- design,
             1 <- Runs.cancel_pending(from(r in Run, where: r.id == ^run_id), :obsolete) do
          append!(design, %{role: :system, code: "queue_timeout", run_id: run_id})
          update!(design, current_run_id: nil)
          {:ok, true}
        else
          _ -> {:ok, false}
        end
      end)

    done?
  end

  @doc """
  The hourly check (decision 10): `open` conversations idle for
  #{@idle_days} days, or whose user is no longer a member or above of the
  workspace, are `expired` (their turn stopped); conversations closed over
  #{@retention_days} days ago are deleted with their messages (their
  design runs stay). Returns `%{expired: n, deleted: n}`.
  """
  @spec expire() :: %{expired: non_neg_integer(), deleted: non_neg_integer()}
  def expire do
    now = DateTime.utc_now()
    idle = DateTime.add(now, -@idle_days * 86_400, :second)
    retention = DateTime.add(now, -@retention_days * 86_400, :second)

    expired =
      from(d in AgentDesign,
        left_join: m in Membership,
        on: m.workspace_id == d.workspace_id and m.user_id == d.user_id,
        where: d.status == :open,
        where: d.last_activity_at < ^idle or is_nil(m.id) or m.role not in ^@member_roles,
        select: d.id
      )
      |> Repo.all()
      |> Enum.count(&expire_one(&1, idle))

    {deleted, _} =
      Repo.delete_all(
        from(d in AgentDesign, where: d.status != :open and d.closed_at < ^retention)
      )

    %{expired: expired, deleted: deleted}
  end

  defp expire_one(id, idle) do
    {:ok, done?} = Tx.run(fn -> {:ok, expire_locked(id, idle)} end)
    done?
  end

  defp expire_locked(id, idle) do
    design = Repo.one(from(d in AgentDesign, where: d.id == ^id, lock: "FOR UPDATE"))

    if design && design.status == :open && expirable?(design, idle) do
      if design.current_run_id, do: stop_run(design.current_run_id, nil)
      close!(design, :expired)
      true
    else
      false
    end
  end

  defp expirable?(design, idle) do
    role =
      Repo.one(
        from(m in Membership,
          where: m.workspace_id == ^design.workspace_id and m.user_id == ^design.user_id,
          select: m.role
        )
      )

    DateTime.compare(design.last_activity_at, idle) == :lt or role not in @member_roles
  end

  # Fault injection for the concurrency tests: compiled in the test
  # environment only.
  if Mix.env() == :test do
    defp test_hook(point) do
      case Process.get(:helmsman_test_hook) do
        hook when is_function(hook, 1) -> hook.(point)
        _ -> :ok
      end
    end
  else
    defp test_hook(_point), do: :ok
  end
end
