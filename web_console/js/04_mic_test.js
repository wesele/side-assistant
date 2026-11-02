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

  if (historyEl && Array.isArray(s.micTestHistory)) {
    if (s.micTestHistory.length === 0) {
      historyEl.innerHTML = '';
    } else {
      historyEl.innerHTML = s.micTestHistory.map(item =>
        '<div class="mic-test-item">' +
          '<span style="flex:1;font-weight:500;">' + escapeHtml(item.text) + '</span>' +
          '<span style="font-size:11px;color:var(--fg-sub);white-space:nowrap;">' +
            escapeHtml(item.time) + (item.durationMs ? (' · ' + item.durationMs + 'ms') : '') +
          '</span>' +
        '</div>'
      ).join('');
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
