defmodule Lovelace.Integrations.GoogleMessageBoundariesTest do
  use ExUnit.Case, async: true

  alias Lovelace.Integrations.Google.Message

  test "thread identity, nonempty message lists and message identities are required" do
    valid = thread(part("text/plain", "Readable"))

    for invalid <- [
          nil,
          %{},
          %{valid | "id" => "another-thread"},
          %{valid | "messages" => []},
          %{valid | "messages" => List.duplicate(hd(valid["messages"]), 101)}
        ] do
      assert {:error, :invalid_response} = Message.summary(invalid, "thread")
      assert {:error, :invalid_response} = Message.thread(invalid, "thread")
    end

    for invalid <- [
          nil,
          %{},
          %{"id" => nil, "payload" => payload()},
          %{"id" => "../message", "payload" => payload()}
        ] do
      assert {:error, :invalid_response} =
               Message.thread(%{valid | "messages" => [invalid]}, "thread")
    end
  end

  test "malformed header and label collections cannot become an inbox summary" do
    valid = thread(payload())
    message = hd(valid["messages"])

    for headers <- [
          nil,
          %{},
          List.duplicate(%{"name" => "From", "value" => "Sender"}, 201),
          [%{"name" => "Subject", "value" => 123}],
          [nil]
        ] do
      invalid = %{valid | "messages" => [%{message | "payload" => %{"headers" => headers}}]}
      assert {:error, :invalid_response} = Message.summary(invalid, "thread")
      assert {:error, :invalid_response} = Message.thread(invalid, "thread")
    end

    for labels <- [nil, "UNREAD", ["INBOX", 1], List.duplicate("INBOX", 101)] do
      invalid = %{valid | "messages" => [Map.put(message, "labelIds", labels)]}
      assert {:error, :invalid_response} = Message.summary(invalid, "thread")
    end
  end

  test "summaries use the last message but aggregate unread state without retaining unsafe text" do
    first = %{"id" => "first", "labelIds" => ["UNREAD"], "payload" => payload()}

    last = %{
      "id" => "last",
      "snippet" => "Last\0 snippet",
      "payload" => %{
        "headers" => [
          %{"name" => "sUbJeCt", "value" => "Last\0 subject"},
          %{"name" => "From", "value" => String.duplicate("x", 8193)},
          %{"name" => "Date", "value" => <<255>>}
        ]
      }
    }

    input = %{"id" => "thread", "messages" => [first, last]}

    assert {:ok,
            %{subject: "Last subject", from: "", date: "", snippet: "Last snippet", unread: true}} =
             Message.summary(input, "thread")

    assert {:ok, %{snippet: ""}} = Message.summary(Map.put(input, "snippet", %{}), "thread")
    assert {:ok, %{unread: false}} = Message.summary(%{input | "messages" => [last]}, "thread")
  end

  test "MIME node budgets apply across siblings, not only to each child list" do
    branch = %{
      "mimeType" => "multipart/mixed",
      "parts" => List.duplicate(part("text/plain", "x"), 50)
    }

    input = thread(%{"mimeType" => "multipart/mixed", "parts" => [branch, branch]})
    assert {:error, :response_too_large} = Message.thread(input, "thread")
  end

  test "malformed MIME nodes fail closed instead of returning a partially parsed message" do
    for {child, reason} <- [
          {nil, :invalid_response},
          {42, :invalid_response},
          {%{"parts" => "not a list"}, :response_too_large}
        ] do
      input =
        thread(%{"mimeType" => "multipart/mixed", "parts" => [part("text/plain", "safe"), child]})

      assert {:error, ^reason} = Message.thread(input, "thread")
    end

    assert {:ok, %{messages: [%{text: "", attachments: []}]}} =
             Message.thread(thread(%{"mimeType" => "application/octet-stream"}), "thread")
  end

  test "attachment traversal is bounded even when text decoding needs no child traversal" do
    deep = Enum.reduce(1..11, %{}, fn _, child -> %{"parts" => [child]} end)

    for {children, reason} <- [
          {[deep], :response_too_large},
          {[nil], :invalid_response},
          {"not a list", :response_too_large}
        ] do
      input = thread(Map.put(part("text/plain", "Readable"), "parts", children))
      assert {:error, ^reason} = Message.thread(input, "thread")
    end
  end

  test "content disposition attachments never leak their decoded bytes into message text" do
    attached =
      part("text/plain", "PRIVATE FILE CONTENT")
      |> Map.put("headers", [
        %{"name" => "CoNtEnT-DiSpOsItIoN", "value" => "  AtTaChMeNt; filename=note.txt"}
      ])

    readable = Map.put(part("text/plain", "Visible\0 text"), "headers", [nil, %{}])

    assert {:ok, %{messages: [%{text: "Visible text", attachments: []}]}} =
             Message.thread(thread(%{"parts" => [attached, readable]}), "thread")
  end

  test "HTML entities stay plain text and invalid Unicode scalars are dropped" do
    html =
      "&quot;quoted&quot;&nbsp;&apos;apostrophe&apos; &amp;lt;script&amp;gt; &#65; &#x41; &#0; &#55296; &#1114112; &unknown;"

    assert Message.html_text(html) ==
             "\"quoted\" 'apostrophe' &lt;script&gt; A A    &unknown;"

    assert Message.html_text("Visible<!-- private unclosed https://private.invalid") == "Visible"
  end

  test "invalid UTF-8 and cumulative decoded text are rejected before display" do
    assert {:error, :invalid_response} =
             Message.thread(thread(part("text/plain", <<255>>)), "thread")

    # Each fragment fits individually; the message-wide decoded budget does not.
    input =
      thread(%{
        "parts" => [
          part("text/plain", String.duplicate("a", 131_073)),
          part("text/plain", String.duplicate("b", 131_073))
        ]
      })

    assert {:error, :response_too_large} = Message.thread(input, "thread")
  end

  defp payload, do: %{"headers" => [%{"name" => "Subject", "value" => "Subject"}]}

  defp part(mime, text),
    do: %{"mimeType" => mime, "body" => %{"data" => Base.url_encode64(text, padding: false)}}

  defp thread(body) do
    %{
      "id" => "thread",
      "messages" => [
        %{"id" => "message", "payload" => Map.put(body, "headers", payload()["headers"])}
      ]
    }
  end
end
