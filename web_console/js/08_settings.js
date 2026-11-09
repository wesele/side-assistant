// ==================== 设置页 (SettingsScreen) 逻辑 ====================

// 静音断句超时（0.1~10 秒）的展示格式化：整数秒不带小数，其余保留 1 位。
function fmtSilenceSecLabel(v) {
  const n = Number(v);
  if (!isFinite(n)) return '10 秒';
  return (Number.isInteger(n) ? String(n) : n.toFixed(1)) + ' 秒';
}

function getVal(id) {
  const el = document.getElementById(id);
  return el ? el.value.trim() : '';
}

function getBool(id) {
  const el = document.getElementById(id);
  return el ? !!el.checked : false;
}

function getInt(id, fallback = 0) {
  const el = document.getElementById(id);
  if (!el) return fallback;
  const n = parseInt(el.value, 10);
  return Number.isFinite(n) ? n : fallback;
}

async function openSettingsScreen() {
  document.getElementById('homeScreen').classList.remove('active');
  document.getElementById('settingsScreen').classList.add('active');
  await loadSettingsAndHardware();
}

async function closeSettingsScreen() {
  if (appState.isMicTesting) {
    await apiFetch('/api/mic-test', {
      method: 'POST',
      body: JSON.stringify({ enabled: false })
    });
  }
  document.getElementById('settingsScreen').classList.remove('active');
  document.getElementById('homeScreen').classList.add('active');
}

async function loadSettingsAndHardware() {
  const [sRes, hwRes] = await Promise.all([
    apiFetch('/api/settings'),
    apiFetch('/api/hardware-devices')
  ]);
  const sData = await sRes.json();
  hardwareDevices = await hwRes.json();
  currentSettings = sData.settings || {};
  populateSettingsForm(currentSettings);
  applySpeakerMeta(sData);
  populateHardwareSelects();
}

// 声纹面板的元信息（样本数与当前模型），来自 /api/settings 顶层字段
function applySpeakerMeta(meta) {
  const countEl = document.getElementById('lbl_speakerEnrolledCount');
  if (countEl && typeof meta.speakerEnrolledCount === 'number') {
    countEl.textContent = meta.speakerEnrolledCount;
  }
  const modelEl = document.getElementById('lbl_speakerModelName');
  if (modelEl && meta.speakerModelLabel) {
    modelEl.textContent = meta.speakerModelLabel;
  }
  const staleEl = document.getElementById('lbl_speakerStale');
  if (staleEl) {
    const stale = (typeof meta.speakerStoredCount === 'number' &&
            typeof meta.speakerEnrolledCount === 'number')
        ? Math.max(0, meta.speakerStoredCount - meta.speakerEnrolledCount)
        : 0;
    staleEl.style.display = stale > 0 ? 'block' : 'none';
    staleEl.textContent = stale > 0
        ? '检测到 ' + stale + ' 个旧模型声纹样本已失效（不参与比对），请点“清空声纹”后重新录制。'
        : '';
  }
}

async function loadHardwareDevices() {
  const hwRes = await apiFetch('/api/hardware-devices');
  hardwareDevices = await hwRes.json();
  populateHardwareSelects();
  showSnackbar('硬件外设列表已刷新');
}

function populateHardwareSelects() {
  // 录音输入源
  const inSel = document.getElementById('cfg_audioInputDeviceId');
  const curIn = currentSettings.audioInputDeviceId || '';
  let inHtml = '<option value="">自动（系统默认，推荐）</option>';
  for (const d of (hardwareDevices.inputDevices || [])) {
    inHtml += '<option value="' + escapeHtml(d.id) + '">' + escapeHtml(d.label) + '</option>';
  }
  inSel.innerHTML = inHtml;
  inSel.value = curIn;

  // 扬声器输出设备
  const outSel = document.getElementById('cfg_audioOutputDeviceId');
  const curOut = currentSettings.audioOutputDeviceId || '';
  let outHtml = '<option value="">自动（系统默认，推荐）</option>';
  for (const d of (hardwareDevices.outputDevices || [])) {
    outHtml += '<option value="' + escapeHtml(d.id) + '">' + escapeHtml(d.label) + '</option>';
  }
  outSel.innerHTML = outHtml;
  outSel.value = curOut;

  // 本地 V4L2 摄像头
  const camSel = document.getElementById('cfg_linuxCameraDevice');
  const curCam = currentSettings.linuxCameraDevice || '';
  let camHtml = '<option value="">自动选择主摄像头 (/dev/video0)</option>';
  for (const d of (hardwareDevices.cameraDevices || [])) {
    camHtml += '<option value="' + escapeHtml(d.id) + '">' + escapeHtml(d.label) + '</option>';
  }
  camSel.innerHTML = camHtml;
  camSel.value = curCam;
}

function populateSettingsForm(s) {
  const textIds = [
    'pipelineMode', 'asrEngine', 'geminiApiKey', 'geminiAsrModel', 'geminiLiveModel', 'geminiLiveVoice',
    'startWord',
    'openAiBaseUrl', 'openAiApiKey', 'openAiModel', 'systemPrompt', 'locationAddress',
    'openCodeCommand', 'codeAgentProvider', 'hermesCommand',
    'ttsEngine', 'edgeVoice', 'cameraSendShortEdge', 'webAccessPassword'
  ];
  for (const id of textIds) {
    const el = document.getElementById('cfg_' + id);
    if (el && s[id] !== undefined) el.value = String(s[id]);
  }
  onPipelineModeChanged();
  updateCodeAgentProviderUI();

  const boolIds = [
    'autoSubmitOnTimeout', 'disableThinking', 'enableWebSearch',
    'enableOpenCode',
    'enableTtsPlayback', 'enableBargeIn',
    'enablePromptTone', 'enableVisionIntent', 'autoStartMicOnLaunch',
    'enableSpeakerVerification', 'speakerVerifyWakeOnly',
    'enableTargetSpeakerExtraction'
  ];
  for (const id of boolIds) {
    const el = document.getElementById('cfg_' + id);
    if (el) el.checked = !!s[id];
  }

  const intIds = ['openCodeTimeoutSeconds'];
  for (const id of intIds) {
    const el = document.getElementById('cfg_' + id);
    if (el && s[id] !== undefined) el.value = s[id];
  }
  if (s.openCodeTimeoutSeconds !== undefined) {
    const el = document.getElementById('cfg_openCodeTimeoutSeconds');
    if (el) el.value = s.openCodeTimeoutSeconds;
  }
  try {
    loadCustomTools();
  } catch (_) {}
  const mode = s.startWordMode || (s.enableStartWordDetection === false ? 'disabled' : 'auto');
  const modeEl = document.getElementById('cfg_startWordMode');
  if (modeEl) {
    modeEl.value = mode;
    onStartWordModeChange();
  }
  const timeoutVal = s.continuousModeTimeoutMinutes || 10;
  const timeoutEl = document.getElementById('cfg_continuousModeTimeoutMinutes');
  if (timeoutEl) timeoutEl.value = timeoutVal;
  const timeoutLbl = document.getElementById('lbl_continuousModeTimeoutMinutes');
  if (timeoutLbl) timeoutLbl.textContent = timeoutVal;
  if (s.speakerVerifyWakeOnly === undefined) {
    const wEl = document.getElementById('cfg_speakerVerifyWakeOnly');
    if (wEl) wEl.checked = true;
  }
  const countEl = document.getElementById('lbl_speakerEnrolledCount');
  if (countEl) countEl.textContent = (s.ownerSpeakerEmbeddings || []).length;

  const sliders = [
    ['vadThreshold', v => Number(v).toFixed(2)],
    ['vadMinSilenceSeconds', v => Number(v).toFixed(2) + ' 秒'],
    ['vadMinSpeechSeconds', v => Number(v).toFixed(2) + ' 秒'],
    ['vadMaxSpeechSeconds', v => Number(v).toFixed(0) + ' 秒'],
    ['preRollMs', v => Number(v).toFixed(0) + ' 毫秒'],
    ['postRollMs', v => Number(v).toFixed(0) + ' 毫秒'],
    ['speakerSimilarityThreshold', v => Math.round(v * 100) + '%'],
    ['speakerMinSpeechSeconds', v => Number(v).toFixed(2) + ' 秒'],
    ['speakerEnergyThreshold', v => Number(v).toFixed(5)],
    ['tseAttenuationDb', v => Math.round(v) + ' dB'],
    ['silenceTimeoutSeconds', v => fmtSilenceSecLabel(v)],
    ['playbackVolume', v => Math.round(v) + '%'],
    ['ttsSpeed', v => Number(v).toFixed(1) + 'x'],
    ['cameraKeepAliveMinutes', v => v + ' 分钟']
  ];
  for (const [id, fmt] of sliders) {
    const el = document.getElementById('cfg_' + id);
    if (el && s[id] !== undefined) {
      el.value = s[id];
      updateSliderLabel(id, fmt(s[id]));
    }
  }

  availableModels = Array.isArray(s.cachedAvailableModels) ? [...s.cachedAvailableModels] : [];
  const curModel = (s.openAiModel || '').trim();
  if (curModel && !availableModels.includes(curModel)) availableModels.unshift(curModel);
  if (availableModels.length === 0) availableModels = ['CLI.gemini-3.8-flash-high', 'WB.deepseek-v4.1-flash', 'gpt-4o-mini'];
  renderModelSelect();
}

function onPipelineModeChanged() {
  const modeEl = document.getElementById('cfg_pipelineMode');
  const isLive = modeEl && modeEl.value === 'gemini_live';
  const asrGroup = document.getElementById('cascadeAsrEngineGroup');
  if (asrGroup) asrGroup.style.display = isLive ? 'none' : 'block';
  const liveFields = document.getElementById('geminiLiveFieldsGroup');
  if (liveFields) liveFields.style.display = isLive ? 'block' : 'none';
  const previewVoiceBtn = document.getElementById('previewGeminiVoiceBtn');
  if (previewVoiceBtn) previewVoiceBtn.style.display = isLive ? '' : 'none';
  const asrModelGroup = document.getElementById('geminiAsrModelGroup');
  if (asrModelGroup) asrModelGroup.style.display = isLive ? 'none' : 'block';
  const expansion = document.getElementById('geminiCloudExpansion');
  if (expansion && isLive) expansion.open = true;
  const openAiGroup = document.getElementById('cascadeOpenAiFieldsGroup');
  if (openAiGroup) openAiGroup.style.display = isLive ? 'none' : 'block';
  const llmHeader = document.getElementById('llmSectionHeaderTitle');
  if (llmHeader) {
    llmHeader.textContent = isLive ? '对话工具与系统人设（Gemini Live 生效）' : '大语言模型（OpenAI 兼容）';
  }
}

function updateCodeAgentProviderUI() {
  const provider = getVal('cfg_codeAgentProvider') || 'opencode';
  const openCodeGroup = document.getElementById('openCodeCmdGroup');
  const hermesGroup = document.getElementById('hermesCmdGroup');
  if (openCodeGroup) openCodeGroup.style.display = provider === 'hermes' ? 'none' : '';
  if (hermesGroup) hermesGroup.style.display = provider === 'hermes' ? '' : 'none';
}

function renderModelSelect() {
  const sel = document.getElementById('cfg_openAiModelSelect');
  const inp = document.getElementById('cfg_openAiModel');
  const cur = inp.value.trim();
  if (cur && !availableModels.includes(cur)) availableModels.unshift(cur);
  sel.innerHTML = availableModels.map(m => '<option value="' + escapeHtml(m) + '">' + escapeHtml(m) + '</option>').join('');
  sel.value = cur || availableModels[0];
}

function onModelSelectChanged(val) {
  document.getElementById('cfg_openAiModel').value = val;
  scheduleAutoSave(true);
}

function toggleManualModelInput() {
  isManualModelInput = !isManualModelInput;
  document.getElementById('cfg_openAiModelSelect').style.display = isManualModelInput ? 'none' : 'block';
  document.getElementById('cfg_openAiModel').style.display = isManualModelInput ? 'block' : 'none';
  document.getElementById('modelFieldLabel').textContent = isManualModelInput ? '模型名称（手动输入）' : '模型名称（下拉选择）';
  if (!isManualModelInput) renderModelSelect();
}

async function fetchAvailableModels() {
  const baseUrl = document.getElementById('cfg_openAiBaseUrl').value.trim();
  const apiKey = document.getElementById('cfg_openAiApiKey').value.trim();
  const res = await apiFetch('/api/fetch-models', {
    method: 'POST',
    body: JSON.stringify({ baseUrl, apiKey })
  });
  const data = await res.json();
  if (Array.isArray(data.models) && data.models.length > 0) {
    availableModels = data.models;
    renderModelSelect();
    showSnackbar('成功获取到 ' + data.models.length + ' 个可用模型');
  } else {
    showSnackbar('获取模型列表失败: ' + (data.error || '无可用模型'));
  }
}

function updateSliderLabel(id, text) {
  const lbl = document.getElementById('lbl_' + id);
  if (lbl) lbl.textContent = text;
}

async function onAudioInputSelectChanged() {
  const sel = document.getElementById('cfg_audioInputDeviceId');
  const id = sel.value;
  const label = id ? (sel.options[sel.selectedIndex]?.text || '') : '';
  await apiFetch('/audio-device', {
    method: 'POST',
    body: JSON.stringify({ id, label })
  });
  showSnackbar('录音输入源已切换');
}

function scheduleAutoSave(immediate = false) {
  clearTimeout(autoSaveTimer);
  document.getElementById('autoSaveBadge').textContent = '保存中...';
  if (immediate) {
    saveAllSettings();
  } else {
    autoSaveTimer = setTimeout(saveAllSettings, 450);
  }
}

async function saveAllSettings() {
  const outSel = document.getElementById('cfg_audioOutputDeviceId');
  const outId = outSel.value;
  const outLabel = outId ? (outSel.options[outSel.selectedIndex]?.text || '') : '';

  const payload = {
    pipelineMode: document.getElementById('cfg_pipelineMode').value,
    asrEngine: document.getElementById('cfg_asrEngine').value,
    geminiApiKey: document.getElementById('cfg_geminiApiKey').value.trim(),
    geminiAsrModel: document.getElementById('cfg_geminiAsrModel').value.trim(),
    geminiLiveModel: document.getElementById('cfg_geminiLiveModel').value.trim(),
    geminiLiveVoice: document.getElementById('cfg_geminiLiveVoice').value,
    autoSubmitOnTimeout: document.getElementById('cfg_autoSubmitOnTimeout').checked,
    vadThreshold: Number(document.getElementById('cfg_vadThreshold').value),
    vadMinSilenceSeconds: Number(document.getElementById('cfg_vadMinSilenceSeconds').value),
    vadMinSpeechSeconds: Number(document.getElementById('cfg_vadMinSpeechSeconds').value),
    vadMaxSpeechSeconds: Number(document.getElementById('cfg_vadMaxSpeechSeconds').value),
    preRollMs: Math.round(Number(document.getElementById('cfg_preRollMs').value)),
    postRollMs: Math.round(Number(document.getElementById('cfg_postRollMs').value)),
    startWord: document.getElementById('cfg_startWord').value.trim(),
    startWordMode: document.getElementById('cfg_startWordMode') ? document.getElementById('cfg_startWordMode').value : 'auto',
    continuousModeTimeoutMinutes: document.getElementById('cfg_continuousModeTimeoutMinutes') ? Number(document.getElementById('cfg_continuousModeTimeoutMinutes').value) : 10,
    enableStartWordDetection: document.getElementById('cfg_startWordMode') ? document.getElementById('cfg_startWordMode').value !== 'disabled' : true,
    silenceTimeoutSeconds: Number(Number(document.getElementById('cfg_silenceTimeoutSeconds').value).toFixed(1)),
    openAiBaseUrl: document.getElementById('cfg_openAiBaseUrl').value.trim(),
    openAiApiKey: document.getElementById('cfg_openAiApiKey').value.trim(),
    openAiModel: document.getElementById('cfg_openAiModel').value.trim(),
    disableThinking: document.getElementById('cfg_disableThinking').checked,
    enableWebSearch: document.getElementById('cfg_enableWebSearch').checked,
    enableOpenCode: getBool('cfg_enableOpenCode'),
    codeAgentProvider: getVal('cfg_codeAgentProvider') || 'opencode',
    openCodeCommand: getVal('cfg_openCodeCommand'),
    hermesCommand: getVal('cfg_hermesCommand'),
    openCodeTimeoutSeconds: getInt('cfg_openCodeTimeoutSeconds', 120),
    systemPrompt: document.getElementById('cfg_systemPrompt').value.trim(),
    locationAddress: document.getElementById('cfg_locationAddress').value.trim(),
    enableTtsPlayback: document.getElementById('cfg_enableTtsPlayback').checked,
    enableBargeIn: document.getElementById('cfg_enableBargeIn').checked,
    enablePromptTone: document.getElementById('cfg_enablePromptTone').checked,
    playbackVolume: Math.round(Number(document.getElementById('cfg_playbackVolume').value)),
    ttsSpeed: Number(document.getElementById('cfg_ttsSpeed').value),
    audioOutputDeviceId: outId,
    audioOutputDeviceLabel: outLabel,
    ttsEngine: document.getElementById('cfg_ttsEngine').value,
    edgeVoice: document.getElementById('cfg_edgeVoice').value,
    enableVisionIntent: document.getElementById('cfg_enableVisionIntent').checked,
    linuxCameraDevice: document.getElementById('cfg_linuxCameraDevice').value,
    cameraSendShortEdge: Math.round(Number(document.getElementById('cfg_cameraSendShortEdge').value)),
    cameraKeepAliveMinutes: Math.round(Number(document.getElementById('cfg_cameraKeepAliveMinutes').value)),
    enableSpeakerVerification: document.getElementById('cfg_enableSpeakerVerification').checked,
    speakerVerifyWakeOnly: document.getElementById('cfg_speakerVerifyWakeOnly').checked,
    speakerSimilarityThreshold: Number(document.getElementById('cfg_speakerSimilarityThreshold').value),
    speakerMinSpeechSeconds: Number(document.getElementById('cfg_speakerMinSpeechSeconds').value),
    speakerEnergyThreshold: Number(document.getElementById('cfg_speakerEnergyThreshold').value),
    enableTargetSpeakerExtraction: document.getElementById('cfg_enableTargetSpeakerExtraction').checked,
    tseAttenuationDb: Number(document.getElementById('cfg_tseAttenuationDb').value),
    autoStartMicOnLaunch: document.getElementById('cfg_autoStartMicOnLaunch').checked,
    webAccessPassword: document.getElementById('cfg_webAccessPassword').value.trim()
  };

  const res = await apiFetch('/api/settings', {
    method: 'POST',
    body: JSON.stringify(payload)
  });
  const data = await res.json();
  currentSettings = data.settings || payload;
  if (payload.webAccessPassword) {
    accessPassword = payload.webAccessPassword;
    localStorage.setItem('sa_web_password', accessPassword);
  }
  document.getElementById('autoSaveBadge').textContent = '已自动保存';
}

async function testGeminiConnection() {
  const btn = document.getElementById('testGeminiBtn');
  const out = document.getElementById('geminiTestResult');
  const isLive = document.getElementById('cfg_pipelineMode').value === 'gemini_live';
  const modelVal = isLive
    ? (document.getElementById('cfg_geminiLiveModel').value.trim() || 'gemini-3.8-live')
    : document.getElementById('cfg_geminiAsrModel').value.trim();
  btn.disabled = true;
  out.textContent = '正在连接 Gemini...';
  try {
    const res = await apiFetch('/api/test-gemini', {
      method: 'POST',
      body: JSON.stringify({
        apiKey: document.getElementById('cfg_geminiApiKey').value.trim(),
        model: modelVal
      })
    });
    const data = await res.json();
    out.textContent = data.result || '';
    out.style.color = (data.result || '').startsWith('连接成功') ? 'var(--accent)' : 'var(--danger)';
  } finally {
    btn.disabled = false;
  }
}

async function previewGeminiLiveVoice() {
  const btn = document.getElementById('previewGeminiVoiceBtn');
  const voice = document.getElementById('cfg_geminiLiveVoice')?.value || 'Aoede';
  if (btn) btn.disabled = true;
  showSnackbar('正在通过服务器扬声器试听 Gemini Live 音色 (' + voice + ')...');
  try {
    if (typeof saveSettings === 'function') await saveSettings(true);
    await apiFetch('/api/preview-voice', {
      method: 'POST',
      body: JSON.stringify({
        voice: voice,
        text: '你好，我是晓漫，这是 Gemini Live ' + voice + ' 原生音色的试听效果。'
      })
    });
  } catch (e) {
    showSnackbar('试听请求失败: ' + e);
  } finally {
    if (btn) {
      setTimeout(() => {
        btn.disabled = false;
      }, 1000);
    }
  }
}

let isEnrollingSpeaker = false;

// 声纹测试得分面板：大号百分比 + 进度条 + 明细
function hideSpeakerScore() {
  const panel = document.getElementById('speakerScorePanel');
  if (panel) panel.style.display = 'none';
}

function renderSpeakerScore(data) {
  const panel = document.getElementById('speakerScorePanel');
  if (!panel) return;
  const sim = typeof data.similarity === 'number' ? data.similarity : null;
  if (data.error || sim === null) {
    hideSpeakerScore();
    return;
  }
  const color = data.passed ? 'var(--accent)' : 'var(--danger)';
  const percent = document.getElementById('speakerScorePercent');
  const verdict = document.getElementById('speakerScoreVerdict');
  const fill = document.getElementById('speakerScoreFill');
  const meta = document.getElementById('speakerScoreMeta');
  const samples = document.getElementById('speakerScoreSamples');
  if (percent) {
    percent.textContent = (sim * 100).toFixed(1) + '%';
    percent.style.color = color;
  }
  if (verdict) {
    verdict.textContent = data.passed ? '✅ 判定为主人' : '❌ 非主人声纹';
    verdict.style.color = color;
  }
  if (fill) {
    fill.style.width = Math.max(0, Math.min(100, sim * 100)).toFixed(1) + '%';
    fill.style.background = color;
  }
  const thr = typeof data.threshold === 'number'
      ? (data.threshold * 100).toFixed(0) + '%' : '-';
  const speech = typeof data.speechSeconds === 'number'
      ? data.speechSeconds.toFixed(2) + 's' : '-';
  const centroid = typeof data.centroidSimilarity === 'number'
      ? (data.centroidSimilarity * 100).toFixed(1) + '%' : '-';
  const best = typeof data.maxSampleSimilarity === 'number'
      ? (data.maxSampleSimilarity * 100).toFixed(1) + '%' : '-';
  const mean = typeof data.meanSampleSimilarity === 'number'
      ? (data.meanSampleSimilarity * 100).toFixed(1) + '%' : '-';
  if (meta) {
    meta.textContent = '判定阈值 ' + thr + ' · 有效语音 ' + speech +
        ' · 质心 ' + centroid + ' · 单样本最高 ' + best + ' · 均值 ' + mean +
        ' · 耗时 ' + (data.durationMs || 0) + 'ms';
  }
  const list = Array.isArray(data.samplePercents) ? data.samplePercents : [];
  if (samples) {
    samples.textContent = list.length
        ? '与各录音样本相似度: ' + list.map(p => Number(p).toFixed(1) + '%').join('  |  ')
        : '';
  }
  panel.style.display = 'block';
}

async function enrollSpeakerSample() {
  if (isEnrollingSpeaker) return;
  isEnrollingSpeaker = true;
  const btn = document.getElementById('btnEnrollSpeaker');
  const out = document.getElementById('speakerTestResult');
  btn.disabled = true;
  hideSpeakerScore();

  const totalSeconds = 3.5;
  let remaining = 3;
  btn.textContent = '🎙️ 正在录制 (3s)...';
  if (out) {
    out.style.color = 'var(--accent)';
    out.textContent = '🎙️ 正在录音中，请对着麦克风清晰朗读 3 秒（例如：“小曼小曼，今天天气怎么样”）...';
  }
  showSnackbar('🎙️ 录音已开始，请对着麦克风清晰朗读 3 秒...', 3500);

  const timer = setInterval(() => {
    remaining--;
    if (remaining > 0) {
      btn.textContent = '🎙️ 正在录制 (' + remaining + 's)...';
    } else {
      btn.textContent = '⚙️ 正在分析声纹特征...';
      clearInterval(timer);
    }
  }, 1000);

  try {
    const res = await apiFetch('/api/speaker/enroll', {
      method: 'POST',
      body: JSON.stringify({ record: true, seconds: totalSeconds })
    });
    clearInterval(timer);
    btn.textContent = '⚙️ 正在保存...';
    const data = await res.json();
    if (data.accepted) {
      document.getElementById('lbl_speakerEnrolledCount').textContent = data.enrolledCount;
      showSnackbar('✅ 成功录入主人声纹样本！共有 ' + data.enrolledCount + ' 个样本');
      if (out) {
        out.style.color = 'var(--accent)';
        out.textContent = '✅ 样本录入成功！当前共有 ' + data.enrolledCount + ' / 5 个声纹样本';
      }
    } else {
      showSnackbar('❌ ' + (data.error || '录入失败'));
      if (out) {
        out.style.color = 'var(--danger)';
        out.textContent = '❌ ' + (data.error || '录入失败');
      }
    }
  } catch (e) {
    clearInterval(timer);
    showSnackbar('❌ 录入异常: ' + e);
    if (out) {
      out.style.color = 'var(--danger)';
      out.textContent = '录入异常: ' + e;
    }
  } finally {
    clearInterval(timer);
    isEnrollingSpeaker = false;
    btn.disabled = false;
    btn.textContent = '录入当前说话声音为样本';
  }
}

let isTestingSpeaker = false;

async function testSpeakerSample() {
  if (isTestingSpeaker) return;
  isTestingSpeaker = true;
  const btn = document.getElementById('btnTestSpeaker');
  const out = document.getElementById('speakerTestResult');
  btn.disabled = true;
  hideSpeakerScore();

  const totalSeconds = 3.0;
  let remaining = 3;
  btn.textContent = '🎙️ 正在录制 (3s)...';
  if (out) {
    out.style.color = 'var(--accent)';
    out.textContent = '🎙️ 正在录音中，请只说一句话，或只播放电视声（不要同时有人说话）...';
  }
  showSnackbar('🎙️ 录音测试已开始，请说一句话或播放电视声...', 3000);

  const timer = setInterval(() => {
    remaining--;
    if (remaining > 0) {
      btn.textContent = '🎙️ 正在录制 (' + remaining + 's)...';
    } else {
      btn.textContent = '⚙️ 正在比对特征...';
      clearInterval(timer);
    }
  }, 1000);

  try {
    const res = await apiFetch('/api/speaker/test', {
      method: 'POST',
      body: JSON.stringify({ record: true, seconds: totalSeconds })
    });
    clearInterval(timer);
    const data = await res.json();
    if (out) {
      out.textContent = data.text || data.error || '未知比对结果';
      out.style.color = data.passed ? 'var(--accent)' : 'var(--danger)';
    }
    renderSpeakerScore(data);
    applySpeakerMeta(data);
    if (data.error) {
      showSnackbar('❌ ' + data.error);
    } else if (data.text) {
      showSnackbar((data.passed ? '✅ ' : '⚠️ ') + data.text);
    }
  } catch (e) {
    clearInterval(timer);
    hideSpeakerScore();
    if (out) {
      out.textContent = '比对异常: ' + e;
      out.style.color = 'var(--danger)';
    }
    showSnackbar('❌ 比对异常: ' + e);
  } finally {
    clearInterval(timer);
    isTestingSpeaker = false;
    btn.disabled = false;
    btn.textContent = '测试最新声音相似度';
  }
}

async function clearSpeakerProfile() {
  if (!confirm('确定要清空所有已保存的主人声纹样本吗？')) return;
  try {
    await apiFetch('/api/speaker/clear', { method: 'POST' });
    document.getElementById('lbl_speakerEnrolledCount').textContent = '0';
    document.getElementById('speakerTestResult').textContent = '';
    hideSpeakerScore();
    showSnackbar('已清空主人声纹样本');
  } catch (e) {
    showSnackbar('清空异常: ' + e);
  }
}

async function previewServerVoice() {
  const voice = document.getElementById('cfg_edgeVoice')?.value || 'zh-CN-XiaoxiaoNeural';
  showSnackbar('正在通过服务器扬声器试听音色...');
  await apiFetch('/api/preview-voice', {
    method: 'POST',
    body: JSON.stringify({
      voice,
      text: '你好，我是晓漫，这是我的全新神经网络发音效果。'
    })
  });
}

async function testCameraCapture() {
  const dev = document.getElementById('cfg_linuxCameraDevice').value;
  const box = document.getElementById('cameraTestPreview');
  box.innerHTML = '<span style="font-size:12px;color:var(--fg-sub);">正在从服务器摄像头抓拍...</span>';
  const res = await apiFetch('/api/test-camera', {
    method: 'POST',
    body: JSON.stringify({ device: dev })
  });
  const data = await res.json();
  if (data.base64) {
    box.innerHTML =
      '<div style="font-size:12px;color:var(--accent);margin-bottom:4px;">✅ 抓拍成功 (' + data.byteLength + ' 字节)</div>' +
      '<img src="data:image/jpeg;base64,' + data.base64 + '" style="max-width:240px;border-radius:12px;cursor:pointer;" onclick="openImageViewer(this.src)">';
  } else {
    box.innerHTML = '<span style="font-size:12px;color:var(--danger);">❌ 抓拍失败: ' + escapeHtml(data.error || '') + '</span>';
  }
}

async function runDiagnosticSelfTest() {
  const btn = document.getElementById('selfTestBtn');
  const logBox = document.getElementById('selfTestLogBox');
  btn.disabled = true;
  btn.textContent = '正在执行自检...';
  logBox.style.display = 'block';
  logBox.textContent = '正在启动全链路 6 步运行态诊断...';
  try {
    const res = await apiFetch('/run-self-test', { method: 'POST', body: '{}' });
    const data = await res.json();
    if (Array.isArray(data.logs)) {
      logBox.textContent = data.logs.join('\n');
      logBox.scrollTop = logBox.scrollHeight;
    }
  } finally {
    btn.disabled = false;
    btn.textContent = '开始全链路诊断';
  }
}

function openImageViewer(src) {
  document.getElementById('imageViewerImg').src = src;
  document.getElementById('imageViewerModal').classList.add('open');
}

function closeImageViewer() {
  document.getElementById('imageViewerModal').classList.remove('open');
}

async function loadCustomTools() {
  const container = document.getElementById('customToolsList');
  if (!container) return;
  try {
    const res = await apiFetch('/api/custom-tools');
    if (!res.ok) {
      container.innerHTML = '<div style="color:var(--danger);font-size:12px;">加载工具列表失败 (' + res.status + ')</div>';
      return;
    }
    const data = await res.json();
    const tools = Array.isArray(data.tools) ? data.tools : [];
    if (tools.length === 0) {
      container.innerHTML = '<div style="color:var(--text-muted);font-size:12px;padding:4px 0;">暂无持久化工具。可在对话中让助手写一个持久化工具自动创建。</div>';
      return;
    }
    let html = '';
    for (const tool of tools) {
      const name = escapeHtml(tool.name || '');
      const summary = escapeHtml(tool.summary || '');
      const hint = escapeHtml(tool.parametersHint || '');
      const cmd = escapeHtml(tool.command || '');
      html += '<div style="background:var(--surface-container);border-radius:6px;padding:8px 10px;display:flex;justify-content:space-between;align-items:flex-start;gap:8px;border:1px solid var(--outline-variant);">'
        + '<div style="flex:1;min-width:0;">'
        + '<div style="font-weight:600;font-family:monospace;font-size:13px;color:var(--primary);">' + name + '</div>'
        + '<div style="font-size:12px;color:var(--on-surface);margin-top:2px;">' + summary + '</div>'
        + (hint ? '<div style="font-size:11px;color:var(--text-muted);margin-top:2px;">参数: ' + hint + '</div>' : '')
        + (cmd ? '<div style="font-size:11px;color:var(--text-muted);font-family:monospace;margin-top:2px;">命令: ' + cmd + '</div>' : '')
        + '</div>'
        + '<button class="icon-btn" style="width:28px;height:28px;color:var(--danger);flex-shrink:0;" title="删除工具" onclick="deleteCustomTool(\'' + name + '\')">'
        + '<svg class="ic-sm" viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>'
        + '</button>'
        + '</div>';
    }
    container.innerHTML = html;
  } catch (err) {
    container.innerHTML = '<div style="color:var(--danger);font-size:12px;">加载失败: ' + escapeHtml(String(err)) + '</div>';
  }
}

async function deleteCustomTool(name) {
  if (!name) return;
  if (!confirm('确定要删除持久化工具 "' + name + '" 吗？此操作不可撤销。')) return;
  try {
    const res = await apiFetch('/api/custom-tools/delete', {
      method: 'POST',
      body: JSON.stringify({ name: name })
    });
    const data = await res.json();
    if (data.deleted) {
      showSnackbar('已删除工具: ' + name);
    } else {
      showSnackbar('删除工具失败: ' + (data.error || '未知错误'));
    }
    await loadCustomTools();
  } catch (err) {
    showSnackbar('删除工具请求失败: ' + err);
  }
}

async function initApp() {
  try {
    const res = await apiFetch('/api/state');
    const data = await res.json();
    applyState(data);
    connectSse();
  } catch (_) {}
}

// 全局滚轮代理（对齐 Gemini Web：鼠标在窗口任意位置如顶栏、底栏、左右留白均可直接滚动当前视图）
window.addEventListener('wheel', (ev) => {
  if (ev.target.closest('.history-drawer, .modal-backdrop.open, .popover-card.open')) return;
  const innerScroll = ev.target.closest('textarea, .mono-log, .mic-test-history');
  if (innerScroll && innerScroll.scrollHeight > innerScroll.clientHeight) return;

  const activeScroll = document.getElementById('settingsScreen').classList.contains('active')
    ? document.getElementById('settingsScroll')
    : document.getElementById('chatList');
  if (!activeScroll) return;
  if (activeScroll.contains(ev.target)) return;
  activeScroll.scrollTop += ev.deltaY;
}, { passive: true });

initApp();
