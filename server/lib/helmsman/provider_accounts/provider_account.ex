defmodule Helmsman.ProviderAccounts.ProviderAccount do
  @moduledoc """
  A user's provider account (`add-provider-accounts` decision 2): the
  address, API key and model aliases a managed agent's CLI uses instead of
  the user's own CLI login and configuration.

  The API key is stored encrypted and never read back: `Inspect` leaves it
  out, a changeset hides it (`redact: true`), and `scrub/1` removes it from
  a failed changeset before it leaves the domain.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Helmsman.ProviderAccounts.Headers

  @type t :: %__MODULE__{}

  @clis ~w(claude codex)
  @max_url 2_048
  @max_key 8_192
  @max_model 128

  @derive {Inspect, except: [:api_key, :headers]}
  schema "provider_accounts" do
    belongs_to :user, Helmsman.Accounts.User
    field :name, :string
    field :cli, :string
    field :base_url, :string
    field :api_key, Helmsman.Encrypted.Binary, redact: true
    field :models, :map, default: %{}
    field :header_names, {:array, :string}, default: []
    field :headers, Helmsman.Encrypted.Binary, redact: true
    timestamps(type: :utc_datetime)
  end

  @doc "The CLIs a provider account can be for."
  @spec clis() :: [String.t()]
  def clis, do: @clis

  @doc """
  Validates `attrs` for `account` (decision 2). On an existing account a
  missing or empty `api_key` keeps the stored one; `models` replaces the
  mapping as a whole; `cli` cannot change. Does not read the database: the
  per-user limit and name uniqueness are checked by the context and the
  unique index.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = account, attrs) when is_map(attrs) do
    account
    |> cast(drop_blank_key(attrs), [:name, :cli, :base_url, :api_key, :models])
    |> update_change(:name, &String.trim/1)
    |> normalize_models()
    |> validate_required([:name, :cli, :base_url, :api_key])
    |> validate_length(:name, min: 1, max: 64)
    |> validate_format(:name, ~r/\A\P{Cc}*\z/u, message: "must not contain control characters")
    |> validate_inclusion(:cli, @clis)
    |> validate_cli_unchanged(account)
    |> validate_base_url()
    |> validate_api_key()
    |> validate_models()
    |> apply_headers(attrs, account)
    |> unique_constraint(:name,
      name: :provider_accounts_user_id_name_index,
      message: "is already used by another of your provider accounts"
    )
    |> scrub_invalid()
  end

  defp scrub_invalid(%{valid?: false} = cs), do: scrub(cs)
  defp scrub_invalid(cs), do: cs

  defp apply_headers(cs, attrs, account) do
    case Headers.apply(attrs, account) do
      {:ok, headers} ->
        if headers != [] and get_field(cs, :cli) == "claude" do
          add_error(cs, :headers, "Claude Code accounts do not support custom headers yet")
        else
          put_headers(cs, headers)
        end

      {:error, message} ->
        add_error(cs, :headers, message)
    end
  end

  defp put_headers(cs, headers) do
    cs
    |> put_change(:header_names, Enum.map(headers, & &1["name"]))
    |> put_change(:headers, if(headers == [], do: nil, else: JSON.encode!(headers)))
  end

  defp drop_blank_key(attrs),
    do:
      Map.reject(attrs, fn {key, value} -> to_string(key) == "api_key" and value in [nil, ""] end)

  # `cast/3` accepts nil for a map field: an explicit null is an error, not
  # an empty mapping (leaving `models` out keeps the current one).
  defp normalize_models(cs) do
    case fetch_change(cs, :models) do
      {:ok, nil} ->
        cs |> delete_change(:models) |> add_error(:models, "must be an object")

      {:ok, models} ->
        put_change(cs, :models, Map.new(models, fn {key, value} -> {to_string(key), value} end))

      :error ->
        cs
    end
  end

  defp validate_cli_unchanged(cs, %__MODULE__{id: nil}), do: cs

  defp validate_cli_unchanged(cs, %__MODULE__{cli: cli}) do
    case fetch_change(cs, :cli) do
      {:ok, new} when new != cli -> add_error(cs, :cli, "cannot be changed")
      _ -> cs
    end
  end

  defp validate_base_url(cs) do
    case fetch_change(cs, :base_url) do
      {:ok, url} when is_binary(url) ->
        url = url |> String.trim() |> String.trim_trailing("/")
        cs = put_change(cs, :base_url, url)

        case url_error(url) do
          nil -> cs
          message -> add_error(cs, :base_url, message)
        end

      _ ->
        cs
    end
  end

  defp url_error(url) when byte_size(url) > @max_url, do: "must be at most 2048 bytes"

  defp url_error(url) do
    case URI.new(url) do
      {:ok, %URI{host: host} = uri} when is_binary(host) and host != "" ->
        part_error(uri) || scheme_error(uri)

      _ ->
        "must be an https URL"
    end
  end

  defp part_error(%URI{userinfo: info}) when not is_nil(info), do: "must not contain credentials"

  defp part_error(%URI{query: query}) when not is_nil(query),
    do: "must not contain a query string"

  defp part_error(%URI{fragment: frag}) when not is_nil(frag), do: "must not contain a fragment"
  defp part_error(_uri), do: nil

  defp scheme_error(%URI{scheme: "https"}), do: nil

  defp scheme_error(%URI{scheme: "http", host: host}) do
    if loopback?(host), do: nil, else: "must use https unless the host is a loopback address"
  end

  defp scheme_error(_uri), do: "must be an https URL"

  defp loopback?(host) do
    case String.downcase(host) do
      "localhost" ->
        true

      "::1" ->
        true

      other ->
        match?({:ok, {127, _, _, _}}, :inet.parse_ipv4strict_address(String.to_charlist(other)))
    end
  end

  defp validate_api_key(cs) do
    validate_change(cs, :api_key, fn :api_key, key ->
      if visible_ascii?(key, @max_key),
        do: [],
        else: [api_key: "must be 1-8192 visible ASCII characters"]
    end)
  end

  defp validate_models(cs) do
    models = get_field(cs, :models) || %{}
    cli = get_field(cs, :cli)

    if cli in @clis do
      aliases = HelmsmanProtocol.ProviderAccount.model_aliases(String.to_existing_atom(cli))
      check_models(cs, models, aliases, cli)
    else
      cs
    end
  end

  defp check_models(cs, models, aliases, cli) do
    unknown = models |> Map.keys() |> Enum.reject(&(&1 in aliases)) |> Enum.sort()

    cond do
      unknown != [] ->
        add_error(cs, :models, "unknown alias %{alias} (allowed: %{allowed})",
          alias: Enum.join(unknown, ", "),
          allowed: Enum.join(aliases, ", ")
        )

      not Enum.all?(Map.values(models), &visible_ascii?(&1, @max_model)) ->
        add_error(cs, :models, "model names must be 1-128 visible ASCII characters")

      cli == "codex" and not Map.has_key?(models, "default") ->
        add_error(cs, :models, "must have a default model for codex")

      true ->
        cs
    end
  end

  defp visible_ascii?(value, max) when is_binary(value) and byte_size(value) in 1..max//1,
    do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x21..0x7E))

  defp visible_ascii?(_value, _max), do: false

  @doc """
  Removes the API key from `cs` (changes, params and data), so neither the
  submitted nor the stored key leaves the domain in an error.
  """
  @spec scrub(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def scrub(%Ecto.Changeset{} = cs) do
    data =
      case cs.data do
        %__MODULE__{} = data -> %{data | api_key: nil, headers: nil}
        data -> data
      end

    %{
      cs
      | data: data,
        changes: Map.drop(cs.changes, [:api_key, :headers]),
        params: cs.params && Map.drop(cs.params, ["api_key", :api_key, "headers", :headers])
    }
  end
end
