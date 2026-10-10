defmodule Helmsman.ApiTokens do
  @moduledoc """
  API tokens (designs/03 §2): issuing, listing, revoking and authenticating
  the `hm_` tokens external agents, scripts and CI use to act as a user in
  one workspace over MCP or REST.

  Tokens are checked against the database on every request (revocation,
  expiry, membership and role take effect immediately); only the SHA-256
  hash and an 8-character prefix are stored.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.ApiTokens.ApiToken
  alias Helmsman.Policy
  alias Helmsman.RateLimit
  alias Helmsman.Repo
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.{Membership, Workspace}

  @token_prefix "hm_"
  @random_bytes 32
  # Unpadded base32 of 32 bytes.
  @random_length 52
  @token_length byte_size(@token_prefix) + @random_length
  @prefix_length 8
  @scopes ApiToken.scopes()

  @rate_window_ms 60_000
  @default_rate_limit 600
  @touch_interval_s 60

  @type authenticated :: %{
          token: ApiToken.t(),
          user: User.t(),
          workspace: Workspace.t(),
          role: Membership.role()
        }

  ## Issuing

  @doc """
  Creates an API token for the scope's user in the scope's workspace
  (`:create_token`, member and above; never agents).

  `attrs`: `name` (1-64 characters), `scopes` (one or more of
  #{Enum.map_join(ApiToken.scopes(), ", ", &"`#{&1}`")}), optional
  `expires_at` and `default_agent_id` (an active agent the user owns).

  Returns the plaintext token, which is never available again, with the
  stored record.
  """
  @spec create(Scope.t(), map()) ::
          {:ok, %{token: String.t(), api_token: ApiToken.t()}}
          | {:error, Ecto.Changeset.t() | :forbidden | :not_found | atom()}
  def create(%Scope{} = scope, attrs) do
    Workspaces.write_transaction(scope, :create_token, nil, fn scope ->
      token = generate_token()

      changeset =
        %ApiToken{
          workspace_id: scope.workspace.id,
          user_id: scope.user.id,
          token_hash: hash_token(token),
          prefix: binary_part(token, byte_size(@token_prefix), @prefix_length)
        }
        |> ApiToken.create_changeset(attrs)
        |> validate_default_agent(scope)

      with {:ok, api_token} <- Repo.insert(changeset) do
        {:ok, %{token: token, api_token: api_token}}
      end
    end)
  end

  defp generate_token do
    random =
      @random_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.encode32(case: :lower, padding: false)

    @token_prefix <> random
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)

  defp validate_default_agent(changeset, scope) do
    case Ecto.Changeset.get_change(changeset, :default_agent_id) do
      nil ->
        changeset

      agent_id ->
        if own_active_agent?(scope, agent_id),
          do: changeset,
          else:
            Ecto.Changeset.add_error(
              changeset,
              :default_agent_id,
              "must be an active agent of your own"
            )
    end
  end

  defp own_active_agent?(scope, agent_id) do
    from(a in Actor,
      where: a.workspace_id == ^scope.workspace.id and a.id == ^agent_id,
      where: a.kind == :agent and a.owner_id == ^scope.user.id and is_nil(a.disabled_at),
      lock: "FOR SHARE"
    )
    |> Repo.exists?()
  end

  ## Listing

  @doc """
  Lists the scope user's own tokens in the workspace, newest first, with
  the default agent preloaded (`:list_own_tokens`, every role).
  """
  @spec list_own(Scope.t()) :: {:ok, [ApiToken.t()]} | {:error, :forbidden}
  def list_own(%Scope{workspace: %Workspace{id: workspace_id}, user: %User{id: user_id}} = scope) do
    with :ok <- Policy.authorize(scope, :list_own_tokens) do
      {:ok,
       workspace_id
       |> tokens_query()
       |> where([t], t.user_id == ^user_id)
       |> preload(:default_agent)
       |> Repo.all()}
    end
  end

  @doc """
  Lists every token in the workspace, newest first, with the user and the
  default agent preloaded (`:list_all_tokens`, admin and above).
  """
  @spec list_all(Scope.t()) :: {:ok, [ApiToken.t()]} | {:error, :forbidden}
  def list_all(%Scope{workspace: %Workspace{id: workspace_id}} = scope) do
    with :ok <- Policy.authorize(scope, :list_all_tokens) do
      {:ok, workspace_id |> tokens_query() |> preload([:user, :default_agent]) |> Repo.all()}
    end
  end

  defp tokens_query(workspace_id) do
    from(t in ApiToken,
      where: t.workspace_id == ^workspace_id,
      order_by: [desc: t.inserted_at, desc: t.id]
    )
  end

  ## Revoking

  @doc """
  Revokes a token of the workspace. One's own token is
  `:revoke_own_token` (every role, viewers included); anyone else's is
  `:revoke_any_token` (admin and above). Revoking an already revoked token
  returns it unchanged.
  """
  @spec revoke(Scope.t(), pos_integer() | String.t()) ::
          {:ok, ApiToken.t()} | {:error, :forbidden | :not_found | atom()}
  def revoke(%Scope{workspace: %Workspace{id: workspace_id}} = scope, token_id) do
    with {:ok, id} <- cast_id(token_id),
         %ApiToken{} = token <- Repo.get_by(ApiToken, workspace_id: workspace_id, id: id) do
      action = if token.user_id == scope.user.id, do: :revoke_own_token, else: :revoke_any_token
      Workspaces.write_transaction(scope, action, token, &revoke_locked(&1, token))
    else
      _ -> {:error, :not_found}
    end
  end

  defp cast_id(id) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} when is_integer(id) -> {:ok, id}
      _ -> :error
    end
  end

  defp revoke_locked(scope, token) do
    query =
      from(t in ApiToken,
        where: t.workspace_id == ^scope.workspace.id and t.id == ^token.id,
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      %ApiToken{revoked_at: nil} = current ->
        current |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second)) |> Repo.update()

      revoked ->
        {:ok, revoked}
    end
  end

  ## Authenticating

  @doc """
  Authenticates a plaintext `hm_` token for an endpoint requiring
  `required_scope`.

  Looks the token up by hash on every call: it must exist, be neither
  revoked nor expired, and its user must still be a member of its
  workspace; the role returned is the current one. Returns
  `{:error, :unauthorized}` otherwise, and `{:error, :insufficient_scope}`
  for a valid token without `required_scope`.
  """
  @spec authenticate(String.t(), ApiToken.scope()) ::
          {:ok, authenticated()} | {:error, :unauthorized | :insufficient_scope}
  def authenticate(token, required_scope) when is_binary(token) and required_scope in @scopes do
    with true <- well_formed?(token),
         %{token: api_token} = found <- Repo.one(authenticate_query(hash_token(token))) do
      if required_scope in api_token.scopes,
        do: {:ok, found},
        else: {:error, :insufficient_scope}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp well_formed?(@token_prefix <> _ = token), do: byte_size(token) == @token_length
  defp well_formed?(_token), do: false

  defp authenticate_query(hash) do
    now = DateTime.utc_now()

    from(t in ApiToken,
      join: u in User,
      on: u.id == t.user_id,
      join: m in Membership,
      on: m.workspace_id == t.workspace_id and m.user_id == t.user_id,
      join: w in Workspace,
      on: w.id == t.workspace_id,
      where: t.token_hash == ^hash and is_nil(t.revoked_at),
      where: is_nil(t.expires_at) or t.expires_at > ^now,
      select: %{token: t, user: u, workspace: w, role: m.role}
    )
  end

  @doc """
  Counts one request against the token's rate limit
  (`config :helmsman, :api_token_rate_limit` requests per minute, default
  #{@default_rate_limit}). Over the limit returns the seconds until the
  window resets (at least 1).
  """
  @spec check_rate_limit(ApiToken.t()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check_rate_limit(%ApiToken{id: id}) do
    limit = Application.get_env(:helmsman, :api_token_rate_limit, @default_rate_limit)

    case RateLimit.hit({:api_token, id}, @rate_window_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:error, {:rate_limited, max(1, ceil(retry_after_ms / 1000))}}
    end
  end

  @doc """
  Records that the token was used, writing to the database at most once a
  minute per token.

  The node-local limiter skips the query for most requests; the condition
  on `last_used_at` keeps the once-a-minute guarantee across limiter
  windows.
  """
  @spec touch_last_used(ApiToken.t()) :: :ok
  def touch_last_used(%ApiToken{id: id}) do
    case RateLimit.hit({:api_token_touch, id}, @touch_interval_s * 1000, 1) do
      {:allow, _count} ->
        now = DateTime.utc_now(:second)
        stale = DateTime.add(now, -@touch_interval_s)

        Repo.update_all(
          from(t in ApiToken,
            where: t.id == ^id,
            where: is_nil(t.last_used_at) or t.last_used_at <= ^stale
          ),
          set: [last_used_at: now]
        )

        :ok

      {:deny, _retry_after} ->
        :ok
    end
  end
end
