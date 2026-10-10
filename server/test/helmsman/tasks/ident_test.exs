defmodule Helmsman.Tasks.IdentTest do
  use ExUnit.Case, async: true

  alias Helmsman.Tasks.Ident

  doctest Ident

  for {input, expected} <- [
        {"BOS-1", {:ok, "BOS-1", "BOS", 1}},
        {"bos-12", {:ok, "BOS-12", "BOS", 12}},
        {"Ab9-7", {:ok, "AB9-7", "AB9", 7}},
        {"ABCDEFGHIJ-100", {:ok, "ABCDEFGHIJ-100", "ABCDEFGHIJ", 100}},
        {"BOS-03", {:error, :not_found}},
        {"BOS-0", {:error, :not_found}},
        {"BOS", {:error, :not_found}},
        {"-1", {:error, :not_found}},
        {"B-1", {:error, :not_found}},
        {"ABCDEFGHIJK-1", {:error, :not_found}},
        {"BOS-1x", {:error, :not_found}},
        {"BOS-1\n", {:error, :not_found}},
        {"1OS-1", {:error, :not_found}},
        {"", {:error, :not_found}}
      ] do
    test "parse(#{inspect(input)})" do
      assert Ident.parse(unquote(input)) == unquote(Macro.escape(expected))
    end
  end

  test "non-strings are not found" do
    assert Ident.parse(nil) == {:error, :not_found}
    assert Ident.parse(12) == {:error, :not_found}
  end
end
