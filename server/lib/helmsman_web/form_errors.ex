defmodule HelmsmanWeb.FormErrors do
  @moduledoc """
  Field errors of a domain changeset as display text: `%{field => [message]}`.

  Messages the domain layer writes itself (task and project validations, assignee
  checks) are translated here under the `ui` domain; Ecto's standard messages go
  through `HelmsmanWeb.CoreComponents.translate_error/1`.
  """
  use Gettext, backend: HelmsmanWeb.Gettext

  alias Ecto.Changeset

  @spec messages(Changeset.t()) :: %{atom() => [String.t()]}
  def messages(%Changeset{errors: errors}) do
    Enum.reduce(Enum.reverse(errors), %{}, fn {field, error}, acc ->
      Map.update(acc, field, [text(field, error)], &[text(field, error) | &1])
    end)
  end

  @doc "The first message of `field`, or nil."
  @spec first(%{atom() => [String.t()]}, atom()) :: String.t() | nil
  def first(errors, field), do: errors |> Map.get(field, []) |> List.first()

  defp text(:key, {"has already been taken", _}), do: dgettext("ui", "Key 已被占用")

  defp text(:key, {"must be 2-10 characters of A-Z and 0-9, starting with a letter", _}),
    do: dgettext("ui", "Key 须以大写字母开头，由 2–10 位大写字母或数字组成")

  defp text(
         :slug,
         {"must be 2-39 characters of a-z, 0-9 and -, starting with a letter or digit", _}
       ),
       do: dgettext("ui", "须为 2–39 位小写字母、数字或 -，以字母或数字开头")

  defp text(:scopes, {"must be one or more of: " <> _, _}),
    do: dgettext("ui", "至少选择一项")

  defp text(:default_agent_id, {"must be an active agent of your own", _}),
    do: dgettext("ui", "须为你名下未停用的 Agent")

  defp text(_field, {"should be at least %{count} character(s)", opts} = error) do
    if opts[:count] == 1,
      do: dgettext("ui", "不能为空"),
      else: HelmsmanWeb.CoreComponents.translate_error(error)
  end

  defp text(_field, {"must be 1-200 characters", _}), do: dgettext("ui", "长度须为 1–200 个字符")
  defp text(_field, {"must be 1-80 characters", _}), do: dgettext("ui", "长度须为 1–80 个字符")
  defp text(_field, {"must be 1-64 characters", _}), do: dgettext("ui", "长度须为 1–64 个字符")
  defp text(_field, {"must be at most 64 KB", _}), do: dgettext("ui", "不能超过 64 KB")

  # Markdown bodies (feedback content) are limited in whole kilobytes.
  defp text(_field, {"should be at most %{count} byte(s)", opts} = error) do
    case opts[:count] do
      count when is_integer(count) and count >= 1024 and rem(count, 1024) == 0 ->
        dgettext("ui", "不能超过 %{n} KB", n: div(count, 1024))

      _ ->
        HelmsmanWeb.CoreComponents.translate_error(error)
    end
  end

  defp text(_field, {"must be at most 20 labels", _}), do: dgettext("ui", "最多 20 个标签")

  defp text(_field, {"each label must be 1-32 characters", _}),
    do: dgettext("ui", "每个标签须为 1–32 个字符")

  # Provider accounts (add-provider-accounts-ui D5, D8).
  defp text(_field, {"is already used by another of your provider accounts", _}),
    do: dgettext("ui", "你已有同名的供应商账号")

  defp text(_field, {"must not contain control characters", _}),
    do: dgettext("ui", "不能包含控制字符")

  defp text(:cli, {"cannot be changed", _}), do: dgettext("ui", "创建后不能修改")
  defp text(:base_url, {"must be an https URL", _}), do: dgettext("ui", "须为 https 地址")

  defp text(:base_url, {"must use https unless the host is a loopback address", _}),
    do: dgettext("ui", "只有本机地址可以使用 http，其他地址须为 https")

  defp text(:base_url, {"must not contain credentials", _}),
    do: dgettext("ui", "不能包含用户名或密码")

  defp text(:base_url, {"must not contain a query string", _}), do: dgettext("ui", "不能包含查询串")
  defp text(:base_url, {"must not contain a fragment", _}), do: dgettext("ui", "不能包含 # 片段")
  defp text(:base_url, {"must be at most 2048 bytes", _}), do: dgettext("ui", "不能超过 2048 字节")

  defp text(:api_key, {"must be 1-8192 visible ASCII characters", _}),
    do: dgettext("ui", "须为 1–8192 个可见 ASCII 字符（不含空格）")

  defp text(:models, {"must be an object", _}), do: dgettext("ui", "格式不正确")

  defp text(:models, {"unknown alias %{alias} (allowed: %{allowed})", opts}),
    do:
      dgettext("ui", "未知的别名 %{alias}（可用：%{allowed}）",
        alias: opts[:alias],
        allowed: opts[:allowed]
      )

  defp text(:models, {"model names must be 1-128 visible ASCII characters", _}),
    do: dgettext("ui", "模型名须为 1–128 个可见 ASCII 字符")

  defp text(:models, {"must have a default model for codex", _}),
    do: dgettext("ui", "Codex 账号必须填写缺省模型（default）")

  defp text(:provider_account_id, {"is for %{cli}", opts}),
    do:
      dgettext("ui", "该账号用于 %{cli}",
        cli: HelmsmanWeb.AgentComponents.provider_label(to_string(opts[:cli]))
      )

  # The domain's header errors (`Helmsman.ProviderAccounts.Headers`) name the header,
  # never its value.
  defp text(:headers, {"reserved header " <> name, _}),
    do: dgettext("ui", "%{name} 是保留的请求头，不能设置", name: name)

  defp text(:headers, {"invalid value for header " <> name, _}),
    do: dgettext("ui", "%{name} 的值须为 1–4096 个可见 ASCII 字符或空格，首尾不能是空格", name: name)

  defp text(:headers, {"unknown header " <> name, _}),
    do: dgettext("ui", "没有名为 %{name} 的请求头", name: name)

  defp text(:headers, {"cannot set and delete header " <> name, _}),
    do: dgettext("ui", "%{name} 不能同时设置和删除", name: name)

  defp text(:headers, {"duplicate header " <> name, _}),
    do: dgettext("ui", "请求头名字重复：%{name}", name: name)

  defp text(:headers, {"names must be 1-64 byte HTTP tokens", _}),
    do: dgettext("ui", "请求头名字须为 1–64 字节的 HTTP 字段名（字母、数字与 !#$%&'*+.^_`|~-）")

  defp text(:headers, {"must have at most 8 headers", _}),
    do: dgettext("ui", "最多 %{n} 个请求头", n: 8)

  defp text(:headers, {"header names must be unique ignoring case", _}),
    do: dgettext("ui", "请求头名字不区分大小写，不能重复")

  defp text(:headers, {"Claude Code accounts do not support custom headers yet", _}),
    do: dgettext("ui", "Claude Code 账号暂不支持自定义请求头")

  # Errors of a creation conversation's draft (add-agent-conversation-ui D11).
  defp text(:name, {"is already in the draft", _}), do: dgettext("ui", "草稿里已有同名 Agent")

  defp text(:access, {"must be owner_only or workspace", _}),
    do: dgettext("ui", "只能是仅所属用户或工作区成员")

  defp text(_field, {"cannot be set in a draft", _}), do: dgettext("ui", "草稿里不能设置这一项")

  defp text(_field, {"does not exist", _}), do: dgettext("ui", "不存在")
  defp text(_field, {"is disabled", _}), do: dgettext("ui", "已停用，不能指派")
  defp text(_field, {"cannot be the system identity", _}), do: dgettext("ui", "不能指派给系统身份")
  defp text(_field, error), do: HelmsmanWeb.CoreComponents.translate_error(error)
end
