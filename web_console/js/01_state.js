let accessPassword = localStorage.getItem('sa_web_password') || '';
let appState = {};
let currentSettings = {};
let availableModels = [];
let isManualModelInput = false;
let hardwareDevices = { inputDevices: [], outputDevices: [], cameraDevices: [] };
let eventSource = null;
let autoSaveTimer = null;
let renamingSessionId = '';
let lastRenderedMessagesSig = '';

// 主题初始化（跟随系统或本地记忆）
(function initTheme() {
  const saved = localStorage.getItem('sa_theme');
  if (saved === 'dark' || (!saved && window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches)) {
    document.documentElement.setAttribute('data-theme', 'dark');
  }
})();

function toggleTheme() {
  const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
  if (isDark) {
    document.documentElement.removeAttribute('data-theme');
    localStorage.setItem('sa_theme', 'light');
  } else {
    document.documentElement.setAttribute('data-theme', 'dark');
    localStorage.setItem('sa_theme', 'dark');
  }
}

function showSnackbar(msg) {
  const el = document.getElementById('snackbar');
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(el._timer);
  el._timer = setTimeout(() => el.classList.remove('show'), 2800);
}

function escapeHtml(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

async function apiFetch(url, options = {}) {
  const headers = Object.assign({ 'Content-Type': 'application/json' }, options.headers || {});
  if (accessPassword) headers['X-Access-Password'] = accessPassword;
  const res = await fetch(url, Object.assign({}, options, { headers }));
  if (res.status === 401) {
    document.getElementById('authModal').classList.add('open');
    throw new Error('Unauthorized');
  }
  return res;
}

function submitAuthPassword() {
  accessPassword = document.getElementById('authPasswordInput').value.trim();
  localStorage.setItem('sa_web_password', accessPassword);
  document.getElementById('authModal').classList.remove('open');
  initApp();
}
