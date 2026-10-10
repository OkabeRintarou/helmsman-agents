defmodule Helmsman.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Helmsman.Repo

  alias Helmsman.Accounts.{SignupGate, User, UserNotifier, UserToken}
  alias Helmsman.Locks
  alias Helmsman.RateLimit
  alias Helmsman.Tx
  alias Helmsman.Workspaces

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Authenticates a user by email and password on behalf of a client `ip`.

  Every attempt counts against the per-IP password rate limit.
  """
  @spec login_user_by_password(String.t(), String.t(), :inet.ip_address() | nil) ::
          {:ok, User.t()} | {:error, :invalid_credentials | :rate_limited}
  def login_user_by_password(email, password, ip)
      when is_binary(email) and is_binary(password) do
    with :ok <- RateLimit.check(:password_ip, RateLimit.ip_key(ip)) do
      case get_user_by_email_and_password(email, password) do
        %User{} = user -> {:ok, user}
        nil -> {:error, :invalid_credentials}
      end
    end
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Returns the configured signup mode, `:invite` (default) or `:open`.
  """
  @spec signup_mode() :: :invite | :open
  def signup_mode, do: Application.get_env(:helmsman, :signup_mode, :invite)

  @doc """
  Returns true when anyone may register without an invitation: the signup
  mode is `:open` or the instance has no users yet.
  """
  @spec registration_open?() :: boolean()
  def registration_open? do
    signup_mode() == :open or not Repo.exists?(User)
  end

  @doc """
  Registers a user.

  The first user of the instance is always allowed and becomes the instance
  administrator and the owner of the workspace `default`. Later users are
  allowed in `:open` signup mode; in `:invite` mode
  `Helmsman.Accounts.SignupGate.allow?/1` decides. The decision runs in one
  transaction serialized by a global advisory lock.

  ## Options

    * `:ip` - client IP; when given, the submission counts against the
      per-IP registration rate limit (successful or not).
    * `:skip_signup_gate` - allow the registration whatever the signup mode
      (command-line bootstrap).
    * `:skip_default_workspace` - do not create the `default` workspace for
      the first user (command-line bootstrap).

  Other options, such as `:invitation_token`, are passed to
  `Helmsman.Accounts.SignupGate.allow?/1` together with `:email`, the
  normalized registration email (a caller's `:email` is overwritten).

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

      iex> register_user(%{field: value})
      {:error, :signup_closed}

  """
  @spec register_user(map(), keyword()) ::
          {:ok, User.t()}
          | {:error, Ecto.Changeset.t() | :signup_closed | :rate_limited}
  def register_user(attrs, opts \\ []) do
    with :ok <- check_register_rate(opts) do
      Tx.run(fn -> register_user_locked(attrs, opts) end)
    end
  end

  # Runs inside the registration transaction.
  defp register_user_locked(attrs, opts) do
    Locks.registration!()
    user_count = Repo.aggregate(User, :count)
    race_delay()

    changeset = User.registration_changeset(%User{}, attrs)
    opts = Keyword.put(opts, :email, normalized_email(changeset))

    with {:ok, instance_admin?} <- signup_decision(user_count, opts),
         {:ok, user} <-
           changeset
           |> Ecto.Changeset.put_change(:instance_admin, instance_admin?)
           |> Repo.insert(),
         {:ok, _workspace} <- maybe_create_default_workspace(user, opts) do
      {:ok, user}
    end
  end

  defp maybe_create_default_workspace(%User{instance_admin: true} = user, opts) do
    if Keyword.get(opts, :skip_default_workspace, false) do
      {:ok, nil}
    else
      Workspaces.create_in_transaction(user, %{slug: "default", name: "Default"})
    end
  end

  defp maybe_create_default_workspace(_user, _opts), do: {:ok, nil}

  defp check_register_rate(opts) do
    case Keyword.fetch(opts, :ip) do
      {:ok, ip} -> RateLimit.check(:register_ip, RateLimit.ip_key(ip))
      :error -> :ok
    end
  end

  defp signup_decision(0, _opts), do: {:ok, true}

  defp signup_decision(_count, opts) do
    cond do
      Keyword.get(opts, :skip_signup_gate, false) -> {:ok, false}
      signup_mode() == :open -> {:ok, false}
      true -> with :ok <- SignupGate.allow?(opts), do: {:ok, false}
    end
  end

  defp normalized_email(changeset) do
    case Ecto.Changeset.get_field(changeset, :email) do
      email when is_binary(email) -> email |> String.trim() |> String.downcase()
      _ -> nil
    end
  end

  # Test-only hook that widens the window between counting users and
  # inserting, so the first-user race test fails without the lock.
  defp race_delay do
    case Application.get_env(:helmsman, :registration_race_delay_ms, 0) do
      0 -> :ok
      ms -> Process.sleep(ms)
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking registration changes.

  See `Helmsman.Accounts.User.registration_changeset/3` for a list of supported options.
  """
  def change_user_registration(user, attrs \\ %{}, opts \\ []) do
    User.registration_changeset(user, attrs, opts)
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user display name.
  """
  def change_user_display_name(user, attrs \\ %{}) do
    User.display_name_changeset(user, attrs)
  end

  @doc """
  Updates the user display name. Does not require sudo mode.
  """
  @spec update_user_display_name(User.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_display_name(%User{} = user, attrs) do
    user
    |> User.display_name_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Helmsman.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Helmsman.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.

  The token is consumed in a transaction that first locks the user row and
  then verifies the token again, so concurrent requests with the user's
  links succeed at most once. Malformed tokens return `{:error, :not_found}`
  like unknown ones.
  """
  def login_user_by_magic_link(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {%User{id: user_id}, _token} <- Repo.one(query) do
      Repo.transact(fn -> consume_magic_link(query, user_id) end)
    else
      _ -> {:error, :not_found}
    end
  end

  def login_user_by_magic_link(_token), do: {:error, :not_found}

  # Lock order is the user row, then its tokens, the same as every other path
  # that deletes a user's tokens (they update the user first). Everything that
  # consumes this user's login tokens holds the user lock, so re-running the
  # unlocked token query here sees the current state.
  defp consume_magic_link(query, user_id) do
    case Repo.one(from(u in User, where: u.id == ^user_id, select: u.id, lock: "FOR UPDATE")) do
      nil -> {:error, :not_found}
      ^user_id -> verify_and_consume_magic_link(query)
    end
  end

  defp verify_and_consume_magic_link(query) do
    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Requests a magic link for `email` on behalf of a client `ip`.

  The email is normalized (trimmed, downcased) and counted against the
  per-IP and per-email rate limits before the user is looked up, so the
  result never reveals whether the email is registered: `:ok` is returned
  whether or not an email was sent.
  """
  @spec request_login_link(String.t(), :inet.ip_address() | nil, (String.t() -> String.t())) ::
          :ok | {:error, :rate_limited}
  def request_login_link(email, ip, magic_link_url_fun)
      when is_binary(email) and is_function(magic_link_url_fun, 1) do
    email = email |> String.trim() |> String.downcase()

    with :ok <- RateLimit.check(:magic_link_ip, RateLimit.ip_key(ip)),
         :ok <- RateLimit.check(:magic_link_email, email) do
      if user = get_user_by_email(email) do
        _ = deliver_login_instructions(user, magic_link_url_fun)
      end

      :ok
    end
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Generates a magic link login token for `user` without sending an email
  (command-line bootstrap). The token is valid for 15 minutes.
  """
  @spec generate_login_token(User.t()) :: String.t()
  def generate_login_token(%User{} = user) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    encoded_token
  end

  @doc """
  Marks the user as confirmed.
  """
  @spec confirm_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def confirm_user(%User{} = user) do
    user |> User.confirm_changeset() |> Repo.update()
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
