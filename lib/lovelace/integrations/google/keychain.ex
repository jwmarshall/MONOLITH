defmodule Lovelace.Integrations.Google.Keychain do
  @moduledoc """
  Local macOS Keychain vault, default service `LOVELACE Gmail`, keyed by account UUID.
  Only the separate `LOVELACE Gemini` service is additionally allowlisted; the default
  Gmail JSON envelope remains unchanged.
  `get/1` returns `{:ok, value}`; `put/2` and idempotent `delete/1` return `:ok`.
  Errors are safe atoms; no plaintext fallback. The caller may inject a fake
  module implementing this behaviour instead of calling this native boundary.

  Build explicitly with `mix lovelace.keychain.build`. Tokens travel solely over
  the helper's newline-delimited JSON stdin/stdout, never argv or temporary files.
  No Keychain operation is permitted in test builds; the test-only runner seam
  exercises framing/limits without launching the helper.
  """

  @callback get(binary()) :: {:ok, binary()} | {:error, atom()}
  @callback put(binary(), binary()) :: :ok | {:error, atom()}
  @callback delete(binary()) :: :ok | {:error, atom()}

  @gmail_service "LOVELACE Gmail"
  @services [@gmail_service, "LOVELACE Gemini"]
  @max_value 16 * 1024
  @max_output 128 * 1024
  @timeout 5_000
  @errors [:not_found, :locked, :unavailable, :timeout, :invalid_account, :invalid_value]

  def get(account, service \\ @gmail_service), do: operation("get", account, nil, service)

  def put(account, value, service \\ @gmail_service),
    do: operation("put", account, value, service)

  def delete(account, service \\ @gmail_service), do: operation("delete", account, nil, service)

  defp operation(op, account, value, service), do: guarded(op, account, value, &native/1, service)

  if Mix.env() == :test do
    @doc false
    def with_test_runner(op, account, value, runner, service \\ @gmail_service)
        when is_function(runner, 1),
        do: guarded(op, account, value, runner, service)
  end

  defp guarded(op, account, value, runner, service) do
    with :ok <- validate_service(service),
         :ok <- validate_account(account),
         :ok <- validate_value(op, value) do
      input = encode_request(op, account, value, service)

      # Catch inside the worker, preventing Task crash reports containing tokens.
      task =
        Task.async(fn ->
          try do
            case runner.(input) do
              {:ok, output} when is_binary(output) and byte_size(output) <= @max_output ->
                decode(output, op)

              {:error, reason} when reason in @errors ->
                {:error, reason}

              _ ->
                {:error, :unavailable}
            end
          rescue
            _ -> {:error, :unavailable}
          catch
            _, _ -> {:error, :unavailable}
          end
        end)

      case Task.yield(task, @timeout) do
        {:ok, result} ->
          result

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}
      end
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp encode_request(op, account, value, service) do
    # An old helper ignores unknown service fields. Namespace Gemini operations
    # so that helper rejects them before any Keychain read/write, until rebuilt.
    wire_op = if service == "LOVELACE Gemini", do: "gemini_" <> op, else: op
    payload = %{operation: wire_op, account: String.downcase(account)}
    payload = if service == @gmail_service, do: payload, else: Map.put(payload, :service, service)
    payload = if op == "put", do: Map.put(payload, :value, value), else: payload
    Jason.encode!(payload) <> "\n"
  end

  defp validate_service(service) when service in @services, do: :ok
  defp validate_service(_), do: {:error, :unavailable}

  defp validate_account(account) when is_binary(account) do
    if Regex.match?(
         ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/,
         account
       ), do: :ok, else: {:error, :invalid_account}
  end

  defp validate_account(_), do: {:error, :invalid_account}

  defp validate_value("put", value) when is_binary(value) and byte_size(value) in 1..@max_value do
    if String.valid?(value), do: :ok, else: {:error, :invalid_value}
  end

  defp validate_value(op, nil) when op in ["get", "delete"], do: :ok
  defp validate_value(_, _), do: {:error, :invalid_value}

  defp decode(output, op) do
    # Exactly one JSON line; JSON whitespace is otherwise harmless.
    with [line, ""] <- String.split(output, "\n"),
         {:ok, result} <- Jason.decode(line) do
      decode_result(result, op)
    else
      _ -> {:error, :unavailable}
    end
  end

  defp decode_result(%{"ok" => true, "value" => value}, "get") do
    if validate_value("put", value) == :ok, do: {:ok, value}, else: {:error, :unavailable}
  end

  defp decode_result(%{"ok" => true}, op) when op in ["put", "delete"], do: :ok
  defp decode_result(%{"error" => "not_found"}, _op), do: {:error, :not_found}
  defp decode_result(%{"error" => "locked"}, _op), do: {:error, :locked}
  defp decode_result(%{"error" => "unavailable"}, _op), do: {:error, :unavailable}
  defp decode_result(%{"error" => "timeout"}, _op), do: {:error, :timeout}
  defp decode_result(_, _), do: {:error, :unavailable}

  if Mix.env() == :test do
    defp native(_input), do: {:error, :unavailable}
  else
    defp native(input) do
      path = Application.app_dir(:lovelace, "priv/native/lovelace-keychain")

      if match?({:unix, :darwin}, :os.type()) and File.regular?(path) do
        port =
          Port.open({:spawn_executable, String.to_charlist(path)}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            :hide,
            args: []
          ])

        try do
          true = Port.command(port, input)
          collect(port, [], 0, System.monotonic_time(:millisecond) + @timeout - 100)
        after
          if Port.info(port), do: Port.close(port)
        end
      else
        {:error, :unavailable}
      end
    end

    defp collect(port, chunks, size, deadline) do
      remaining = max(0, deadline - System.monotonic_time(:millisecond))

      receive do
        {^port, {:data, data}} when byte_size(data) + size <= @max_output ->
          collect(port, [data | chunks], size + byte_size(data), deadline)

        {^port, {:data, _}} ->
          {:error, :unavailable}

        {^port, {:exit_status, 124}} ->
          {:error, :timeout}

        {^port, {:exit_status, 0}} ->
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

        {^port, {:exit_status, _}} ->
          {:error, :unavailable}
      after
        remaining -> {:error, :timeout}
      end
    end
  end
end
