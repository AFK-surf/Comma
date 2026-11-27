/**
 * @vitest-environment jsdom
 */
import { describe, expect, it } from "vitest";
import {
  isInteractiveChatMessageTarget,
  resolveChatMessageArticleFromEventTarget,
  resolveChatMessageCopyText,
  resolveChatMessageSelectionShare,
  resolveChatMessageText,
  resolveShareSourceTitle,
  selectedTextInRoot,
} from "../chatMessageContextMenu";

function assistantArticle(text: string, messageId = "msg_1") {
  const article = document.createElement("article");
  article.className = "comma-chat-message-assistant";
  article.dataset.slot = "chat-assistant-output";
  article.dataset.messageId = messageId;
  article.dataset.responseKey = "rsp_1";
  const paragraph = document.createElement("p");
  paragraph.textContent = text;
  article.appendChild(paragraph);
  return { article, paragraph };
}

function userArticle(text: string, messageId = "msg_user") {
  const article = document.createElement("article");
  article.className = "comma-chat-message-user";
  article.dataset.slot = "chat-user-output";
  article.dataset.messageId = messageId;
  const content = document.createElement("div");
  content.dataset.testid = "chat-user-bubble-content";
  content.textContent = text;
  article.appendChild(content);
  return { article, content };
}

describe("chatMessageContextMenu", () => {
  it("resolves assistant and user articles inside the root", () => {
    const root = document.createElement("div");
    const { article, paragraph } = assistantArticle("Hello");
    const { article: user, content } = userArticle("User");
    root.appendChild(article);
    root.appendChild(user);
    document.body.appendChild(root);

    expect(resolveChatMessageArticleFromEventTarget(paragraph, root)).toBe(article);
    expect(resolveChatMessageArticleFromEventTarget(content, root)).toBe(user);
    expect(resolveChatMessageArticleFromEventTarget(root, root)).toBeNull();

    document.body.removeChild(root);
  });

  it("treats message actions and leftover links as interactive", () => {
    const { article } = assistantArticle("Hello");
    const actions = document.createElement("div");
    actions.className = "comma-chat-message-actions";
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "Copy reply";
    actions.appendChild(button);
    article.appendChild(actions);
    const link = document.createElement("a");
    link.href = `${window.location.origin}/inbox`;
    link.textContent = "Inbox";
    article.appendChild(link);
    document.body.appendChild(article);

    expect(isInteractiveChatMessageTarget(button, article)).toBe(true);
    expect(isInteractiveChatMessageTarget(link, article)).toBe(true);
    expect(isInteractiveChatMessageTarget(article.querySelector("p"), article)).toBe(
      false
    );

    document.body.removeChild(article);
  });

  it("copies selected text when the selection is inside the article", () => {
    const { article, paragraph } = assistantArticle("Hello world");
    document.body.appendChild(article);
    const textNode = paragraph.firstChild;
    if (!textNode) throw new Error("expected text node");
    const range = document.createRange();
    range.setStart(textNode, 0);
    range.setEnd(textNode, 5);
    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);

    expect(selectedTextInRoot(article)).toBe("Hello");
    expect(
      resolveChatMessageCopyText(article, [{ messageId: "msg_1", text: "Hello world" }])
    ).toBe("Hello");

    selection?.removeAllRanges();
    expect(
      resolveChatMessageCopyText(article, [{ messageId: "msg_1", text: "Hello world" }])
    ).toBe("Hello world");

    document.body.removeChild(article);
  });

  it("falls back to the streaming draft when the article has no message id", () => {
    const article = document.createElement("article");
    article.className = "comma-chat-message-assistant";
    article.dataset.slot = "chat-assistant-output";
    article.dataset.responseKey = "rsp_draft";
    expect(
      resolveChatMessageText(article, [], {
        responseKey: "rsp_draft",
        text: "Streaming…",
      })
    ).toBe("Streaming…");
  });

  it("extracts selected text with inline and paragraph surrounding context", () => {
    const article = document.createElement("article");
    article.className = "comma-chat-message-assistant";
    article.dataset.slot = "chat-assistant-output";
    const p1 = document.createElement("p");
    p1.textContent = "OpenAI 或 Anthropic 可能已经在内部做出了题。";
    const p2 = document.createElement("p");
    p2.textContent = "但现在的问题是，激励完全不同。";
    const actions = document.createElement("div");
    actions.className = "comma-chat-message-actions";
    actions.textContent = "Copy";
    article.append(p1, p2, actions);
    document.body.appendChild(article);

    const range = document.createRange();
    range.setStart(p1.firstChild!, 13); // "ropic 可能..."
    range.setEnd(p2.firstChild!, 10); // "但现在的问题是，激励"
    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);

    const payload = resolveChatMessageSelectionShare(article);
    expect(payload).not.toBeNull();
    expect(payload?.beforeContext).toBe("OpenAI 或 Anth");
    expect(payload?.beforeJoin).toBe("inline");
    expect(payload?.selectedText).toBe(
      "ropic 可能已经在内部做出了题。\n\n但现在的问题是，激励"
    );
    expect(payload?.afterContext).toBe("完全不同。");
    expect(payload?.afterJoin).toBe("inline");
    expect(payload?.authorRole).toBe("assistant");

    selection?.removeAllRanges();
    expect(resolveChatMessageSelectionShare(article)).toBeNull();
    document.body.removeChild(article);
  });

  it("resolves the latest Task title and omits titles for Router chats on share cards", () => {
    expect(
      resolveShareSourceTitle(
        { kind: "agent_task", title: "Old task title", updated_at: 100 },
        { kind: "agent_task", title: "Renamed task title", updated_at: 200 }
      )
    ).toBe("Renamed task title");

    expect(
      resolveShareSourceTitle(
        { kind: "agent_task", title: "Fresh conversation title", updated_at: 300 },
        { kind: "agent_task", title: "Stale summary title", updated_at: 200 }
      )
    ).toBe("Fresh conversation title");

    expect(
      resolveShareSourceTitle(
        { kind: "user_chat", title: "Comma", updated_at: 100 },
        { kind: "agent_task", title: "Unrelated task", updated_at: 500 }
      )
    ).toBe("");

    expect(
      resolveShareSourceTitle(
        { kind: "user_chat", title: "Bridge chat", updated_at: 100 },
        null
      )
    ).toBe("");

    expect(
      resolveShareSourceTitle(null, {
        kind: "agent_task",
        title: "Cold summary task title",
        updated_at: 150,
      })
    ).toBe("Cold summary task title");

    expect(resolveShareSourceTitle(null, null)).toBe("");
  });
});
