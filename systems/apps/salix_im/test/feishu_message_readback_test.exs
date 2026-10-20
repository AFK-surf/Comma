defmodule SalixIM.Provider.Feishu.MessageReadbackTest do
  use SystemsClock.Case, async: true

  alias SalixIM.Provider.Feishu.{Message, MessageRenderer}
  alias SalixIM.MessageRenderer.Input

  test "flat and localized post nodes keep Markdown, code indentation, mentions and links" do
    content = %{
      "content" => [
        [%{"tag" => "md", "text" => "# 标题\n\n**正文** @_user_1"}],
        [%{"tag" => "code_block", "language" => "MARKDOWN", "text" => "  first\n```\n  last\n"}],
        [%{"tag" => "at", "user_id" => "ou_alice", "user_name" => "Alice"}],
        [%{"tag" => "a", "text" => "docs", "href" => "https://example.com"}],
        [%{"tag" => "img", "image_key" => "img_key"}]
      ]
    }

    for post <- [content, %{"zh_cn" => content}] do
      message = %{
        "msg_type" => "post",
        "body" => %{"content" => Jason.encode!(post)},
        "mentions" => [
          %{"key" => "@_user_1", "id" => %{"open_id" => "ou_alice"}, "name" => "Alice"}
        ]
      }

      normalized = Message.normalize(message)
      assert normalized["text"] =~ "# 标题\n\n**正文** @Alice"
      assert normalized["text"] =~ "````\n  first\n```\n  last\n````"
      assert normalized["text"] =~ "docs (https://example.com)"
      assert [%{"file_key" => "img_key"}] = normalized["attachments"]
    end
  end
end
