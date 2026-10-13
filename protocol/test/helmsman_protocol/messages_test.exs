defmodule HelmsmanProtocol.MessagesTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{ErrorReply, Fixtures, Messages, Reply, Report}

  test "directories contain exactly the specified reports and pushes" do
    assert Messages.daemon_to_server() ==
             ~w(join sync claim starting started events heartbeat steer_ack git_token pushed repo_status finished rotate_token)

    assert Messages.server_to_daemon() == ~w(runs_available cancel steer config_changed revoked)
  end

  test "every message decodes and encodes back with its name" do
    for {name, payload} <- Map.merge(Fixtures.reports(), Fixtures.pushes()) do
      assert {:ok, value} = Messages.decode(name, payload)
      assert {:ok, {^name, ^payload}} = Messages.encode(value)

      for version <- 1..HelmsmanProtocol.version() do
        expected =
          case Fixtures.at_version(name, payload, version) do
            :error -> {:error, {:not_in_version, version}}
            wire -> {:ok, {name, wire}}
          end

        assert expected == Messages.encode(value, version), "#{name} at #{version}"
      end

      assert {:ok, ^value} = Messages.decode(name, payload)
      assert {:error, {:not_in_version, 0}} = Messages.encode(value, 0)
      future = HelmsmanProtocol.version() + 1
      assert {:error, {:not_in_version, ^future}} = Messages.encode(value, future)
    end

    assert {:ok, %Report.Starting{run_id: 7}} = Messages.decode("starting", %{"run_id" => 7})
    assert {:error, {:invalid_payload, ["message"], _}} = Messages.decode("hello", %{})

    assert {:error, {:invalid_payload, ["run_id"], :type}} =
             Messages.decode("starting", %{"run_id" => "7"})

    assert {:error, {:invalid_payload, ["run_id"], :type}} =
             Messages.encode(%Report.Starting{run_id: "7"})

    assert {:error, {:invalid_payload, ["message"], :not_allowed}} =
             Messages.encode(%Reply.Empty{})
  end

  test "join needs protocol, events must contain 1 to 200 items, unknown fields ignored" do
    assert {:error, {:invalid_payload, ["protocol"], :required}} =
             Messages.decode("join", Map.delete(Fixtures.join(), "protocol"))

    for count <- [0, 201] do
      events = for seq <- 1..count//1, do: Fixtures.event("text", seq)

      assert {:error, {:invalid_payload, ["events"], {:count, 1, 200}}} =
               Messages.decode("events", %{"run_id" => 7, "events" => events})
    end

    assert {:ok, _} =
             Messages.decode("events", %{
               "run_id" => 7,
               "events" => Enum.map(1..200, &Fixtures.event("text", &1))
             })

    payload = Fixtures.reports()["heartbeat"]

    assert Messages.decode("heartbeat", payload) ==
             Messages.decode("heartbeat", Map.put(payload, "extra", true))
  end

  test "every successful reply decodes and roundtrips" do
    for {name, payload} <- Fixtures.replies() do
      assert {:ok, value} = Messages.decode_reply(name, payload)
      module = value.__struct__
      assert module.to_wire(value) == payload
      assert {:ok, ^payload} = Messages.encode_reply(name, value)
      assert {:ok, ^module} = Messages.reply_module(name)
      assert {:error, {:not_in_version, 0}} = Messages.encode_reply(name, value, 0)
      assert {:ok, error} = ErrorReply.new(:wrong_state, "wrong state")
      assert {:ok, wire} = Messages.encode_reply(name, error)
      assert {:ok, ^error} = ErrorReply.from_wire(wire)
      assert {:ok, ^value} = module.new(Map.from_struct(value))
    end

    assert {:error, {:invalid_payload, ["message"], _}} = Messages.decode_reply("hello", %{})

    assert {:error, {:invalid_payload, ["message"], _}} =
             Messages.encode_reply("hello", %Reply.Empty{})

    assert {:error, {:invalid_payload, [], :not_allowed}} =
             Messages.encode_reply("claim", %Reply.Empty{})

    assert {:error, {:invalid_payload, ["acked_seq"], :type}} =
             Messages.encode_reply("events", %Reply.Events{acked_seq: -1})

    assert {:error, {:invalid_payload, ["reason"], :required}} =
             Messages.decode_reply("starting", %{"action" => "abort"})

    assert {:ok, _} =
             Messages.decode_reply("starting", %{"action" => "abort", "reason" => "obsolete"})
  end

  test "all error codes are strict, ordinary errors omit and ignore version details" do
    assert ErrorReply.codes() == ~w(invalid_payload unsupported_protocol not_found wrong_state)a
    assert {:ok, error} = ErrorReply.new(:wrong_state, "run 7 already finished")

    assert ErrorReply.to_wire(error) == %{
             "reason" => "wrong_state",
             "message" => "run 7 already finished"
           }

    payload =
      ErrorReply.to_wire(error)
      |> Map.merge(%{"server_version" => "bad", "min_version" => -1, "upgrade_url" => []})

    assert {:ok, ^error} = ErrorReply.from_wire(payload)

    for reason <- [:invalid_payload, :not_found, :wrong_state] do
      assert {:ok, value} = ErrorReply.new(reason, "error")
      assert {:ok, wire} = Messages.encode_reply("finished", value)
      assert {:ok, ^value} = ErrorReply.from_wire(wire)
    end

    assert {:error, {:invalid_payload, ["reason"], _}} =
             ErrorReply.from_wire(%{"reason" => "teapot", "message" => "x"})
  end

  test "unsupported_protocol preserves structured version range and requires all details" do
    assert {:ok, error} = ErrorReply.unsupported_protocol("https://h.example/install.sh")
    payload = ErrorReply.to_wire(error)
    assert error.server_version == HelmsmanProtocol.version()
    assert error.min_version == HelmsmanProtocol.min_version()
    assert {:ok, ^error} = ErrorReply.from_wire(payload |> JSON.encode!() |> JSON.decode!())
    assert {:ok, ^payload} = Messages.encode_reply("join", error)
    assert {:error, {:not_in_version, 0}} = Messages.encode_reply("join", error, 0)

    assert {:ok, ^error} =
             ErrorReply.new(Map.from_struct(error) |> Map.put(:reason, "unsupported_protocol"))

    assert {:error, {:invalid_payload, [], :type}} = ErrorReply.new(["bad"])

    for field <- ~w(server_version min_version upgrade_url) do
      assert {:error, {:invalid_payload, [^field], :required}} =
               ErrorReply.from_wire(Map.delete(payload, field))

      assert {:error, {:invalid_payload, [^field], :required}} =
               ErrorReply.from_wire(Map.put(payload, field, nil))
    end

    assert {:error, {:invalid_payload, ["server_version"], :required}} =
             ErrorReply.from_wire(%{"reason" => "unsupported_protocol", "message" => "x"})
  end

  test "push and rotation tokens are redacted while wire preserves them" do
    for {module, payload} <- [
          {Reply.GitToken, Fixtures.replies()["git_token"]},
          {Reply.RotateToken, Fixtures.replies()["rotate_token"]}
        ] do
      assert {:ok, value} = module.from_wire(payload)
      refute inspect(value) =~ payload["token"]
      assert inspect(value) =~ "**redacted**"
      assert module.to_wire(value) == payload
    end
  end

  test "CLI availability, version and explanation constraints" do
    for payload <- [
          Fixtures.cli() |> Map.put("version", nil),
          Fixtures.cli() |> Map.put("unavailable_reason", "broken"),
          Fixtures.cli() |> Map.put("available", false)
        ] do
      assert {:error, {:invalid_payload, _, _}} = HelmsmanProtocol.CLI.from_wire(payload)
    end

    assert {:ok, _} =
             HelmsmanProtocol.CLI.from_wire(
               Fixtures.cli()
               |> Map.merge(%{
                 "version" => nil,
                 "available" => false,
                 "unavailable_reason" => "Cannot detect version"
               })
             )

    assert {:error, {:invalid_payload, ["unavailable_reason"], {:too_long, 1_024}}} =
             HelmsmanProtocol.CLI.from_wire(
               Fixtures.cli()
               |> Map.merge(%{
                 "available" => false,
                 "unavailable_reason" => String.duplicate("x", 1_025)
               })
             )
  end
end
