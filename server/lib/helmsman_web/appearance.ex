defmodule HelmsmanWeb.Appearance do
  @moduledoc """
  The workspace's identity appearance table (add-actor-avatars D7, update-actor-icons
  D4): pure functions only. `HelmsmanWeb.Shell` loads it into `@appearance` (and reloads
  it on the notifications listed there); pages and components pass it to `decorate/2`
  when building the actor maps of `actor_chip` / `actor_mark`, which draw what `mark/1`
  resolves.
  """

  alias HelmsmanWeb.{AvatarData, Brands}
  alias HelmsmanWeb.Components.Brand

  @type entry :: %{
          kind: atom(),
          provider: String.t() | nil,
          managed?: boolean(),
          avatar_url: String.t() | nil,
          avatar_icon: String.t() | nil,
          vendor: String.t() | nil,
          vendor_source: :account | :runtime | nil
        }

  @type t :: %{String.t() => entry()}

  @typedoc """
  What an identity's mark shows besides an image avatar (D4, levels 2–5): a built-in
  icon, a managed Agent's vendor or CLI icon, or the kind's default mark.
  """
  @type mark :: {:icon, String.t()} | {:vendor, String.t()} | {:cli, String.t()} | :default

  @doc """
  Reads the table of the scope's workspace: `%{name => entry}`, `avatar_url` being the
  workspace avatar address. Empty without a workspace (the `/dev/ui` demo scope).
  """
  @spec load(map() | nil) :: t()
  def load(%{workspace: %{id: id, slug: slug}} = scope) when is_integer(id) do
    scope
    |> AvatarData.appearance()
    |> Map.new(fn {name, entry} ->
      {name,
       %{
         kind: to_kind(entry.kind),
         provider: entry.provider && to_string(entry.provider),
         managed?: entry.managed? == true,
         avatar_url: AvatarData.workspace_avatar_url(slug, entry.avatar_key),
         avatar_icon: entry.avatar_icon,
         vendor: entry.vendor,
         vendor_source: entry.vendor_source
       }}
    end)
  end

  def load(_scope), do: %{}

  @doc """
  Adds `avatar_url`, `avatar_icon` and, for Agents, `provider`, `managed?`, `vendor` and
  `vendor_source` of `actor`'s entry in `appearance`, looked up by name. An actor that is
  missing, or whose kind differs (a rename not yet reloaded), is returned unchanged and
  shows its default mark: it never takes another identity's avatar.
  """
  @spec decorate(map(), t() | nil) :: map()
  def decorate(actor, appearance) when is_map(actor) and is_map(appearance) do
    kind = actor |> Map.get(:kind) |> to_kind()

    case appearance[Map.get(actor, :name)] do
      %{kind: ^kind} = entry ->
        actor
        |> Map.put(:avatar_url, entry.avatar_url)
        |> Map.put(:avatar_icon, Map.get(entry, :avatar_icon))
        |> put_agent(kind, entry)

      _ ->
        actor
    end
  end

  def decorate(actor, _appearance), do: actor

  defp put_agent(actor, :agent, entry) do
    actor
    |> Map.put(:provider, entry.provider)
    |> Map.put_new(:managed?, entry.managed?)
    |> Map.put(:vendor, Map.get(entry, :vendor))
    |> Map.put(:vendor_source, Map.get(entry, :vendor_source))
  end

  defp put_agent(actor, _kind, _entry), do: actor

  @doc """
  What the mark of `actor` shows under an image avatar (D4, interface order): its
  built-in icon when that icon is in `HelmsmanWeb.Brands`; for a managed Agent the
  vendor when it is in the vendor or platform table, otherwise the CLI icon; otherwise
  the kind's default. Unknown icons and vendors count as absent; the system identity
  always gets its default.
  """
  @spec mark(map()) :: mark()
  def mark(actor) do
    kind = actor |> Map.get(:kind) |> to_kind()
    managed? = kind == :agent and Map.get(actor, :managed?) != false

    cond do
      kind == :system -> :default
      icon = builtin_icon(Map.get(actor, :avatar_icon)) -> {:icon, icon}
      managed? and vendor_icon(Map.get(actor, :vendor)) -> {:vendor, Map.get(actor, :vendor)}
      managed? and cli_icon(Map.get(actor, :provider)) -> {:cli, cli_icon(actor.provider)}
      true -> :default
    end
  end

  @doc "The mark `actor` falls back to without a custom avatar (image or built-in icon)."
  @spec default_mark(map()) :: mark()
  def default_mark(actor), do: actor |> Map.drop([:avatar_url, :avatar_icon]) |> mark()

  @doc "Whether `actor` shows an image avatar (never for the system identity)."
  @spec image?(map()) :: boolean()
  def image?(actor),
    do: is_binary(Map.get(actor, :avatar_url)) and to_kind(Map.get(actor, :kind)) != :system

  @doc "Whether `actor` has a custom avatar: an image or a known built-in icon."
  @spec custom?(map()) :: boolean()
  def custom?(actor), do: image?(actor) or match?({:icon, _}, mark(actor))

  defp builtin_icon(icon) when is_binary(icon),
    do: if(Brands.icon_label(icon) && Brand.vendored?(icon), do: icon)

  defp builtin_icon(_icon), do: nil

  defp vendor_icon(vendor) when is_binary(vendor) do
    icon = Brands.vendor_icon(vendor)
    icon && Brand.vendored?(icon)
  end

  defp vendor_icon(_vendor), do: false

  defp cli_icon(provider) do
    icon = Brands.cli_icon(provider)
    if icon && Brand.vendored?(icon), do: icon
  end

  defp to_kind(kind) when kind in [:human, :agent, :squad, :system], do: kind
  defp to_kind("agent"), do: :agent
  defp to_kind("squad"), do: :squad
  defp to_kind("system"), do: :system
  defp to_kind(_), do: :human
end
