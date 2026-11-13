defmodule MonolithWeb.ErrorHTMLTest do
  use MonolithWeb.ConnCase, async: false

  import Phoenix.Template, only: [render_to_string: 4]

  test "HTML errors provide a labelled destination and local assets without exposing request details" do
    for status <- ["403", "404", "500", "503"] do
      html =
        render_to_string(MonolithWeb.ErrorHTML, status, "html",
          reason: "synthetic-private-error-detail",
          request_path: "/synthetic-private-path"
        )

      document = LazyHTML.from_document(html)
      assert Enum.any?(LazyHTML.query(document, "html[lang=en]"))
      assert Enum.any?(LazyHTML.query(document, "meta[name=viewport]"))

      assert Enum.any?(
               LazyHTML.query(document, "main[aria-labelledby=error-heading] #error-heading")
             )

      assert Enum.any?(LazyHTML.query(document, "a[href='/']"))
      assert Enum.any?(LazyHTML.query(document, "link[rel=stylesheet][href^='/assets/']"))
      assert LazyHTML.query(document, ".onboarding-eyebrow") |> LazyHTML.text() =~ status
      assert Enum.empty?(LazyHTML.query(document, "script, input, form"))
      refute html =~ "synthetic-private"
    end
  end
end
