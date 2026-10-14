defmodule HelmsmanWeb.Appearance do
  @moduledoc """
  The workspace's identity appearance table (add-actor-avatars D7): pure functions only.
  `HelmsmanWeb.Shell` loads it into `@appearance` (and reloads it on the notifications
  listed there); pages and components pass it to `decorate/2` when building the actor
  maps of `actor_chip` / `actor_mark`.
  """

  alias HelmsmanWeb.AvatarData

  @type t :: %{
          String.t() => %{
            kind: atom(),
            provider: String.t() | nil,
            managed?: boolean(),
            avatar_url: String.t() | nil
          }
        }

  @doc """
  Reads the table of the scope's workspace: `%{name => %{kind, provider, managed?,
  avatar_url}}`, `avatar_url` being the workspace avatar address. Empty without a
  workspace (the `/dev/ui` demo scope).
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
         avatar_url: AvatarData.workspace_avatar_url(slug, entry.avatar_key)
       }}
    end)
  end

  def load(_scope), do: %{}

  @doc """
  Adds `provider`, `managed?` (Agents) and `avatar_url` of `actor`'s entry in
  `appearance`, looked up by name. An actor that is missing, or whose kind differs (a
  rename not yet reloaded), is returned unchanged and shows its default mark: it never
  takes another identity's avatar.
  """
  @spec decorate(map(), t() | nil) :: map()
  def decorate(actor, appearance) when is_map(actor) and is_map(appearance) do
    kind = actor |> Map.get(:kind) |> to_kind()

    case appearance[Map.get(actor, :name)] do
      %{kind: ^kind} = entry ->
        actor
        |> Map.put(:avatar_url, entry.avatar_url)
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
  end

  defp put_agent(actor, _kind, _entry), do: actor

  defp to_kind(kind) when kind in [:human, :agent, :squad, :system], do: kind
  defp to_kind("agent"), do: :agent
  defp to_kind("squad"), do: :squad
  defp to_kind("system"), do: :system
  defp to_kind(_), do: :human
end
