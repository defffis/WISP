(() => {
 'use strict';
 const L=window.WISP_LOCALE;
 document.documentElement.lang=L.lang;
 document.querySelectorAll('[data-i18n]').forEach(el=>{el.textContent=L[el.dataset.i18n];});
 const $ = id => document.getElementById(id);
 let state = null, csrf = '', busy = false, checked = false, switching = false, timer = null, deadline = 0, removing = false, clientNotice = false;
 const idle = phase => ['OFF','ROLLED_BACK','ABORTED'].includes(phase);
 const active = phase => ['ACTIVE','PENDING','TEST','STARTING','APPLYING','ROLLING_BACK'].includes(phase);
 const show = (id, yes) => { $(id).hidden = !yes; };
 function render() {
  if (!state) return;
  const p = state.phase;
  const clients = state.clients || {phase:'IDLE'};
  const clientsBusy = ['QUEUED','RUNNING'].includes(clients.phase);
  $('version').textContent = 'v' + state.version;
  $('boot').textContent = state.persistent ? L.m0 : L.m1;
  $('badge').textContent = p === 'ACTIVE' ? L.m2 : idle(p) ? L.m3 : L.m4;
  const titles = {ACTIVE:L.m5,PENDING:L.m6,OFF:L.m7,ROLLED_BACK:L.m7,ABORTED:L.m8,TEST:L.m9,RECOVERY_FAILED:L.m10,UNKNOWN:L.m11};
  $('state').textContent = titles[p] || L.m12;
  $('detail').textContent = p === 'ACTIVE' ? L.m13 : p === 'PENDING' ? L.m14 : idle(p) ? L.m15 : L.m16;
  if (state.remove_error) $('notice').textContent = state.remove_error;
  else if (state.reason_message) $('notice').textContent = state.reason_message;
  show('check', idle(p) && !checked); show('start', idle(p) && checked);
  show('confirm', p === 'PENDING' && state.can_confirm);
  show('reconnect', p === 'ACTIVE' || idle(p));
  show('rollback', active(p)); $('rollback').textContent = p === 'ACTIVE' ? L.m17 : L.m18;
  show('retry', false); show('newlink', p === 'PENDING' && !state.can_confirm);
  document.querySelectorAll('button').forEach(b => { b.disabled = busy || removing; });
  $('reconnect').disabled = busy || removing || clientsBusy;
  $('uninstall').disabled = busy || removing || !csrf;
  if (clientNotice && ['DONE','PARTIAL','FAILED'].includes(clients.phase)) {
   $('notice').textContent = clients.phase === 'DONE' ? L.m19 + clients.requested + L.m20 : L.m21;
  }
 }
 async function api(op, arg = '') {
  const options = {cache:'no-store',credentials:'same-origin'};
  let url = '/api?status';
  if (op !== 'status') {
   url = '/api'; Object.assign(options, {method:'POST',headers:{'Content-Type':'text/plain','X-WISP-CSRF':csrf},body:op+(arg?' '+arg:'')});
  }
  const response = await fetch(url, options);
  if (response.status === 401) {csrf='';throw new Error(L.m22);}
  if (!response.ok) throw new Error(L.m23);
  const token = response.headers.get('X-WISP-CSRF'); if (token) csrf = token;
  const data = await response.json();
  if (!data.ok) throw new Error(data.msg || L.m24);
  return data;
 }
 async function refresh() {
  if (removing) return;
  try {
   const s = await api('status');
   if (!state || state.phase !== s.phase) { checked = false; clientNotice=false; $('notice').textContent = ''; }
   if (s.phase === 'REMOVING') { removalStarted(); return; }
   state = s; deadline = Date.now() + s.remaining*1000; switching = ['PENDING','STARTING','APPLYING'].includes(s.phase); render();
  } catch (e) {
   clientNotice=false;
   $('notice').textContent = switching ? L.m25 : e.message;
   show('newlink', switching); show('retry', true);
   document.querySelectorAll('#check,#start,#confirm,#rollback,#reconnect').forEach(b => {b.hidden=true;});
   $('badge').textContent = L.m26;
   $('uninstall').disabled = !csrf || busy;
  } finally { if (!removing) {clearTimeout(timer); timer = setTimeout(refresh, 5000);} }
 }
 function removalStarted() {
  removing=true; clientNotice=false; clearTimeout(timer);
  $('state').textContent=L.m27; $('badge').textContent=L.m28;
  $('detail').textContent=L.m29;
  $('notice').textContent='';
  clearTimeout(timer); timer=setTimeout(monitorRemoval,3000);
  document.querySelectorAll('button').forEach(b => {b.disabled=true;});
  show('newlink',false);
 }
 async function monitorRemoval() {
  try {
   const s=await api('status');
   if (s.phase !== 'REMOVING') {
    removing=false; state=s; render();
    $('notice').textContent=s.remove_error || L.m30;
    timer=setTimeout(refresh,5000); return;
   }
   timer=setTimeout(monitorRemoval,3000);
  } catch (e) {
   $('notice').textContent=L.m31;
  }
 }
 async function action(op) {
  if (busy || removing) return;
  if (op === 'reconnect' && !window.confirm(L.m32)) return;
  if (op === 'uninstall' && window.prompt(L.m33) !== L.m34) return;
  if (op === 'rollback' && !window.confirm(L.m35)) return;
  if (op !== 'reconnect') clientNotice=false;
  busy = true; $('notice').textContent = ''; render();
  try {
   if (op === 'start') { switching=true; $('notice').textContent=L.m36; show('newlink',true); }
   await api(op, op === 'confirm' ? state.transaction : op === 'uninstall' ? 'DELETE' : '');
   if (op === 'uninstall') { removalStarted(); return; }
   if (op === 'reconnect') {clientNotice=true; $('notice').textContent=L.m37;}
   if (op === 'check') {
    checked=true; $('notice').textContent=L.m38;
   } else await refresh();
  } catch (e) {
   clientNotice=false;
   $('notice').textContent = switching ? L.m39 : e.message;
   show('newlink', switching);
  } finally { busy=false; if (!removing) render(); if (switching && !removing) show('newlink',true); }
 }
 ['check','start','confirm','rollback','reconnect','uninstall'].forEach(op => $(op).addEventListener('click', () => action(op)));
 $('retry').addEventListener('click', refresh);
 setInterval(() => {
  if (!removing && state && state.phase === 'PENDING') $('detail').textContent = L.m40 + Math.max(0,Math.ceil((deadline-Date.now())/1000)) + L.m41;
 }, 1000);
 refresh();
})();
