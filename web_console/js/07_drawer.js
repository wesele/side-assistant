// ==================== 左侧历史抽屉逻辑 (ChatHistoryDrawer) ====================
function openDrawer() {
  document.getElementById('drawerBackdrop').classList.add('open');
  document.getElementById('historyDrawer').classList.add('open');
  renderDrawerSessions();
}

function closeDrawer() {
  document.getElementById('drawerBackdrop').classList.remove('open');
  document.getElementById('historyDrawer').classList.remove('open');
}

function clearDrawerSearch() {
  document.getElementById('drawerSearchInput').value = '';
  renderDrawerSessions();
}

function getTimeGroupLabel(isoStr) {
  const d = new Date(isoStr);
  const now = new Date();
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const yesterdayStart = new Date(todayStart.getTime() - 86400000);
  const sevenDaysStart = new Date(todayStart.getTime() - 7 * 86400000);
  if (d >= todayStart) return '今天';
  if (d >= yesterdayStart) return '昨天';
  if (d >= sevenDaysStart) return '过去 7 天';
  return '更早';
}

function renderDrawerSessions() {
  const q = (document.getElementById('drawerSearchInput').value || '').trim().toLowerCase();
  document.getElementById('drawerSearchClearBtn').style.display = q ? 'inline-flex' : 'none';
  const all = appState.sessions || [];
  const filtered = q ? all.filter(s => (s.title || '').toLowerCase().includes(q)) : all;
  const listEl = document.getElementById('drawerSessionList');
  const footerEl = document.getElementById('drawerFooter');
  footerEl.style.display = all.length > 0 ? 'flex' : 'none';

  if (filtered.length === 0) {
    listEl.innerHTML = '<div style="text-align:center;padding:24px;font-size:13px;color:var(--fg-sub);">' +
      (all.length === 0 ? '暂无历史对话' : '未找到匹配的对话') + '</div>';
    return;
  }

  const groups = { '今天': [], '昨天': [], '过去 7 天': [], '更早': [] };
  for (const s of filtered) {
    groups[getTimeGroupLabel(s.updatedAt)].push(s);
  }

  let html = '';
  for (const g of ['今天', '昨天', '过去 7 天', '更早']) {
    if (groups[g].length === 0) continue;
    html += '<div class="drawer-group-title">' + g + '</div>';
    for (const s of groups[g]) {
      const sel = s.id === appState.currentSessionId ? ' selected' : '';
      html +=
        '<div class="session-tile' + sel + '" onclick="switchSession(\'' + s.id + '\')">' +
          '<svg class="ic-sm" viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H6l-2 2V4h16v12z"/></svg>' +
          '<span class="session-tile-title">' + escapeHtml(s.title) + '</span>' +
          '<span class="session-tile-actions" onclick="event.stopPropagation();">' +
            '<button class="icon-btn" style="width:28px;height:28px;" title="重命名" onclick="openRenameModal(\'' + s.id + '\', \'' + escapeHtml(s.title).replace(/'/g, "\\'") + '\')">' +
              '<svg class="ic-sm" style="width:16px;height:16px;" viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04a.996.996 0 0 0 0-1.41l-2.34-2.34a.996.996 0 0 0-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>' +
            '</button>' +
            '<button class="icon-btn" style="width:28px;height:28px;color:var(--danger);" title="删除" onclick="deleteSession(\'' + s.id + '\')">' +
              '<svg class="ic-sm" style="width:16px;height:16px;" viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>' +
            '</button>' +
          '</span>' +
        '</div>';
    }
  }
  listEl.innerHTML = html;
}

async function switchSession(id) {
  closeDrawer();
  await apiFetch('/api/sessions/switch', {
    method: 'POST',
    body: JSON.stringify({ id })
  });
}

function openRenameModal(id, title) {
  renamingSessionId = id;
  document.getElementById('renameSessionInput').value = title;
  document.getElementById('renameModal').classList.add('open');
}

function closeRenameModal() {
  document.getElementById('renameModal').classList.remove('open');
}

async function confirmRenameSession() {
  const title = document.getElementById('renameSessionInput').value.trim();
  if (!title) return;
  closeRenameModal();
  await apiFetch('/api/sessions/rename', {
    method: 'POST',
    body: JSON.stringify({ id: renamingSessionId, title })
  });
}

async function deleteSession(id) {
  await apiFetch('/api/sessions/delete', {
    method: 'POST',
    body: JSON.stringify({ id })
  });
}

function openClearAllDialog() {
  document.getElementById('clearAllModal').classList.add('open');
}

function closeClearAllDialog() {
  document.getElementById('clearAllModal').classList.remove('open');
}

async function confirmClearAllHistory() {
  closeClearAllDialog();
  closeDrawer();
  await apiFetch('/api/sessions/clear', { method: 'POST', body: '{}' });
  showSnackbar('已清空全部历史对话');
}

function exportAllHistoryHtml() {
  const tokenParam = accessPassword ? ('?token=' + encodeURIComponent(accessPassword)) : '';
  window.open('/api/export-html' + tokenParam, '_blank');
}
