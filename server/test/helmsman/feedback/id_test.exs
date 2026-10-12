defmodule Helmsman.Feedback.IdTest do
  use ExUnit.Case, async: true

  alias Helmsman.Feedback.Id

  doctest Id

  for {input, expected} <- [
        {"BOS-12#3", {:ok, "BOS-12", 3}},
        {"bos-12#3", {:ok, "BOS-12", 3}},
        {"BOS-12#2147483647", {:ok, "BOS-12", 2_147_483_647}},
        {"BOS-12#03", {:error, :not_found}},
        {"BOS-12#0", {:error, :not_found}},
        {"BOS-12", {:error, :not_found}},
        {"BOS-12#", {:error, :not_found}},
        {"BOS-012#3", {:error, :not_found}},
        {"BOS-12#3#4", {:error, :not_found}},
        {"BOS-12#-3", {:error, :not_found}},
        {"BOS-12# 3", {:error, :not_found}},
        {"BOS-12#2147483648", {:error, :not_found}},
        {"#3", {:error, :not_found}},
        {"", {:error, :not_found}}
      ] do
    test "parse(#{inspect(input)})" do
      assert Id.parse(unquote(input)) == unquote(Macro.escape(expected))
    end
  end

  test "non-strings are not found" do
    assert Id.parse(nil) == {:error, :not_found}
    assert Id.parse(12) == {:error, :not_found}
  end

  test "build" do
    assert Id.build("BOS-12", 3) == "BOS-12#3"
  end
end
