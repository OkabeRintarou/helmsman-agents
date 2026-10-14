defmodule Helmsman.ProviderAccounts do
  @moduledoc """
  A user's provider accounts (`add-provider-accounts` decision 3).

  Every function first authorizes `:manage_provider_accounts`, which only
  the user's own web session passes (never an API token, a run or an
  agent); refused, it reads, writes and broadcasts nothing. It then only
  sees `scope.user`'s accounts: another user's account is `:not_found`,
  like one that does not exist. Accounts belong to no workspace.

  The API key is write-only: views only say `api_key_set`. It is read in
  one place, the claim of a run (`Helmsman.Runs.Spec`), never here.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.{Events, Policy, Repo, Tx}
  alias Helmsman.ProviderAccounts.ProviderAccount
  alias Helmsman.Workspaces.Workspace

  @max_accounts 32

  @type agent_ref :: %{workspace_slug: String.t(), name: String.t()}
  @type view :: %{
          id: pos_integer(),
          name: String.t(),
          cli: String.t(),
          base_url: String.t(),
          models: %{String.t() => String.t()},
          headers: [String.t()],
          icon: String.t() | nil,
          api_key_set: boolean(),
          agents: [agent_ref()],
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
  @type option :: %{
          id: pos_integer(),
          name: String.t(),
          base_url: String.t(),
          models: %{String.t() => String.t()},
          headers: [String.t()],
          icon: String.t() | nil
        }

  @doc "The most provider accounts a user may have."
  @spec max_accounts() :: pos_integer()
  def max_accounts, do: @max_accounts

  @doc "The PubSub topic of `user_id`'s provider accounts."
  @spec topic(pos_integer()) :: String.t()
  def topic(user_id), do: Events.topic(:provider_accounts, user_id)

  @doc "The user's accounts, by name, with the unarchived agents bound to each."
  @spec list(Scope.t()) :: {:ok, [view()]} | {:error, :forbidden}
  def list(scope) do
    with :ok <- authorize(scope) do
      accounts =
        Repo.all(from(a in ProviderAccount, where: a.user_id == ^scope.user.id, order_by: a.name))

      {:ok, views(accounts)}
    end
  end

  @doc "The user's account `id`."
  @spec get(Scope.t(), term()) :: {:ok, view()} | {:error, :forbidden | :not_found}
  def get(scope, id) do
    with :ok <- authorize(scope),
         %ProviderAccount{} = account <- own(scope, id) do
      {:ok, hd(views([account]))}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Creates an account for the user. At most #{@max_accounts}: the user row
  is locked first, so concurrent creations are counted one after the
  other (`{:error, :limit_reached}`).
  """
  @spec create(Scope.t(), map()) ::
          {:ok, view()} | {:error, :forbidden | :limit_reached | Ecto.Changeset.t()}
  def create(scope, attrs) when is_map(attrs) do
    with :ok <- authorize(scope) do
      fn -> insert(scope.user.id, attrs) end |> Tx.run() |> scrub()
    end
  end

  # Ecto SQL logs cast_params, before Cloak encrypts them; schema redact:
  # true and Phoenix parameter filters cannot protect these query logs.
  # Suppress both account writes, including writes rejected by constraints.
  defp insert(user_id, attrs) do
    Repo.one!(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE", select: u.id))
    count = Repo.aggregate(from(a in ProviderAccount, where: a.user_id == ^user_id), :count)

    with :ok <- below_limit(count),
         {:ok, account} <-
           %ProviderAccount{user_id: user_id}
           |> ProviderAccount.changeset(attrs)
           |> Repo.insert(log: false) do
      notify(user_id)
      {:ok, hd(views([account]))}
    end
  end

  defp below_limit(count) when count < @max_accounts, do: :ok
  defp below_limit(_count), do: {:error, :limit_reached}

  @doc """
  Updates the account `id`. A missing or empty `api_key` keeps the stored
  key. Notifies the user and every workspace with an agent bound to it.
  """
  @spec update(Scope.t(), term(), map()) ::
          {:ok, view()} | {:error, :forbidden | :not_found | Ecto.Changeset.t()}
  def update(scope, id, attrs) when is_map(attrs) do
    with :ok <- authorize(scope) do
      fn -> modify(scope, id, attrs) end |> Tx.run() |> scrub()
    end
  end

  defp modify(scope, id, attrs) do
    with %ProviderAccount{} = account <- own(scope, id, :lock),
         {:ok, account} <- account |> ProviderAccount.changeset(attrs) |> Repo.update(log: false) do
      notify(account.user_id)
      Enum.each(bound_workspace_ids(account.id), &notify_agents/1)
      {:ok, hd(views([account]))}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  A changeset for the account form: `account` is a view of the user's own
  account (`get/2`) or nil for a new one. Reads nothing and never holds
  the key.
  """
  @spec change(Scope.t(), view() | nil, map()) ::
          {:ok, Ecto.Changeset.t()} | {:error, :forbidden}
  def change(scope, account, attrs \\ %{}) do
    with :ok <- authorize(scope) do
      {:ok, account |> form_data(scope) |> ProviderAccount.changeset(attrs) |> scrub_changeset()}
    end
  end

  # A stand-in key so that an existing account's form does not ask for one;
  # removed by `scrub_changeset/1`.
  defp form_data(nil, scope), do: %ProviderAccount{user_id: scope.user.id}

  defp form_data(%{id: id} = view, scope) do
    %ProviderAccount{
      id: id,
      user_id: scope.user.id,
      name: view.name,
      cli: view.cli,
      base_url: view.base_url,
      models: view.models,
      api_key: "set",
      icon: view.icon,
      header_names: view.headers,
      headers: JSON.encode!(Enum.map(view.headers, &%{"name" => &1, "value" => "set"}))
    }
  end

  @doc """
  Deletes the account `id`. Refused while unarchived agents are bound to
  it (`{:in_use, agents}`); archived agents bound to it lose the binding.
  Runs that used it keep no account.
  """
  @spec delete(Scope.t(), term()) ::
          :ok | {:error, :forbidden | :not_found | {:in_use, [agent_ref()]}}
  def delete(scope, id) do
    with :ok <- authorize(scope),
         {:ok, :deleted} <- Tx.run(fn -> remove(scope, id) end) do
      :ok
    end
  end

  # The account row FOR UPDATE first: a concurrent binding (FOR SHARE in
  # `AgentProfile.changeset/3`) either committed and is seen here, or
  # waits and then finds no account.
  defp remove(scope, id) do
    with %ProviderAccount{} = account <- own(scope, id, :lock),
         [] <- Map.get(bound_agents([account.id]), account.id, []) do
      Repo.update_all(
        from(p in AgentProfile,
          where: p.provider_account_id == ^account.id and not is_nil(p.archived_at)
        ),
        set: [provider_account_id: nil]
      )

      Repo.delete!(account)
      notify(account.user_id)
      {:ok, :deleted}
    else
      nil -> {:error, :not_found}
      agents when is_list(agents) -> {:error, {:in_use, agents}}
    end
  end

  @doc "The user's accounts for `cli` (`claude` or `codex`), for the agent form."
  @spec options(Scope.t(), String.t() | atom()) :: {:ok, [option()]} | {:error, :forbidden}
  def options(scope, cli) do
    with :ok <- authorize(scope) do
      cli = to_string(cli)

      {:ok,
       Repo.all(
         from(a in ProviderAccount,
           where: a.user_id == ^scope.user.id and a.cli == ^cli,
           order_by: a.name,
           select: %{
             id: a.id,
             name: a.name,
             base_url: a.base_url,
             models: a.models,
             headers: a.header_names,
             icon: a.icon
           }
         )
       )}
    end
  end

  @type summary :: %{
          id: pos_integer(),
          name: String.t(),
          cli: String.t(),
          host: String.t() | nil,
          port: pos_integer() | nil,
          headers: [String.t()],
          icon: String.t() | nil
        }

  @doc """
  The summaries of the accounts `ids`, by id, in one query: what any
  reader of an agent or run bound to them sees (`add-provider-accounts`
  decision 14; `port` and `icon` from `add-actor-avatars` decision 19).
  Never the key, the full address or the header values; `port` only when
  the address writes one. No authorization: callers have authorized
  reading the agent or run.
  """
  @spec summaries([pos_integer()]) :: %{pos_integer() => summary()}
  def summaries([]), do: %{}

  def summaries(ids) when is_list(ids) do
    Repo.all(
      from(a in ProviderAccount,
        where: a.id in ^Enum.uniq(ids),
        select: {a.id, a.name, a.cli, a.base_url, a.header_names, a.icon}
      )
    )
    |> Map.new(fn {id, name, cli, base_url, headers, icon} ->
      uri = URI.parse(base_url)

      {id,
       %{
         id: id,
         name: name,
         cli: cli,
         host: uri.host,
         port: explicit_port(base_url, uri),
         headers: headers,
         icon: icon
       }}
    end)
  end

  # URI.parse/1 fills in the scheme's default port; only a port written in
  # the address counts. Addresses never carry credentials (validated).
  defp explicit_port(base_url, %URI{port: port}) when is_integer(port) do
    if Regex.match?(~r{\A[a-z][a-z0-9+.-]*://[^/?#]*:\d+(?:[/?#]|\z)}i, base_url),
      do: port,
      else: nil
  end

  defp explicit_port(_base_url, _uri), do: nil

  defp authorize(scope), do: Policy.authorize(scope, :manage_provider_accounts)

  defp own(scope, id, row_lock \\ false) do
    case parse_id(id) do
      nil ->
        nil

      id ->
        query =
          from(a in ProviderAccount, where: a.id == ^id and a.user_id == ^scope.user.id)

        Repo.one(if row_lock, do: lock(query, "FOR UPDATE"), else: query)
    end
  end

  defp parse_id(id) when is_integer(id) and id > 0, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil

  # Two queries whatever the number of accounts.
  defp views(accounts) do
    agents = bound_agents(Enum.map(accounts, & &1.id))

    Enum.map(accounts, fn account ->
      %{
        id: account.id,
        name: account.name,
        cli: account.cli,
        base_url: account.base_url,
        models: account.models || %{},
        headers: account.header_names,
        icon: account.icon,
        api_key_set: true,
        agents: Map.get(agents, account.id, []),
        inserted_at: account.inserted_at,
        updated_at: account.updated_at
      }
    end)
  end

  # The unarchived agents bound to each account, also in workspaces the
  # user has left: they are still the user's and block a deletion.
  defp bound_agents([]), do: %{}

  defp bound_agents(ids) do
    Repo.all(
      from(p in AgentProfile,
        join: a in Actor,
        on: a.id == p.actor_id,
        join: w in Workspace,
        on: w.id == p.workspace_id,
        where: p.provider_account_id in ^ids and is_nil(p.archived_at),
        order_by: [w.slug, a.name],
        select: {p.provider_account_id, %{workspace_slug: w.slug, name: a.name}}
      )
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp bound_workspace_ids(account_id) do
    Repo.all(
      from(p in AgentProfile,
        where: p.provider_account_id == ^account_id,
        distinct: true,
        select: p.workspace_id
      )
    )
  end

  defp notify(user_id), do: Events.after_commit(topic(user_id), {:provider_accounts_changed})

  defp notify_agents(workspace_id),
    do: Events.after_commit(Events.topic(:workspace, workspace_id), {:agents_changed})

  defp scrub({:error, %Ecto.Changeset{} = cs}), do: {:error, scrub_changeset(cs)}
  defp scrub(result), do: result

  defp scrub_changeset(cs), do: ProviderAccount.scrub(cs)
end
