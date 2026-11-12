defmodule MonolithWeb.Plugs.SensitivePath do
  @moduledoc false

  # Match the decoded, nonempty path components Phoenix routes, including aliases
  # such as /unlock/ and /%75nlock. Raw request_path equality is insufficient.
  def matches?(conn, segments) do
    conn.path_info
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&URI.decode/1)
    |> Kernel.==(segments)
  end
end
