defmodule Helmsman.ProviderAccounts.Headers do
  @moduledoc false
  alias HelmsmanProtocol.ProviderAccount.Header

  def decode(nil), do: []
  def decode(bytes), do: JSON.decode!(bytes)

  def apply(attrs, account) do
    case fetch(attrs, "headers") do
      :error -> {:ok, decode(account.headers)}
      {:ok, headers} when is_nil(account.id) -> create(headers)
      {:ok, patch} -> patch(patch, decode(account.headers), account.header_names)
    end
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      :error ->
        Map.fetch(attrs, %{"headers" => :headers, "set" => :set, "delete" => :delete}[key])

      found ->
        found
    end
  end

  defp create(headers) when is_map(headers) and not is_struct(headers) do
    with {:ok, entries} <- entries(headers), do: validate(entries)
  end

  defp create(_), do: {:error, "must be an object of names and values"}

  defp patch(patch, existing, names) when is_map(patch) and not is_struct(patch) do
    if Enum.all?(Map.keys(patch), &(&1 in ["set", "delete", :set, :delete])) do
      set = get(patch, "set", %{})
      delete = get(patch, "delete", [])

      with {:ok, entries} <- entries(set),
           :ok <- deletions(delete, names, entries) do
        changed =
          Enum.map(entries, &String.downcase(&1["name"])) ++ Enum.map(delete, &String.downcase/1)

        kept = Enum.reject(existing, &(String.downcase(&1["name"]) in changed))
        validate(kept ++ entries)
      end
    else
      {:error, "must contain only set and delete"}
    end
  end

  defp patch(_, _, _), do: {:error, "must be a set/delete patch"}

  defp get(map, key, default) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp entries(map) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, []}, fn {name, value}, {:ok, acc} ->
      cond do
        not Header.valid_name?(name) -> {:halt, {:error, "names must be 1-64 byte HTTP tokens"}}
        Header.reserved?(name) -> {:halt, {:error, "reserved header " <> name}}
        not Header.valid_value?(value) -> {:halt, {:error, "invalid value for header " <> name}}
        true -> {:cont, {:ok, [%{"name" => name, "value" => value} | acc]}}
      end
    end)
  end

  defp entries(_), do: {:error, "set must be an object of names and values"}

  defp deletions(delete, names, entries) when is_list(delete) do
    set_names = Enum.map(entries, &String.downcase(&1["name"]))
    existing = Enum.map(names, &String.downcase/1)

    Enum.reduce_while(delete, {:ok, []}, fn name, {:ok, seen} ->
      cond do
        not Header.valid_name?(name) ->
          {:halt, {:error, "delete must contain HTTP header names"}}

        String.downcase(name) in set_names ->
          {:halt, {:error, "cannot set and delete header " <> name}}

        String.downcase(name) not in existing ->
          {:halt, {:error, "unknown header " <> name}}

        String.downcase(name) in seen ->
          {:halt, {:error, "duplicate header " <> name}}

        true ->
          {:cont, {:ok, [String.downcase(name) | seen]}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp deletions(_, _, _), do: {:error, "delete must be a list of header names"}

  defp validate(entries) do
    names = Enum.map(entries, &String.downcase(&1["name"]))

    cond do
      length(entries) > 8 ->
        {:error, "must have at most 8 headers"}

      length(names) != length(Enum.uniq(names)) ->
        {:error, "header names must be unique ignoring case"}

      true ->
        {:ok, Enum.sort_by(entries, &String.downcase(&1["name"]))}
    end
  end
end
