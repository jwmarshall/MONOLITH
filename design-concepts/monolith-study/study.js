'use strict';
(async () => {
  const V = window.MonolithViews;
  try {
    await V.readySignals();
  } catch (error) {
    const gate = document.getElementById('gate');
    gate.innerHTML = '<div class="threshold-body"><div class="threshold-center"><p class="eyebrow">MONOLITH / Study unavailable</p><h1 id="gate-title" tabindex="-1">Signals could not load.</h1><p class="threshold-intro" role="alert">The local signal artwork is unavailable. The study has not opened, so incomplete signals are not shown. Serve this folder over HTTP and retry.</p><p class="muted" id="signal-load-error"></p><button class="button primary" id="retry-signals">Retry loading study</button><p><a class="text-link" href="../index.html">Return to all ten demos</a></p></div></div>';
    document.getElementById('signal-load-error').textContent = error.message;
    document.getElementById('retry-signals').addEventListener('click', () => location.reload());
    gate.removeAttribute('aria-busy');
    document.getElementById('gate-title').focus({preventScroll:true});
    return;
  }
  document.getElementById('gate').removeAttribute('aria-busy');
  document.getElementById('proof-controls').inert = false;
  const I = window.MonolithIdentity;
  const body = document.body;
  const content = document.getElementById('content');
  const plane = document.getElementById('working-plane');
  const gate = document.getElementById('gate');
  gate.innerHTML = I.threshold({gate:true});
  const enter = document.getElementById('enter');
  const brand = document.getElementById('brand');
  brand.querySelector('svg').outerHTML = I.entranceMark(false, 'unlock-mark');
  const dialog = document.getElementById('study-dialog');
  const dialogBody = document.getElementById('dialog-body');
  const sidebar = document.getElementById('product-sidebar');
  const sidebarContent = document.getElementById('sidebar-content');
  const navigationToggle = document.getElementById('navigation-toggle');
  const viewPicker = document.getElementById('view-picker');
  const statePicker = document.getElementById('state-picker');
  const motion = matchMedia('(prefers-reduced-motion: reduce)');
  let disposeIdentityMotion = () => {};
  let disposeCSS = () => {};
  let cancelIdentityMotion = () => false;
  const ctx = {
    workspaces:[{id:'personal',name:'Personal'},{id:'studio',name:'Studio'}],
    memberships:{personal:['personal'],studio:['studio']}, calendarSelections:{personal:['primary'],studio:['primary']},
    scene:'02',idleMinutes:3,startup:false,state:'ready',path:'/home',query:new URLSearchParams(),
    sceneDraft:null,sceneDirty:false,sceneSaved:{subject:'architecture',setting:'mountains',light:'overcast',palette:'charcoal'},
    sceneRequest:{model:'gemini-nano-banana-2.1',ratio:'16:9',size:'1K'},sceneUnknownAcknowledged:false,
    review:{},disconnected:new Set()
  };
  let mode = 'gate';
  let animations = [];
  let sequence = 0;
  let lastActivity = Date.now();
  let idleTimer;
  let lastFocus;
  let dialogOpener;
  let dialogContext = {};
  let returnResult = null;
  let pendingReturn = '/home';
  let nextWorkspace = 1;
  let sceneSelection = 0;
  const stateLabels = {ready:'Ready',loading:'Loading',empty:'Empty',stale:'Stale',offline:'Offline',reconnect:'Sign-in required','rate-limit':'Rate limited',error:'Failed',partial:'Partial',missing:'Not configured',checking:'Checking locally',unavailable:'Key unavailable','no-selection':'No selection',queued:'Queued',submitting:'Submitting',rendering:'Rendering',paused:'Tracking paused',unknown:'Outcome unknown',cleanup:'Cleanup pending',expired:'Code expired'};
  stateLabels.zero = 'Zero unread / Personal';
  const ownerRoute = () => ['/unlock','/setup','/onboarding'].includes(ctx.path);
  const proofRoute = () => ['/identity','/components','/css','/voice','/review'].includes(ctx.path);
  const announce = text => { document.getElementById('announcement').textContent = ''; requestAnimationFrame(() => {document.getElementById('announcement').textContent=text;}); };
  function mountMarks() {
    document.querySelectorAll('[data-current-mark]').forEach(slot=>{slot.innerHTML=I.inverseMark('', 'sidebar-mark-cutout');});
  }
  const navigationExpanded = () => !sidebarContent.hidden;
  function closeNavigation(restoreFocus=true) {
    if(!navigationExpanded())return;
    sidebarContent.hidden=true;
    plane.dataset.navigation='collapsed';
    navigationToggle.setAttribute('aria-expanded','false');
    navigationToggle.setAttribute('aria-label','Expand sidebar');
    navigationToggle.title='Expand sidebar';
    if(restoreFocus&&mode==='focused'&&!ownerRoute())navigationToggle.focus({preventScroll:true});
    activity();
  }
  function openNavigation() {
    if(navigationExpanded()||mode!=='focused'||ownerRoute()||dialog.open)return;
    clearTimeout(idleTimer);
    sidebarContent.hidden=false;
    plane.dataset.navigation='expanded';
    navigationToggle.setAttribute('aria-expanded','true');
    navigationToggle.setAttribute('aria-label','Collapse sidebar');
    navigationToggle.title='Collapse sidebar';
  }
  function setMode(next) {
    if(next!=='focused')cancelIdentityMotion();
    mode=next;
    body.dataset.mode=next;
    gate.inert=next!=='gate';
    plane.inert=next==='gate'||next==='entering';
    sidebar.inert=next==='gate'||next==='entering';
    navigationToggle.inert=next==='gate'||next==='entering';
    if(next!=='focused') clearTimeout(idleTimer);
    if(next!=='focused')closeNavigation(false);
  }
  function activity() {
    lastActivity=Date.now();
    clearTimeout(idleTimer);
    if(mode==='focused' && !dialog.open && !navigationExpanded() && !ownerRoute()) idleTimer=setTimeout(showScenery,ctx.idleMinutes*60000);
  }
  function showScenery() {
    if(mode!=='focused' || dialog.open || navigationExpanded() || ownerRoute()) return;
    lastFocus=document.activeElement;
    setMode('scenery');
    if (lastFocus?.closest('#product-sidebar,#navigation-toggle')) lastFocus.blur();
  }
  function wake() {
    if(mode!=='scenery') return;
    const needsReturn = document.activeElement === document.body;
    setMode('focused');
    if(needsReturn && lastFocus?.isConnected) lastFocus.focus({preventScroll:true});
    activity();
  }
  function stopAnimations() { animations.forEach(animation=>animation.cancel()); animations=[]; }
  function animate(element,frames,options) {
    const animation=element.animate(frames,{...options,fill:'both'});
    animations.push(animation);
    return animation.finished.catch(()=>{});
  }
  function finishEntrance() {
    const focus=document.activeElement;
    const handoff=!focus?.isConnected||focus===body||focus===document.documentElement||gate.contains(focus)||brand.contains(focus);
    sequence++;
    stopAnimations();
    setMode('focused');
    if(handoff)document.getElementById('view-title')?.focus({preventScroll:true});
    activity();
  }
  async function entrance() {
    if(mode!=='gate') return;
    setMode('entering');
    enter.blur();
    const token=++sequence;
    if(motion.matches) return finishEntrance();
    await I.playEntrance(brand, animate, () => token===sequence);
    if(token===sequence) finishEntrance();
  }
  function mountIdentityMotion() {
    const stage = document.getElementById('identity-motion-stage');
    if (!stage) return () => {};
    const treatment = document.getElementById('motion-treatment');
    const polarity = document.getElementById('motion-polarity');
    const play = document.getElementById('motion-play');
    const stop = document.getElementById('motion-stop');
    const status = document.getElementById('motion-status');
    let running = false;
    let version = 0;
    let proofAnimations = [];
    const staticMark = () => {
      stage.classList.toggle('identity-logo-proof--dark', polarity.value==='dark');
      stage.classList.toggle('identity-logo-proof--outline', treatment.value==='outline');
      stage.classList.toggle('identity-logo-proof--light', polarity.value==='light');
      stage.setAttribute('aria-label', `MONOLITH ${treatment.value} unlock animation, ${polarity.selectedOptions[0].text.toLowerCase()}`);
      stage.innerHTML = `<div class="identity-motion-lockup brand-lockup">${treatment.value==='solid'?I.inverseMark():I.mark()}<span class="brand-wordmark" aria-hidden="true">MONOLITH</span></div>`;
    };
    function reset(message) {
      version++;
      running = false;
      proofAnimations.forEach(animation=>animation.cancel());
      proofAnimations = [];
      stage.dataset.state = 'ready';
      stop.disabled = true;
      staticMark();
      status.textContent = motion.matches ? 'Reduced motion: completed identity shown. Animation is skipped.' : message;
    }
    cancelIdentityMotion = () => {
      if (!running) return false;
      const returnFocus = document.activeElement===stop;
      reset('Stopped. Completed identity restored.');
      if (returnFocus) play.focus({preventScroll:true});
      return true;
    };
    play.addEventListener('click', async () => {
      reset('Playing the unlock animation.');
      if (motion.matches) return;
      const token = version;
      running = true;
      stop.disabled = false;
      stage.dataset.state = 'playing';
      stage.innerHTML = `<div class="identity-motion-lockup brand-lockup">${I.entranceMark(treatment.value==='solid', 'identity-motion-solid')}<span class="wordmark brand-wordmark" aria-hidden="true">${[...'MONOLITH'].map(letter=>`<span>${letter}</span>`).join('')}</span></div>`;
      const animateProof = (element, frames, options) => {
        const animation = element.animate(frames,{...options,fill:'both'});
        proofAnimations.push(animation);
        return animation.finished.catch(()=>{});
      };
      await I.playEntrance(stage.firstElementChild, animateProof, () => token===version);
      if (token===version) {
        const returnFocus = document.activeElement===stop;
        reset('Replay complete. Completed identity restored.');
        if (returnFocus) play.focus({preventScroll:true});
      }
    });
    stop.addEventListener('click', ()=>cancelIdentityMotion());
    const change = () => reset('Ready. Selection changed; completed identity shown.');
    treatment.addEventListener('change', change);
    polarity.addEventListener('change', change);
    motion.addEventListener('change', change);
    window.addEventListener('beforeprint', change);
    document.getElementById('motion-jump').addEventListener('click', () => {
      stage.closest('section').scrollIntoView({block:'start'});
      play.focus({preventScroll:true});
    });
    reset('Ready. Choose a treatment and replay; nothing plays automatically.');
    return () => {
      reset('');
      motion.removeEventListener('change', change);
      window.removeEventListener('beforeprint', change);
      cancelIdentityMotion = () => false;
    };
  }
  function replay() {
    sequence++;
    stopAnimations();
    if(dialog.open) dialog.close();
    setMode('gate');
    window.scrollTo(0,0);
    enter.focus({preventScroll:true});
  }
  function states(path) {
    if(path==='/home') return ['ready','loading','zero','empty','stale','offline','reconnect','error'];
    if(path.includes('/threads/')) return ['ready','loading','stale','error'];
    if(path.endsWith('/mail')) return ['ready','loading','empty','stale','offline','reconnect','rate-limit','error'];
    if(path.includes('/github/')) return ['ready','loading','empty','stale','partial','error'];
    if(path==='/scenes') return ['ready','missing','checking','unavailable','queued','submitting','rendering','paused','unknown','error','cleanup'];
    if(path==='/connections/calendar') return ['ready','missing','checking','reconnect','error','no-selection','partial'];
    if(path==='/connections/gmail'||path==='/connections/github') return ['ready','missing','checking','reconnect','error'];
    if(path.startsWith('/connections/')) return ['ready','missing','checking','error'];
    if(path==='/setup') return ['ready','error','expired'];
    if(path==='/unlock'||path==='/onboarding') return ['ready','error'];
    if(path.startsWith('/workspaces')&&!path.endsWith('/integrations')) return ['ready','empty','loading','stale','partial','error'];
    return ['ready'];
  }
  function parseHash() {
    const raw=location.hash.startsWith('#/')?location.hash.slice(1):'/home';
    const index=raw.indexOf('?');
    return {path:index<0?raw:raw.slice(0,index),query:new URLSearchParams(index<0?'':raw.slice(index+1))};
  }
  function navigate(path) {
    if(location.hash===`#${path}`) render();
    else location.hash=path;
  }
  function changeState(state) {
    const query=new URLSearchParams(ctx.query);
    if(state==='ready') query.delete('state'); else query.set('state',state);
    navigate(`${ctx.path}${query.size?'?'+query:''}`);
  }
  function renderProductView() {
    const p=ctx.path;
    const parts=p.split('/').filter(Boolean);
    if(p==='/home') return V.home(ctx);
    if(p==='/workspaces') return V.workspaces(ctx);
    if(parts[0]==='workspaces' && parts[2]==='integrations') return V.integrations(ctx,parts[1]);
    if(parts[0]==='workspaces' && parts[2]==='github') return V.activity(ctx,parts[1],parts[3]);
    if(parts[0]==='workspaces' && parts[2]==='accounts') return parts[5]==='threads'?V.thread(ctx,parts[3],parts[6],parts[1]):V.inbox(ctx,parts[3],parts[1]);
    if(parts[0]==='workspaces' && parts.length===2) return V.workspace(ctx,parts[1]);
    if(parts[0]==='accounts') return parts[3]==='threads'?V.thread(ctx,parts[1],parts[4]):V.inbox(ctx,parts[1]);
    if(p==='/connections') return V.connections(ctx);
    if(parts[0]==='connections') return V.provider(ctx,parts[1]);
    if(p==='/scenes') return V.scenes(ctx);
    if(p==='/settings') return V.settings(ctx);
    if(p==='/unlock') return V.unlock(ctx);
    if(p==='/setup') return V.setup(ctx);
    if(p==='/onboarding') return V.onboarding(ctx);
    if(p==='/identity') return I.identity();
    if(p==='/components') return window.MonolithComponents();
    if(p==='/css') return window.MonolithCSS.view();
    if(p==='/voice') return window.MonolithVoice();
    if(p==='/review') return V.review(ctx);
    return V.unavailable();
  }
  function captureDraft() {
    if(ctx.path==='/scenes') {
      const form=content.querySelector('[data-form="scene-direction"]');
      if(form) ctx.sceneDraft=Object.fromEntries(new FormData(form));
    }
    if(ctx.path==='/review') content.querySelectorAll('input,textarea').forEach(input=>{ctx.review[input.id||input.name]=input.type==='checkbox'?input.checked:input.value;});
  }
  function restoreDraft() {
    if(ctx.path==='/scenes' && ctx.sceneDraft) {
      for(const [name,value] of Object.entries(ctx.sceneDraft)) {const field=content.querySelector(`[name="${name}"]`);if(field) field.value=value;}
      updatePrompt();
    }
    if(ctx.path==='/review') content.querySelectorAll('input,textarea').forEach(input=>{const value=ctx.review[input.id||input.name];if(value!==undefined){if(input.type==='checkbox')input.checked=value;else input.value=value;}});
  }
  function render() {
    captureDraft();
    disposeIdentityMotion();
    disposeCSS();
    const parsed=parseHash();
    ctx.path=parsed.path;
    ctx.query=parsed.query;
    const available=states(ctx.path);
    ctx.state=available.includes(ctx.query.get('state'))?ctx.query.get('state'):'ready';
    closeNavigation(false);
    if(dialog.open) dialog.close();
    body.classList.toggle('owner-view',ownerRoute());
    content.innerHTML=renderProductView();
    disposeIdentityMotion = mountIdentityMotion();
    disposeCSS = window.MonolithCSS.mount(content);
    mountMarks();
    if(!content.querySelector('#view-title')) {
      const heading=content.querySelector('h1,h2');
      if(heading) {heading.id='view-title';heading.tabIndex=-1;}
    }
    restoreDraft();
    const headingText=content.querySelector('#view-title');
    const title=headingText?[...headingText.childNodes].map(node=>node.nodeName==='BR'?' ':node.textContent).join('').replace(/\s+/g,' ').trim():'Study';
    document.title=`${title} / MONOLITH / design study`;
    const selectedView=V.viewList.find(([path])=>path===ctx.path);
    const fallback=ctx.path.includes('/threads/')?'/accounts/personal/mail/threads/weekend':ctx.path.includes('/mail')?'/accounts/personal/mail':ctx.path.startsWith('/workspaces/')?'/workspaces/studio':null;
    viewPicker.value=selectedView?ctx.path:fallback||'/review';
    statePicker.innerHTML=available.map(state=>`<option value="${state}">${stateLabels[state]}</option>`).join('');
    statePicker.value=ctx.state;
    statePicker.disabled=available.length===1;
    document.getElementById('route-caption').textContent=`MONOLITH / ${ctx.path} / ${ctx.state.toUpperCase()}`;
    document.querySelectorAll('#product-nav a').forEach(anchor=>{
      const path=anchor.hash.slice(1);
      const active=path==='/home'?ctx.path==='/home'||ctx.path.startsWith('/accounts/'):ctx.path===path||ctx.path.startsWith(path+'/');
      if(active) anchor.setAttribute('aria-current','page'); else anchor.removeAttribute('aria-current');
    });
    document.querySelectorAll('[data-proof-link]').forEach(anchor=>{
      const active=anchor.dataset.proofLink==='views'?!proofRoute():ctx.path===`/${anchor.dataset.proofLink}`;
      if(active) anchor.setAttribute('aria-current','page');else anchor.removeAttribute('aria-current');
    });
    window.scrollTo(0,0);
    if(mode==='scenery') setMode('focused');
    if(mode==='focused') {
      if(returnResult && ctx.path===returnResult.path) {
        const result=document.getElementById(returnResult.id);
        if(result) {result.focus({preventScroll:true});window.scrollTo(0,returnResult.scroll);}
        else content.querySelector('#view-title')?.focus({preventScroll:true});
        returnResult=null;
      } else content.querySelector('#view-title')?.focus({preventScroll:true});
    }
    activity();
  }
  function dialogFrame(label,title,copy,bodyHtml='',actions='') {
    return `<p class="eyebrow">${label}</p><h2 id="dialog-title">${title}</h2>${copy?`<p>${copy}</p>`:''}${bodyHtml}<div class="dialog-actions"><button class="button" data-action="close-dialog">Cancel</button>${actions}</div>`;
  }
  function openDialog(button) {
    const name=button.dataset.dialog;
    dialogContext={name,workspace:button.dataset.workspace,account:button.dataset.account,origin:ctx.path};
    const account=V.accounts[dialogContext.account||'personal'];
    let html='';
    if(name==='workspace'||name==='rename') {
      const current=ctx.workspaces.find(workspace=>workspace.id===dialogContext.workspace);
      html=`<form data-form="workspace" novalidate><p class="eyebrow">${name==='rename'?'Rename':'New'} workspace / local study</p><h2 id="dialog-title">${name==='rename'?'A clearer name.':'Name a workspace.'}</h2><div class="field"><label for="workspace-name">Workspace name</label><input id="workspace-name" name="name" maxlength="60" autocomplete="off" value="${V.escape(current?.name||'')}" aria-describedby="workspace-help workspace-error"><small id="workspace-help">An area of life. Connections can be added later.</small><span id="workspace-error" class="error" role="alert"></span></div><div class="dialog-actions"><button class="button" type="button" data-action="close-dialog">Cancel</button><button class="button primary" type="submit">${name==='rename'?'Save name':'Create workspace'}</button></div></form>`;
    } else if(name==='detach') {
      const workspace=ctx.workspaces.find(row=>row.id===dialogContext.workspace);
      html=dialogFrame('Workspace membership','Remove from this workspace?',`${account.name} · ${account.email}<br>Workspace: ${V.escape(workspace?.name||'')}`,'<p>The connection remains available in other workspaces and Connections. Google access is not revoked. This changes only the HTML study.</p>','<button class="button danger" data-action="confirm-detach">Remove from workspace</button>');
    } else if(name==='disconnect') {
      html=dialogFrame('Global connection / sample confirmation','Disconnect everywhere?',`${account.name} · ${account.email}`,'<div class="notice" data-tone="error"><strong>Not the same as workspace removal.</strong><p>In production, this removes access from every workspace using this connection. Gmail and Calendar share the Google credential. No real connection exists in this study.</p></div>','<button class="button danger" data-action="confirm-disconnect">Preview disconnected state</button>');
    } else if(name==='generation') {
      if(ctx.sceneDirty) {announce('Save the scene direction before reviewing a request.');document.getElementById('direction-status')?.scrollIntoView({block:'center'});return;}
      const prompt=document.getElementById('scene-prompt')?.textContent||'';
      const request = {...ctx.sceneRequest, prompt};
      dialogContext.request = request;
      html=`<form data-form="generation"><p class="eyebrow">Single request / cost confirmation</p><h2 id="dialog-title">Review this scene request.</h2><p>${V.escape(request.model)} · ${V.escape(request.ratio)} · ${V.escape(request.size)}</p><details open><summary>Exact reviewed prompt</summary><p>${V.escape(request.prompt)}</p></details><div class="notice" data-tone="warning"><strong>Google may charge for this request.</strong><p>A failed or unknown result can still incur charges. Paid submissions are one-shot; no automatic retry. Google background processing stores the interaction remotely; MONOLITH requests deletion of the known result after local publication. Cleanup can fail and is reported separately.</p></div><label><input type="checkbox" name="cost" required>I understand the possible charge and provider storage.</label><p class="muted">This study does not contact Google. Confirming previews only the accepted state.</p><div class="dialog-actions"><button type="button" class="button" data-action="close-dialog">Cancel</button><button type="submit" class="button primary">Confirm sample request</button></div></form>`;
    } else if(name==='unknown-scene') {
      html=`<form data-form="unknown-scene"><p class="eyebrow">Unknown outcome / no blind retry</p><h2 id="dialog-title">Review possible charge and overlap.</h2><p>The previous request may have been accepted and charged. There is no known provider ID to retrieve safely. A new request could overlap and incur another charge.</p><label><input type="checkbox" name="overlap" required>I acknowledge a possible previous charge and overlapping request.</label><p>This acknowledgment does not submit another request. A fresh cost confirmation is still required.</p><div class="dialog-actions"><button class="button" type="button" data-action="close-dialog">Cancel</button><button class="button primary" type="submit">Acknowledge in study</button></div></form>`;
    } else if(name==='lock') {
      html=dialogFrame('Owner security / illustrative only','Lock MONOLITH?', 'In the product, Lock revokes owner sessions, stops protected work and closes encrypted storage and the dedicated keychain. Escape and scenery mode do none of these.', '<p>The HTML study has no vault or session. This action opens the locked-screen design.</p>','<button class="button primary" data-action="lock-demo">Preview locked screen</button>');
    } else if(name.startsWith('event-')) {
      const studio=name==='event-studio';
      html=dialogFrame('Calendar / read-only sample',studio?'Material review':'Walk by the water',studio?'11:00–11:45 · Friday, 6 November 2026':'17:30–18:15 · Friday, 6 November 2026',`<p>Calendar: ${studio?'Studio shared':'Personal'}<br>Account: ${studio?V.accounts.studio.email:V.accounts.personal.email}<br>Timezone: Europe/London (GMT)</p><p>No descriptions, attendees, remote content or calendar writes are shown.</p>`,'');
    } else if(name.startsWith('credentials-')) {
      const provider=name.slice('credentials-'.length);
      const fields=provider==='google'?['Desktop client ID','Client secret']:provider==='github'?['Client ID','Client secret','App slug']:['Gemini API key'];
      html=dialogFrame('Protected credential form / non-editable specimen',provider==='gemini'?'Store a Gemini key.':provider==='github'?'Store GitHub App settings.':'Store Google client settings.','Credential saves are local-only. They do not verify the provider or grant account access.',fields.map(field=>`<div class="field"><span>${field}</span><div class="masked-field" aria-label="${field}, static specimen">••••••••••••</div></div>`).join('')+'<p>No editable secret fields are provided in this study. Production uses an early protected POST boundary and never returns secret values.</p>','<button class="button primary" data-action="credential-proof">Mark form reviewed</button>');
    } else if(name==='connect-google') {
      html=`<form data-form="consent"><p class="eyebrow">Gmail / account authorization</p><h2 id="dialog-title">Choose the receiving workspace.</h2><p>Google sign-in is a separate consent step. Reconnecting this account does not merge inboxes or change another account.</p><div class="field"><label for="receiving-workspace">Receiving workspace</label><select id="receiving-workspace" name="workspace">${ctx.workspaces.map(workspace=>`<option value="${V.escape(workspace.id)}">${V.escape(workspace.name)}</option>`).join('')}</select></div><p class="muted">Read-only Gmail. No mailbox writes. In production this continues to Google; the study stays local.</p><div class="dialog-actions"><button type="button" class="button" data-action="close-dialog">Cancel</button><button type="submit" class="button primary">Preview consent handoff</button></div></form>`;
    } else if(name==='calendar-consent') {
      html=dialogFrame('Calendar / optional permission','Enable read-only Calendar?', 'Account: mara@vale.example', '<p>Gmail access alone does not grant Calendar access. After consent, choose personal or shared calendars. Today follows the browser’s local day.</p><p>This study previews the calendar picker without authorizing or contacting Google.</p>','<button class="button primary" data-action="calendar-proof">Preview selected calendars</button>');
    } else if(name==='keychain') {
      html=dialogFrame('Local diagnostic / fictional observation','Credential readable locally.',`${account.email} · observed 09:41 GMT`,'<p>This checks the dedicated Keychain item, not Google. Readability does not verify access, refresh mail, change grants or clear stale provider health.</p><p>No Keychain is accessed by this HTML study.</p>','<button class="button primary" data-action="close-dialog">Done</button>');
    } else if(name==='remove-key') {
      html=dialogFrame('Gemini / local credential','Remove the API key?', 'Saved scenes and permanent attempt history remain. An already authorized request may still finish or incur a charge.','<p>Study only: no real credential will be deleted.</p>','<button class="button danger" data-action="remove-key-proof">Preview missing-key state</button>');
    } else if(name==='github-signin') {
      html=dialogFrame('GitHub / account authorization','Start a fresh sign-in?', 'Authorizing an account is separate from choosing installation repositories.','<p>The production handoff uses single-use state and PKCE. The study opens no external authorization page.</p>','<button class="button primary" data-action="github-proof">Preview authorized state</button>');
    } else if(name==='github-repositories') {
      html=dialogFrame('GitHub / installation selection','Choose repository access.', 'Northline installation · read-only metadata', '<p>Selected in this sample: northline/site and northline/design-system.</p><p>Production installation access is selected on GitHub. Workspace subsets filter its bounded snapshot; they do not change installation permission.</p>','<button class="button primary" data-action="close-dialog">Done</button>');
    } else if(name==='github-disconnect') {
      html=dialogFrame('GitHub / global authorization','Disconnect GitHub account?', 'All workspace readouts using this authorization lose access. This does not change repositories or write to GitHub.','<p>Study only: no real authorization is revoked.</p>','<button class="button danger" data-action="github-disconnect-proof">Preview setup state</button>');
    } else {
      html=dialogFrame('Component specimen / native modal','A focused decision.', 'The rest of the page is inert while this dialog is open. Escape closes only the dialog and restores the opener.', '<div class="field"><label for="example-note">Sample note</label><input id="example-note" value="A clear next step" autocomplete="off"></div>','<button class="button primary" data-action="example-confirm">Confirm sample</button>');
    }
    dialogBody.innerHTML=html;
    dialogOpener=sidebar.contains(button)?navigationToggle:button;
    closeNavigation(false);
    clearTimeout(idleTimer);
    dialog.showModal();
    const first=dialog.querySelector('input:not([type=checkbox]),select,button');
    first?.focus();
  }
  function updatePrompt() {
    const form=content.querySelector('[data-form="scene-direction"]');
    if(!form) return;
    const data=Object.fromEntries(new FormData(form));
    const subject=data.subject==='landscape'?'an expansive landscape':'minimalist architecture';
    document.getElementById('scene-prompt').textContent=`Create quiet cinematic scenery with ${subject} in ${data.setting}, soft ${data.light} light and a ${data.palette} palette. Use negative space and a calm center. No people, text, logos or interface elements.`;
    const status=document.getElementById('direction-status');
    if(status) status.textContent=ctx.sceneDirty?' Unsaved direction':' Saved default';
    const generation=content.querySelector('[data-dialog="generation"]');
    if(generation) generation.disabled=ctx.sceneDirty||['queued','submitting','rendering','paused','unknown'].includes(ctx.state);
  }
  function closeAndAnnounce(text) {dialog.close();announce(text);}
  function act(action,button) {
    if(action==='close-dialog') dialog.close();
    else if(action==='replay') replay();
    else if(action==='download-logo') {
      const svg=`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 104 104" fill="none" role="img" aria-label="MONOLITH: ${V.escape(I.logo.name)}"><path d="${I.logo.path}" stroke="currentColor" stroke-width="2.4" stroke-linecap="square" stroke-linejoin="miter"/></svg>\n`;
      const url=URL.createObjectURL(new Blob([svg],{type:'image/svg+xml'}));
      const anchor=document.createElement('a');anchor.href=url;anchor.download='monolith-mark-outline.svg';anchor.click();
      setTimeout(()=>URL.revokeObjectURL(url),1000);announce('Downloaded the MONOLITH outline mark SVG.');
    }
    else if(action==='scenery') showScenery();
    else if(action==='refresh') {
      announce('Sample refresh reviewed. No provider call was made. The selected state and original observation time are unchanged.');
      const target=content.querySelector('.notice');
      if(target) {target.dataset.refreshed='true';const p=target.querySelector('p');if(p)p.textContent+=' Sample refresh reviewed; no live request was made.';button.disabled=true;}
    } else if(action==='confirm-detach') {
      ctx.memberships[dialogContext.workspace]=(ctx.memberships[dialogContext.workspace]||[]).filter(id=>id!==dialogContext.account);
      dialog.close();render();announce('Removed from this sample workspace. The global connection is unchanged.');
    } else if(action==='confirm-disconnect') {
      ctx.disconnected.add(dialogContext.account||'personal');
      dialog.close();render();announce('Sample account disconnected everywhere. The other account is unchanged. Reload resets the study.');
    } else if(action==='lock-demo') {
      pendingReturn=ctx.path+(ctx.query.size?'?'+ctx.query:'');dialog.close();navigate('/unlock');
    } else if(action==='unlock-demo') {
      navigate(pendingReturn);replay();entrance();
    } else if(action==='pair-demo') {
      document.getElementById('loss-acknowledgment')?.focus();announce('Paired step preview. No terminal code was checked. Review the password-loss acknowledgment.');
    } else if(action==='setup-demo') navigate('/onboarding');
    else if(action==='finish-onboarding') {navigate('/home');announce('Setup preview complete. No real owner or integration was created.');}
    else if(action==='credential-proof') closeAndAnnounce('Credential form reviewed. No credentials were accepted, stored or checked.');
    else if(action==='calendar-proof') {dialog.close();navigate(dialogContext.origin==='/onboarding'?'/onboarding?step=calendar':'/connections/calendar');announce('Calendar consent preview returned to its initiating picker. No access was granted.');}
    else if(action==='remove-key-proof') {dialog.close();navigate('/connections/gemini?state=missing');}
    else if(action==='github-proof') {dialog.close();navigate('/connections/github');}
    else if(action==='github-disconnect-proof') {dialog.close();navigate('/connections/github?state=missing');}
    else if(action==='example-confirm') closeAndAnnounce('Sample confirmed. Focus returned to the dialog opener.');
    else if(action==='use-scene') {
      if(!['01','02','03'].includes(button.dataset.scene))return;
      const scene=button.dataset.scene;
      const request=++sceneSelection;
      const image=new Image();
      image.onload=()=>{
        if(request!==sceneSelection)return;
        ctx.scene=scene;
        document.getElementById('scenery').src=image.src;
        const preview=content.querySelector('.scene-preview');
        if(preview)preview.src=image.src;
        content.querySelectorAll('[data-action="use-scene"]').forEach(control=>{
          control.disabled=control.dataset.scene===scene;
          control.textContent=control.disabled?'Active scene':'Use scene';
        });
        announce('Local sample scene selected. Current forms and dialogs are unchanged.');
      };
      image.onerror=()=>{if(request===sceneSelection)announce('The sample image could not be loaded. The current scene is unchanged.');};
      image.src=`../backgrounds/${scene}.jpg`;
    } else if(action==='cleanup') {button.disabled=true;button.textContent='Cleanup retry reviewed';announce('Sample cleanup retry reviewed. No generation or remote deletion was requested.');}
    else if(action==='resume-retrieval') {changeState('rendering');announce('Known-request tracking preview resumed. No new generation was submitted.');}
    else if(action==='discard-direction') {
      ctx.sceneDraft={...ctx.sceneSaved};ctx.sceneDirty=false;restoreDraft();announce('Unsaved direction discarded. No generation was requested.');
    }
    else if(action==='print') window.print();
    else if(action==='download-sample') {
      const blob=new Blob([V.sampleAttachment],{type:'text/plain'});
      const url=URL.createObjectURL(blob);const anchor=document.createElement('a');anchor.href=url;anchor.download='monolith-sample-material-notes.txt';anchor.click();setTimeout(()=>URL.revokeObjectURL(url),1000);announce('Downloaded a local fictional attachment.');
    }
  }
  document.addEventListener('click',event=>{
    const target=event.target.closest('button,a');
    if(!target) return;
    if(target.matches('.skip-link')) {
      event.preventDefault();
      if(mode==='gate') enter.focus();
      else content.querySelector('#view-title')?.focus();
      return;
    }
    if(target.matches('.mail-row')) returnResult={path:ctx.path,id:target.id,scroll:window.scrollY};
    if(target.tagName==='A'&&target.closest('#product-sidebar')) {
      closeNavigation(false);
      if(target.hash===location.hash)content.querySelector('#view-title')?.focus({preventScroll:true});
    }
    if(target.dataset.dialog) openDialog(target);
    else if(target.dataset.action) act(target.dataset.action,target);
    else if(target.tagName==='A'&&target.hash.startsWith('#/')&&(mode==='gate'||mode==='entering')) finishEntrance();
  });
  document.addEventListener('submit',event=>{
    const form=event.target;
    if(!(form instanceof HTMLFormElement)||!form.dataset.form)return;
    event.preventDefault();
    const data=new FormData(form);
    const type=form.dataset.form;
    if(type==='workspace') {
      const name=String(data.get('name')||'').trim();
      if(!name) {const field=form.querySelector('input');field.setAttribute('aria-invalid','true');document.getElementById('workspace-error').textContent='Enter a workspace name.';field.focus();return;}
      if(dialogContext.name==='rename') {
        const workspace=ctx.workspaces.find(row=>row.id===dialogContext.workspace);if(workspace)workspace.name=name;
      } else {const id=`study-${nextWorkspace++}`;ctx.workspaces.push({id,name});ctx.memberships[id]=[];}
      dialog.close();if(ctx.state==='empty')changeState('ready');else render();announce('Workspace saved in this study only.');
    } else if(type==='attach') {
      ctx.memberships[form.dataset.workspace]=data.getAll('account').filter(id=>V.accounts[id]);
      navigate(`/workspaces/${form.dataset.workspace}`);announce('Sample workspace selection saved. Global credentials are unchanged.');
    } else if(type==='search') {
      const query=String(data.get('q')||'').trim();navigate(form.dataset.base.slice(1)+(query?'?q='+encodeURIComponent(query):''));
    } else if(type==='calendar'||type==='onboarding-calendar') {
      if(type==='onboarding-calendar')navigate('/onboarding?step=review');
      else ctx.calendarSelections[form.dataset.account]=data.getAll('calendar');
      announce(data.getAll('calendar').length?'Sample calendar selection reviewed. No Google read or consent occurred.':'No calendars selected. This is not an empty agenda observation.');
    } else if(type==='scene-direction') {
      ctx.sceneDraft=Object.fromEntries(data);ctx.sceneSaved={...ctx.sceneDraft};ctx.sceneDirty=false;updatePrompt();announce('Sample direction saved. No generation, credential probe or startup change occurred.');
    } else if(type==='generation') {
      if(!data.get('cost'))return;
      dialog.close();changeState('rendering');announce('Accepted request state previewed. No paid generation was submitted.');
    } else if(type==='unknown-scene') {
      if(!data.get('overlap'))return;
      ctx.sceneUnknownAcknowledged=true;dialog.close();changeState('ready');announce('Unknown-outcome acknowledgment reviewed. Any new request still requires its own cost confirmation. No generation was submitted.');
    } else if(type==='consent') {
      if(dialogContext.account)ctx.disconnected.delete(dialogContext.account);
      closeAndAnnounce('Consent handoff reviewed. No Google authorization occurred. Sample local connection retained.');
      if(dialogContext.origin==='/onboarding')navigate('/onboarding?step=calendar');else render();
    } else if(type==='idle') {
      ctx.idleMinutes=Number(data.get('minutes'));activity();announce(`Study scenery delay set to ${ctx.idleMinutes} minutes. This is visual, not Lock.`);
    } else if(type==='startup') {
      ctx.startup=data.has('startup');announce('Startup choice changed in memory only. No generation or production preference change occurred.');
    } else if(type==='onboarding-workspace') {
      const name=String(data.get('name')||'').trim();if(!name)return;
      if(ctx.workspaces[0])ctx.workspaces[0].name=name;else{ctx.workspaces.push({id:'personal',name});ctx.memberships.personal=[];}
      navigate('/onboarding?step=google');
    } else if(type==='specimen') announce('Component form submitted locally. No data was stored or sent.');
  });
  document.addEventListener('input',event=>{
    if(event.target.closest('[data-form="scene-direction"]')) {ctx.sceneDirty=true;updatePrompt();}
    if(event.target.id==='loss-acknowledgment')document.getElementById('setup-continue').disabled=!event.target.checked;
  });
  document.addEventListener('change',event=>{
    if(event.target.dataset.request)ctx.sceneRequest[event.target.dataset.request]=event.target.value;
  });
  dialog.addEventListener('close',()=>{
    if(mode==='focused'&&dialogOpener?.isConnected) {
      const fromNavigation=dialogOpener===navigationToggle||sidebar.contains(dialogOpener);
      const target=fromNavigation
        ? ownerRoute()?content.querySelector('#view-title'):navigationToggle
        : dialogOpener;
      target?.focus({preventScroll:true});
    }
    dialogOpener=null;activity();
  });
  document.addEventListener('keydown',event=>{
    if(dialog.open)return;
    if(event.key==='Escape'&&cancelIdentityMotion()) {
      event.preventDefault();return;
    }
    if(event.key==='Escape'&&navigationExpanded()) {
      event.preventDefault();closeNavigation();return;
    }
    if(event.key==='Escape') {
      if(mode==='entering')replay();else if(mode==='focused')showScenery();return;
    }
    if(mode==='scenery'&&!event.metaKey&&!event.ctrlKey&&!event.altKey&&!['Shift','Control','Alt','Meta'].includes(event.key))wake();
    activity();
  });
  document.addEventListener('pointerdown',()=>{if(mode==='scenery')wake();activity();},{passive:true});
  ['wheel','touchmove','scroll'].forEach(type=>document.addEventListener(type,activity,{passive:true}));
  document.addEventListener('visibilitychange',()=>{if(!document.hidden&&mode==='focused'&&Date.now()-lastActivity>=ctx.idleMinutes*60000)showScenery();});
  motion.addEventListener('change',()=>{if(motion.matches&&mode==='entering')finishEntrance();});
  navigationToggle.addEventListener('click',()=>{
    if(navigationExpanded())closeNavigation();else openNavigation();
  });
  enter.addEventListener('click',entrance);
  viewPicker.innerHTML=V.viewList.map(([path,name])=>`<option value="${path}">${name}</option>`).join('');
  viewPicker.addEventListener('change',()=>{finishEntrance();navigate(viewPicker.value);});
  statePicker.addEventListener('change',()=>{finishEntrance();changeState(statePicker.value);});
  window.addEventListener('hashchange',render);
  const directProof = new URLSearchParams(location.search).get('proof')==='1';
  render();
  if(directProof||ownerRoute()||proofRoute())setMode('focused');else setMode('gate');
  if(directProof)document.querySelector('.proof-fact').textContent='DIRECT PROOF MODE / ENTRANCE SKIPPED · FICTIONAL DATA';
  activity();
})();
