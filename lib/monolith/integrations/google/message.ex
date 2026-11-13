defmodule Monolith.Integrations.Google.Message do
  @moduledoc false

  @max_text 256 * 1024
  @max_encoded 2 * 1024 * 1024
  @max_parts 100
  @max_depth 10

  def summary(%{"id" => id, "messages" => messages} = thread, expected)
      when id == expected and is_list(messages) and length(messages) in 1..100 do
    with true <- Enum.all?(messages, &is_map/1),
         last = List.last(messages),
         {:ok, fields} <- fields(last),
         true <- Enum.all?(messages, &valid_labels?/1) do
      {:ok,
       %{
         id: id,
         subject: fields.subject,
         from: fields.from,
         date: fields.date,
         snippet: text_field(thread["snippet"] || last["snippet"] || "", 8192),
         unread: Enum.any?(messages, &("UNREAD" in Map.get(&1, "labelIds", [])))
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def summary(_, _), do: {:error, :invalid_response}

  def thread(%{"id" => id, "messages" => messages}, expected)
      when id == expected and is_list(messages) and length(messages) in 1..100 do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
      with %{"id" => message_id, "payload" => payload} <- message,
           true <- valid_id?(message_id),
           {:ok, fields} <- fields(message),
           {:ok, text} <- body(payload),
           {:ok, attachments} <- attachments(payload) do
        {:cont,
         {:ok, [Map.merge(fields, %{id: message_id, text: text, attachments: attachments}) | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:halt, {:error, :invalid_response}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, %{id: id, messages: Enum.reverse(rows)}}
      error -> error
    end
  end

  def thread(_, _), do: {:error, :invalid_response}

  defp fields(%{"payload" => %{"headers" => headers}})
       when is_list(headers) and length(headers) <= 200 do
    if Enum.all?(
         headers,
         &match?(
           %{"name" => name, "value" => value} when is_binary(name) and is_binary(value),
           &1
         )
       ) do
      {:ok,
       Map.new([:from, :to, :date, :subject], fn key ->
         value =
           Enum.find_value(headers, "", fn %{"name" => name, "value" => value} ->
             if String.downcase(name) == Atom.to_string(key), do: value
           end)

         {key, text_field(value, 8192)}
       end)}
    else
      {:error, :invalid_response}
    end
  end

  defp fields(_), do: {:error, :invalid_response}

  defp valid_labels?(message) do
    labels = Map.get(message, "labelIds", [])
    is_list(labels) and length(labels) <= 100 and Enum.all?(labels, &is_binary/1)
  end

  defp attachments(payload) do
    with {:ok, parts} <- attachment_parts(payload, 0, []) do
      {:ok, Enum.reverse(parts)}
    end
  end

  defp attachment_parts(_, depth, _) when depth > @max_depth,
    do: {:error, :response_too_large}

  defp attachment_parts(part, depth, acc) when is_map(part) do
    if attachment?(part),
      do: attachment_metadata(part, acc),
      else: attachment_children(part, depth, acc)
  end

  defp attachment_parts(_, _, _), do: {:error, :invalid_response}

  defp attachment_metadata(part, acc) do
    body = part["body"] || %{}
    id = body["attachmentId"]
    filename = part["filename"] || "attachment"
    mime = part["mimeType"] || "application/octet-stream"
    size = body["size"] || 0

    cond do
      is_nil(id) ->
        {:ok, acc}

      valid_attachment?(id, filename, mime, size) ->
        {:ok, [%{attachment_id: id, filename: filename, mime_type: mime, size: size} | acc]}

      true ->
        # An unsupported optional attachment must not make its whole email unreadable.
        {:ok, acc}
    end
  end

  defp valid_attachment?(id, filename, mime, size) do
    valid_attachment_id?(id) and valid_filename?(filename) and valid_mime?(mime) and
      is_integer(size) and size >= 0
  end

  defp valid_attachment_id?(id),
    do: is_binary(id) and Regex.match?(~r/\A[-A-Za-z0-9_.+=~]{1,2048}\z/, id)

  defp valid_filename?(value), do: is_binary(value) and byte_size(value) <= 1024
  defp valid_mime?(value), do: is_binary(value) and byte_size(value) <= 255

  defp attachment_children(part, depth, acc) do
    case part["parts"] do
      nil ->
        {:ok, acc}

      children when is_list(children) and length(children) <= @max_parts ->
        walk_attachment_children(children, depth, acc)

      _ ->
        {:error, :response_too_large}
    end
  end

  defp walk_attachment_children(children, depth, acc) do
    Enum.reduce_while(children, {:ok, acc}, fn child, {:ok, rows} ->
      case attachment_parts(child, depth + 1, rows) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp body(payload) do
    with {:ok, {_, _, _, plain, html}} <- parts(payload, 0, {0, 0, 0, [], []}) do
      selected = if plain == [], do: html, else: plain
      text = selected |> Enum.reverse() |> Enum.join("\n")
      if byte_size(text) <= @max_text, do: {:ok, text}, else: {:error, :response_too_large}
    end
  end

  defp parts(_, depth, _) when depth > @max_depth, do: {:error, :response_too_large}

  defp parts(part, depth, {count, encoded, bytes, plain, html}) when is_map(part) do
    count = count + 1

    cond do
      count > @max_parts ->
        {:error, :response_too_large}

      attachment?(part) ->
        {:ok, {count, encoded, bytes, plain, html}}

      part["mimeType"] in ["text/plain", "text/html"] ->
        decode_part(part, {count, encoded, bytes, plain, html})

      true ->
        children(part["parts"], depth, {count, encoded, bytes, plain, html})
    end
  end

  defp parts(_, _, _), do: {:error, :invalid_response}

  defp children(nil, _depth, acc), do: {:ok, acc}

  defp children(children, depth, acc) when is_list(children) and length(children) <= @max_parts do
    Enum.reduce_while(children, {:ok, acc}, fn child, {:ok, acc} ->
      case parts(child, depth + 1, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp children(_, _, _), do: {:error, :response_too_large}

  defp attachment?(part) do
    filename = part["filename"]
    body = part["body"]
    headers = Map.get(part, "headers", [])

    (is_binary(filename) and filename != "") or
      (is_map(body) and is_binary(body["attachmentId"])) or
      (is_list(headers) and
         Enum.any?(headers, fn
           %{"name" => name, "value" => value} when is_binary(name) and is_binary(value) ->
             String.downcase(name) == "content-disposition" and
               String.starts_with?(String.downcase(String.trim(value)), "attachment")

           _ ->
             false
         end))
  end

  defp decode_part(part, {_, encoded, _, _, _} = acc) do
    data = get_in(part, ["body", "data"]) || ""

    if is_binary(data) and encoded + byte_size(data) <= @max_encoded,
      do: decode_data(data, part, acc),
      else: {:error, :response_too_large}
  end

  defp decode_data(data, part, {_, _, bytes, _, _} = acc) do
    # Gmail uses unpadded base64url, but padding is legal too.
    case Base.url_decode64(data, padding: rem(byte_size(data), 4) == 0) do
      {:ok, decoded} when byte_size(decoded) + bytes <= @max_text ->
        append_text(part, decoded, byte_size(data), acc)

      {:ok, _} ->
        {:error, :response_too_large}

      :error ->
        {:error, :invalid_response}
    end
  end

  defp append_text(part, decoded, encoded_size, {n, encoded, bytes, plain, html}) do
    if String.valid?(decoded) do
      text = String.replace(decoded, "\0", "")
      e = encoded + encoded_size
      b = bytes + byte_size(decoded)

      if part["mimeType"] == "text/plain",
        do: {:ok, {n, e, b, [text | plain], html}},
        else: {:ok, {n, e, b, plain, [html_text(text) | html]}}
    else
      {:error, :invalid_response}
    end
  end

  @doc """
  Conservative HTML-to-text extraction, not an HTML renderer/sanitizer. Drop all
  markup/attributes/comments and script/style/template contents; never resolve
  URLs, CSS or entities to markup. Unknown entities remain literal plain text.
  Unterminated tags/comments suppress the remainder. Output still needs escaping.
  """
  def html_text(html) when is_binary(html) and byte_size(html) <= @max_text do
    html
    |> scan_html([], nil)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> decode_entities()
    |> String.trim()
  end

  defp scan_html(<<>>, acc, _skip), do: acc

  defp scan_html("<!--" <> rest, acc, skip) do
    case :binary.split(rest, "-->") do
      [_, after_comment] -> scan_html(after_comment, acc, skip)
      _ -> acc
    end
  end

  defp scan_html("<" <> rest, acc, skip) do
    case take_tag(rest, nil, []) do
      {:ok, tag, tail} ->
        name =
          tag
          |> String.trim()
          |> String.downcase()
          |> String.split([" ", "\t", "\r", "\n", "/"], trim: true)
          |> List.first()

        closing? = String.starts_with?(String.trim_leading(tag), "/")

        scan_tag(tail, acc, skip, name, closing?)

      _ ->
        acc
    end
  end

  defp scan_html(<<byte, rest::binary>>, acc, nil), do: scan_html(rest, [<<byte>> | acc], nil)
  defp scan_html(<<_byte, rest::binary>>, acc, skip), do: scan_html(rest, acc, skip)

  # Quoted attribute delimiters are not tag boundaries. Malformed/unclosed markup
  # suppresses the remainder instead of leaking attribute/URL fragments into text.
  defp take_tag(<<>>, _quote, _acc), do: :incomplete

  defp take_tag(">" <> tail, nil, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), tail}

  defp take_tag(<<char, tail::binary>>, nil, acc) when char in [?", ?'],
    do: take_tag(tail, char, [<<char>> | acc])

  defp take_tag(<<char, tail::binary>>, quote, acc) when char == quote,
    do: take_tag(tail, nil, [<<char>> | acc])

  defp take_tag(<<char, tail::binary>>, quote, acc),
    do: take_tag(tail, quote, [<<char>> | acc])

  defp scan_tag(tail, acc, skip, name, closing?) do
    cond do
      not is_nil(skip) and closing? and name == skip -> scan_html(tail, ["\n" | acc], nil)
      not is_nil(skip) -> scan_html(tail, acc, skip)
      name in ["script", "style", "template"] and not closing? -> scan_html(tail, acc, name)
      true -> scan_html(tail, ["\n" | acc], nil)
    end
  end

  defp decode_entities(text) do
    # One pass; encoded markup stays text. HEEx must escape the returned string.
    Regex.replace(
      ~r/&(?:amp|lt|gt|quot|apos|nbsp|#[0-9]{1,7}|#x[0-9a-fA-F]{1,6});/,
      text,
      fn entity ->
        case entity do
          "&amp;" -> "&"
          "&lt;" -> "<"
          "&gt;" -> ">"
          "&quot;" -> "\""
          "&apos;" -> "'"
          "&nbsp;" -> " "
          _ -> decode_numeric(entity)
        end
      end
    )
  end

  defp decode_numeric(entity) do
    {digits, base} =
      if String.starts_with?(entity, "&#x"),
        do: {String.slice(entity, 3..-2//1), 16},
        else: {String.slice(entity, 2..-2//1), 10}

    case Integer.parse(digits, base) do
      {n, ""} when n in 1..0x10FFFF and n not in 0xD800..0xDFFF -> <<n::utf8>>
      _ -> ""
    end
  end

  defp text_field(value, max) when is_binary(value) and byte_size(value) <= max do
    if String.valid?(value), do: String.replace(value, "\0", ""), else: ""
  end

  defp text_field(_, _), do: ""

  defp valid_id?(value) when is_binary(value),
    do: Regex.match?(~r/\A[A-Za-z0-9_-]{1,256}\z/, value)

  defp valid_id?(_), do: false
end
