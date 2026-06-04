/* BAR Scenario Designer - app logic.  No build step; loaded straight from disk. */
'use strict';

/* ---- diagnostics logger -------------------------------------------------
 * file:// pages can't write to disk, so we keep a ring buffer in memory +
 * localStorage (survives reloads) and expose it via the "Log" button and
 * Ctrl+Shift+L (downloads bar-designer-log.txt).  Errors are recorded too. */
const DBG = {
  lines: [],
  log(){ let parts=[]; for(let i=0;i<arguments.length;i++){ const a=arguments[i];
      parts.push(typeof a==='string'?a:safeJson(a)); }
    const line='['+new Date().toISOString()+'] '+parts.join(' ');
    this.lines.push(line); if(this.lines.length>800) this.lines.shift();
    try{ localStorage.setItem('barDesignerLog', this.lines.slice(-400).join('\n')); }catch(e){}
    try{ console.log(line); }catch(e){} },
  dump(){ return 'BAR Scenario Designer log\nUA: '+navigator.userAgent+'\nURL: '+location.href+'\n\n'+this.lines.join('\n'); }
};
function safeJson(o){ try{ return JSON.stringify(o); }catch(e){ return String(o); } }
window.addEventListener('error', e=>DBG.log('ERROR', (e.error&&e.error.stack)||e.message||'(empty)'));
window.addEventListener('unhandledrejection', e=>DBG.log('REJECTION', (e.reason&&e.reason.stack)||String(e.reason)));
DBG.log('script loaded');

/* =========================================================================
 * 1. Schemas  (mirror luarules/mission_api/{triggers,actions}_schema.lua)
 * ========================================================================= */
const TT = { TimeElapsed:1, UnitKilled:6, UnitEnteredLocation:9, UnitLeftLocation:10,
  ResourceStored:17, TeamDestroyed:23, TechLevelReached:26, ArmyValueExceeded:27 };
const AT = { EnableTrigger:1, DisableTrigger:2, IssueOrders:3, SpawnUnits:9, DespawnUnits:11,
  SendMessage:22, Victory:23, Defeat:24, GiveResource:25, FreezeTeam:26, UnfreezeTeam:27,
  SpawnBarrier:28, ExplodeBarrier:29 };
const TT_REV = rev(TT), AT_REV = rev(AT);
function rev(o){ const r={}; for(const k in o) r[o[k]]=k; return r; }

// field types: int|num|str|bool|team|select|unit|message|nameRef|triggerRef
const TRIGGER_SPEC = {
  TimeElapsed:        { label:'Time elapsed', spatial:null, fields:[
    {k:'gameFrame',t:'int',req:true,def:1,help:'30 frames = 1 second'},
    {k:'interval',t:'int',help:'repeat every N frames (needs repeating)'} ] },
  UnitEnteredLocation:{ label:'Unit entered area', spatial:'circle', fields:[
    {k:'team',t:'team',def:'humans',teamKind:'side'},{k:'onlyCommander',t:'bool'},
    {k:'x',t:'int',req:true},{k:'z',t:'int',req:true},{k:'radius',t:'int',req:true,def:600} ] },
  UnitLeftLocation:   { label:'Unit left area', spatial:'circle', fields:[
    {k:'team',t:'team',def:'humans',teamKind:'side'},{k:'onlyCommander',t:'bool'},
    {k:'x',t:'int',req:true},{k:'z',t:'int',req:true},{k:'radius',t:'int',req:true,def:600} ] },
  UnitKilled:         { label:'Unit killed', spatial:null, fields:[
    {k:'unitName',t:'nameRef',help:'a named spawn/barrier group'},
    {k:'team',t:'team',def:'humans',teamKind:'side'},{k:'onlyCommander',t:'bool'} ] },
  TechLevelReached:   { label:'Tech level reached', spatial:null, fields:[
    {k:'team',t:'team',def:'humans',teamKind:'side'},{k:'techLevel',t:'int',def:2} ] },
  ArmyValueExceeded:  { label:'Army value exceeded', spatial:null, fields:[
    {k:'team',t:'team',def:'humans',teamKind:'side'},{k:'value',t:'int',req:true,def:8000} ] },
  ResourceStored:     { label:'Resource stored', spatial:null, fields:[
    {k:'team',t:'team',def:'humans',teamKind:'side'},{k:'resource',t:'select',opts:['metal','energy'],req:true,def:'metal'},
    {k:'amount',t:'int',req:true,def:1000} ] },
  TeamDestroyed:      { label:'Team destroyed', spatial:null, fields:[
    {k:'team',t:'team',req:true,def:'enemies',teamKind:'side'} ] },
};
const ACTION_SPEC = {
  SendMessage:   { label:'Send message', spatial:null, fields:[ {k:'message',t:'message',req:true} ] },
  SpawnUnits:    { label:'Spawn units', spatial:'point', fields:[
    {k:'name',t:'str',help:'group name (for Despawn/IssueOrders/UnitKilled)'},
    {k:'unitDefName',t:'unit',req:true},{k:'quantity',t:'int',def:1},
    {k:'x',t:'int',req:true},{k:'z',t:'int',req:true},{k:'y',t:'int'},
    {k:'team',t:'team',def:'ai1',teamKind:'owner'},{k:'facing',t:'select',opts:['','south','north','east','west']} ] },
  DespawnUnits:  { label:'Despawn units', spatial:null, fields:[ {k:'name',t:'nameRef',req:true} ] },
  GiveResource:  { label:'Give resource', spatial:null, fields:[
    {k:'team',t:'team',req:true,def:'ai1',teamKind:'side'},{k:'metal',t:'int'},{k:'energy',t:'int'} ] },
  FreezeTeam:    { label:'Freeze team', spatial:null, fields:[ {k:'team',t:'team',req:true,def:'ai1',teamKind:'side'} ] },
  UnfreezeTeam:  { label:'Unfreeze team', spatial:null, fields:[
    {k:'team',t:'team',req:true,def:'ai1',teamKind:'side'},{k:'metal',t:'int'},{k:'energy',t:'int'} ] },
  SpawnBarrier:  { label:'Spawn barrier', spatial:'line', fields:[
    {k:'name',t:'str',req:true,help:'group name — reference this from an ExplodeBarrier action to blow it up'},
    {k:'unitDefName',t:'unit',req:true,def:'armfort'},{k:'team',t:'team',def:'',teamKind:'owner-gaia'},
    {k:'x1',t:'int',req:true},{k:'z1',t:'int',req:true},{k:'x2',t:'int',req:true},{k:'z2',t:'int',req:true},
    {k:'spacing',t:'int',def:40} ] },
  ExplodeBarrier:{ label:'Explode barrier', spatial:null, fields:[ {k:'name',t:'nameRef',req:true} ] },
  IssueOrders:   { label:'Issue orders', spatial:'point', fields:[
    {k:'name',t:'nameRef'},{k:'team',t:'team',teamKind:'side'},
    {k:'cmd',t:'select',opts:['move','fight','attack','patrol','guard','stop'],req:true,def:'move'},
    {k:'x',t:'int'},{k:'z',t:'int'} ] },
  Victory:       { label:'Victory', spatial:null, fields:[ {k:'team',t:'team',def:'humans',teamKind:'side'} ] },
  Defeat:        { label:'Defeat', spatial:null, fields:[ {k:'team',t:'team',def:'humans',teamKind:'side'} ] },
  EnableTrigger: { label:'Enable trigger', spatial:null, fields:[ {k:'triggerId',t:'triggerRef',req:true} ] },
  DisableTrigger:{ label:'Disable trigger', spatial:null, fields:[ {k:'triggerId',t:'triggerRef',req:true} ] },
};

/* =========================================================================
 * 2. State
 * ========================================================================= */
let S = null;            // current scenario state
let MAPIMG = null;       // loaded minimap Image
const MAPS = window.BAR_MAPS || [];
const UNITS = window.BAR_UNITS || [];

function newState(map){
  return {
    map: { file:map.file, name:map.name, w:map.w, h:map.h, thumb:map.thumb },
    meta: { title:'New Scenario', author:'', summary:'', briefing:'',
            difficulty:'normal', deathmode:'own_com', missionFile: slug(map.name)+'_mission', scenarioIndex:26 },
    playerStart:null, aiStarts:[], aiCount:1, freeze:['enemies'],
    buildings:[], triggers:[], actions:[],
    nextId:1,
    view:{scale:1, ox:0, oy:0},
    tool:'select', selection:null,
    build:{ def:null, defName:null, role:'ai1', facing:'' },
    _pendingBarrier:null,
  };
}
const uid = () => 'e'+(S.nextId++);
function slug(s){ return (s||'scenario').toLowerCase().replace(/[^a-z0-9]+/g,'_').replace(/^_|_$/g,'')||'scenario'; }

/* =========================================================================
 * 3. Launch / map picker
 * ========================================================================= */
const $ = sel => document.querySelector(sel);
const $$ = sel => Array.from(document.querySelectorAll(sel));

function initLaunch(){
  DBG.log('initLaunch: maps='+MAPS.length+' units='+UNITS.length);
  const grid = $('#mapGrid');
  if(!MAPS.length){ $('#noData').hidden=false; }
  $('#mapCount').textContent = MAPS.length ? MAPS.length+' maps' : '';
  const render = (q='') => {
    q = q.trim().toLowerCase();
    const list = MAPS.filter(m => !q || m.name.toLowerCase().includes(q) || m.file.toLowerCase().includes(q));
    grid.innerHTML='';
    for(const m of list){
      const c = el('div','map-card');
      const t = el('div','thumb'); if(m.thumb) t.style.backgroundImage=`url("${m.thumb}")`;
      const cap = el('div','cap');
      cap.innerHTML = `<div class="nm">${esc(m.name)}</div><div class="dm">${m.w}&times;${m.h} &middot; ${ratioStr(m.w,m.h)}</div>`;
      c.append(t,cap);
      c.onclick = ()=> chooseMap(m);
      grid.append(c);
    }
  };
  $('#mapSearch').oninput = e => render(e.target.value);
  render();
  $('#btnOpenExisting').onclick = ()=> openFileDialog(true);
}
function ratioStr(w,h){ const g=gcd(w,h); return (w/g)+':'+(h/g); }
function gcd(a,b){ return b? gcd(b,a%b):a; }

function chooseMap(map){
  DBG.log('chooseMap', map.name, map.w+'x'+map.h);
  S = newState(map);
  startApp();
}

/* =========================================================================
 * 4. App bootstrap
 * ========================================================================= */
let cv, ctx, dpr=1;
function startApp(){
  $('#launch').hidden = true;
  $('#app').hidden = false;
  cv = $('#canvas'); ctx = cv.getContext('2d');
  loadMapImage();
  buildSidebar();
  buildLists();
  buildInspector();
  setTool('select');
  if(!startApp._bound){          // bind global/canvas listeners exactly once
    bindCanvas(); bindChrome();
    window.addEventListener('resize', ()=>{ resizeCanvas(); render(); });
    startApp._bound=true;
  }
  resizeCanvas(); fitView(); render();
  $('#curMapName').textContent = S.map.name;
  $('#curMapDims').textContent = `(${S.map.w}×${S.map.h})`;
  DBG.log('startApp done: canvas '+cv.width+'x'+cv.height+' scale='+S.view.scale.toFixed(4));
}
function loadMapImage(){
  MAPIMG=null;
  if(S.map.thumb){ const im=new Image();
    im.onload=()=>{ MAPIMG=im; DBG.log('map image loaded', S.map.thumb, im.width+'x'+im.height); render(); };
    im.onerror=()=>DBG.log('map image FAILED to load', S.map.thumb);
    im.src=S.map.thumb; }
}

/* ---- canvas sizing & view transforms ---- */
function resizeCanvas(){
  dpr = window.devicePixelRatio||1;
  const r = cv.getBoundingClientRect();
  cv.width = Math.max(1,Math.round(r.width*dpr));
  cv.height= Math.max(1,Math.round(r.height*dpr));
}
const W = ()=>cv.width/dpr, H = ()=>cv.height/dpr;
function fitView(){
  const s = Math.min(W()/S.map.w, H()/S.map.h)*0.92;
  S.view.scale=s; S.view.ox=(W()-S.map.w*s)/2; S.view.oy=(H()-S.map.h*s)/2;
}
const w2s = (x,z)=>[S.view.ox+x*S.view.scale, S.view.oy+z*S.view.scale];
const s2w = (sx,sy)=>[(sx-S.view.ox)/S.view.scale, (sy-S.view.oy)/S.view.scale];

/* =========================================================================
 * 5. Rendering
 * ========================================================================= */
function render(){ try{ renderInner(); }
  catch(err){ DBG.log('RENDER ERROR', (err&&err.stack)||String(err));
    if(window.__err) window.__err('render() failed:\n'+((err&&err.stack)||err)); } }
function renderInner(){
  if(!ctx) return;
  ctx.setTransform(dpr,0,0,dpr,0,0);
  ctx.clearRect(0,0,W(),H());
  ctx.fillStyle='#0a0d12'; ctx.fillRect(0,0,W(),H());

  const [rx,ry]=w2s(0,0), rw=S.map.w*S.view.scale, rh=S.map.h*S.view.scale;
  // minimap (square source stretched to true-aspect rect => correct proportions)
  if(MAPIMG) ctx.drawImage(MAPIMG,0,0,MAPIMG.width,MAPIMG.height,rx,ry,rw,rh);
  else { ctx.fillStyle='#11161e'; ctx.fillRect(rx,ry,rw,rh); }
  // grid every 1024 elmos
  ctx.strokeStyle='rgba(255,255,255,.07)'; ctx.lineWidth=1; ctx.beginPath();
  for(let x=0;x<=S.map.w;x+=1024){ const[sx]=w2s(x,0); ctx.moveTo(sx,ry); ctx.lineTo(sx,ry+rh); }
  for(let z=0;z<=S.map.h;z+=1024){ const[,sy]=w2s(0,z); ctx.moveTo(rx,sy); ctx.lineTo(rx+rw,sy); }
  ctx.stroke();
  ctx.strokeStyle='rgba(255,255,255,.35)'; ctx.lineWidth=1.5; ctx.strokeRect(rx,ry,rw,rh);

  const selKey = S.selection ? S.selection.kind+':'+S.selection.id : null;

  // barriers (SpawnBarrier actions)
  for(const a of S.actions) if(specOf(a).spatial==='line'){
    const p=a.params, sel = selKey==='action:'+a.id;
    if(!num(p.x1)) continue;
    const [s1x,s1y]=w2s(p.x1,p.z1),[s2x,s2y]=w2s(p.x2,p.z2);
    ctx.strokeStyle=sel?'#fff':'#b07cf0';
    ctx.lineWidth=sel?4:3; ctx.setLineDash([7,5]);
    ctx.beginPath(); ctx.moveTo(s1x,s1y); ctx.lineTo(s2x,s2y); ctx.stroke(); ctx.setLineDash([]);
    handle(s1x,s1y,sel); handle(s2x,s2y,sel);
    label((s1x+s2x)/2,(s1y+s2y)/2-10, a.name||'barrier', '#b07cf0');
  }
  // trigger areas
  for(const t of S.triggers) if(specOf(t).spatial==='circle'){
    const p=t.params, sel=selKey==='trigger:'+t.id; if(!num(p.x)) continue;
    const [cx,cy]=w2s(p.x,p.z), rr=(p.radius||0)*S.view.scale;
    ctx.beginPath(); ctx.arc(cx,cy,rr,0,7);
    ctx.fillStyle='rgba(242,201,76,.10)'; ctx.fill();
    ctx.strokeStyle=sel?'#fff':'#f2c94c'; ctx.lineWidth=sel?2.5:1.5; ctx.setLineDash([6,4]); ctx.stroke(); ctx.setLineDash([]);
    marker(cx,cy,'#f2c94c',sel);
    if(sel) handle(cx+rr,cy,true); // radius handle
    label(cx,cy-12,t.name||'trigger','#f2c94c');
  }
  // spawn / order points (SpawnUnits, IssueOrders)
  for(const a of S.actions) if(specOf(a).spatial==='point'){
    const p=a.params, sel=selKey==='action:'+a.id; if(!num(p.x)) continue;
    const [cx,cy]=w2s(p.x,p.z);
    const col = a.type==='SpawnUnits'?'#3fb6c9':'#9aa7ff';
    marker(cx,cy,col,sel);
    const lab = a.type==='SpawnUnits'
      ? unitName(a.params.unitDefName||'')+(a.params.quantity>1?' ×'+a.params.quantity:'')
      : 'order: '+(a.params.cmd||'');
    label(cx,cy-12,lab||'spawn',col);
  }
  // AI base buildings
  for(const b of S.buildings){
    const [cx,cy]=w2s(b.x,b.z), sel=selKey==='building:'+b.id;
    const sz=Math.max(8,Math.min(26, (footprint(b.def))*8*S.view.scale));
    ctx.fillStyle = sel?'#fff':'#e5484d'; ctx.globalAlpha=sel?.95:.85;
    ctx.fillRect(cx-sz/2,cy-sz/2,sz,sz); ctx.globalAlpha=1;
    ctx.strokeStyle='#000'; ctx.lineWidth=1; ctx.strokeRect(cx-sz/2,cy-sz/2,sz,sz);
    if(S.view.scale>0.02) label(cx,cy+sz/2+10,unitName(b.def),'#ffb4b6');
  }
  // AI spawns
  S.aiStarts.forEach((p,i)=>{ const[cx,cy]=w2s(p.x,p.z),sel=selKey==='aiStart:'+i;
    flag(cx,cy,'#e5484d',sel); label(cx,cy-20,'AI start '+(i+1),'#ff9a9c'); });
  // player start
  if(S.playerStart){ const[px,py]=w2s(S.playerStart.x,S.playerStart.z);
    flag(px,py,'#39b54a',selKey==='playerStart:0'); label(px,py-20,'Player start','#8be79a'); }

  // pending barrier rubber-band
  if(S._pendingBarrier && lastMouse){ const [bx,by]=w2s(S._pendingBarrier.x,S._pendingBarrier.z);
    ctx.strokeStyle='#b07cf0'; ctx.setLineDash([5,5]); ctx.beginPath();
    ctx.moveTo(bx,by); ctx.lineTo(lastMouse.sx,lastMouse.sy); ctx.stroke(); ctx.setLineDash([]); }
}
function marker(cx,cy,col,sel){ ctx.beginPath(); ctx.arc(cx,cy,sel?7:5,0,7);
  ctx.fillStyle=col; ctx.fill(); ctx.lineWidth=2; ctx.strokeStyle=sel?'#fff':'#000'; ctx.stroke(); }
function handle(cx,cy,on){ ctx.beginPath(); ctx.arc(cx,cy,5,0,7); ctx.fillStyle=on?'#fff':'#ddd';
  ctx.fill(); ctx.strokeStyle='#000'; ctx.lineWidth=1; ctx.stroke(); }
function flag(cx,cy,col,sel){ ctx.beginPath(); ctx.arc(cx,cy,sel?8:6,0,7); ctx.fillStyle=col; ctx.fill();
  ctx.lineWidth=2.5; ctx.strokeStyle=sel?'#fff':'#000'; ctx.stroke(); }
function label(cx,cy,txt,col){ ctx.font='600 11px Segoe UI,sans-serif'; ctx.textAlign='center';
  const w=ctx.measureText(txt).width; ctx.fillStyle='rgba(0,0,0,.6)';
  ctx.fillRect(cx-w/2-4,cy-11,w+8,14); ctx.fillStyle=col||'#fff'; ctx.fillText(txt,cx,cy); ctx.textAlign='left'; }
function footprint(def){ const u=UNITS.find(u=>u.def===def); return 4; }
function num(v){ return typeof v==='number' && !isNaN(v); }
function specOf(e){ return e.kind==='trigger'?TRIGGER_SPEC[e.type]:(e.kind==='action'?ACTION_SPEC[e.type]:(e.type&&ACTION_SPEC[e.type])||{}); }

/* =========================================================================
 * 6. Hit testing + pointer interaction
 * ========================================================================= */
function handles(){ // list of draggable points in WORLD coords
  const out=[];
  if(S.playerStart) out.push({kind:'playerStart',id:0,sub:'c',x:S.playerStart.x,z:S.playerStart.z});
  S.aiStarts.forEach((p,i)=>out.push({kind:'aiStart',id:i,sub:'c',x:p.x,z:p.z}));
  S.buildings.forEach(b=>out.push({kind:'building',id:b.id,sub:'c',x:b.x,z:b.z}));
  for(const t of S.triggers){ const sp=TRIGGER_SPEC[t.type]; const p=t.params;
    if(sp&&sp.spatial==='circle'&&num(p.x)){ out.push({kind:'trigger',id:t.id,sub:'c',x:p.x,z:p.z});
      if(S.selection&&S.selection.kind==='trigger'&&S.selection.id===t.id) out.push({kind:'trigger',id:t.id,sub:'r',x:p.x+(p.radius||0),z:p.z}); } }
  for(const a of S.actions){ const sp=ACTION_SPEC[a.type]; const p=a.params;
    if(sp&&sp.spatial==='point'&&num(p.x)) out.push({kind:'action',id:a.id,sub:'c',x:p.x,z:p.z});
    if(sp&&sp.spatial==='line'&&num(p.x1)){ out.push({kind:'action',id:a.id,sub:'p1',x:p.x1,z:p.z1});
      out.push({kind:'action',id:a.id,sub:'p2',x:p.x2,z:p.z2});
      out.push({kind:'action',id:a.id,sub:'mid',x:(p.x1+p.x2)/2,z:(p.z1+p.z2)/2}); } }
  return out;
}
function hitTest(sx,sy){
  let best=null,bd=12;
  for(const h of handles()){ const[hx,hy]=w2s(h.x,h.z); const d=Math.hypot(hx-sx,hy-sy);
    if(d<bd){ bd=d; best=h; } }
  return best;
}

let drag=null, panning=null, spaceDown=false, lastMouse=null;
function bindCanvas(){
  cv.addEventListener('pointerdown',onDown);
  cv.addEventListener('pointermove',onMove);
  window.addEventListener('pointerup',onUp);
  cv.addEventListener('wheel',onWheel,{passive:false});
  cv.addEventListener('contextmenu',e=>e.preventDefault());
  window.addEventListener('keydown',e=>{ if(e.code==='Space')spaceDown=true; hotkeys(e); });
  window.addEventListener('keyup',e=>{ if(e.code==='Space')spaceDown=false; });
}
function evPos(e){ const r=cv.getBoundingClientRect(); return [e.clientX-r.left,e.clientY-r.top]; }

function onDown(e){
  const [sx,sy]=evPos(e);
  if(e.button===1||e.button===2||spaceDown){ panning={sx,sy,ox:S.view.ox,oy:S.view.oy}; cv.setPointerCapture(e.pointerId); return; }
  const [wx,wz]=s2w(sx,sy);
  if(S.tool==='select'){
    const h=hitTest(sx,sy);
    if(h){ select(h.kind,h.id); drag={h}; }
    else { select(null); }
    render(); return;
  }
  placeAt(wx,wz);
}
function onMove(e){
  const [sx,sy]=evPos(e); lastMouse={sx,sy};
  const [wx,wz]=s2w(sx,sy);
  $('#readout').innerHTML = inMap(wx,wz)?`x: ${Math.round(wx)}, z: ${Math.round(wz)}`:'x: &mdash;, z: &mdash;';
  if(panning){ S.view.ox=panning.ox+(sx-panning.sx); S.view.oy=panning.oy+(sy-panning.sy); render(); return; }
  if(drag){ applyDrag(drag.h,wx,wz); render(); refreshInspectorCoords(); return; }
  if(S._pendingBarrier) render();
}
function onUp(e){ if(drag){drag=null; buildLists();} panning=null; }
function onWheel(e){ e.preventDefault();
  const [sx,sy]=evPos(e); const [wx,wz]=s2w(sx,sy);
  const f = e.deltaY<0?1.12:1/1.12; S.view.scale*=f;
  S.view.ox = sx-wx*S.view.scale; S.view.oy = sy-wz*S.view.scale; render();
}
function inMap(x,z){ return x>=0&&z>=0&&x<=S.map.w&&z<=S.map.h; }
const clampX=x=>Math.max(0,Math.min(S.map.w,Math.round(x)));
const clampZ=z=>Math.max(0,Math.min(S.map.h,Math.round(z)));

function applyDrag(h,wx,wz){
  wx=clampX(wx); wz=clampZ(wz);
  if(h.kind==='playerStart') S.playerStart={x:wx,z:wz};
  else if(h.kind==='aiStart') S.aiStarts[h.id]={x:wx,z:wz};
  else if(h.kind==='building'){ const b=S.buildings.find(b=>b.id===h.id); b.x=wx; b.z=wz; }
  else if(h.kind==='trigger'){ const t=S.triggers.find(t=>t.id===h.id);
    if(h.sub==='r'){ t.params.radius=Math.max(16,Math.round(Math.hypot(wx-t.params.x,wz-t.params.z))); }
    else { t.params.x=wx; t.params.z=wz; } }
  else if(h.kind==='action'){ const a=S.actions.find(a=>a.id===h.id);
    if(h.sub==='c'){ a.params.x=wx; a.params.z=wz; }
    else if(h.sub==='p1'){ a.params.x1=wx; a.params.z1=wz; }
    else if(h.sub==='p2'){ a.params.x2=wx; a.params.z2=wz; }
    else if(h.sub==='mid'){ const dx=wx-(a.params.x1+a.params.x2)/2, dz=wz-(a.params.z1+a.params.z2)/2;
      a.params.x1=clampX(a.params.x1+dx);a.params.z1=clampZ(a.params.z1+dz);
      a.params.x2=clampX(a.params.x2+dx);a.params.z2=clampZ(a.params.z2+dz); } }
}

function placeAt(wx,wz){
  if(!inMap(wx,wz)) return;
  wx=clampX(wx); wz=clampZ(wz);
  switch(S.tool){
    case 'player': S.playerStart={x:wx,z:wz}; select('playerStart',0); break;
    case 'ai': S.aiStarts.push({x:wx,z:wz}); S.aiCount=S.aiStarts.length; syncAiCountInput(); renderFreeze();
      select('aiStart',S.aiStarts.length-1); break;
    case 'building':
      if(!S.build.def){ toast('Pick a unit first (Placement panel).',true); return; }
      { const b={id:uid(),def:S.build.def,x:wx,z:wz,facing:S.build.facing,role:S.build.role};
        S.buildings.push(b); select('building',b.id); } break;
    case 'zone':
      { const t=mkTrigger('UnitEnteredLocation'); t.params.x=wx; t.params.z=wz; t.params.radius=600;
        S.triggers.push(t); select('trigger',t.id); buildLists(); } break;
    case 'spawn':
      { const a=mkAction('SpawnUnits'); a.params.x=wx; a.params.z=wz;
        a.params.unitDefName=S.build.def||'armrock'; S.actions.push(a); select('action',a.id); buildLists(); } break;
    case 'barrier':
      if(!S._pendingBarrier){ S._pendingBarrier={x:wx,z:wz}; }
      else { const a=mkAction('SpawnBarrier');
        a.params.x1=S._pendingBarrier.x; a.params.z1=S._pendingBarrier.z; a.params.x2=wx; a.params.z2=wz;
        a.params.unitDefName=S.build.def||'armfort'; a.params.spacing=40;
        S.actions.push(a); S._pendingBarrier=null; select('action',a.id); buildLists(); }
      break;
  }
  render();
}

/* =========================================================================
 * 7. Entity factories
 * ========================================================================= */
function defaults(spec){ const p={}; for(const f of spec.fields) if(f.def!==undefined) p[f.k]=f.def; return p; }
function mkTrigger(type){ const t={kind:'trigger',id:uid(),name:uniqueName('trigger',TRIGGER_SPEC[type].label),
  type, settings:{repeating:false}, params:defaults(TRIGGER_SPEC[type]), actions:[]}; return t; }
function mkAction(type){ const a={kind:'action',id:uid(),name:uniqueName('action',ACTION_SPEC[type].label),
  type, params:defaults(ACTION_SPEC[type])}; seedGroupName(a); return a; }
function uniqueName(kind,base){ const list=kind==='trigger'?S.triggers:S.actions; let n=base,i=2;
  const has=x=>list.some(e=>e.name===x); while(has(n)){ n=base+' '+i++; } return n; }
// Group-defining actions (SpawnBarrier/SpawnUnits) carry a `name` PARAMETER that
// other actions/triggers reference (ExplodeBarrier, DespawnUnits, UnitKilled...).
// Auto-seed it from the action's label so the author never has to invent a key;
// only definers (t:'str') get seeded — reference fields (t:'nameRef') stay manual.
function seedGroupName(a){ const f=ACTION_SPEC[a.type].fields.find(f=>f.k==='name'&&f.t==='str');
  if(f && (a.params.name===undefined||a.params.name==='')) a.params.name=uniqueGroupName(slug(a.name)); }
function uniqueGroupName(base){ const used=new Set(groupNames()); let n=base||'group',i=2;
  while(used.has(n)){ n=base+'_'+i++; } return n; }

/* =========================================================================
 * 8. Selection + lists + inspector
 * ========================================================================= */
function select(kind,id){ S.selection = kind?{kind,id}:null; buildLists(); buildInspector(); render(); }

function buildLists(){
  const tl=$('#triggerList'); tl.innerHTML='';
  S.triggers.forEach(t=>tl.append(entityRow('trigger',t,'#f2c94c',TRIGGER_SPEC[t.type].label)));
  const al=$('#actionList'); al.innerHTML='';
  S.actions.forEach(a=>al.append(entityRow('action',a,actionColor(a.type),ACTION_SPEC[a.type].label)));
}
function actionColor(t){ const sp=ACTION_SPEC[t]; if(sp.spatial==='line')return'#b07cf0'; if(t==='SpawnUnits')return'#3fb6c9';
  if(t==='Victory')return'#39b54a'; if(t==='Defeat')return'#e5484d'; return'#8b97a7'; }
function entityRow(kind,e,col,ty){
  const li=el('li'); if(S.selection&&S.selection.kind===kind&&S.selection.id===e.id) li.classList.add('sel');
  const dot=el('span','dot'); dot.style.background=col;
  const nm=el('span','nm'); nm.textContent=e.name;
  const tyy=el('span','ty'); tyy.textContent=ty;
  const del=el('span','del'); del.textContent='✕';
  del.onclick=ev=>{ ev.stopPropagation(); removeEntity(kind,e.id); };
  li.append(dot,nm,tyy,del);
  li.onclick=()=>select(kind,e.id);
  return li;
}
function removeEntity(kind,id){
  if(kind==='trigger'){ S.triggers=S.triggers.filter(t=>t.id!==id); }
  else if(kind==='action'){ S.actions=S.actions.filter(a=>a.id!==id);
    S.triggers.forEach(t=>t.actions=t.actions.filter(x=>x!==id)); }
  else if(kind==='building'){ S.buildings=S.buildings.filter(b=>b.id!==id); }
  else if(kind==='aiStart'){ S.aiStarts.splice(id,1); S.aiCount=Math.max(1,S.aiStarts.length); syncAiCountInput(); renderFreeze(); }
  else if(kind==='playerStart'){ S.playerStart=null; }
  if(S.selection&&S.selection.kind===kind&&S.selection.id===id) S.selection=null;
  buildLists(); buildInspector(); render();
}

function buildInspector(){
  const body=$('#inspectorBody'); body.innerHTML='';
  const sel=S.selection;
  if(!sel){ body.innerHTML='<p class="hint">Select something on the map, or add a trigger/action below.</p>'; return; }
  if(sel.kind==='trigger') return inspectTrigger(body,S.triggers.find(t=>t.id===sel.id));
  if(sel.kind==='action')  return inspectAction(body,S.actions.find(a=>a.id===sel.id));
  if(sel.kind==='building')return inspectBuilding(body,S.buildings.find(b=>b.id===sel.id));
  if(sel.kind==='aiStart') return inspectPoint(body,'AI spawn '+(sel.id+1),S.aiStarts[sel.id],()=>removeEntity('aiStart',sel.id));
  if(sel.kind==='playerStart')return inspectPoint(body,'Player start',S.playerStart,()=>removeEntity('playerStart',0));
}
function inspHead(body,title,col,onDel){
  const h=el('div','insp-head'); const d=el('span','dot'); d.style.background=col;
  const t=el('strong'); t.textContent=title; t.style.flex='1';
  const del=el('button','btn btn-sm'); del.textContent='Delete'; del.onclick=onDel;
  h.append(d,t,del); body.append(h);
}
function inspectPoint(body,title,pt,onDel){
  inspHead(body,title,title[0]==='P'?'#39b54a':'#e5484d',onDel);
  body.append(numField('x',pt.x,v=>{pt.x=clampX(v);render();}), numField('z',pt.z,v=>{pt.z=clampZ(v);render();}));
  body.append(hint('Drag the marker on the map to move it.'));
}
function inspectBuilding(body,b){
  inspHead(body,'Building',' #e5484d',()=>removeEntity('building',b.id));
  const row=el('div','field'); row.innerHTML='<label>Unit</label>';
  const pr=el('div','pick-row'); const inp=el('input'); inp.readOnly=true; inp.value=`${unitName(b.def)} (${b.def})`;
  const pick=el('button','btn btn-sm'); pick.textContent='Change';
  pick.onclick=()=>pickUnit(def=>{b.def=def; buildInspector(); render();});
  pr.append(inp,pick); row.append(pr); body.append(row);
  body.append(teamSelectField('Owner',b.role,'owner',v=>{b.role=v;render();}));
  body.append(selectField('Facing',['','south','north','east','west'],b.facing,v=>{b.facing=v;}));
  body.append(numField('x',b.x,v=>{b.x=clampX(v);render();}),numField('z',b.z,v=>{b.z=clampZ(v);render();}));
}

function inspectTrigger(body,t){
  inspHead(body,'Trigger','#f2c94c',()=>removeEntity('trigger',t.id));
  body.append(textField('Trigger name',t.name,v=>{t.name=v;buildLists();}));
  body.append(selectField('Trigger type',Object.keys(TRIGGER_SPEC),t.type,v=>{ t.type=v; t.params=defaults(TRIGGER_SPEC[v]); buildInspector(); buildLists(); render(); }));
  // settings
  const fs=el('div','field'); fs.innerHTML='<label>Settings</label>';
  fs.append(checkbox('repeating',!!t.settings.repeating,v=>{t.settings.repeating=v;}));
  fs.append(checkbox('start active',t.settings.active!==false,v=>{ if(v) delete t.settings.active; else t.settings.active=false; }));
  body.append(fs);
  if(t.settings.repeating) body.append(numField('maxRepeats',t.settings.maxRepeats||'',v=>{t.settings.maxRepeats=v||undefined;}));
  // params
  body.append(divider('Parameters'));
  paramFields(body,t,TRIGGER_SPEC[t.type]);
  // linked actions
  body.append(divider('Fires these actions'));
  if(!S.actions.length) body.append(hint('No actions yet. Add actions below, then link them here.'));
  const ll=el('div','link-list');
  S.actions.forEach(a=>{ const lab=el('label'); const cb=el('input'); cb.type='checkbox';
    cb.checked=t.actions.includes(a.id); cb.onchange=()=>{ if(cb.checked){ if(!t.actions.includes(a.id))t.actions.push(a.id);} else t.actions=t.actions.filter(x=>x!==a.id); };
    lab.append(cb,document.createTextNode(' '+a.name+'  ')); const s=el('span','ty'); s.textContent=ACTION_SPEC[a.type].label; lab.append(s); ll.append(lab); });
  body.append(ll);
}
function inspectAction(body,a){
  inspHead(body,'Action',actionColor(a.type),()=>removeEntity('action',a.id));
  body.append(textField('Action name',a.name,v=>{a.name=v;buildLists();}));
  body.append(selectField('Action type',Object.keys(ACTION_SPEC),a.type,v=>{ a.type=v; a.params=defaults(ACTION_SPEC[v]); seedGroupName(a); buildInspector(); buildLists(); render(); }));
  body.append(divider('Parameters'));
  paramFields(body,a,ACTION_SPEC[a.type]);
}

function paramFields(body,e,spec){
  for(const f of spec.fields){
    const val=e.params[f.k];
    const set=v=>{ if(v===''||v===undefined||v===null) delete e.params[f.k]; else e.params[f.k]=v; render(); };
    let node;
    switch(f.t){
      case 'int': case 'num': node=numField(flabel(f),val,v=>set(v)); break;
      case 'bool': { const d=el('div','field'); d.append(checkbox(flabel(f),!!val,v=>set(v||undefined))); node=d; } break;
      case 'team': node=teamSelectField(flabel(f),(val!==undefined?val:''),f.teamKind||'side',v=>set(v),!f.req); break;
      case 'select': node=selectField(flabel(f),f.opts,val||'',v=>set(v)); break;
      case 'message': node=areaField(flabel(f),val||'',v=>set(v)); break;
      case 'unit': node=unitRefField(flabel(f),val||'',v=>set(v)); break;
      case 'nameRef': node=datalistField(flabel(f),val||'',groupNames(),v=>set(v)); break;
      case 'triggerRef': node=triggerRefField(flabel(f),val||'',v=>set(v)); break;
      default: node=textField(flabel(f),val||'',v=>set(v));
    }
    if(f.help){ const h=hint(f.help); h.style.margin='-4px 0 8px'; if(node)node.append(h); }
    body.append(node);
  }
  if(spec.spatial) body.append(hint('Tip: drag this on the map to set position'+(spec.spatial==='circle'?'/radius':'')+'.'));
}
function flabel(f){ return f.k+(f.req?' *':''); }
function groupNames(){ const s=new Set();
  S.actions.forEach(a=>{ if(a.params.name)s.add(a.params.name); }); return [...s]; }

/* small field builders */
function el(tag,cls){ const e=document.createElement(tag); if(cls)e.className=cls; return e; }
function fieldWrap(label){ const d=el('div','field'); const l=el('label'); l.textContent=label; d.append(l); return d; }
function textField(label,val,on){ const d=fieldWrap(label); const i=el('input'); i.value=val||''; i.oninput=()=>on(i.value); d.append(i); return d; }
function numField(label,val,on){ const d=fieldWrap(label); const i=el('input'); i.type='number'; i.value=(val===''||val==null)?'':val;
  i.dataset.k=label; i.oninput=()=>on(i.value===''?'':Number(i.value)); d.append(i); return d; }
function areaField(label,val,on){ const d=fieldWrap(label); const i=el('textarea'); i.rows=3; i.value=val||''; i.oninput=()=>on(i.value); d.append(i); return d; }
function selectField(label,opts,val,on){ const d=fieldWrap(label); const s=el('select');
  opts.forEach(o=>{ const op=el('option'); op.value=o; op.textContent=o===''?'(default)':o; if(o===val)op.selected=true; s.append(op); });
  s.onchange=()=>on(s.value); d.append(s); return d; }
function checkbox(label,val,on){ const l=el('label'); l.style.display='flex'; l.style.gap='7px'; l.style.alignItems='center'; l.style.margin='3px 0';
  const c=el('input'); c.type='checkbox'; c.checked=val; c.style.width='auto'; c.onchange=()=>on(c.checked);
  l.append(c,document.createTextNode(label)); return l; }
function teamField(label,val,on){ const d=fieldWrap(label); const i=el('input'); i.setAttribute('list','dlTeams'); i.value=val||''; i.oninput=()=>on(i.value); d.append(i); return d; }
// concrete team/owner options derived from the AI count.
// kind: 'owner' (one AI or the player), 'owner-gaia' (+ Gaia/neutral), 'side' (also whole-side roles)
function aiRoles(){ const r=[]; for(let i=1;i<=S.aiCount;i++) r.push('ai'+i); return r; }
function teamOptionList(kind,includeNone){
  const out=[];
  if(kind==='owner-gaia') out.push({v:'',label:'Gaia / neutral',group:''});
  else if(includeNone) out.push({v:'',label:'(none / default)',group:''});
  aiRoles().forEach((r,i)=>out.push({v:r,label:'AI '+(i+1)+' ('+r+')',group:'Specific AI'}));
  out.push({v:'humans',label:'Player (humans)',group:'Player'});
  if(kind==='side') out.push({v:'enemies',label:'All AIs (enemies)',group:'Whole side'});
  return out;
}
function fillTeamSelect(sel,val,kind,includeNone){
  sel.innerHTML='';
  const opts=teamOptionList(kind,includeNone), groups={}, order=[];
  opts.forEach(o=>{ if(!(o.group in groups)){groups[o.group]=[];order.push(o.group);} groups[o.group].push(o); });
  order.forEach(g=>{ let parent=sel; if(g){ const og=document.createElement('optgroup'); og.label=g; sel.append(og); parent=og; }
    groups[g].forEach(o=>{ const op=document.createElement('option'); op.value=o.v; op.textContent=o.label; parent.append(op); }); });
  if(val!==undefined && val!=='' && !opts.some(o=>o.v===val)){ const op=document.createElement('option'); op.value=val; op.textContent=val+' (custom)'; sel.append(op); }
  sel.value=(val!==undefined&&val!==null)?val:'';
}
function teamSelectField(label,val,kind,on,includeNone){ const d=fieldWrap(label); const s=el('select'); fillTeamSelect(s,val,kind,includeNone); s.onchange=()=>on(s.value); d.append(s); return d; }
function datalistField(label,val,opts,on){ const d=fieldWrap(label); const i=el('input'); const id='dl'+Math.random().toString(36).slice(2);
  i.setAttribute('list',id); const dl=el('datalist'); dl.id=id; opts.forEach(o=>{const op=el('option');op.value=o;dl.append(op);});
  i.value=val||''; i.oninput=()=>on(i.value); d.append(i,dl); return d; }
function unitRefField(label,val,on){ const d=fieldWrap(label); const pr=el('div','pick-row');
  const i=el('input'); i.readOnly=true; i.placeholder='(none)'; i.value=val?`${unitName(val)} (${val})`:'';
  const b=el('button','btn btn-sm'); b.textContent='Pick'; b.onclick=()=>pickUnit(def=>{ i.value=`${unitName(def)} (${def})`; on(def); });
  pr.append(i,b); d.append(pr); return d; }
function triggerRefField(label,val,on){ const d=fieldWrap(label); const s=el('select');
  const none=el('option'); none.value=''; none.textContent='(select trigger)'; s.append(none);
  S.triggers.forEach(t=>{ const op=el('option'); op.value=t.id; op.textContent=t.name; if(t.id===val)op.selected=true; s.append(op); });
  s.onchange=()=>on(s.value); d.append(s); return d; }
function divider(txt){ const d=el('div'); d.style.cssText='border-top:1px solid var(--line);margin:12px 0 8px;padding-top:6px;color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.5px'; d.textContent=txt; return d; }
function hint(txt){ const p=el('p','hint'); p.textContent=txt; return p; }
function refreshInspectorCoords(){ if(!S.selection)return;
  $$('#inspectorBody input[type=number]').forEach(i=>{ const k=i.dataset.k; const e=curEntity(); if(!e)return;
    const src = e.params||e; if(k in src && document.activeElement!==i) i.value=src[k]; }); }
function curEntity(){ const s=S.selection; if(!s)return null;
  if(s.kind==='trigger')return S.triggers.find(t=>t.id===s.id);
  if(s.kind==='action')return S.actions.find(a=>a.id===s.id);
  if(s.kind==='building')return S.buildings.find(b=>b.id===s.id);
  if(s.kind==='aiStart')return S.aiStarts[s.id]; if(s.kind==='playerStart')return S.playerStart; }

/* =========================================================================
 * 9. Sidebar (meta, freeze, build palette)
 * ========================================================================= */
function buildSidebar(){
  $('#metaTitle').value=S.meta.title; $('#metaTitle').oninput=e=>S.meta.title=e.target.value;
  $('#metaAuthor').value=S.meta.author; $('#metaAuthor').oninput=e=>S.meta.author=e.target.value;
  $('#metaSummary').value=S.meta.summary; $('#metaSummary').oninput=e=>S.meta.summary=e.target.value;
  $('#metaBriefing').value=S.meta.briefing; $('#metaBriefing').oninput=e=>S.meta.briefing=e.target.value;
  $('#metaDifficulty').value=S.meta.difficulty; $('#metaDifficulty').onchange=e=>S.meta.difficulty=e.target.value;
  $('#metaDeathmode').value=S.meta.deathmode||'own_com'; $('#metaDeathmode').onchange=e=>S.meta.deathmode=e.target.value;
  fillTeamSelect($('#buildRole'),S.build.role,'owner'); $('#buildRole').onchange=e=>S.build.role=e.target.value;
  $('#buildFacing').value=S.build.facing; $('#buildFacing').onchange=e=>S.build.facing=e.target.value;
  $$('#placeCatBtns .catbtn').forEach(b=>{ b.onclick=()=>{
    openUnitPicker({fac:b.dataset.fac, building:b.dataset.b==='1'}, def=>setBuildDef(def)); }; });
  updateBuildDisplay();
  $('#aiCount').value=S.aiCount; $('#aiCount').onchange=e=>setAiCount(parseInt(e.target.value,10));
  renderFreeze();
}
function setBuildDef(def){ S.build.def=def; updateBuildDisplay();
  if(S.tool==='select') setTool('building'); }   // ready to place
function updateBuildDisplay(){
  const u=S.build.def?UNITS.find(x=>x.def===S.build.def):null;
  const ic=$('#curUnitIcon'); ic.style.backgroundImage = (u&&u.icon)?`url("${u.icon}")`:'';
  ic.classList.toggle('noicon', !(u&&u.icon));
  $('#curUnitName').textContent = u?(u.name||u.def):'(no unit selected)';
  $('#curUnitDef').textContent  = u?u.def:'';
}
// aiteam==enemies and players==humans in the Mission API (api_missions.lua) -
// they are aliases for the same teams. Normalise so we never show duplicates.
const ROLE_ALIASES={ aiteam:'enemies', players:'humans' };
function normalizeFreeze(){ const seen=new Set(); S.freeze=S.freeze.map(r=>ROLE_ALIASES[r]||r).filter(r=>{ if(seen.has(r))return false; seen.add(r); return true; }); }
function renderFreeze(){
  normalizeFreeze();
  const roles=['humans','enemies'];                 // 'enemies' = the whole AI side (all AIs)
  for(let i=1;i<=S.aiCount;i++) roles.push('ai'+i);  // a single specific AI
  const titles={humans:'all human players',enemies:'all AIs (whole enemy side)'};
  const c=$('#freezeList'); c.innerHTML='';
  roles.forEach(r=>{ const chip=el('span','chip'); if(S.freeze.includes(r))chip.classList.add('on');
    chip.textContent=r; if(titles[r])chip.title=titles[r]; else chip.title='AI #'+r.slice(2)+' only';
    chip.onclick=()=>{ if(S.freeze.includes(r))S.freeze=S.freeze.filter(x=>x!==r); else S.freeze.push(r); renderFreeze(); };
    c.append(chip); });
}
function syncAiCountInput(){ const i=$('#aiCount'); if(i) i.value=S.aiCount; }
function defaultAiPos(i,n){ return { x:Math.round(S.map.w*0.82), z:Math.round(S.map.h*(i+1)/(n+1)) }; }
function setAiCount(n){
  n=Math.max(1,Math.min(8, isNaN(n)?1:n)); S.aiCount=n;
  while(S.aiStarts.length<n) S.aiStarts.push(defaultAiPos(S.aiStarts.length,n));
  while(S.aiStarts.length>n) S.aiStarts.pop();
  if(S.selection&&S.selection.kind==='aiStart'&&S.selection.id>=n) S.selection=null;
  if(aiRoles().indexOf(S.build.role)<0 && S.build.role!=='humans' && S.build.role!=='') S.build.role='ai'+n;
  syncAiCountInput(); renderFreeze();
  if($('#buildRole')) fillTeamSelect($('#buildRole'),S.build.role,'owner');
  buildInspector(); render();
  DBG.log('setAiCount '+n);
}
function unitName(def){ const u=UNITS.find(u=>u.def===def); return u?u.name:def; }

/* =========================================================================
 * 10. Unit picker modal
 * ========================================================================= */
const FACTIONS=['Armada','Cortex','Legion'];
function isBuilding(u){ return /Buildings$/.test(u.cat); }
let unitPickCb=null, unitFilter={fac:null,building:null};
function initUnitModal(){
  const cb=$('#unitCatBtns'); cb.innerHTML='';
  FACTIONS.forEach(fac=>{ [['Units',0],['Buildings',1]].forEach(pair=>{
    const b=el('button','catbtn'); b.textContent=fac+' '+pair[0]; b.dataset.fac=fac; b.dataset.b=String(pair[1]);
    b.onclick=()=>{ unitFilter={fac,building:!!pair[1]}; drawUnits(); }; cb.append(b); }); });
  const all=el('button','catbtn'); all.textContent='All'; all.dataset.fac=''; all.dataset.b='';
  all.onclick=()=>{ unitFilter={fac:null,building:null}; drawUnits(); }; cb.append(all);
  $('#unitSearch').oninput=drawUnits;
}
function markCat(){ $$('#unitCatBtns .catbtn').forEach(b=>{
  const on=(b.dataset.fac||null)===(unitFilter.fac||null) && (b.dataset.b===''?unitFilter.building==null:(b.dataset.b==='1')===!!unitFilter.building);
  b.classList.toggle('active',on); }); }
function drawUnits(){
  markCat();
  const q=$('#unitSearch').value.trim().toLowerCase();
  const list=UNITS.filter(u=>{
    if(unitFilter.fac && u.faction!==unitFilter.fac) return false;
    if(unitFilter.building!=null && isBuilding(u)!==unitFilter.building) return false;
    if(q && !u.def.includes(q) && !(u.name||'').toLowerCase().includes(q)) return false;
    return true; }).slice(0,800);
  const g=$('#unitGrid'); g.innerHTML='';
  list.forEach(u=>{ const c=el('div','unit-card'); c.title=u.faction+' · '+u.cat;
    const ic=el('div','uicon'); if(u.icon) ic.style.backgroundImage=`url("${u.icon}")`; else ic.classList.add('noicon');
    const nm=el('div','un'); nm.textContent=u.name||u.def;
    const df=el('div','ud'); df.textContent=u.def;
    c.append(ic,nm,df);
    c.onclick=()=>{ closeModal('#unitModal'); if(unitPickCb)unitPickCb(u.def); };
    g.append(c); });
  if(!list.length) g.innerHTML='<p class="hint" style="padding:16px">No units match.</p>';
}
function openUnitPicker(filter,cb){ unitPickCb=cb; unitFilter=filter||{fac:null,building:null};
  openModal('#unitModal'); drawUnits(); $('#unitSearch').value=''; $('#unitSearch').focus(); }
function pickUnit(cb){ openUnitPicker(null,cb); }   // inline fields: all categories available

/* =========================================================================
 * 11. Modals + toast helpers
 * ========================================================================= */
function openModal(sel){ $(sel).hidden=false; }
function closeModal(sel){ $(sel).hidden=true; }
function bindModals(){ $$('.modal [data-close]').forEach(b=>b.onclick=()=>b.closest('.modal').hidden=true);
  $$('.modal').forEach(m=>m.onclick=e=>{ if(e.target===m) m.hidden=true; }); }
let toastT;
function toast(msg,err){ clearTimeout(toastT); let t=$('#toastEl'); if(!t){t=el('div','toast');t.id='toastEl';document.body.append(t);}
  t.className='toast'+(err?' err':''); t.textContent=msg; t.style.display='block'; toastT=setTimeout(()=>t.style.display='none',2600); }
function esc(s){ return (s||'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }

/* generic prompt modal: returns via callback. fields=[{k,label,type,opts,val}] */
function genericModal(title,fields,onOk){
  $('#gmTitle').textContent=title; const b=$('#gmBody'); b.innerHTML='';
  const vals={}; fields.forEach(f=>{ vals[f.k]=f.val??'';
    let node; if(f.type==='select') node=selectField(f.label,f.opts,f.val||'',v=>vals[f.k]=v);
    else node=textField(f.label,f.val||'',v=>vals[f.k]=v); b.append(node); });
  openModal('#genericModal');
  $('#gmCancel').onclick=()=>closeModal('#genericModal');
  $('#gmOk').onclick=()=>{ closeModal('#genericModal'); onOk(vals); };
}

/* =========================================================================
 * 12. Tools + chrome wiring
 * ========================================================================= */
function setTool(t){ S.tool=t; S._pendingBarrier=null;
  $$('.tool').forEach(b=>b.classList.toggle('active',b.dataset.tool===t));
  const hints={select:'Click to select; drag handles to move. Hold Space or right-drag to pan; wheel to zoom.',
    player:'Click the map to set the player start.', ai:'Click the map to add an AI spawn point.',
    building:'Click to place the selected unit. Pick a unit in the Placement panel first.',
    zone:'Click to drop a circular trigger area (Unit entered area).',
    barrier:'Click the start, then the end of the barrier line.',
    spawn:'Click to drop a Spawn-units point.'};
  $('#toolHint').textContent=hints[t]||''; cv&&(cv.style.cursor=t==='select'?'default':'crosshair'); render&&render();
}
function hotkeys(e){
  if(e.target.matches('input,textarea,select')) return;
  const m={'KeyV':'select','Digit1':'player','Digit2':'ai','Digit3':'building','Digit4':'zone','Digit5':'barrier','Digit6':'spawn'};
  if(m[e.code]){ setTool(m[e.code]); }
  if(e.code==='Delete'&&S.selection){ removeEntity(S.selection.kind,S.selection.id); }
}
function bindChrome(){
  $$('.tool').forEach(b=>b.onclick=()=>setTool(b.dataset.tool));
  $('#zoomIn').onclick=()=>{S.view.scale*=1.2;render();};
  $('#zoomOut').onclick=()=>{S.view.scale/=1.2;render();};
  $('#zoomFit').onclick=()=>{fitView();render();};
  $('#btnAddTrigger').onclick=()=>genericModal('Add trigger',
    [{k:'type',label:'Type',type:'select',opts:Object.keys(TRIGGER_SPEC),val:'UnitEnteredLocation'}],
    v=>{ const t=mkTrigger(v.type); S.triggers.push(t); buildLists(); select('trigger',t.id); });
  $('#btnAddAction').onclick=()=>genericModal('Add action',
    [{k:'type',label:'Type',type:'select',opts:Object.keys(ACTION_SPEC),val:'SendMessage'}],
    v=>{ const a=mkAction(v.type); S.actions.push(a); buildLists(); select('action',a.id); });
  $('#btnNew').onclick=()=>{ if(confirm('Discard current scenario and start a new one on this map?')){ const m=S.map; S=newState({file:m.file,name:m.name,w:m.w,h:m.h,thumb:m.thumb}); startApp(); } };
  $('#btnChangeMap').onclick=()=>{ $('#app').hidden=true; $('#launch').hidden=false; };
  $('#btnOpen').onclick=()=>openFileDialog(false);
  $('#btnSaveMission').onclick=saveMission;
  $('#btnSaveScenario').onclick=saveScenario;
  $('#btnTestPlay').onclick=testPlay;
  $('#btnStartScript').onclick=()=>{ download('play_'+slug(S.meta.missionFile)+'.txt', exportStartScript('Beyond All Reason $VERSION')); toast('Start script downloaded.'); };
  $('#btnLog').onclick=downloadLog;
}
function downloadLog(){ DBG.log('downloadLog requested'); download('bar-designer-log.txt', DBG.dump()); toast('Diagnostic log downloaded.'); }

/* =========================================================================
 * 13. Export -> Lua
 * ========================================================================= */
function luaStr(s){ s=String(s==null?'':s);
  if(/[\n"\\]/.test(s)){ if(!s.includes(']]')) return '[['+s+']]'; return '"'+s.replace(/\\/g,'\\\\').replace(/"/g,'\\"').replace(/\n/g,'\\n')+'"'; }
  return '"'+s+'"'; }
function luaNum(n){ return String(n); }

function exportMission(){
  const T=S, idToKey={}, used=new Set();
  const keyFor=(name,fallback)=>{ let k=(name||'').replace(/[^A-Za-z0-9_]/g,''); if(!/^[A-Za-z_]/.test(k))k='_'+k; if(!k)k=fallback;
    let b=k,i=2; while(used.has(k)){k=b+i++;} used.add(k); return k; };
  T.actions.forEach(a=>idToKey['action:'+a.id]=keyFor(a.name,'act'));
  T.triggers.forEach(t=>idToKey['trigger:'+t.id]=keyFor(t.name,'trg'));

  const L=[]; const p=(s='')=>L.push(s);
  p('-- '+(T.meta.title||'Scenario')+'  -- generated by BAR Scenario Designer');
  p('-- Map: '+T.map.name+'  ('+T.map.w+'x'+T.map.h+')');
  p('-- Edit/iterate in-game with /luarules reload (logic-only changes).');
  p(designerBlock());
  p('');
  p("local triggerTypes = GG['MissionAPI'].TriggerTypes");
  p("local actionTypes  = GG['MissionAPI'].ActionTypes");
  p('');
  // Teams
  p('local Teams = { humans = { allyTeam = 0 }, enemies = { allyTeam = 1 } }');
  p('');
  // Setup
  p('local Setup = {');
  if(T.freeze.length) p('\tfreeze = { '+T.freeze.map(luaStr).join(', ')+' },');
  // start positions: pin player + each AI commander where they were placed
  const sps=[]; if(T.playerStart) sps.push({role:'humans',x:T.playerStart.x,z:T.playerStart.z});
  T.aiStarts.forEach((a,i)=>sps.push({role:'ai'+(i+1),x:a.x,z:a.z}));
  if(sps.length){ p('\tstartPositions = {');
    sps.forEach(s=>p('\t\t{ role = '+luaStr(s.role)+', x = '+luaNum(s.x)+', z = '+luaNum(s.z)+' },'));
    p('\t},'); }
  const byRole={}; T.buildings.forEach(b=>{ (byRole[b.role]=byRole[b.role]||[]).push(b); });
  if(Object.keys(byRole).length){ p('\tbases = {');
    for(const role in byRole){ p('\t\t'+luaKey(role)+' = {');
      byRole[role].forEach(b=>{ let s='\t\t\t{ def = '+luaStr(b.def)+', x = '+luaNum(b.x)+', z = '+luaNum(b.z);
        if(b.facing) s+=', facing = '+luaStr(b.facing); s+=' },'; p(s); });
      p('\t\t},'); }
    p('\t},'); }
  p('}'); p('');
  // Triggers
  p('local Triggers = {');
  T.triggers.forEach(t=>{ const key=idToKey['trigger:'+t.id];
    p('\t'+key+' = {');
    p('\t\ttype = triggerTypes.'+t.type+',');
    p('\t\tsettings = { '+settingsStr(t.settings)+' },');
    p('\t\tparameters = { '+paramsStr(t,TRIGGER_SPEC[t.type],idToKey)+' },');
    const acts=t.actions.map(id=>idToKey['action:'+id]).filter(Boolean);
    p('\t\tactions = { '+acts.map(luaStr).join(', ')+' },');
    p('\t},'); });
  p('}'); p('');
  // Actions
  p('local Actions = {');
  T.actions.forEach(a=>{ const key=idToKey['action:'+a.id];
    p('\t'+key+' = {');
    p('\t\ttype = actionTypes.'+a.type+',');
    p('\t\tparameters = { '+paramsStr(a,ACTION_SPEC[a.type],idToKey)+' },');
    p('\t},'); });
  p('}'); p('');
  p('return { Teams = Teams, Setup = Setup, Triggers = Triggers, Actions = Actions }');
  p('');
  return L.join('\n');
}
function luaKey(k){ return /^[A-Za-z_][A-Za-z0-9_]*$/.test(k)?k:'["'+k+'"]'; }
function settingsStr(s){ const parts=['repeating = '+(s.repeating?'true':'false')];
  if(s.repeating&&s.maxRepeats) parts.push('maxRepeats = '+luaNum(s.maxRepeats));
  if(s.active===false) parts.push('active = false'); return parts.join(', '); }
function paramsStr(e,spec,idToKey){ const parts=[];
  for(const f of spec.fields){ let v=e.params[f.k]; if(v===undefined||v===''||v===null) continue;
    if(f.t==='triggerRef'){ const k=idToKey['trigger:'+v]; if(!k)continue; parts.push(f.k+' = '+luaStr(k)); continue; }
    if(f.t==='bool'){ parts.push(f.k+' = '+(v?'true':'false')); continue; }
    if(f.t==='int'||f.t==='num'){ parts.push(f.k+' = '+luaNum(v)); continue; }
    parts.push(f.k+' = '+luaStr(v)); }
  return parts.join(', '); }

function designerBlock(){
  const data={ v:1, map:S.map, meta:S.meta, playerStart:S.playerStart, aiStarts:S.aiStarts, aiCount:S.aiCount,
    freeze:S.freeze, buildings:S.buildings, triggers:S.triggers, actions:S.actions, nextId:S.nextId };
  return '--[==[ SCENARIO_DESIGNER_V1\n'+JSON.stringify(data)+'\n]==]';
}

/* scenario menu file (singleplayer/scenarios/scenarioNNN.lua) */
function exportScenario(idx){
  const T=S, mp='missions/'+slug(T.meta.missionFile)+'.lua';
  const ps=T.playerStart||{x:Math.round(T.map.w*0.15),z:Math.round(T.map.h*0.5)};
  const ais=T.aiStarts.length?T.aiStarts:[{x:Math.round(T.map.w*0.85),z:Math.round(T.map.h*0.5)}];
  const pxPct=Math.round(ps.x/T.map.w*100)+'%', pyPct=Math.round(ps.z/T.map.h*100)+'%';
  const L=[],p=(s='')=>L.push(s);
  p('-- Generated by BAR Scenario Designer. Place in singleplayer/scenarios/.');
  p('local scenariodata = {');
  p('\tindex = '+idx+',');
  p('\tscenarioid = "'+slug(T.meta.title)+'",');
  p('\tversion = "1",');
  p('\ttitle = '+luaStr(T.meta.title)+',');
  p('\tauthor = '+luaStr(T.meta.author||'local mod')+',');
  p('\timagepath = "scenario'+idx+'.jpg",');
  p('\timageflavor = '+luaStr(T.meta.summary||'')+',');
  p('\tsummary = '+luaStr(T.meta.summary||'')+',');
  p('\tbriefing = '+luaStr(T.meta.briefing||'')+',');
  p('\tmapfilename = '+luaStr(T.map.name)+',');
  p('\tplayerstartx = "'+pxPct+'",');
  p('\tplayerstarty = "'+pyPct+'",');
  p('\tpartime = 3000, parresources = 1000000,');
  p('\tdifficulty = 4, defaultdifficulty = "Normal",');
  p('\tdifficulties = {');
  p('\t\t{name = "Beginner", playerhandicap = 50, enemyhandicap = 0},');
  p('\t\t{name = "Normal",   playerhandicap = 0,  enemyhandicap = 0},');
  p('\t\t{name = "Hard",     playerhandicap = 0,  enemyhandicap = 25},');
  p('\t},');
  p('\tallowedsides = {"Armada", "Cortex", "Random"},');
  p('\tvictorycondition = "Complete the scripted objectives",');
  p('\tlosscondition = "Death of your Commander",');
  p('\tunitlimits = {},');
  p('\tscenariooptions = { scenarioid = "'+slug(T.meta.title)+'" },');
  // start script
  p('\tstartscript = [[[Game]');
  p('{');
  p('\t[allyTeam0] { startrectleft = 0; startrectright = 0.25; startrecttop = 0; startrectbottom = 1; numallies = 0; }');
  p('\t[allyTeam1] { startrectleft = 0.75; startrectright = 1; startrecttop = 0; startrectbottom = 1; numallies = 0; }');
  p('\t[team0] { Side = __PLAYERSIDE__; Handicap = __PLAYERHANDICAP__; RgbColor = 0 0.51 0.78; AllyTeam = 0; TeamLeader = 0; StartPosX = '+ps.x+'; StartPosZ = '+ps.z+'; }');
  ais.forEach((a,i)=>{ p('\t[team'+(i+1)+'] { Side = Armada; Handicap = __ENEMYHANDICAP__; RgbColor = 0.9 0.1 0.29; AllyTeam = 1; TeamLeader = 0; StartPosX = '+a.x+'; StartPosZ = '+a.z+'; }'); });
  ais.forEach((a,i)=>{ p('\t[ai'+i+'] { Host = 0; IsFromDemo = 0; Name = BARbarianAI('+(i+1)+'); ShortName = BARb; Team = '+(i+1)+'; Version = stable; }'); });
  p('\t[modoptions] { scenariooptions = __SCENARIOOPTIONS__; mission_path = '+mp+'; mission_difficulty = '+(T.meta.difficulty||'normal')+'; deathmode = '+(T.meta.deathmode||'own_com')+'; }');
  p('\t[player0] { IsFromDemo = 0; Name = __PLAYERNAME__; Team = 0; rank = 0; }');
  p('\thostip = 127.0.0.1; hostport = 0; numplayers = 1; startpostype = 0;');
  p('\tmapname = __MAPNAME__; ishost = 1; numusers = '+(ais.length+1)+'; gametype = __BARVERSION__;');
  p('\tGameStartDelay = 3; myplayername = __PLAYERNAME__; nohelperais = 0;');
  p('\tNumRestrictions = __NUMRESTRICTIONS__;');
  p('\t[RESTRICT] { __RESTRICTEDUNITS__ }');
  p('}');
  p('\t]],');
  p('}');
  p('return scenariodata');
  return L.join('\n');
}

/* A ready-to-run engine start script (direct solo launch, startpostype=0 with the
   placed start positions). gametypeToken is filled by serve.ps1 for /play, or the
   literal dev-game name for a downloaded script. */
function exportStartScript(gametypeToken){
  const T=S, mp='missions/'+slug(T.meta.missionFile)+'.lua';
  const ps=T.playerStart||{x:Math.round(T.map.w*0.15),z:Math.round(T.map.h*0.5)};
  const ais=T.aiStarts.length?T.aiStarts:[{x:Math.round(T.map.w*0.85),z:Math.round(T.map.h*0.5)}];
  const L=[],p=s=>L.push(s);
  p('// Generated by BAR Scenario Designer - run with: spring.exe --write-dir <data> this.txt');
  p('[Game]'); p('{');
  const infLos = $('#chkInfLos') && $('#chkInfLos').checked;
  p('\t[modoptions] { mission_path = '+mp+'; mission_difficulty = '+(T.meta.difficulty||'normal')+'; deathmode = '+(T.meta.deathmode||'own_com')+(infLos?'; mission_debug_los = 1':'')+'; }');
  p('\t[allyTeam0] { numallies = 0; }');
  p('\t[allyTeam1] { numallies = 0; }');
  p('\t[team0] { TeamLeader = 0; AllyTeam = 0; Side = Armada; RgbColor = 0 0.5 1; StartPosX = '+ps.x+'; StartPosZ = '+ps.z+'; }');
  ais.forEach((a,i)=>p('\t[team'+(i+1)+'] { TeamLeader = 0; AllyTeam = 1; Side = Armada; RgbColor = 0.9 0.1 0.29; StartPosX = '+a.x+'; StartPosZ = '+a.z+'; }'));
  ais.forEach((a,i)=>p('\t[ai'+i+'] { Host = 0; IsFromDemo = 0; Name = BARbarianAI('+(i+1)+'); ShortName = BARb; Team = '+(i+1)+'; Version = stable; }'));
  p('\t[player0] { Name = Tester; Team = 0; rank = 0; IsFromDemo = 0; }');
  p('\tmapname = '+T.map.name+';');
  p('\tgametype = '+gametypeToken+';');
  p('\tstartpostype = 0;');
  p('\tishost = 1; hostip = 127.0.0.1; hostport = 0;');
  p('\tnumplayers = 1; numusers = '+(ais.length+1)+';');
  p('\tmyplayername = Tester; nohelperais = 0; GameStartDelay = 0;');
  p('}');
  return L.join('\n');
}
const onServer = ()=> location.protocol==='http:' || location.protocol==='https:';
function testPlay(){
  const errs=validate(); if(errs.length){ toast(errs[0]+(errs.length>1?' (+'+(errs.length-1)+' more)':''),true); return; }
  if(onServer()){
    DBG.log('testPlay via server');
    toast('Launching game…');
    fetch('/play',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({ missionFile:slug(S.meta.missionFile), mission:exportMission(), startscript:exportStartScript('__GAMETYPE__') })})
      .then(r=>r.json())
      .then(j=>{ if(j&&j.ok) toast('Game launching — '+(j.detail||'')); else { toast('Launch failed: '+((j&&j.error)||'?'),true); DBG.log('play failed',j); } })
      .catch(e=>{ toast('Launch failed: '+e.message,true); DBG.log('play error',e.message); });
  } else {
    toast('Run serve.ps1 and open via http://localhost for one-click launch. Downloading start script instead.',true);
    download('play_'+slug(S.meta.missionFile)+'.txt', exportStartScript('Beyond All Reason $VERSION'));
  }
}
function download(name,text){ const b=new Blob([text],{type:'text/plain'});
  const u=URL.createObjectURL(b); const a=el('a'); a.href=u; a.download=name; a.click(); setTimeout(()=>URL.revokeObjectURL(u),2000); }
function validate(){ const errs=[];
  S.triggers.forEach(t=>{ const sp=TRIGGER_SPEC[t.type]; sp.fields.forEach(f=>{ if(f.req&&(t.params[f.k]===undefined||t.params[f.k]==='')) errs.push('Trigger "'+t.name+'": missing '+f.k); }); });
  S.actions.forEach(a=>{ const sp=ACTION_SPEC[a.type]; sp.fields.forEach(f=>{ if(f.req&&(a.params[f.k]===undefined||a.params[f.k]==='')) errs.push('Action "'+a.name+'": missing '+f.k); }); });
  return errs; }
function saveMission(){ const errs=validate(); if(errs.length){ toast(errs[0]+(errs.length>1?' (+'+(errs.length-1)+' more)':''),true); }
  download(slug(S.meta.missionFile)+'.lua', exportMission());
  toast('Saved '+slug(S.meta.missionFile)+'.lua  → put it in singleplayer/missions/'); }
function saveScenario(){ genericModal('Export scenario menu file',
  [{k:'idx',label:'Scenario index (filename number, must be unique)',type:'text',val:String(S.meta.scenarioIndex||26)},
   {k:'mf',label:'Mission file name (without .lua)',type:'text',val:slug(S.meta.missionFile)}],
  v=>{ S.meta.scenarioIndex=Number(v.idx)||26; S.meta.missionFile=v.mf||S.meta.missionFile;
    const n=String(S.meta.scenarioIndex).padStart(3,'0');
    download('scenario'+n+'.lua', exportScenario(S.meta.scenarioIndex));
    toast('Saved scenario'+n+'.lua  → put it in singleplayer/scenarios/'); }); }

/* =========================================================================
 * 14. Import / open
 * ========================================================================= */
function openFileDialog(fromLaunch){ const inp=$('#fileInput');
  inp.onchange=()=>{ const f=inp.files[0]; if(!f)return; const rd=new FileReader();
    rd.onload=()=>{ try{ loadScenarioText(rd.result,fromLaunch); }catch(err){ toast('Open failed: '+err.message,true); console.error(err); } inp.value=''; };
    rd.readAsText(f); };
  inp.click();
}
function loadScenarioText(text,fromLaunch){
  const m=text.match(/SCENARIO_DESIGNER_V1\s*\n([\s\S]*?)\n\]==\]/);
  if(m){ const data=JSON.parse(m[1]); applyImported(data); toast('Scenario loaded (designer format).'); return; }
  // best-effort parse of a hand-written / generated mission lua
  const parsed=parseLuaScenario(text);
  if(parsed){ applyImported(parsed); toast('Imported (parsed from Lua). Verify positions.'); }
  else toast('Could not read this file. Only Mission API scenario files are supported.',true);
}
function applyImported(data){
  // resolve map: prefer embedded; else keep current; else ask
  let map=data.map;
  if(!map || !MAPS.find(x=>x.file===map.file)){
    const found = data.map && MAPS.find(x=>x.name===data.map.name);
    map = found || (S&&S.map) || MAPS[0];
  } else { map = MAPS.find(x=>x.file===map.file); }
  if(!map){ toast('No maps available; run prepare_assets.ps1.',true); return; }
  S = newState({file:map.file,name:map.name,w:map.w,h:map.h,thumb:map.thumb});
  if(data.meta) Object.assign(S.meta,data.meta);
  S.playerStart=data.playerStart||null; S.aiStarts=data.aiStarts||[];
  S.aiCount=data.aiCount||S.aiStarts.length||1;
  S.freeze=data.freeze||[]; S.buildings=data.buildings||[];
  S.triggers=data.triggers||[]; S.actions=data.actions||[];
  // ensure ids & nextId
  let mx=0; const fix=e=>{ if(!e.id){e.id=uid();} const n=parseInt(String(e.id).replace(/\D/g,'')); if(n>mx)mx=n; };
  S.triggers.forEach(t=>{t.kind='trigger';fix(t);}); S.actions.forEach(a=>{a.kind='action';fix(a);}); S.buildings.forEach(b=>fix(b));
  S.nextId=Math.max(S.nextId,mx+1)||1;
  startApp();
}

/* ---- minimal Lua reader for scenario mission files (best effort) ---- */
function parseLuaScenario(src){
  try{
    const env=luaEval(src, S?{mapSizeX:S.map.w,mapSizeZ:S.map.h}:{mapSizeX:8192,mapSizeZ:8192});
    const ret=env.__return;
    if(!ret||typeof ret!=='object') return null;
    const out={ meta:{title:'Imported scenario'}, playerStart:null, aiStarts:[], freeze:[], buildings:[], triggers:[], actions:[] };
    const Setup=ret.Setup||{};
    if(Setup.freeze) out.freeze=arr(Setup.freeze).map(String);
    if(Setup.bases) for(const role in Setup.bases){ arr(Setup.bases[role]).forEach(b=>{
      out.buildings.push({id:'e'+(idc++),def:String(b.def),x:+b.x,z:+b.z,facing:b.facing?String(b.facing):'',role}); }); }
    if(Setup.startPositions) arr(Setup.startPositions).forEach(sp=>{ const r=String(sp.role);
      if(r==='humans'||r==='players') out.playerStart={x:+sp.x,z:+sp.z};
      else if(/^(ai|enemy)\d+$/.test(r)){ out.aiStarts[parseInt(r.replace(/\D/g,''),10)-1]={x:+sp.x,z:+sp.z}; } });
    // actions first (so triggers can reference by key)
    const keyToId={};
    const Actions=ret.Actions||{};
    for(const key in Actions){ const a=Actions[key]; const type=AT_REV[a.type]; if(!type||!ACTION_SPEC[type])continue;
      const id='e'+(idc++); keyToId[key]=id;
      out.actions.push({kind:'action',id,name:key,type,params:cleanParams(a.parameters||{},ACTION_SPEC[type])}); }
    const Triggers=ret.Triggers||{};
    for(const key in Triggers){ const t=Triggers[key]; const type=TT_REV[t.type]; if(!type||!TRIGGER_SPEC[type])continue;
      const id='e'+(idc++);
      const acts=arr(t.actions).map(k=>keyToId[k]).filter(Boolean);
      const st=t.settings||{}; const settings={repeating:!!st.repeating}; if(st.maxRepeats)settings.maxRepeats=+st.maxRepeats; if(st.active===false)settings.active=false;
      out.triggers.push({kind:'trigger',id,name:key,type,settings,params:cleanParams(t.parameters||{},TRIGGER_SPEC[type]),actions:acts}); }
    // map: try to infer from mapfilename? mission files have none; leave to current.
    return out;
  }catch(err){ console.warn('lua parse failed',err); return null; }
}
let idc=1;
function arr(t){ if(Array.isArray(t))return t; if(t&&typeof t==='object'){ const a=[]; for(let i=1;t[i]!==undefined;i++)a.push(t[i]); return a.length?a:Object.values(t);} return []; }
function cleanParams(pin,spec){ const p={}; for(const f of spec.fields){ if(pin[f.k]!==undefined){ let v=pin[f.k];
  if(f.t==='int'||f.t==='num')v=+v; else if(f.t==='bool')v=!!v; else v=String(v); p[f.k]=v; } } return p; }

/* tiny Lua evaluator: enough for our scenario files (locals + arithmetic + tables) */
function luaEval(src,game){
  // strip block/line comments but KEEP the return table
  src=src.replace(/--\[==\[[\s\S]*?\]==\]/g,'').replace(/--\[\[[\s\S]*?\]\]/g,'').replace(/--[^\n]*/g,'');
  const TKN=tokenize(src);
  let i=0;
  const locals={ Game:{mapSizeX:game.mapSizeX,mapSizeZ:game.mapSizeZ},
    GG:{MissionAPI:{TriggerTypes:TT,ActionTypes:AT}} };
  const peek=()=>TKN[i], next=()=>TKN[i++];
  function expect(v){ const t=next(); if(t.v!==v) throw new Error('expected '+v+' got '+(t&&t.v)); }
  function parsePrimary(){
    let t=peek();
    if(t.t==='num'){ next(); return t.v; }
    if(t.t==='str'){ next(); return t.v; }
    if(t.v==='true'){next();return true;} if(t.v==='false'){next();return false;} if(t.v==='nil'){next();return null;}
    if(t.v==='{'){ return parseTable(); }
    if(t.v==='('){ next(); const e=parseExpr(); expect(')'); return e; }
    if(t.v==='-'){ next(); return -parsePrimary(); }
    if(t.t==='name'){ next(); let val=resolve(t.v);
      // member / index access
      while(peek()&&(peek().v==='.'||peek().v==='[')){ const op=next();
        if(op.v==='.'){ const key=next().v; val=val&&val[key]; }
        else { const k=parseExpr(); expect(']'); val=val&&val[k]; } }
      return val; }
    throw new Error('unexpected token '+JSON.stringify(t));
  }
  function parseMul(){ let v=parsePrimary(); while(peek()&&(peek().v==='*'||peek().v==='/')){ const op=next().v;
    const r=parsePrimary(); v=op==='*'?v*r:v/r; } return v; }
  function parseAdd(){ let v=parseMul(); while(peek()&&(peek().v==='+'||peek().v==='-')){ const op=next().v;
    const r=parseMul(); v=op==='+'?v+r:v-r; } return v; }
  function parseConcat(){ let v=parseAdd(); while(peek()&&peek().v==='..'){ next(); const r=parseAdd(); v=String(v)+String(r); } return v; }
  function parseExpr(){ return parseConcat(); }
  function parseTable(){ expect('{'); const obj={}; let arrIdx=1; let isArr=true;
    while(peek()&&peek().v!=='}'){
      let t=peek();
      if(t.v==='['){ next(); const k=parseExpr(); expect(']'); expect('='); obj[k]=parseExpr(); isArr=false; }
      else if(t.t==='name'&&TKN[i+1]&&TKN[i+1].v==='='){ const k=next().v; expect('='); obj[k]=parseExpr(); isArr=false; }
      else if(t.t==='str'&&TKN[i+1]&&TKN[i+1].v==='='){ const k=next().v; expect('='); obj[k]=parseExpr(); isArr=false; }
      else { obj[arrIdx++]=parseExpr(); }
      if(peek()&&(peek().v===','||peek().v===';')) next();
    }
    expect('}');
    if(isArr&&arrIdx>1){ const a=[]; for(let k=1;k<arrIdx;k++)a.push(obj[k]); return a; }
    return obj;
  }
  function resolve(name){ if(name in locals) return locals[name]; return undefined; }
  function assignList(names){ const vals=[parseExpr()]; while(peek()&&peek().v===','){ next(); vals.push(parseExpr()); }
    names.forEach((nm,k)=>{ locals[nm]=vals[k]; }); }
  // statement loop  (handles `local a,b = x,y` and `a,b = x,y` multiple assignment)
  while(i<TKN.length){ const t=peek();
    if(!t){break;}
    if(t.v==='local'){ next(); const names=[next().v];
      while(peek()&&peek().v===','){ next(); names.push(next().v); }
      if(peek()&&peek().v==='='){ next(); assignList(names); } continue; }
    if(t.v==='return'){ next(); locals.__return=parseExpr(); break; }
    if(t.t==='name'){
      const start=i; const names=[next().v]; let ok=true;
      while(peek()&&peek().v===','){ next(); if(peek()&&peek().t==='name'){ names.push(next().v); } else { ok=false; break; } }
      if(ok&&peek()&&peek().v==='='){ next(); assignList(names); continue; }
      i=start+1; continue;   // not an assignment (call etc.) -> skip
    }
    next();
  }
  return locals;
}
function tokenize(s){ const out=[]; let i=0; const n=s.length;
  const isW=c=>/\s/.test(c), isD=c=>/[0-9]/.test(c), isA=c=>/[A-Za-z_]/.test(c), isAN=c=>/[A-Za-z0-9_]/.test(c);
  while(i<n){ let c=s[i];
    if(isW(c)){ i++; continue; }
    if(c==='['&&s[i+1]==='['){ const e=s.indexOf(']]',i+2); const v=s.slice(i+2,e<0?n:e); out.push({t:'str',v}); i=(e<0?n:e+2); continue; }
    if(c==='"'||c==="'"){ const q=c; let j=i+1,v=''; while(j<n&&s[j]!==q){ if(s[j]==='\\'){v+=s[j+1];j+=2;} else {v+=s[j++];} } out.push({t:'str',v}); i=j+1; continue; }
    if(isD(c)||(c==='.'&&isD(s[i+1]))){ let j=i; while(j<n&&/[0-9.eE+\-xa-fA-F]/.test(s[j])&&!(s[j]==='-'&&!/[eE]/.test(s[j-1]))) j++;
      const str=s.slice(i,j); out.push({t:'num',v:Number(str)}); i=j; continue; }
    if(isA(c)){ let j=i; while(j<n&&isAN(s[j]))j++; out.push({t:'name',v:s.slice(i,j)}); i=j; continue; }
    if(c==='.'&&s[i+1]==='.'){ out.push({t:'op',v:'..'}); i+=2; continue; }
    out.push({t:'op',v:c}); i++;
  }
  return out;
}

/* =========================================================================
 * boot
 * ========================================================================= */
function boot(){
  // Ctrl+Shift+L downloads the log from anywhere (incl. the launch screen)
  window.addEventListener('keydown',e=>{ if(e.ctrlKey&&e.shiftKey&&e.code==='KeyL'){ e.preventDefault(); downloadLog(); } });
  try{ DBG.log('boot start'); initLaunch(); initUnitModal(); bindModals(); DBG.log('boot ok');
    if(location.hash.indexOf('#autotest')===0 && MAPS.length){ chooseMap(MAPS[0]);   // headless self-test
      if(location.hash==='#autotestpick') openUnitPicker({fac:'Armada',building:true}, ()=>{});
      if(location.hash==='#autotestscene'){
        setAiCount(3);
        const b={id:uid(),def:'armmex',x:Math.round(S.map.w*0.3),z:Math.round(S.map.h*0.4),facing:'',role:'ai2'};
        S.buildings.push(b);
        const a=mkAction('UnfreezeTeam'); a.params.team='ai3'; S.actions.push(a);
        buildLists(); select('building',b.id); render(); } }
  }
  catch(err){ DBG.log('BOOT ERROR',(err&&err.stack)||String(err)); (window.__err||console.error)((err&&err.stack)||String(err)); }
}
if(document.readyState==='loading') window.addEventListener('DOMContentLoaded',boot); else boot();
