defmodule HelmsmanProtocol.ProviderAccountTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{Fixtures, Messages, ProviderAccount, Reply, RunSpec}

  defp account do
    %{
      "base_url" => "https://api.example.com/anthropic",
      "api_key" => "provider-secret-sentinel",
      "models" => %{"default" => "model-example"}
    }
  end

  test "aliases are shared without creating atoms from payloads" do
    assert ProviderAccount.model_aliases(:claude) == ~w(default opus sonnet haiku fable subagent)
    assert ProviderAccount.model_aliases(:codex) == ~w(default)
  end

  test "account roundtrips and inspect redacts secrets through every containing struct" do
    wire = put_in(Fixtures.run_spec(), ["agent", "provider_account"], account())
    assert {:ok, run} = RunSpec.from_wire(wire)
    assert {:ok, reply} = Reply.Claim.new(runs: [run])
    assert {:ok, encoded} = Messages.encode_reply("claim", reply)
    assert {:ok, ^reply} = Messages.decode_reply("claim", encoded)
    assert RunSpec.to_wire(run) == wire

    for value <- [run.agent.provider_account, run.agent, run, reply] do
      rendered = inspect(value, limit: :infinity)
      refute rendered =~ account()["api_key"]
      assert rendered =~ "api.example.com"
      assert rendered =~ "model-example"
    end
  end

  test "unknown model aliases are rejected at the nested models path" do
    wire = put_in(Fixtures.run_spec(), ["agent", "provider_account"], account())
    wire = put_in(wire, ["agent", "provider_account", "models"], %{"gpt" => "model"})

    assert {:error, {:invalid_payload, ["agent", "provider_account", "models"], _}} =
             RunSpec.from_wire(wire)
  end

  test "old claim replies omit empty accounts, reject nonempty accounts and preserve free JSON" do
    old = HelmsmanProtocol.provider_account_version() - 1
    wire = Fixtures.run_spec()
    wire = put_in(wire, ["agent", "extra_mcp_servers"], %{"provider_account" => "custom"})
    assert {:ok, run} = RunSpec.from_wire(wire)
    assert {:ok, reply} = Reply.Claim.new(runs: [run, run])
    assert {:ok, encoded} = Messages.encode_reply("claim", reply, old)
    assert length(encoded["runs"]) == 2

    for run <- encoded["runs"] do
      refute Map.has_key?(run["agent"], "provider_account")
      assert run["agent"]["extra_mcp_servers"] == %{"provider_account" => "custom"}
    end

    assert {:ok, ^reply} = Messages.decode_reply("claim", encoded)
    assert {:ok, current} = Messages.encode_reply("claim", reply)
    assert Map.has_key?(hd(current["runs"])["agent"], "provider_account")
    wire = put_in(wire, ["agent", "provider_account"], account())
    assert {:ok, bound} = RunSpec.from_wire(wire)
    assert {:ok, mixed} = Reply.Claim.new(runs: [run, bound])
    assert {:error, {:not_in_version, ^old}} = Messages.encode_reply("claim", mixed, old)
    assert {:ok, %{"runs" => []}} = Messages.encode_reply("claim", %Reply.Claim{runs: []}, old)
  end

  test "byte boundaries validate native construction and wire decoding" do
    for {field, max} <- [{"base_url", 2_048}, {"api_key", 8_192}] do
      for size <- [1, max] do
        wire = Map.put(account(), field, String.duplicate("x", size))
        assert {:ok, value} = ProviderAccount.from_wire(wire)
        assert {:ok, ^value} = ProviderAccount.new(Map.from_struct(value))
      end

      for value <- [nil, "", String.duplicate("x", max + 1), <<255>>] do
        assert {:error, {:invalid_payload, [^field], _}} =
                 ProviderAccount.from_wire(Map.put(account(), field, value))
      end

      assert {:error, {:invalid_payload, [^field], :required}} =
               ProviderAccount.from_wire(Map.delete(account(), field))
    end
  end

  test "model count and value byte boundaries" do
    for count <- [8, 9] do
      wire = Map.put(account(), "models", Map.new(1..count, &{"alias#{&1}", "model"}))
      assert {:error, {:invalid_payload, ["models"], reason}} = ProviderAccount.from_wire(wire)
      # Six aliases exist: eight entries pass the count gate but fail alias validation.
      if count == 8,
        do: assert(match?({:enum, _}, reason)),
        else: assert(reason == {:count, 0, 8})
    end

    for models <- [%{}, Map.new(ProviderAccount.model_aliases(:claude), &{&1, "model"})] do
      assert {:ok, _} = ProviderAccount.from_wire(Map.put(account(), "models", models))
    end

    for size <- [1, 128] do
      assert {:ok, _} =
               ProviderAccount.from_wire(
                 Map.put(account(), "models", %{"default" => String.duplicate("x", size)})
               )
    end

    for value <- ["", String.duplicate("x", 129), nil, <<255>>] do
      assert {:error, {:invalid_payload, ["models"], _}} =
               ProviderAccount.from_wire(Map.put(account(), "models", %{"default" => value}))
    end
  end
end
