defmodule HelmsmanProtocol.ProviderHeadersTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{Fixtures, Messages, ProviderAccount, Reply, RunSpec}

  defp account(headers) do
    %{
      "base_url" => "https://example.invalid/v1",
      "api_key" => "test-key",
      "models" => %{"default" => "model"},
      "headers" => headers
    }
  end

  test "headers roundtrip in order and redact values through the containing structs" do
    headers = [
      %{"name" => "user", "value" => "header-sentinel-one"},
      %{"name" => "Ocp-Apim-Subscription-Key", "value" => "header-sentinel-two"}
    ]

    wire = put_in(Fixtures.run_spec(), ["agent", "provider_account"], account(headers))
    assert {:ok, run} = RunSpec.from_wire(wire)
    assert {:ok, reply} = Reply.Claim.new(runs: [run])
    assert {:ok, encoded} = Messages.encode_reply("claim", reply, 5)
    assert hd(encoded["runs"])["agent"]["provider_account"]["headers"] == headers
    assert {:ok, ^reply} = Messages.decode_reply("claim", encoded)

    for value <- [run.agent.provider_account, run.agent, run, reply] do
      text = inspect(value, limit: :infinity)
      assert text =~ "user"
      refute text =~ "header-sentinel-one"
      refute text =~ "header-sentinel-two"
    end
  end

  test "old target omits empty headers and refuses nonempty headers" do
    for headers <- [[], [%{"name" => "user", "value" => "sentinel"}]] do
      wire = put_in(Fixtures.run_spec(), ["agent", "provider_account"], account(headers))
      assert {:ok, run} = RunSpec.from_wire(wire)
      assert {:ok, reply} = Reply.Claim.new(runs: [run])

      if headers == [] do
        assert {:ok, wire} = Messages.encode_reply("claim", reply, 4)
        refute Map.has_key?(hd(wire["runs"])["agent"]["provider_account"], "headers")
        assert {:ok, ^reply} = Messages.decode_reply("claim", wire)
      else
        assert {:error, {:not_in_version, 4}} = Messages.encode_reply("claim", reply, 4)
      end
    end
  end

  test "count, names and values enforce all wire and native boundaries without echoing values" do
    valid = for i <- 1..8, do: %{"name" => "X-#{i}", "value" => "value"}
    assert {:ok, value} = ProviderAccount.from_wire(account(valid))
    assert {:ok, ^value} = ProviderAccount.new(Map.from_struct(value))

    for {name, value} <- [{String.duplicate("X", 64), String.duplicate("v", 4096)}, {"X", "a b"}] do
      assert {:ok, _} = ProviderAccount.from_wire(account([%{"name" => name, "value" => value}]))
    end

    invalid =
      [
        valid ++ [%{"name" => "X-9", "value" => "value"}],
        [%{"name" => "user", "value" => "value"}, %{"name" => "USER", "value" => "value"}]
      ] ++
        Enum.map(
          ["", "invalid name", String.duplicate("X", 65), "Authorization", "TE"],
          &[%{"name" => &1, "value" => "header-sensitive"}]
        ) ++
        Enum.map(
          [
            "",
            " value",
            "value ",
            "header-sensitive\r",
            "a\n",
            "非ASCII",
            String.duplicate("v", 4097)
          ],
          &[%{"name" => "user", "value" => &1}]
        )

    for headers <- invalid do
      assert {:error, {:invalid_payload, ["headers" | _], _}} =
               error = ProviderAccount.from_wire(account(headers))

      refute inspect(error) =~ "header-sensitive"

      native = %{
        base_url: "https://example.invalid/v1",
        api_key: "test-key",
        models: %{},
        headers: Enum.map(headers, &%{name: &1["name"], value: &1["value"]})
      }

      assert {:error, {:invalid_payload, ["headers" | _], _}} = ProviderAccount.new(native)
    end
  end
end
