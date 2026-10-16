defmodule Helmsman.McpServers.Templates do
  @moduledoc "Built-in starter configurations; credentials are always local references."
  def all do
    [
      template(
        "github",
        "GitHub（远程）",
        "http",
        %{
          "url" => "https://api.githubcopilot.com/mcp/",
          "headers" => %{"Authorization" => "Bearer ${env:GITHUB_PAT}"}
        },
        ["GITHUB_PAT"]
      ),
      template(
        "github-local",
        "GitHub（本地容器）",
        "stdio",
        %{
          "command" => "docker",
          "args" => [
            "run",
            "-i",
            "--rm",
            "-e",
            "GITHUB_PERSONAL_ACCESS_TOKEN",
            "ghcr.io/github/github-mcp-server"
          ],
          "env" => %{"GITHUB_PERSONAL_ACCESS_TOKEN" => "${env:GITHUB_PAT}"}
        },
        ["GITHUB_PAT"]
      ),
      template(
        "playwright",
        "Playwright",
        "stdio",
        %{"command" => "npx", "args" => ["@playwright/mcp@latest"]},
        []
      ),
      template(
        "filesystem",
        "Filesystem（请修改目录）",
        "stdio",
        %{
          "command" => "npx",
          "args" => [
            "-y",
            "@modelcontextprotocol/server-filesystem",
            "/replace/with/your/directory"
          ]
        },
        []
      ),
      template(
        "fetch",
        "Fetch",
        "stdio",
        %{"command" => "uvx", "args" => ["mcp-server-fetch"]},
        []
      ),
      template("context7", "Context7", "http", %{"url" => "https://mcp.context7.com/mcp"}, [])
    ]
  end

  defp template(name, description, type, config, env_refs),
    do: %{
      name: name,
      description: description,
      config: Map.put(config, "type", type),
      env_refs: env_refs
    }
end
