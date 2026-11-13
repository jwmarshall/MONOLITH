defmodule Monolith.TestSupport.OAuthJobs do
  @moduledoc false
  alias Monolith.GitHub.Auth

  def complete(session, params), do: run(fn -> Auth.complete(session, params) end)

  def get(conn, path) do
    run(fn -> Phoenix.ConnTest.dispatch(conn, MonolithWeb.Endpoint, :get, path, nil) end)
  end

  def run(fun) do
    task = Task.async(fun)
    await(task, System.monotonic_time(:millisecond) + 10_000)
  end

  defp await(task, deadline) do
    case Task.yield(task, 0) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        exit(reason)

      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          Task.shutdown(task, :brutal_kill)
          raise "synthetic OAuth job did not settle"
        end

        Oban.drain_queue(queue: :oauth, with_safety: false)
        Process.sleep(5)
        await(task, deadline)
    end
  end
end
