// ==================== 服务器音量控制 ====================
function syncVolumeUi(vol) {
  const v = Math.max(0, Math.min(100, Math.round(vol)));
  const popSlider = document.getElementById('popoverVolSlider');
  const popLbl = document.getElementById('popoverVolLabel');
  const cfgSlider = document.getElementById('cfg_playbackVolume');
  const cfgLbl = document.getElementById('lbl_playbackVolume');
  if (popSlider && document.activeElement !== popSlider) popSlider.value = v;
  if (popLbl) popLbl.textContent = v + '%';
  if (cfgSlider && document.activeElement !== cfgSlider) cfgSlider.value = v;
  if (cfgLbl) cfgLbl.textContent = v + '%';
}

function onVolumeSliderInput(val) {
  const v = Math.round(Number(val));
  document.getElementById('popoverVolLabel').textContent = v + '%';
  document.getElementById('lbl_playbackVolume').textContent = v + '%';
  document.getElementById('popoverVolSlider').value = v;
  document.getElementById('cfg_playbackVolume').value = v;
}

async function commitVolumeChange(val) {
  const v = Math.round(Number(val));
  onVolumeSliderInput(v);
  await apiFetch('/api/volume', {
    method: 'POST',
    body: JSON.stringify({ volume: v })
  });
  showSnackbar('服务器播放音量已设为 ' + v + '%');
}

function toggleVolumePopover(ev) {
  ev.stopPropagation();
  document.getElementById('volumePopover').classList.toggle('open');
}

document.addEventListener('click', (ev) => {
  const pop = document.getElementById('volumePopover');
  if (pop && pop.classList.contains('open') && !pop.contains(ev.target)) {
    pop.classList.remove('open');
  }
});
