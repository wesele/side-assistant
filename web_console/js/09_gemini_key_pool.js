// ==================== Gemini Live 多 Key 池管理与 60s TPM 监控 ====================

function populateGeminiKeyPool(apiKeys, legacyKey) {
  const list = [];
  const seen = new Set();
  if (Array.isArray(apiKeys)) {
    for (let i = 0; i < apiKeys.length; i++) {
      const raw = apiKeys[i];
      if (!raw || typeof raw !== 'object') continue;
      const k = String(raw.apiKey || '').trim();
      if (!k || seen.has(k)) continue;
      seen.add(k);
      const tpm = parseInt(raw.tpmLimit, 10);
      list.push({
        id: String(raw.id || ('key-' + (list.length + 1))).trim(),
        label: String(raw.label || ('Key ' + (list.length + 1))).trim(),
        apiKey: k,
        tpmLimit: Number.isFinite(tpm) && tpm >= 1000 ? tpm : 65000,
        visible: false
      });
    }
  }
  const fallback = String(legacyKey || '').trim();
  if (list.length === 0 && fallback) {
    list.push({
      id: 'legacy-1',
      label: '默认 Key',
      apiKey: fallback,
      tpmLimit: 65000,
      visible: false
    });
  }
  if (list.length === 0) {
    list.push({
      id: 'key-1',
      label: 'Key 1',
      apiKey: '',
      tpmLimit: 65000,
      visible: false
    });
  }
  geminiKeyPoolEntries = list;
  syncHiddenPrimaryGeminiKey();
  renderGeminiKeyPool();
  refreshGeminiKeyPoolStatus();
}

function collectGeminiKeyPool() {
  const out = [];
  const seen = new Set();
  for (let i = 0; i < geminiKeyPoolEntries.length; i++) {
    const e = geminiKeyPoolEntries[i];
    const k = String(e.apiKey || '').trim();
    if (!k || seen.has(k)) continue;
    seen.add(k);
    const tpm = parseInt(e.tpmLimit, 10);
    out.push({
      id: String(e.id || ('key-' + (out.length + 1))).trim(),
      label: String(e.label || ('Key ' + (out.length + 1))).trim(),
      apiKey: k,
      tpmLimit: Number.isFinite(tpm) && tpm >= 1000 ? tpm : 65000
    });
  }
  return out;
}

function getPrimaryGeminiApiKey() {
  for (let i = 0; i < geminiKeyPoolEntries.length; i++) {
    const k = String(geminiKeyPoolEntries[i].apiKey || '').trim();
    if (k) return k;
  }
  return '';
}

function syncHiddenPrimaryGeminiKey() {
  const hiddenEl = document.getElementById('cfg_geminiApiKey');
  if (hiddenEl) hiddenEl.value = getPrimaryGeminiApiKey();
}

function addGeminiKeyRow() {
  const idx = geminiKeyPoolEntries.length + 1;
  geminiKeyPoolEntries.push({
    id: 'key-' + Date.now() + '-' + idx,
    label: 'Key ' + idx,
    apiKey: '',
    tpmLimit: 65000,
    visible: false
  });
  renderGeminiKeyPool();
}

function removeGeminiKeyRow(idx) {
  if (geminiKeyPoolEntries.length <= 1) {
    geminiKeyPoolEntries[0].apiKey = '';
    geminiKeyPoolEntries[0].label = 'Key 1';
    geminiKeyPoolEntries[0].tpmLimit = 65000;
  } else {
    geminiKeyPoolEntries.splice(idx, 1);
  }
  syncHiddenPrimaryGeminiKey();
  renderGeminiKeyPool();
  scheduleAutoSave(true);
}

function toggleGeminiKeyVisibility(idx) {
  const entry = geminiKeyPoolEntries[idx];
  if (!entry) return;
  entry.visible = !entry.visible;
  const input = document.getElementById('geminiKeySecret_' + idx);
  if (input) input.type = entry.visible ? 'text' : 'password';
  const btn = document.getElementById('geminiKeyEye_' + idx);
  if (btn) btn.textContent = entry.visible ? '隐藏' : '显示';
}

function onGeminiKeyFieldChange(idx, field, value) {
  const entry = geminiKeyPoolEntries[idx];
  if (!entry) return;
  if (field === 'label') {
    entry.label = value;
  } else if (field === 'tpmLimit') {
    const n = parseInt(value, 10);
    entry.tpmLimit = Number.isFinite(n) && n >= 1000 ? n : 65000;
  } else if (field === 'apiKey') {
    entry.apiKey = value;
    syncHiddenPrimaryGeminiKey();
  }
  updateGeminiKeyMetersInPlace();
  scheduleAutoSave();
}

function renderGeminiKeyPool() {
  const container = document.getElementById('cfg_geminiApiKeys');
  if (!container) return;
  let html = '';
  for (let i = 0; i < geminiKeyPoolEntries.length; i++) {
    const e = geminiKeyPoolEntries[i];
    html += '<div class="key-pool-card">'
      + '<div class="key-pool-row">'
      + '<input type="text" class="m3-input" style="flex:1;min-width:110px;" placeholder="项目名称/备注" '
      + 'value="' + escapeHtml(e.label || '') + '" oninput="onGeminiKeyFieldChange(' + i + ',\'label\',this.value)">'
      + '<span style="font-size:12px;color:var(--fg-sub);">TPM上限</span>'
      + '<input type="number" class="m3-input" style="width:96px;" min="1000" step="1000" '
      + 'value="' + Number(e.tpmLimit || 65000) + '" oninput="onGeminiKeyFieldChange(' + i + ',\'tpmLimit\',this.value)">'
      + '<button type="button" class="m3-btn-tonal" style="padding:4px 8px;font-size:12px;color:var(--danger);" '
      + 'onclick="removeGeminiKeyRow(' + i + ')">删除</button>'
      + '</div>'
      + '<div class="key-pool-row">'
      + '<input id="geminiKeySecret_' + i + '" type="' + (e.visible ? 'text' : 'password') + '" '
      + 'class="m3-input" style="flex:1;min-width:160px;" placeholder="AIza..." '
      + 'value="' + escapeHtml(e.apiKey || '') + '" oninput="onGeminiKeyFieldChange(' + i + ',\'apiKey\',this.value)">'
      + '<button type="button" id="geminiKeyEye_' + i + '" class="m3-btn-tonal" style="padding:4px 8px;font-size:12px;" '
      + 'onclick="toggleGeminiKeyVisibility(' + i + ')">' + (e.visible ? '隐藏' : '显示') + '</button>'
      + '</div>'
      + '<div id="geminiKeyMeterWrap_' + i + '"></div>'
      + '</div>';
  }
  container.innerHTML = html;
  updateGeminiKeyMetersInPlace();
}

function updateGeminiKeyMetersInPlace() {
  for (let i = 0; i < geminiKeyPoolEntries.length; i++) {
    const wrap = document.getElementById('geminiKeyMeterWrap_' + i);
    if (!wrap) continue;
    const e = geminiKeyPoolEntries[i];
    const k = String(e.apiKey || '').trim();
    if (!k) {
      wrap.innerHTML = '';
      continue;
    }
    const st = geminiKeyPoolStatusMap[k] || {};
    const limit = Math.max(1000, Number(e.tpmLimit || st.limit || 65000));
    const currentTpm = Number(st.tpm || 0);
    const pct = Math.min(100, Math.round((currentTpm / limit) * 100));
    const ratio = currentTpm / limit;
    const cooling = !!st.coolingDown;
    const coolSec = Math.ceil(Number(st.cooldownRemainingMs || 0) / 1000);
    const cls = cooling ? 'cooling' : (ratio >= 0.8 ? 'warn' : 'ok');
    const badgeText = cooling
      ? ('429 冷却中 ' + coolSec + 's')
      : (ratio >= 0.8 ? '≥80% 待切换' : '可用');
    wrap.innerHTML = '<div style="display:flex;justify-content:space-between;align-items:center;font-size:11px;color:var(--fg-sub);">'
      + '<span>60s TPM: ' + currentTpm + ' / ' + limit + ' (' + pct + '%)</span>'
      + '<span class="key-pool-badge ' + cls + '">' + badgeText + '</span>'
      + '</div>'
      + '<div class="key-pool-meter"><div class="key-pool-meter-fill ' + cls + '" style="width:' + pct + '%;"></div></div>';
  }
}

function applyGeminiKeyPoolStatuses(items) {
  if (!Array.isArray(items)) return;
  const map = {};
  for (const item of items) {
    if (item && item.apiKey) map[String(item.apiKey).trim()] = item;
  }
  geminiKeyPoolStatusMap = map;
  updateGeminiKeyMetersInPlace();
}

async function refreshGeminiKeyPoolStatus() {
  try {
    const res = await apiFetch('/api/gemini-key-pool');
    const data = await res.json();
    applyGeminiKeyPoolStatuses(data.keys || []);
  } catch (_) {}
}

function startGeminiKeyPoolPolling() {
  stopGeminiKeyPoolPolling();
  refreshGeminiKeyPoolStatus();
  geminiKeyPoolPollTimer = setInterval(() => {
    const scr = document.getElementById('settingsScreen');
    if (scr && scr.classList.contains('active')) {
      refreshGeminiKeyPoolStatus();
    }
  }, 2500);
}

function stopGeminiKeyPoolPolling() {
  if (geminiKeyPoolPollTimer) {
    clearInterval(geminiKeyPoolPollTimer);
    geminiKeyPoolPollTimer = null;
  }
}
