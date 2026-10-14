defmodule HelmsmanWeb.ProviderAccountComponents do
  @moduledoc """
  Pieces shared by the provider accounts page, the agent form and the agent page
  (add-provider-accounts-ui D3): the account summary (name + host), the host of an
  address and the labels of the model aliases.
  """
  use HelmsmanWeb, :html

  alias HelmsmanWeb.Brands

  @accounts_path "/users/settings/provider-accounts"

  @doc "The provider accounts page; `params` (a keyword list, in order) become its query."
  def accounts_path(params \\ [])
  def accounts_path([]), do: @accounts_path
  def accounts_path(params), do: @accounts_path <> "?" <> URI.encode_query(params)

  @doc "The edit panel of the account `id`."
  def edit_path(id), do: accounts_path(panel: "edit", id: id)

  @doc "The CLIs that take provider accounts."
  def clis, do: ~w(claude codex)

  @doc "Whether agents of the CLI `provider` may bind a provider account."
  def supported?(provider), do: provider in clis()

  @doc "The model aliases of the CLI `cli` (`HelmsmanProtocol.ProviderAccount`)."
  def aliases("codex"), do: HelmsmanProtocol.ProviderAccount.model_aliases(:codex)
  def aliases(_cli), do: HelmsmanProtocol.ProviderAccount.model_aliases(:claude)

  @doc "The most custom headers of an account (spec provider-accounts)."
  def max_headers, do: 8

  @doc "Whether accounts of the CLI `cli` take custom headers (only Codex so far)."
  def headers?(cli), do: cli == "codex"

  @doc "The host of an address; the address itself when it has none."
  def host(nil), do: ""

  def host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> url
    end
  end

  @doc "`{host, rest}` of an address, to render the host prominently and the path muted."
  def split_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} = uri when is_binary(host) and host != "" ->
        prefix = "#{uri.scheme}://"
        rest = String.replace_prefix(url, prefix <> host, "")
        {prefix, host, rest}

      _ ->
        {"", url, ""}
    end
  end

  @doc "The label of a model alias in the account form."
  def model_alias_label("default"), do: dgettext("ui", "缺省模型（default）")
  def model_alias_label("subagent"), do: dgettext("ui", "子 Agent（subagent）")
  def model_alias_label(other), do: other

  @doc "`别名 → 模型` lines of a model map, `default` first."
  def mapping_lines(models) when is_map(models) do
    models
    |> Enum.sort_by(fn {k, _} -> {k != "default", k} end)
    |> Enum.map(fn {k, v} -> "#{k} → #{v}" end)
  end

  def mapping_lines(_models), do: []

  @doc """
  The brand icon of an account (add-actor-avatars D19): its chosen `icon`, otherwise the
  one inferred from its base URL (`base_url`, or `host` in the agent summaries) and CLI.
  nil (the neutral icon) when neither is known, and for a chosen key that is not in the
  tables (web-components 品牌图标「未知键」): a choice is never replaced by inference.
  """
  def account_icon(nil), do: nil

  def account_icon(account) do
    case account[:icon] do
      icon when is_binary(icon) and icon != "" -> Brands.vendor_icon(icon)
      _ -> Brands.host_icon(account_url(account), account[:cli])
    end
  end

  @doc "An account's brand icon on its plate, named for assistive technology (D19)."
  attr :account, :map, required: true
  attr :size, :atom, default: :sm

  def account_icon_mark(assigns) do
    icon = account_icon(assigns.account)
    assigns = assign(assigns, icon: icon, label: icon && Brands.vendor_name(icon))

    ~H"""
    <span class="inline-flex" data-account-icon={@icon || "none"}>
      <.brand_icon icon={@icon} size={@size} label={@label} />
    </span>
    """
  end

  defp account_url(%{base_url: url}), do: url
  # Agent / run summaries carry only the host and, when the address names one, the port
  # (domain-request-2 R10); an IPv6 host goes back into brackets.
  defp account_url(%{host: host} = account) when is_binary(host) and host != "" do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host

    case account[:port] do
      port when is_integer(port) -> "https://#{host}:#{port}"
      _ -> "https://" <> host
    end
  end

  defp account_url(_account), do: nil

  @doc """
  An account's brand icon (`account_icon/1`), name and host (the agent summary
  `%{id, name, cli, host, icon}`). With `link` set the whole summary links to the
  account's edit panel.
  """
  attr :account, :map, required: true
  attr :link, :boolean, default: false
  attr :rest, :global

  def account_summary(%{link: true} = assigns) do
    ~H"""
    <.link
      navigate={edit_path(@account.id)}
      title={title(@account)}
      class="flex min-w-0 items-center gap-1.5 text-fg hover:underline"
      {@rest}
    >
      <.summary_parts account={@account} />
    </.link>
    """
  end

  def account_summary(assigns) do
    ~H"""
    <span title={title(@account)} class="flex min-w-0 items-center gap-1.5 text-fg" {@rest}>
      <.summary_parts account={@account} />
    </span>
    """
  end

  attr :account, :map, required: true

  defp summary_parts(assigns) do
    ~H"""
    <.account_icon_mark account={@account} size={:xs} />
    <span class="truncate" data-account-name>{@account.name}</span>
    <span :if={@account[:host]} class="truncate font-mono text-label text-fg-muted" data-account-host>
      {@account.host}
    </span>
    """
  end

  defp title(%{cli: cli}),
    do: dgettext("ui", "%{cli} 供应商账号", cli: HelmsmanWeb.AgentComponents.provider_label(cli))

  defp title(_account), do: nil
end
