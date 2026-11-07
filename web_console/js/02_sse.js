// ==================== SSE 与实时状态渲染 ====================
function connectSse() {
  if (eventSource) {
    try { eventSource.close(); } catch (_) {}
  }
  const tokenParam = accessPassword ? ('?token=' + encodeURIComponent(accessPassword)) : '';
  eventSource = new EventSource('/api/events' + tokenParam);
  eventSource.onmessage = (ev) => {
    try {
      const data = JSON.parse(ev.data);
      applyState(data);
    } catch (_) {}
  };
  eventSource.onerror = () => {
    setTimeout(connectSse, 3000);
  };
}

function applyState(s) {
  appState = s || {};
  renderTopBarAndStatusPill(appState);
  renderSpeakerDomainHint(appState);
  renderChatMessages(appState);
  renderDrawerSessions();
  renderMicTestLiveState(appState);
  if (typeof appState.playbackVolume === 'number') {
    syncVolumeUi(appState.playbackVolume);
  }
  if (Array.isArray(appState.selfTestLogs) && appState.selfTestLogs.length > 0) {
    const logBox = document.getElementById('selfTestLogBox');
    logBox.style.display = 'block';
    logBox.textContent = appState.selfTestLogs.join('\n');
    logBox.scrollTop = logBox.scrollHeight;
  }
}

// 声纹模板按音源域分组后，明确提示「当前音源是否已有专属模板」。
// 换到 8kHz 蓝牙窄带却只有宽带模板时，本人分数会被压低，必须补录。
function renderSpeakerDomainHint(s) {
  const el = document.getElementById('lbl_speakerDomainHint');
  if (!el) return;
  const domain = s.speakerAcousticDomain || 'wideband';
  const counts = s.speakerDomainCounts || {};
  const own = counts[domain] || 0;
  const total = (counts.wideband || 0) + (counts.narrowband || 0);
  const label = domain === 'narrowband' ? '蓝牙窄带 (8kHz)' : '内置 / 宽带 (16kHz)';
  if (own === 0) {
    el.style.color = 'var(--danger)';
    el.textContent = '当前音源：' + label + ' — 本音源域还没有专属声纹模板，请用当前麦克风补录 3~5 条（旧域 ' + total + ' 条已保留，切回时可直接复用）。';
  } else {
    el.style.color = 'var(--fg-sub)';
    el.textContent = '当前音源：' + label + ' — 已匹配 ' + own + ' 条专属模板；其它音源域 ' + (total - own) + ' 条保留。';
  }
}

function renderTopBarAndStatusPill(s) {
  // 话筒按钮状态与图标
  const micBtn = document.getElementById('micToggleBtn');
  const micIcon = document.getElementById('micToggleIcon');
  if (s.isMicListening) {
    micBtn.className = 'icon-btn accent';
    micBtn.title = '话筒监听中（点击静音）';
    if (micIcon) {
      micIcon.innerHTML = '<path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5.91-3c-.49 0-.9.36-.98.85C16.52 14.2 14.47 16 12 16s-4.52-1.8-4.93-4.15c-.08-.49-.49-.85-.98-.85-.61 0-1.09.54-1 1.14.49 3 2.89 5.35 5.91 5.78V20c0 .55.45 1 1 1s1-.45 1-1v-2.08c3.02-.43 5.42-2.78 5.91-5.78.1-.6-.39-1.14-1-1.14z"/>';
    }
  } else {
    micBtn.className = 'icon-btn muted';
    micBtn.title = '话筒已静音（点击开启）';
    if (micIcon) {
      micIcon.innerHTML = '<path d="M19 11h-1.7c0 .74-.16 1.43-.43 2.05l1.23 1.23c.56-.98.9-2.09.9-3.28zm-4.02.17c0-.06.02-.11.02-.17V5c0-1.66-1.34-3-3-3S9 3.34 9 5v.18l5.98 5.99zM4.27 3L3 4.27l6.01 6.01V11c0 1.66 1.33 3 2.99 3 .22 0 .44-.03.65-.08l1.66 1.66c-.71.33-1.5.52-2.31.52-2.76 0-5.3-2.1-5.3-5.1H5c0 3.41 2.72 6.23 6 6.72V21h2v-3.28c.91-.13 1.77-.45 2.54-.9L19.73 21 21 19.73 4.27 3z"/>';
    }
  }

  // 音源类型：内置 / 蓝牙 / 外接（8kHz 蓝牙 HFP 链路排障时一眼可辨）
  const kind = s.audioInputDeviceKind || 'unknown';
  const kindLabel = s.audioInputDeviceKindLabel || '';
  const device = s.audioInputDevice || '';
  micBtn.classList.toggle('bt-source', kind === 'bluetooth');
  micBtn.classList.toggle('ext-source', kind === 'external');
  const badge = document.getElementById('micSourceBadge');
  const badgeText = { bluetooth: 'BT', builtIn: '内置', external: '外接' }[kind];
  if (badge) {
    if (badgeText) {
      badge.hidden = false;
      badge.className = 'mic-source-badge k-' + kind;
      badge.textContent = badgeText;
    } else {
      badge.hidden = true;
      badge.textContent = '';
    }
  }
  micBtn.title = (s.isMicListening ? '话筒监听中（点击静音）' : '话筒已静音（点击开启）')
    + (kindLabel ? '\n' + kindLabel : '')
    + (device ? ' · ' + device : '');

  // 底部手动录音按钮
  const recBtn = document.getElementById('micRecordBtn');
  const recIcon = document.getElementById('micRecordIcon');
  if (s.isManualRecording) {
    recBtn.className = 'circle-action-btn mic-btn recording';
    recBtn.title = '停止录音并直接发送';
    recIcon.innerHTML = '<path d="M6 6h12v12H6z"/>';
  } else {
    recBtn.className = 'circle-action-btn mic-btn' + (s.isMicListening ? ' listening' : '');
    recBtn.title = '点按对讲录音（直接发送，免唤醒词）';
    recIcon.innerHTML = '<path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5.91-3c-.49 0-.9.36-.98.85C16.52 14.2 14.47 16 12 16s-4.52-1.8-4.93-4.15c-.08-.49-.49-.85-.98-.85-.61 0-1.09.54-1 1.14.49 3 2.89 5.35 5.91 5.78V20c0 .55.45 1 1 1s1-.45 1-1v-2.08c3.02-.43 5.42-2.78 5.91-5.78.1-.6-.39-1.14-1-1.14z"/>';
  }

  // 顶部动态状态胶囊 (_buildStatusPill)
  const pill = document.getElementById('statusPill');
  const titleEl = document.getElementById('statusPillTitle');
  const textEl = document.getElementById('statusPillText');
  const badgeEl = document.getElementById('statusPillBadge');
  const stopBtn = document.getElementById('statusPillStopBtn');

  pill.className = 'status-pill' + (!s.isMicListening ? ' clickable' : '');
  if (s.status === 'listeningContent' || s.status === 'playing') {
    pill.classList.add('state-active');
  } else if (s.status === 'thinking') {
    pill.classList.add('state-thinking');
  }

  const titleMap = {
    idle: '低功耗待机中',
    listeningContent: '正在倾听指令',
    thinking: '大模型思考中',
    playing: '正在语音朗读'
  };
  titleEl.textContent = titleMap[s.status] || '低功耗待机中';

  const displaySpeech = (s.displayTranscript || '').trim();
  if (s.isMicTesting && (s.micTestText || '').trim()) {
    textEl.innerHTML = '<strong style="color:var(--accent);">[测麦识别] </strong>' + escapeHtml(s.micTestText);
    badgeEl.style.display = 'inline-block';
    badgeEl.className = 'status-pill-badge matched';
    badgeEl.textContent = '测麦模式';
  } else if (displaySpeech) {
    const matched = !!s.isWakeWordMatched;
    const prefixColor = matched ? 'var(--accent)' : 'var(--fg-sub)';
    const prefixText = matched ? '已命中: ' : '未匹配: ';
    textEl.innerHTML = '<strong style="color:' + prefixColor + ';">' + prefixText + '</strong>' + escapeHtml(displaySpeech);
    badgeEl.style.display = 'inline-block';
    badgeEl.className = 'status-pill-badge ' + (matched ? 'matched' : 'unmatched');
    badgeEl.textContent = matched ? '已激活' : '未触发';
  } else {
    textEl.textContent = s.isMicTesting
      ? '麦克风测试中：请对着服务器麦克风说话...'
      : (s.statusHint || '');
    badgeEl.style.display = 'none';
  }

  stopBtn.style.display = (s.status === 'playing') ? 'inline-flex' : 'none';

  // 顶部迷你音量计
  const miniVolWrap = document.getElementById('miniVolWrap');
  if (s.isMicListening) {
    miniVolWrap.style.display = 'inline-flex';
    const pct = Math.round((s.micLevel || 0) * 100);
    document.getElementById('miniVolLabel').textContent = pct + '%';
    const thresholds = [8, 22, 40, 60, 80];
    for (let i = 0; i < 5; i++) {
      const bar = document.getElementById('mvBar' + (i + 1));
      if (pct >= thresholds[i] || (i === 0 && s.vadDetected)) {
        bar.classList.add('lit');
      } else {
        bar.classList.remove('lit');
      }
    }
  } else {
    miniVolWrap.style.display = 'none';
  }

  // 顶部服务器实时 CPU 占用率指标
  const miniCpuWrap = document.getElementById('miniCpuWrap');
  const miniCpuLabel = document.getElementById('miniCpuLabel');
  if (miniCpuWrap && miniCpuLabel) {
    if (typeof s.cpuUsage === 'number' && !isNaN(s.cpuUsage)) {
      miniCpuWrap.style.display = 'inline-flex';
      const cpuVal = Math.round(s.cpuUsage);
      miniCpuLabel.textContent = 'CPU ' + cpuVal + '%';
      if (cpuVal >= 85) {
        miniCpuWrap.classList.add('high');
      } else {
        miniCpuWrap.classList.remove('high');
      }
    } else {
      miniCpuLabel.textContent = 'CPU --%';
    }
  }
}

function onStatusPillClick() {
  if (!appState.isMicListening) {
    toggleMic();
  }
}

function onStartWordModeChange() {
  const modeEl = document.getElementById('cfg_startWordMode');
  if (!modeEl) return;
  const m = modeEl.value;
  const desc = document.getElementById('desc_startWordMode');
  const grp = document.getElementById('group_continuousTimeout');
  if (desc) {
    desc.textContent = m === 'auto'
      ? '自动模式：默认需说开始词唤醒；唤醒后进入连续对话，无需重复说开始词；无对话超时或说“结束对话/停止对话”退出。'
      : (m === 'enabled'
          ? '启用模式：每次发起提问或交互前，均需先说开始词唤醒。'
          : '关闭模式：待机状态下无需说开始词，随时直接说话即可发起交互。');
  }
  if (grp) {
    grp.style.display = m === 'auto' ? 'block' : 'none';
  }
}
