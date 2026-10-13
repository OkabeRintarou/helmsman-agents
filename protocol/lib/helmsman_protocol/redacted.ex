defmodule HelmsmanProtocol.Redacted do
  @moduledoc false
  defmacro __using__(fields) do
    quote do
      defimpl Inspect do
        def inspect(value, opts),
          do: HelmsmanProtocol.Redacted.inspect(value, opts, unquote(fields))
      end
    end
  end

  def inspect(value, opts, fields) do
    values = redact_map(Map.from_struct(value), fields)

    Inspect.Algebra.concat([
      "#",
      inspect(value.__struct__),
      "<",
      Inspect.Algebra.to_doc(values, opts),
      ">"
    ])
  end

  defp redact_map(value, fields) do
    Enum.reduce(fields, value, fn
      {:nested, field, nested_fields}, acc ->
        Map.update(acc, field, "**redacted**", &redact_nested(&1, nested_fields))

      :env, acc ->
        Map.update(acc, :env, "**redacted**", &redact_env/1)

      field, acc ->
        Map.put(acc, field, "**redacted**")
    end)
  end

  defp redact_nested(nil, _), do: nil

  defp redact_nested(values, fields) when is_list(values),
    do: Enum.map(values, &redact_nested(&1, fields))

  defp redact_nested(%{__struct__: _} = value, fields),
    do: redact_map(Map.from_struct(value), fields)

  defp redact_nested(value, fields) when is_map(value), do: redact_map(value, fields)
  defp redact_nested(_, _), do: "**redacted**"

  defp redact_env(nil), do: nil

  defp redact_env(env) when is_map(env) and not is_struct(env) do
    if Enum.all?(env, fn {name, value} -> is_binary(name) and is_binary(value) end) do
      Map.new(env, fn {name, _} -> {name, "**redacted**"} end)
    else
      "**redacted**"
    end
  end

  defp redact_env(_), do: "**redacted**"
end
