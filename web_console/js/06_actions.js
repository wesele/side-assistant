// ==================== 聊天交互与快捷操作 ====================
function autoGrowInput(el) {
  el.style.height = 'auto';
  el.style.height = Math.min(el.scrollHeight, 110) + 'px';
}

function onChatInputKey(ev) {
  if (ev.key === 'Enter' && !ev.shiftKey) {
    ev.preventDefault();
    sendChat();
  }
}

async function sendChat() {
  const input = document.getElementById('chatInput');
  const text = input.value.trim();
  if (!text) return;
  input.value = '';
  input.style.height = 'auto';
  await apiFetch('/api/chat', {
    method: 'POST',
    body: JSON.stringify({ text, speak: true })
  });
}

async function captureAndAsk() {
  showSnackbar('正在调用服务器摄像头抓拍并提问...');
  await apiFetch('/api/capture-and-ask', {
    method: 'POST',
    body: JSON.stringify({ question: '这是什么，介绍一下' })
  });
}

async function toggleMic() {
  await apiFetch('/toggle-mic', { method: 'POST', body: '{}' });
}

async function toggleManualRecord() {
  const endpoint = appState.isManualRecording ? '/api/manual-record/stop' : '/api/manual-record/start';
  await apiFetch(endpoint, { method: 'POST', body: '{}' });
}

async function interruptSpeaking() {
  await apiFetch('/simulate', {
    method: 'POST',
    body: JSON.stringify({ text: '停止' })
  });
}

async function resetSession() {
  await apiFetch('/reset', { method: 'POST', body: '{}' });
  showSnackbar('已开启新对话');
}
