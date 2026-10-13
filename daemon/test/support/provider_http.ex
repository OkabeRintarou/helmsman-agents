defmodule HelmsmanDaemon.ProviderHTTP do
  @moduledoc "Loopback-only fake provider; reports credential classes, never header values."

  def start(owner, name, expected_key) do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(socket)
    task = Task.start_link(fn -> accept(socket, owner, name, expected_key, 0) end)
    {:ok, pid} = task

    {"http://127.0.0.1:#{port}",
     fn ->
       :gen_tcp.close(socket)
       Process.unlink(pid)
       Process.exit(pid, :shutdown)
     end}
  end

  defp accept(socket, owner, name, key, calls) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        try do
          serve(client, owner, name, key, calls)
        after
          :gen_tcp.close(client)
        end

        accept(socket, owner, name, key, calls + 1)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(client, owner, name, key, calls) do
    with {:ok, header, body} <- headers(client, ""),
         [request | lines] <- String.split(header, "\r\n"),
         [_, path, _] <- String.split(request, " "),
         headers <-
           Map.new(lines, fn line ->
             [name, value] = String.split(line, ":", parts: 2)
             {String.downcase(name), String.trim(value)}
           end),
         {:ok, body} <- body(client, body, String.to_integer(headers["content-length"] || "0")) do
      model =
        case JSON.decode(body) do
          {:ok, value} -> value["model"]
          _ -> nil
        end

      classes = Map.new(["authorization", "x-api-key"], &{&1, credential(headers[&1], key)})

      send(owner, {:provider_request, name, %{path: path, credentials: classes, model: model}})
      respond(client, path, body, calls)
    end
  end

  defp credential(nil, _key), do: :absent
  defp credential(key, key), do: :account
  defp credential("Bearer " <> key, key), do: :account
  defp credential(_value, _key), do: :other

  defp headers(client, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, body] ->
        {:ok, head, body}

      _ ->
        with {:ok, next} <- :gen_tcp.recv(client, 0, 10_000), do: headers(client, bytes <> next)
    end
  end

  defp body(_client, bytes, size) when byte_size(bytes) >= size, do: {:ok, bytes}

  defp body(client, bytes, size) do
    with {:ok, next} <- :gen_tcp.recv(client, 0, 10_000), do: body(client, bytes <> next, size)
  end

  defp respond(client, path, body, calls) do
    request =
      case JSON.decode(body) do
        {:ok, request} -> request
        _ -> %{}
      end

    cond do
      String.starts_with?(path, "/account/v1/messages") ->
        claude_response(client, request)

      path == "/account/v1/responses" ->
        codex_response(client, request, calls)

      true ->
        bytes =
          JSON.encode!(%{
            "error" => %{
              "type" => "authentication_error",
              "message" => "Local fake provider rejects this request"
            }
          })

        :gen_tcp.send(
          client,
          "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(bytes)}\r\nConnection: close\r\n\r\n" <>
            bytes
        )
    end
  end

  defp claude_response(client, request) do
    used? =
      Enum.any?(request["messages"] || [], fn message ->
        is_list(message["content"]) and
          Enum.any?(message["content"], &(&1["type"] == "tool_result"))
      end)

    block =
      if used?,
        do: %{"type" => "text", "text" => "OK"},
        else: %{
          "type" => "tool_use",
          "id" => "tool_local",
          "name" => "Bash",
          "input" => %{
            "command" => "printf SHELL_EXECUTED",
            "description" => "Print local smoke sentinel"
          }
        }

    events = [
      {"message_start",
       %{
         "type" => "message_start",
         "message" => %{
           "id" => "msg_local",
           "type" => "message",
           "role" => "assistant",
           "model" => "account-model",
           "content" => [],
           "stop_reason" => nil,
           "stop_sequence" => nil,
           "usage" => %{"input_tokens" => 1, "output_tokens" => 0}
         }
       }},
      {"content_block_start",
       %{
         "type" => "content_block_start",
         "index" => 0,
         "content_block" =>
           if(used?, do: %{block | "text" => ""}, else: %{block | "input" => %{}})
       }},
      {"content_block_stop", %{"type" => "content_block_stop", "index" => 0}},
      {"message_delta",
       %{
         "type" => "message_delta",
         "delta" => %{
           "stop_reason" => if(used?, do: "end_turn", else: "tool_use"),
           "stop_sequence" => nil
         },
         "usage" => %{"output_tokens" => 1}
       }},
      {"message_stop", %{"type" => "message_stop"}}
    ]

    events =
      if used? do
        List.insert_at(
          events,
          2,
          {"content_block_delta",
           %{
             "type" => "content_block_delta",
             "index" => 0,
             "delta" => %{"type" => "text_delta", "text" => "OK"}
           }}
        )
      else
        List.insert_at(
          events,
          2,
          {"content_block_delta",
           %{
             "type" => "content_block_delta",
             "index" => 0,
             "delta" => %{
               "type" => "input_json_delta",
               "partial_json" => JSON.encode!(block["input"])
             }
           }}
        )
      end

    send_sse(client, events)
  end

  defp codex_response(client, request, calls) do
    tool =
      Enum.find(
        request["tools"] || [],
        &(&1["name"] in ["exec_command", "shell_command", "shell"])
      )

    output =
      if calls == 0 and tool do
        args =
          case tool["name"] do
            "exec_command" ->
              %{
                "cmd" => "printf SHELL_EXECUTED",
                "yield_time_ms" => 1000,
                "max_output_tokens" => 1000
              }

            "shell_command" ->
              %{"command" => "printf SHELL_EXECUTED", "timeout_ms" => 1000}

            "shell" ->
              %{"command" => ["/bin/sh", "-c", "printf SHELL_EXECUTED"], "timeout_ms" => 1000}
          end

        %{
          "type" => "function_call",
          "id" => "fc_local",
          "call_id" => "call_local",
          "name" => tool["name"],
          "arguments" => JSON.encode!(args),
          "status" => "completed"
        }
      else
        %{
          "type" => "message",
          "id" => "msg_local",
          "role" => "assistant",
          "status" => "completed",
          "content" => [%{"type" => "output_text", "text" => "OK", "annotations" => []}]
        }
      end

    response = %{
      "id" => "resp_local",
      "object" => "response",
      "created_at" => 0,
      "status" => "completed",
      "model" => "account-model",
      "output" => [output],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
    }

    events = [
      {"response.created",
       %{
         "type" => "response.created",
         "response" => %{response | "status" => "in_progress", "output" => []}
       }},
      {"response.output_item.added",
       %{"type" => "response.output_item.added", "output_index" => 0, "item" => output}},
      {"response.output_item.done",
       %{"type" => "response.output_item.done", "output_index" => 0, "item" => output}},
      {"response.completed", %{"type" => "response.completed", "response" => response}}
    ]

    send_sse(client, events)
  end

  defp send_sse(client, events) do
    bytes =
      Enum.map_join(events, "", fn {event, data} ->
        "event: #{event}\ndata: #{JSON.encode!(data)}\n\n"
      end)

    :gen_tcp.send(
      client,
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: #{byte_size(bytes)}\r\nConnection: close\r\n\r\n" <>
        bytes
    )
  end
end
