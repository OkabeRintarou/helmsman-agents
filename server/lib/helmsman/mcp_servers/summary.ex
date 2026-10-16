defmodule Helmsman.McpServers.Summary do
  @moduledoc "Conservative display summaries; fixed env/header values and opaque fields never leave the domain."
  alias Helmsman.McpServers.Entry
  @mask "••••"
  @sensitive ~r/token|key|secret|password|passwd|auth|credential/i
  @prefix ~r/\A(?:ghp_|gho_|github_pat_|glpat-|sk-|xoxb-|xoxp-|AKIA)/
  @random ~r/\A[A-Za-z0-9_\-+=]{32,}\z/

  def of(name, entry, source \\ "agent")

  def of(name, entry, source) when is_map(entry) do
    %{
      name: name,
      source: source,
      type: if(Entry.type(entry) in ~w(stdio http sse), do: Entry.type(entry), else: nil),
      command: mask(entry["command"]),
      args: if(is_list(entry["args"]), do: mask(entry["args"]), else: []),
      url: mask(entry["url"]),
      env: keys(entry["env"]),
      headers: keys(entry["headers"]),
      other_fields: Map.keys(entry) -- ~w(type command args env cwd url headers)
    }
  end

  def of(name, _, source), do: %{name: name, source: source, type: nil}

  def mask(values) when is_list(values), do: mask_args(values, false)

  def mask(value) when is_binary(value) do
    cond do
      String.starts_with?(value, ["http://", "https://"]) ->
        mask_url(value)

      String.contains?(value, "${env:") ->
        Regex.split(~r/(\$\{env:[A-Za-z_][A-Za-z0-9_]*\})/, value, include_captures: true)
        |> Enum.map_join(&mask_part/1)

      true ->
        mask_token(value)
    end
  end

  def mask(nil), do: nil
  def mask(_value), do: @mask

  defp mask_args([], _), do: []

  defp mask_args([value | rest], hide?) do
    {shown, next?} =
      cond do
        hide? ->
          {keep_refs(value), false}

        is_binary(value) and String.starts_with?(value, "-") and Regex.match?(@sensitive, value) ->
          case String.split(value, "=", parts: 2) do
            [key, val] -> {key <> "=" <> keep_refs(val), false}
            [_] -> {value, true}
          end

        true ->
          {mask(value), false}
      end

    [shown | mask_args(rest, next?)]
  end

  defp keep_refs(value) when is_binary(value) do
    refs = Regex.scan(~r/\$\{env:[A-Za-z_][A-Za-z0-9_]*\}/, value) |> List.flatten()
    if refs == [], do: @mask, else: Enum.join(refs)
  end

  defp keep_refs(_), do: @mask

  defp mask_part("${env:" <> _ = part), do: part
  defp mask_part(part), do: mask_token(part)

  defp mask_token(value),
    do: if(Regex.match?(@prefix, value) or Regex.match?(@random, value), do: @mask, else: value)

  defp mask_url(value) do
    uri = URI.parse(value)

    query =
      if uri.query do
        uri.query
        |> String.split("&")
        |> Enum.map_join("&", &mask_query/1)
      end

    URI.to_string(%{uri | userinfo: if(uri.userinfo, do: @mask), query: query})
  end

  defp mask_query(item) do
    case String.split(item, "=", parts: 2) do
      [key, value] -> key <> "=" <> keep_refs(value)
      [key] -> key
    end
  end

  defp keys(values) when is_map(values),
    do: Map.new(values, fn {key, value} -> {key, Entry.references(value)} end)

  defp keys(_), do: %{}
end
