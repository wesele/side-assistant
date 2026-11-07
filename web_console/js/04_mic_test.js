function renderMicTestSpeakerBadge(item) {
  if (item.similarityPercent != null) {
    const isMatched = !!item.speakerMatched;
    const cls = isMatched ? 'badge-matched' : 'badge-unmatched';
    const label = (isMatched ? '🟢 声纹相似度 ' : '⚠️ 声纹相似度 ') + item.similarityPercent + '% (' + (isMatched ? '匹配' : '未达标') + ')';
    return '<span class="mic-badge ' + cls + '" title="声纹相似度 ' + item.similarityPercent + '%">' + escapeHtml(label) + '</span>';
  }
  if (item.speakerStatus) {
    return '<span class="mic-badge badge-neutral">' + escapeHtml(item.speakerStatus) + '</span>';
  }
  return '';
}

function renderMicTestLlmBadge(item) {
  if (item.shouldReply === true) {
    const intentHint = item.intent ? ' (' + escapeHtml(item.intent) + ')' : '';
    return '<span class="mic-badge badge-reply" title="' + escapeHtml(item.detail || '大模型判定需回答') + '">💬 大模型认为需回答' + intentHint + '</span>';
  }
  if (item.shouldReply === false) {
    if (item.llmDecision === '测试模式') {
      return '<span class="mic-badge badge-neutral" title="麦克风测试模式，不触发大模型">🛠️ 测试模式 (未发大模型)</span>';
    }
    if (item.llmDecision === '待机未唤醒') {
      return '<span class="mic-badge badge-muted" title="' + escapeHtml(item.detail || '待机状态未命中唤醒词') + '">💤 待机未唤醒</span>';
    }
    if (item.llmDecision === '声纹拦截') {
      return '<span class="mic-badge badge-unmatched" title="' + escapeHtml(item.detail || '声纹不匹配已拦截') + '">🚫 声纹拦截已忽略</span>';
    }
    if (item.llmDecision === '外放回声已丢弃') {
      return '<span class="mic-badge badge-muted" title="疑似外放回声已丢弃">🔇 回声丢弃</span>';
    }
    const intentHint = item.intent ? ' (' + escapeHtml(item.intent) + ')' : '';
    return '<span class="mic-badge badge-muted" title="' + escapeHtml(item.detail || '大模型判定无需回答') + '">🔇 大模型认为无需回答' + intentHint + '</span>';
  }
  if (item.llmDecision) {
    const isThinking = item.llmDecision.includes('判定中') || item.llmDecision.includes('思考中') || item.llmDecision.includes('请求中');
    const cls = isThinking ? 'badge-info' : 'badge-neutral';
    return '<span class="mic-badge ' + cls + '" title="' + escapeHtml(item.detail || '') + '">' + escapeHtml(item.llmDecision) + '</span>';
  }
  return '';
}

// ==================== 麦克风实时测试面板更新 ====================
function renderMicTestLiveState(s) {
  const pct = Math.round((s.micLevel || 0) * 100);
  const dbfs = typeof s.micDbfs === 'number' ? s.micDbfs.toFixed(1) : '-60.0';
  const vad = !!s.vadDetected;

  const pctEl = document.getElementById('micTestVolPercent');
  const dbEl = document.getElementById('micTestDbfs');
  const fillEl = document.getElementById('micTestVolFill');
  const vadBadge = document.getElementById('micTestVadBadge');
  const toggleBtn = document.getElementById('micTestToggleBtn');
  const latestTextEl = document.getElementById('micTestLatestText');
  const latestBadgesEl = document.getElementById('micTestLatestBadges');
  const historyEl = document.getElementById('micTestHistoryList');

  if (pctEl) pctEl.textContent = pct + '%';
  if (dbEl) dbEl.textContent = dbfs + ' dB';
  if (fillEl) fillEl.style.width = pct + '%';

  if (vadBadge) {
    if (!s.isMicListening) {
      vadBadge.textContent = '话筒已静音';
      vadBadge.style.background = 'var(--fill)';
      vadBadge.style.color = 'var(--fg-sub)';
    } else if (vad) {
      vadBadge.textContent = '🟢 检测到语音输入';
      vadBadge.style.background = 'rgba(0, 137, 123, 0.2)';
      vadBadge.style.color = 'var(--accent)';
    } else {
      vadBadge.textContent = '监听中（静音）';
      vadBadge.style.background = 'var(--fill)';
      vadBadge.style.color = 'var(--fg-sub)';
    }
  }

  if (toggleBtn) {
    if (s.isMicTesting) {
      toggleBtn.textContent = '停止麦克风测试';
      toggleBtn.className = 'btn-filled danger';
    } else {
      toggleBtn.textContent = '开始麦克风测试';
      toggleBtn.className = 'btn-filled accent-bg';
    }
  }

  const latest = (s.micTestText || s.displayTranscript || '').trim();
  if (latestTextEl) {
    latestTextEl.textContent = latest || (s.isMicListening ? '正在监听，请对着服务器麦克风说话...' : '请点击「开始麦克风测试」或开启话筒监听');
  }

  if (latestBadgesEl) {
    if (Array.isArray(s.micTestHistory) && s.micTestHistory.length > 0) {
      const top = s.micTestHistory[0];
      const spk = renderMicTestSpeakerBadge(top);
      const llm = renderMicTestLlmBadge(top);
      latestBadgesEl.innerHTML = spk + llm;
      latestBadgesEl.style.display = (spk || llm) ? 'flex' : 'none';
    } else {
      latestBadgesEl.innerHTML = '';
      latestBadgesEl.style.display = 'none';
    }
  }

  if (historyEl && Array.isArray(s.micTestHistory)) {
    if (s.micTestHistory.length === 0) {
      historyEl.innerHTML = '';
    } else {
      historyEl.innerHTML = s.micTestHistory.map(item => {
        const speakerBadge = renderMicTestSpeakerBadge(item);
        const llmBadge = renderMicTestLlmBadge(item);
        const hasBadges = speakerBadge || llmBadge;
        return '<div class="mic-test-item">' +
          '<div class="mic-test-header">' +
            '<span class="mic-test-text">' + escapeHtml(item.text) + '</span>' +
            '<span class="mic-test-meta">' +
              escapeHtml(item.time) + (item.durationMs ? (' · ' + item.durationMs + 'ms') : '') +
            '</span>' +
          '</div>' +
          (hasBadges ? ('<div class="mic-test-tags">' + speakerBadge + llmBadge + '</div>') : '') +
        '</div>';
      }).join('');
    }
  }
}

async function toggleMicTestMode() {
  const target = !appState.isMicTesting;
  await apiFetch('/api/mic-test', {
    method: 'POST',
    body: JSON.stringify({ enabled: target })
  });
  showSnackbar(target ? '已开启麦克风测试模式（说话仅识别文字，不触发对话）' : '已退出麦克风测试模式');
}

async function clearMicTestHistory() {
  await apiFetch('/api/mic-test', {
    method: 'POST',
    body: JSON.stringify({ enabled: !!appState.isMicTesting, clear: true })
  });
}

function openMicTestInSettings() {
  document.getElementById('volumePopover').classList.remove('open');
  openSettingsScreen();
  setTimeout(() => {
    const panel = document.getElementById('micTestPanel');
    if (panel) panel.scrollIntoView({ behavior: 'smooth', block: 'center' });
    if (!appState.isMicTesting) {
      toggleMicTestMode();
    }
  }, 120);
}
