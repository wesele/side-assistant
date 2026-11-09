// ==================== 消息列表渲染 (_buildMessageBubble) ====================
function renderMarkdown(raw) {
  let text = String(raw || '');
  let thinkHtml = '';
  const thinkMatch = text.match(/<think>([\s\S]*?)(?:<\/think>|$)/i);
  if (thinkMatch) {
    const thinkContent = thinkMatch[1].trim();
    text = text.replace(thinkMatch[0], '').trim();
    if (thinkContent) {
      thinkHtml = '<details class="think-details"><summary>思考过程</summary><div class="think-body">' + escapeHtml(thinkContent) + '</div></details>';
    }
  }
  let html = escapeHtml(text);
  // 代码块
  html = html.replace(/```([a-zA-Z0-9_-]*)\n([\s\S]*?)```/g, (_, lang, code) => {
    return '<pre><code>' + code + '</code></pre>';
  });
  // 行内代码
  html = html.replace(/`([^`\n]+)`/g, '<code>$1</code>');
  // 标题
  html = html.replace(/^### (.+)$/gm, '<h3>$1</h3>');
  html = html.replace(/^## (.+)$/gm, '<h2>$1</h2>');
  html = html.replace(/^# (.+)$/gm, '<h1>$1</h1>');
  // 粗体
  html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  // 换行转段落
  const paragraphs = html.split(/\n{2,}/).map(p => '<p>' + p.replace(/\n/g, '<br>') + '</p>').join('');
  return thinkHtml + '<div class="md-body">' + (paragraphs || '...') + '</div>';
}

function renderChatMessages(s) {
  const list = document.getElementById('chatList');
  const msgs = s.messages || [];
  const sig = JSON.stringify(msgs.map(m => [m.id, m.role, (m.content || '').length, m.imagePath, m.isUnintended ? '1' : '0'])) + '|' + (s.startWords || []).join(',');
  if (sig === lastRenderedMessagesSig) return;
  lastRenderedMessagesSig = sig;

  if (msgs.length === 0) {
    const startW = (s.startWords && s.startWords.length) ? s.startWords.join('、') : '晓漫';
    list.innerHTML =
      '<div class="empty-state">' +
        '<svg class="ic-lg" viewBox="0 0 24 24"><path d="M7 18h2V6H7v12zm4 4h2V2h-2v20zm-8-8h2v-4H3v4zm12 4h2V6h-2v12zm4-8v4h2v-4h-2z"/></svg>' +
        '<div class="empty-state-title">随身助理已就绪</div>' +
        '<div class="empty-state-sub">' +
          '你可以随时呼唤「' + escapeHtml(startW) + '」开始对话，系统将由大模型智能理解对话意图与连续交互。' +
        '</div>' +
      '</div>';
    return;
  }

  let html = '';
  for (const m of msgs) {
    const isUser = m.role === 'user';
    let imgHtml = '';
    if (m.imagePath) {
      const tokenParam = accessPassword ? ('&token=' + encodeURIComponent(accessPassword)) : '';
      const imgUrl = '/api/image?msgId=' + encodeURIComponent(m.id || '') + '&path=' + encodeURIComponent(m.imagePath) + tokenParam;
      imgHtml =
        '<div><div class="msg-img-wrap" onclick="openImageViewer(\'' + imgUrl + '\')">' +
          '<img src="' + imgUrl + '" alt="已捕获画面">' +
          '<span class="msg-img-zoom"><svg class="ic-sm" style="width:16px;height:16px;" viewBox="0 0 24 24"><path d="M15.5 14h-.79l-.28-.27A6.471 6.471 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14zm2.5-4h-2v2H9v-2H7V9h2V7h1v2h2v1z"/></svg></span>' +
        '</div></div>';
    }
    const rawContent = m.content || '...';
    if (m.isUnintended) {
      html += '<div class="msg-unintended-row"><div class="msg-unintended-bubble"><div class="unintended-badge">无交谈意图 · 背景信息</div><div class="unintended-text">' + escapeHtml(rawContent) + '</div></div></div>';
    } else if (isUser) {
      html += '<div class="msg-user-row"><div class="msg-user-bubble">' + imgHtml + escapeHtml(rawContent) + '</div></div>';
    } else {
      html += '<div class="msg-assistant-row">' + imgHtml + renderMarkdown(rawContent) + '</div>';
    }
  }
  list.innerHTML = html;
  list.scrollTop = list.scrollHeight;
}
