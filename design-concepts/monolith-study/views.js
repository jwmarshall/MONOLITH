'use strict';
(() => {
  const escape = value => String(value).replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));
  const signalStates = ['healthy','loading','unknown','waiting','disconnected','attention'];
  const signalBase = new URL('signals/', document.currentScript.src);
  let signalTemplates;
  let signalReadiness;
  function readySignals() {
    if (!signalReadiness) signalReadiness = Promise.all(signalStates.map(async state => {
      const response = await fetch(new URL(`${state}.svg`, signalBase));
      if (!response.ok) throw new Error(`Could not load the ${state} signal (${response.status}).`);
      const source = new DOMParser().parseFromString(await response.text(), 'image/svg+xml');
      const svg = source.documentElement;
      if (source.querySelector('parsererror') || svg.localName !== 'svg' || svg.namespaceURI !== 'http://www.w3.org/2000/svg') {
        throw new Error(`The ${state} signal is not a valid SVG.`);
      }
      const rules = [...svg.querySelectorAll('style')].map(style => style.textContent).join('\n');
      svg.querySelectorAll('title, desc, style').forEach(node => node.remove());
      svg.removeAttribute('id');
      svg.querySelectorAll('[id]').forEach(node => node.removeAttribute('id'));
      ['width','height','role','aria-labelledby','aria-describedby'].forEach(attribute => svg.removeAttribute(attribute));
      svg.classList.add('signal');
      svg.setAttribute('data-state', state);
      svg.setAttribute('aria-hidden', 'true');
      svg.setAttribute('focusable', 'false');
      return {state, rules, markup:svg.outerHTML};
    })).then(sources => {
      const styles = document.createElement('style');
      styles.dataset.monolithSignals = '';
      styles.textContent = sources.map(source => source.rules).join('\n');
      document.head.append(styles);
      signalTemplates = Object.fromEntries(sources.map(source => [source.state, source.markup]));
    });
    return signalReadiness;
  }
  const signal = (state = 'healthy') => {
    if (!signalTemplates) throw new Error('Await MonolithViews.readySignals() before rendering signals.');
    return signalTemplates[signalStates.includes(state) ? state : 'unknown'];
  };
  const badge = (text, tone = 'muted', state = 'healthy') => `<span class="badge" data-tone="${tone}">${signal(state)}${text}</span>`;
  const link = (href, text, className = 'text-link') => `<a class="${className}" href="${href}">${text}</a>`;
  const heading = (number, title, description = '', actions = '') => `<header class="view-head"><div><p class="eyebrow">${number}</p><h1 id="view-title" tabindex="-1">${title.endsWith('.') ? title : `${title}.`}</h1>${description ? `<p class="lede">${description}</p>` : ''}</div>${actions}</header>`;
  const subviewHeading = (number, title, backLink, description = '', actions = '') => `<header class="subview-head"><div class="subview-heading-row"><p class="eyebrow">${number}</p>${backLink}</div><div class="view-head"><div><h1 id="view-title" tabindex="-1">${title.endsWith('.') ? title : `${title}.`}</h1>${description ? `<p class="lede">${description}</p>` : ''}</div>${actions}</div></header>`;
  const notice = (title, text, action = '', tone = 'warning') => `<div class="notice" data-tone="${tone}" role="status"><strong>${title}</strong><p>${text}</p>${action}</div>`;
  const empty = (title, text, action = '') => `<div class="empty-state">${signal('unknown')}<h2>${title}</h2><p>${text}</p>${action}</div>`;
  const sampleAttachment = 'MONOLITH — fictional material notes\n\nLinen, pale oak and stone. Review in morning light.\nNo real account data.\n';
  const sampleAttachmentBytes = new TextEncoder().encode(sampleAttachment).length;
  const accounts = {
    personal: {id:'personal', registerLetter:'A', name:'Personal', email:'mara@vale.example', total:4, recent:2, calendar:'Personal', subject:'A plan for the long weekend', sender:'Elin Park'},
    studio: {id:'studio', registerLetter:'B', name:'Northline Studio', email:'mara@northline.example', total:2, recent:1, calendar:'Studio shared', subject:'Material samples, ready to review', sender:'Jules Rowan'}
  };
  const mail = {
    personal: [
      {id:'weekend',sender:'Elin Park',subject:'A plan for the long weekend',preview:'Shall we take the coastal path on Sunday?',time:'09:18',unread:true},
      {id:'reading',sender:'Owen Lake',subject:'The reading list',preview:'Three books for the colder evenings.',time:'Yesterday',unread:true},
      {id:'table',sender:'Cedar House',subject:'Your table for Saturday',preview:'Your reservation for two at 19:30 is confirmed.',time:'Wed 4 Nov',unread:false}
    ],
    studio: [
      {id:'materials',sender:'Jules Rowan',subject:'Material samples, ready to review',preview:'The linen and pale oak samples are on the studio table.',time:'08:54',unread:true},
      {id:'site',sender:'Ivo Lane',subject:'Friday site photographs',preview:'The north-facing room, photographed in morning light.',time:'08:12',unread:true},
      {id:'delivery',sender:'Linen Workshop',subject:'Delivery on Monday',preview:'The samples will arrive before noon.',time:'Yesterday',unread:false}
    ]
  };
  function observedState(state, subject = 'readout', recovery = subject.includes('GitHub') ? '#/connections/github' : '#/connections/gmail', observedAt = '09:41 GMT') {
    const map = {
      loading: notice(`Loading ${subject}`, 'Waiting for a read-only update. No new observation is available.', '', 'muted'),
      stale: notice('Showing an earlier observation', `Last successful read: ${observedAt}. This information may have changed.`, link(recovery,'Review connection')),
      offline: notice('You’re offline', 'The last saved observation is still visible. Reconnect to the internet before refreshing.', '<button class="button" data-action="refresh">Try again</button>'),
      reconnect: notice('Sign in to Google again', 'This account’s Gmail permission needs attention. Calendar has its own access status.', link('#/connections/gmail?state=reconnect','Review Gmail connection'), 'error'),
      'rate-limit': notice('Google asked us to wait', 'Try again after 09:45 GMT. The earlier observation remains available.', '<button class="button" disabled>Refresh available at 09:45</button>'),
      error: notice(`Couldn’t update this ${subject}`, 'No new information was saved. Earlier content remains labeled with its original time.', '<button class="button" data-action="refresh">Try again</button>', 'error'),
      partial: notice('Some results are unavailable', 'This is a bounded, incomplete snapshot. Missing results are not counted as zero.', '<button class="button" data-action="refresh">Refresh</button>')
    };
    return map[state] || '';
  }
  function count(value, label, unavailable = false, tone = '') {
    return `<span class="count ${tone}">${unavailable ? '<b aria-hidden="true">—</b><span class="sr-only">Unavailable</span>' : `<b>${value}</b>`}<small>${label}</small></span>`;
  }
  function workspaceNames(ctx, account) {
    const names = ctx.workspaces.filter(workspace => (ctx.memberships[workspace.id] || []).includes(account.id)).map(workspace => escape(workspace.name));
    return names.length ? names.join(' · ') : 'Not in a workspace';
  }
  function workspaceTitle(ctx, id) {
    const workspace = ctx.workspaces.find(workspace => workspace.id === id);
    return workspace ? escape(workspace.name) : 'Not in a workspace';
  }
  function accountReadout(account, state = 'ready', href = `#/accounts/${account.id}/mail`, memberships = '') {
    const unknown = state === 'loading';
    const retained = ['stale','offline','error','reconnect'].includes(state);
    return `<a class="readout account-register" href="${href}"><span class="account-index">${account.registerLetter}01</span><div class="account-identity"><h3>${account.name}</h3><p>${account.email}</p><p>Gmail · ${memberships}</p>${state === 'reconnect' ? badge('Sign-in required','error','attention') : ''}</div><div class="counts" aria-label="Unread inbox conversations">${count(state === 'zero' ? 0 : account.total,'Total unread',unknown)}${count(state === 'zero' ? 0 : account.recent,'Last 24h',unknown)}</div><div class="account-detail"><span>Open account inbox <small>${unknown ? 'No observation yet' : `${retained ? 'Earlier sample observation' : 'Sample observation'} · 09:41 GMT`}</small></span><span aria-hidden="true">↗</span></div></a>`;
  }
  function agenda(account, state = 'ready', selection = ['primary']) {
    const studio = account.id === 'studio';
    let body;
    if (!selection.length) body = `<p>No calendars selected.</p><p class="muted">Choose calendars for this account to show its agenda.</p>${link('#/connections/calendar','Choose calendars')}`;
    else if (state === 'loading') body = `<p role="status">${badge('Loading today’s agenda','muted','loading')}</p>`;
    else if (state === 'empty' || !selection.includes('primary')) body = '<p>No events today.</p><p class="muted">No events were returned from the selected calendars.</p>';
    else body = `<div class="event-row"><h3><button class="event-button" data-dialog="event-${account.id}">${studio ? 'Material review' : 'Walk by the water'}</button></h3><time>${studio ? '11:00–11:45' : '17:30–18:15'}</time><p>${account.calendar}</p></div>`;
    return `<article class="panel calendar-card"><p class="account-label"><span class="account-index">${account.registerLetter}02</span>${account.email}</p>${body}${state === 'partial' && selection.length ? '<p class="badge" data-tone="warning">Some selected calendars could not be read.</p>' : ''}</article>`;
  }
  function home(ctx) {
    const active = Object.values(accounts).filter(account => !ctx.disconnected.has(account.id));
    const gmail = ctx.state === 'empty' || !active.length
      ? empty('No Gmail accounts','Connect an account to see its unread conversations.',link('#/connections/gmail?state=missing','Set up Gmail'))
      : active.map((account,index) => accountReadout(account,index === 0 ? ctx.state : 'ready',undefined,workspaceNames(ctx,account))).join('');
    const calendar = ctx.state === 'empty' || !active.length
      ? empty('Calendar is optional','Choose an account and the calendars you want to read.',link('#/connections/calendar?state=missing','Set up Calendar'))
      : active.map(account => agenda(account,ctx.state,ctx.calendarSelections[account.id])).join('');
    return `<section class="home-hero"><div class="date-block"><p class="eyebrow">Europe, London</p><div class="day-number" aria-hidden="true">06</div><div class="date-caption"><span>November</span><span>Friday / 2026</span></div></div><div class="home-greeting"><h1 id="view-title" tabindex="-1">A day<br>in focus.</h1><div class="hero-bottom"><p>Good morning, Mara.</p><div class="index-mark">FRI 06 NOV 2026<br>09:41 / SAMPLE</div></div></div></section>${observedState(ctx.state,'readouts')}<div class="home-readouts"><section class="home-section"><div class="section-head"><h2>01 / Email</h2></div><div class="stack">${gmail}</div></section><section class="home-section"><div class="section-head"><h2>02 / Calendar</h2><span class="eyebrow">GMT</span></div><div class="stack">${calendar}</div></section></div><section class="github-section"><div class="section-head"><h2>03 / GitHub activity</h2></div>${ctx.state === 'empty' ? empty('No GitHub installations','Choose an installation owner in Connections.',link('#/connections/github?state=missing','Set up GitHub')) : `<div class="grid-2">${githubCard(ctx,'northline','Northline','studio',7,2,4,6,1)}${githubCard(ctx,'mara','mara-vale','personal',2,0,1,3,0)}</div>`}</section>`;
  }
  function githubCard(ctx,id,name,workspaceId,prs,attention,issues,runs,failed) {
    return `<a class="readout github-readout" href="#/workspaces/${workspaceId}/github/${id}"><span class="account-index">${id==='northline'?'A':'B'}03</span><div><h3>${name}</h3><p>${workspaceTitle(ctx,workspaceId)} · GitHub installation</p></div><div class="counts">${count(prs,'Open PRs')}${count(attention,'Need attention',false,'attention')}</div><div class="account-detail"><span>${issues} open issues · ${runs} recent runs / ${failed} need attention</span><span aria-hidden="true">↗</span></div></a>`;
  }
  function workspaces(ctx) {
    const isEmpty = ctx.state === 'empty' || !ctx.workspaces.length;
    return `${heading('02 / Workspaces','Workspaces.','', isEmpty ? '' : '<button class="button primary" data-dialog="workspace">New workspace</button>')}${isEmpty ? empty('Name your first workspace','Choose an area of life. You can add connections later.','<button class="button primary" data-dialog="workspace">New workspace</button>') : `${observedState(ctx.state,'workspace directory')}<div class="grid-2">${ctx.workspaces.map((workspace,index)=>`<article class="workspace-card"><header class="workspace-card-head"><p class="eyebrow">${String(index+1).padStart(2,'0')}</p><button type="button" class="text-link workspace-rename" data-dialog="rename" data-workspace="${escape(workspace.id)}" aria-label="Rename ${escape(workspace.name)} workspace">Rename</button></header><a class="workspace-link" href="#/workspaces/${escape(workspace.id)}"><h2>${escape(workspace.name)}</h2><p>${(ctx.memberships[workspace.id] || []).filter(id => !ctx.disconnected.has(id)).length} Google accounts${workspace.id === 'studio' ? ' · Northline on GitHub' : ''}</p></a></article>`).join('')}</div>`}`;
  }
  function workspace(ctx, id) {
    const current = ctx.workspaces.find(workspace => workspace.id === id);
    if (!current) return unavailable();
    const members = (ctx.memberships[id] || []).filter(key => !ctx.disconnected.has(key));
    return `${subviewHeading(`02 / ${escape(current.name)}`,escape(current.name),link('#/workspaces','All workspaces'),'',`<a class="button primary" href="#/workspaces/${escape(id)}/integrations">Add integration</a>`)}${observedState(ctx.state,'workspace')}<div class="workspace-detail-grid"><section><div class="section-head"><h2>01 / Google accounts</h2></div><div class="integrations">${ctx.state === 'empty' || !members.length ? empty('No accounts here yet','Add an existing Google account, or connect a new one.',link(`#/workspaces/${escape(id)}/integrations`,'Add integration')) : members.map(key=>`<article class="workspace-account">${accountReadout(accounts[key],ctx.state,`#/workspaces/${escape(id)}/accounts/${key}/mail`,escape(current.name))}<div class="account-actions"><button class="button danger compact" data-dialog="detach" data-workspace="${escape(id)}" data-account="${key}">Remove from workspace</button></div></article>`).join('')}</div></section><section><div class="section-head"><h2>02 / Today’s calendar</h2><span class="eyebrow">GMT</span></div><div class="stack">${ctx.state === 'empty' || !members.length ? empty('No calendars here','Add a Google account with Calendar enabled.',link(`#/workspaces/${escape(id)}/integrations`,'Choose account')) : members.map(key=>agenda(accounts[key],ctx.state,ctx.calendarSelections[key])).join('')}</div></section></div>${id === 'studio' && ctx.state !== 'empty' ? `<section class="github-section"><div class="section-head"><h2>03 / Northline / GitHub</h2>${link('#/workspaces/studio/github/northline','View activity')}</div><div class="panel"><div class="row spread"><div><h3>Selected repositories</h3><p class="muted">northline/site · northline/design-system</p></div>${badge('Snapshot subset','attention','attention')}</div><p>7 open pull requests · 2 need attention</p><p class="muted">Filtered owner snapshot, not repository totals. Observed 09:39 GMT.</p></div></section>` : ''}`;
  }
  function integrations(ctx,id) {
    const current=ctx.workspaces.find(workspace=>workspace.id===id);
    if(!current) return unavailable();
    const attached=ctx.memberships[id]||[];
    return `${link(`#/workspaces/${escape(id)}`,`Back to ${escape(current.name)}`)}${heading('02 / Add integration','Use a connection again.')}<form class="panel" data-form="attach" data-workspace="${escape(id)}"><h2>Google accounts</h2><p class="muted">One connection can belong to several workspaces. No additional Google consent is requested by this local selection.</p>${Object.values(accounts).map(account=>`<label><input type="checkbox" name="account" value="${account.id}" ${attached.includes(account.id)?'checked':''}>${account.name} · ${account.email}</label>`).join('')}<button class="button primary" type="submit">Save selection</button></form><section class="review-section"><h2>GitHub installations</h2><div class="integration-row"><div><h3>Northline</h3><p>Organization installation · selected repositories</p></div>${link('#/connections/github','Manage installation access')}</div></section>${link('#/connections/gmail','Connect another Google account')}`;
  }
  function mailContext(ctx, id, workspaceId) {
    const account=accounts[id];
    if(!account || ctx.disconnected.has(id) || (workspaceId && !(ctx.memberships[workspaceId]||[]).includes(id))) return null;
    const base=workspaceId ? `#/workspaces/${escape(workspaceId)}/accounts/${id}/mail` : `#/accounts/${id}/mail`;
    return {account,base};
  }
  function inbox(ctx,id,workspaceId) {
    const context=mailContext(ctx,id,workspaceId);
    if(!context) return unavailable();
    const {account,base}=context;
    const query=ctx.query.get('q')||'';
    const page=ctx.query.get('page')==='2'?'2':'1';
    const filtered=mail[id].filter(row=>`${row.sender} ${row.subject} ${row.preview}`.toLowerCase().includes(query.toLowerCase()));
    return `<header class="mail-head"><div><p class="eyebrow">Gmail / ${workspaceId ? escape(ctx.workspaces.find(w=>w.id===workspaceId)?.name || '') : 'Account'}</p><h1 id="view-title" tabindex="-1">${account.name.endsWith('.') ? account.name : `${account.name}.`}</h1><p class="muted">${account.email}</p></div><form class="search-form" data-form="search" data-base="${base}"><div class="field"><label class="sr-only" for="mail-search">Search ${account.email}</label><input id="mail-search" name="q" type="search" value="${escape(query)}" placeholder="Search this account"></div><button class="button" type="submit">Search</button></form></header><div class="mail-toolbar"><div class="row">${workspaceId ? link(`#/workspaces/${escape(workspaceId)}`,'All accounts') : link('#/connections/gmail','Manage connection')}<span class="muted">Read-only</span></div><div class="row"><details><summary>Observed 09:41 GMT</summary><p>Friday, 6 November 2026 at 09:41 GMT.<br>Sample observation, not a live read.</p></details><button class="button compact" data-action="refresh" ${ctx.state==='rate-limit'?'disabled':''}>Refresh</button></div></div>${observedState(ctx.state,'inbox')}<div class="mail-results" aria-label="${account.name} conversations">${ctx.state==='loading' ? `<p role="status">${badge('Loading conversations','muted','loading')}</p>` : ctx.state==='empty' || !filtered.length ? empty(query ? 'No matching conversations' : 'No conversations to show',query ? 'Try a different word, or return to this account’s inbox.' : 'The read completed and this sample inbox is empty.',link(base,'Clear search')) : `<ol class="mail-list">${(page==='2' ? filtered.slice(-1) : filtered).map(row=>`<li><a id="thread-${row.id}" class="mail-row ${row.unread?'unread':''}" href="${base}/threads/${row.id}${query ? `?q=${encodeURIComponent(query)}&page=${page}` : `?page=${page}`}"><span class="mail-marker" aria-label="${row.unread?'Unread':'Read'}">${row.unread?'•':'–'}</span><div class="mail-copy"><span class="mail-sender">${row.sender}</span><p class="mail-subject">${row.subject}</p><p class="mail-preview">${row.preview}</p></div><time title="6 November 2026, sample time">${row.time}</time></a></li>`).join('')}</ol><div class="mail-pagination"><span class="muted">Sample page ${escape(page)} · bounded results</span>${page==='1' ? link(`${base}?page=2${query?`&q=${encodeURIComponent(query)}`:''}`,'Older conversations') : link(`${base}${query?`?q=${encodeURIComponent(query)}`:''}`,'Newer conversations')}</div>`}</div>`;
  }
  function thread(ctx,id,threadId,workspaceId) {
    const context=mailContext(ctx,id,workspaceId);
    const message=mail[id]?.find(row=>row.id===threadId);
    if(!context || !message) return unavailable();
    const {account,base}=context;
    const suffix=ctx.query.toString() ? `?${escape(ctx.query.toString())}` : '';
    const addresses={weekend:'elin@park.example',reading:'owen@lake.example',table:'reservations@cedar.example',materials:'jules@northline.example',site:'ivo@northline.example',delivery:'hello@linen.example'};
    const body=threadId==='weekend'
      ? '<p>Hi Mara,</p><p>Shall we take the coastal path on Sunday? We could meet at the old boathouse at ten, then walk to the headland.</p><p>I’ll bring coffee. Let me know what suits you.</p><p>Elin</p>'
      : threadId==='materials'
        ? '<p>Good morning Mara,</p><p>The linen and pale oak samples are on the studio table. We can compare them in the eleven o’clock review.</p><p>I’ve included the stone finish in the same light. The softer edge looks right against the north wall.</p><p>See you at eleven,<br>Jules</p>'
        : `<p>Hi Mara,</p><p>${message.preview}</p><p>This is fictional correspondence for checking reading measure, spacing and message hierarchy.</p><p>${message.sender}</p>`;
    const messages = ctx.state==='loading'
      ? `<p role="status">${badge('Loading conversation','muted','loading')}</p>`
      : `<details><summary>Earlier message · Mara Vale · Yesterday, 18:42</summary><div class="message-body"><p>Could we look at this together tomorrow?</p><p>Mara</p></div></details><section aria-label="Latest message"><div class="message-summary"><strong>${message.sender}</strong><span>${message.time}</span></div><details class="metadata"><summary>Message details</summary><p>From: ${addresses[threadId]}<br>To: ${account.email}<br>Date: ${message.time} · fictional observation<br>Subject: ${message.subject}</p></details><div class="message-body">${body}<blockquote><p>On Thursday, Mara wrote:</p><p>Could we look at this together tomorrow?</p></blockquote></div>${threadId==='materials' ? `<div class="attachment"><div><strong>material-notes.txt</strong><p>Plain text · ${sampleAttachmentBytes} bytes · sample attachment</p></div><button class="button" data-action="download-sample">Download sample</button></div>` : ''}</section>`;
    return `<div class="row spread">${link(`${base}${suffix}`,'Back to results')}<span class="muted">${account.email}</span></div>${observedState(ctx.state,'conversation')}<article class="reader"><p class="eyebrow">${account.name} / Read-only conversation</p><h1 id="view-title" tabindex="-1">${message.subject}</h1>${messages}</article>`;
  }
  function activity(ctx,workspaceId,ownerId) {
    const organization = ownerId === 'northline' && workspaceId === 'studio';
    const personal = ownerId === 'mara' && workspaceId === 'personal';
    if ((!organization && !personal) || !ctx.workspaces.some(workspace => workspace.id === workspaceId)) return unavailable();
    const owner = organization ? 'Northline' : 'mara-vale';
    const repository = organization ? 'northline/site' : 'mara-vale/field-notes';
    const available = !['loading','empty'].includes(ctx.state);
    const rows = organization
      ? [{repo:repository,id:142,author:'Jules Rowan',title:'Refine the material palette',status:'Review requested'},{repo:'northline/design-system',id:38,author:'Ivo Lane',title:'Align typography across the directory',status:'Checks failed'}]
      : [{repo:repository,id:18,author:'Mara Vale',title:'Add the November reading list',status:'Checks passed'},{repo:repository,id:17,author:'Mara Vale',title:'Organize the coastal walking notes',status:'Checks passed'}];
    return `${link(`#/workspaces/${workspaceId}`,'Back to workspace')}${heading('GitHub / Installation owner',owner,'Selected repository snapshot', '<button class="button" data-action="refresh">Refresh</button>')}${observedState(ctx.state,'GitHub snapshot','#/connections/github','09:39 UTC')}<div class="panel"><p class="muted">${organization?'northline/site · northline/design-system':repository}<br>Observed 6 November 2026, 09:39 UTC · bounded snapshot</p>${badge(ctx.state==='partial'?'Partial results':ctx.state==='loading'?'Loading snapshot':'Snapshot available',ctx.state==='partial'?'warning':'muted',ctx.state==='loading'?'loading':'healthy')}<p>Filtered owner snapshot, not selected-repository totals.</p></div>${ctx.state==='empty' ? empty('No matching activity','The selected repositories returned no items in this bounded snapshot.',link('#/connections/github','Review repository selection')) : available ? `<section class="review-section"><div class="section-head"><h2>Pull requests</h2><span class="eyebrow">${organization?'7 open / 2 need attention':'2 open / 0 need attention'}</span></div><ul class="activity-list">${rows.map(row=>`<li><div><p>${row.repo} · #${row.id} · ${row.author}</p><h3>${row.title}</h3><p>Updated 6 Nov 2026, 09:22 UTC</p></div>${badge(row.status,organization?'attention':'success',organization?'attention':'healthy')}</li>`).join('')}</ul></section><section class="review-section"><h2>Issues</h2><ul class="activity-list"><li><div><p>${repository} · #${organization?'139':'12'} · Mara Vale</p><h3>${organization?'Check narrow-screen reading rhythm':'Choose the next coastal route'}</h3><p>Open · Updated 5 Nov 2026, 16:10 UTC</p></div>${badge('Open','muted','unknown')}</li></ul></section><section class="review-section"><h2>Recent Actions</h2><ul class="activity-list"><li><div><h3>${organization?'Site checks':'Notes checks'} / main</h3><p>${repository} · Completed 6 Nov 2026, 09:20 UTC</p></div>${badge(organization?'Failed':'Passed',organization?'error':'success',organization?'attention':'healthy')}</li></ul></section>` : ''}`;
  }
  const providers=['google','gmail','calendar','gemini','github'];
  const providerNames={google:'Google',gmail:'Gmail',calendar:'Calendar',gemini:'Gemini',github:'GitHub'};
  const purposes={google:'Shared Desktop client settings for Google account consent.',gmail:'Read-only mail connections and their workspace memberships.',calendar:'Optional access and selected calendars, separately by account.',gemini:'App-wide scenery credentials. Optional and potentially billable.',github:'Read-only installation owners and repository access.'};
  function connections() {
    return `${heading('03 / Connections','Connections.')}<div class="provider-overview">${providers.map(provider=>`<a href="#/connections/${provider}"><p class="eyebrow">${provider==='google'?'Shared configuration':provider==='gemini'?'App-wide':provider==='github'?'Installation access':'Per Google account'}</p><h2>${providerNames[provider]}</h2><p>${purposes[provider]}</p></a>`).join('')}</div>`;
  }
  const connectionHead = (title, status, identity = '') => `<header class="connection-card-head"><div><h2>${title}</h2>${identity ? `<p class="identity">${identity}</p>` : ''}</div>${status}</header>`;
  function providerDetails(ctx, name) {
    if (['checking','error'].includes(ctx.state)) return '';
    if (name === 'google') return `<details><summary>Google project setup</summary><ol><li>Create or select your project in Google Cloud.</li><li>Configure the OAuth consent audience and test users.</li><li>Create a Desktop OAuth client.</li><li>Enable Gmail, and Calendar only if you choose to use it.</li></ol><p class="muted">This guide is a content specimen. It does not verify console settings or open Google.</p></details>`;
    if (name === 'gmail') return `<details><summary>What does Check Keychain mean?</summary><p>A readable credential does not verify Google, refresh mail or change permissions. Production access failures may lock the application; a missing individual credential is a separate state.</p></details>`;
    if (name === 'gemini') return `<details><summary>Removing a key</summary><p>Saved scenes and attempt history remain. Removal does not cancel an already authorized provider operation or prove that no charge occurred.</p></details>`;
    if (name === 'github') return ctx.state === 'missing'
      ? `<details open><summary>Registration and permissions</summary><ol><li>Register a GitHub App for GitHub.com.</li><li>Allow read-only pull requests, issues and Actions metadata.</li><li>Configure the local callback and save client settings.</li><li>Authorize the account, then choose installation repositories.</li></ol><p>No contents, logs, artifacts or repository writes.</p></details>`
      : `<details><summary>GitHub App settings</summary><p>Settings stored locally. Saving settings alone is not account authorization.</p><button class="button" data-dialog="credentials-github">Preview replacement form</button></details>`;
    return '';
  }
  function provider(ctx,name) {
    if(!providers.includes(name)) return unavailable();
    const title=providerNames[name];
    const subnav=`<nav class="provider-tabs" aria-label="Connection providers">${providers.map(provider=>`<a href="#/connections/${provider}"${provider===name?' aria-current="page"':''}>${providerNames[provider]}</a>`).join('')}</nav>`;
    let content='';
    if(ctx.state==='checking') content=`<div class="panel" role="status">${connectionHead('Local credentials',badge('Checking local availability','muted','loading'))}<p class="muted">This is a local credential check, not a provider health check. Editing and connection actions are unavailable until it settles.</p></div>`;
    else if(ctx.state==='error') content=`<div class="panel" role="status">${connectionHead('Local credentials',badge('Unavailable','error','attention'))}<p>Local credentials are unavailable. A failed read does not mean credentials are missing. No provider request was made. Review Keychain access before trying again.</p><button class="button" data-action="refresh">Check local status again</button></div>`;
    else if(name==='google') content=googleSettings(ctx);
    else if(name==='gmail') content=gmailSettings(ctx);
    else if(name==='calendar') content=calendarSettings(ctx);
    else if(name==='gemini') content=geminiSettings(ctx);
    else content=githubSettings(ctx);
    return `${subviewHeading(`03 / ${title}`,title,link('#/connections','All connections'))}${subnav}<div class="provider-layout"><div class="provider-main">${content}</div><aside class="provider-context"><h2>${name==='gemini'?'Optional, potentially billable.':'Permission is specific.'}</h2><p>${name==='google'?'Saving a client ID and secret stores settings locally. It does not verify Google access or connect Gmail or Calendar.':name==='gmail'?'Gmail and Calendar share a Google identity, but their permissions and health are separate. An unread total belongs to one inbox.':name==='calendar'?'Calendar is opt-in. Select shared or personal calendars per account. A calendar access failure does not mean Gmail is unavailable.':name==='gemini'?'Saving or removing an API key does not generate an image, contact Google or change automatic startup consent.':'Authorizing a GitHub account and choosing an installation’s repositories are separate steps. No repository writes are requested.'}</p>${providerDetails(ctx,name)}<details><summary>Privacy and recovery</summary><p>Production credentials belong in the dedicated LOVELACE Keychain. This study accepts no secrets. Only local study assets load; no provider or off-origin requests occur. Every connection and action shown here is fictional.</p></details></aside></div>`;
  }
  function googleSettings(ctx) {
    return `<div class="panel">${connectionHead('Google Desktop client',ctx.state==='missing'?badge('Not configured','muted','unknown'):badge('Settings stored locally','success'))}${ctx.state==='missing' ? `<p>No client settings are saved.</p><p class="muted">Create a Desktop OAuth client in your own Google project, then save its settings locally.</p><button class="button primary" data-dialog="credentials-google">Preview client form</button>` : `<p class="muted">Client settings are present. Google access has not been verified by this observation.</p><details><summary>Replace client settings</summary><p>The production form accepts the client ID and secret through a protected credential POST.</p><button class="button" data-dialog="credentials-google">Preview client form</button></details>`}</div>`;
  }
  function gmailSettings(ctx) {
    if(ctx.state==='missing') return `<div class="empty-state">${connectionHead('Connect your first Gmail account',badge('Not connected','muted','unknown'))}<p>Google client settings must be available before you start consent. Choose the receiving workspace explicitly.</p><button class="button primary" data-dialog="connect-google">Add Gmail account</button></div>`;
    return `<div class="stack">${Object.values(accounts).map((account,index)=>{
      const disconnected = ctx.disconnected.has(account.id);
      return `<article class="provider-account">${connectionHead(account.name,disconnected?badge('Disconnected','error','disconnected'):ctx.state==='reconnect' && index===0?badge('Sign-in required','error','attention'):badge('Connected','success'),account.email)}<p class="muted">${disconnected?'Disconnected across all sample workspaces.':`Workspaces: ${workspaceNames(ctx,account)}<br>Gmail observed 09:41 GMT · Calendar enabled independently`}</p>${ctx.state==='reconnect' && index===0 && !disconnected?notice('Gmail access needs your attention','Sign in again to restore Gmail access. The Calendar observation has not changed.','','error'):''}<div class="account-actions">${disconnected?'':`<button class="button" data-dialog="keychain" data-account="${account.id}">Check Keychain</button>`}<button class="button" data-dialog="connect-google" data-account="${account.id}">${disconnected?'Preview reconnect':'Sign in again'}</button>${disconnected?'':`<button class="button danger" data-dialog="disconnect" data-account="${account.id}">Disconnect everywhere</button>`}</div></article>`;
    }).join('')}</div><div class="row" style="margin-top:24px"><button class="button primary" data-dialog="connect-google">Add Gmail account</button></div>`;
  }
  function calendarSettings(ctx) {
    if(ctx.state==='missing') return `<div class="empty-state">${connectionHead('Choose Calendar access',badge('Not enabled','muted','unknown'))}<p>Calendar access is optional and independent of Gmail.</p><button class="button primary" data-dialog="calendar-consent">Preview Calendar consent</button></div>`;
    const cards = Object.values(accounts).map(account => {
      if (ctx.disconnected.has(account.id)) return `<article class="provider-account">${connectionHead(account.name,badge('Disconnected','error','disconnected'),account.email)}<p>Gmail and Calendar access were removed from all sample workspaces.</p><button class="button" data-dialog="connect-google" data-account="${account.id}">Preview reconnect</button></article>`;
      const requiresSignIn=ctx.state==='reconnect'&&account.id==='personal';
      const selection=ctx.calendarSelections[account.id] || ['primary'];
      return `<form class="provider-account" data-form="calendar" data-account="${account.id}">${connectionHead(account.name,badge(requiresSignIn?'Calendar sign-in required':'Calendar enabled',requiresSignIn?'error':'success',requiresSignIn?'attention':'healthy'),account.email)}<fieldset ${requiresSignIn?'disabled':''}><legend>Selected calendars</legend><label><input type="checkbox" name="calendar" value="primary" ${ctx.state!=='no-selection'&&selection.includes('primary')?'checked':''}>${account.calendar}</label><label><input type="checkbox" name="calendar" value="shared" ${ctx.state!=='no-selection'&&selection.includes('shared')?'checked':''}>${account.id==='personal'?'Coastal walks · shared':'Studio holidays · shared'}</label><p class="muted">Today in Europe/London. No descriptions, attendees or calendar writes.</p><button class="button primary" type="submit">Save selection</button></fieldset></form>`;
    }).join('');
    return `${ctx.state==='reconnect'?notice('Personal Calendar needs sign-in','Gmail can remain connected while Calendar access needs attention.','<button class="button" data-dialog="calendar-consent">Review Calendar access</button>','error'):''}${ctx.state==='partial'?observedState('partial','calendar list'):''}<div class="stack">${cards}</div>`;
  }
  function geminiSettings(ctx) {
    return `<div class="panel">${connectionHead('Gemini API key',ctx.state==='missing'?badge('No key stored','muted','unknown'):badge('Key stored locally','success'))}${ctx.state==='missing' ? `<p>No API key is stored.</p><button class="button primary" data-dialog="credentials-gemini">Preview API key form</button>` : `<p class="muted">A key is present in the fictional dedicated Keychain. This does not verify Google access.</p><div class="account-actions"><button class="button" data-dialog="credentials-gemini">Replace API key</button><button class="button danger" data-dialog="remove-key">Remove API key</button></div>`}<p class="notice">Generation can incur Google charges. Saving a key does not generate, test the provider or enable automatic startup generation.</p></div>`;
  }
  function githubSettings(ctx) {
    if(ctx.state==='missing') return `<div class="panel">${connectionHead('Set up your GitHub App',badge('Not configured','muted','unknown'))}<p class="muted">App settings are required before account sign-in is available.</p><button class="button primary" data-dialog="credentials-github">Preview App settings form</button></div>`;
    return `${ctx.state==='reconnect'?notice('Start connection again','The previous sign-in did not finish. A fresh request needs your explicit action.','<button class="button" data-dialog="github-signin">Start connection again</button>','error'):''}<div class="panel">${connectionHead('mara-vale',badge('Connected','success'))}<p class="muted">GitHub App account authorization · saved locally</p><div class="account-actions"><button class="button" data-dialog="github-repositories">Choose repositories on GitHub</button><button class="button danger" data-dialog="github-disconnect">Disconnect GitHub account</button></div></div><section class="review-section"><h2>Installation owners</h2><div class="installation-owner-list"><div class="integration-row"><div><h3>Northline</h3><p>Organization · 2 selected repositories · ${workspaceTitle(ctx,'studio')}</p></div>${link('#/workspaces/studio/github/northline','View activity')}</div><div class="integration-row"><div><h3>mara-vale</h3><p>Personal · 1 selected repository · ${workspaceTitle(ctx,'personal')}</p></div>${link('#/workspaces/personal/github/mara','View activity')}</div></div></section>`;
  }
  function scenes(ctx) {
    const title=heading('04 / Scenes','Scenes.');
    const setupStates={
      missing:['Set up Gemini, if you choose.','Generated scenes are optional and potentially billable. Bundled scenery remains available without an API key.'],
      checking:['Checking local key availability','Waiting for the local Keychain observation. The editor and generation controls remain unavailable.'],
      unavailable:['The local key could not be checked.','This is not proof that the key is missing. Earlier requests may still incur charges. Your current scene remains available.']
    };
    if(setupStates[ctx.state]) {
      const [label,text]=setupStates[ctx.state];
      return `${title}<div class="panel"><h2>${label}</h2><p class="muted">${text}</p>${ctx.state==='checking'?badge('Checking locally','muted','loading'):link('#/connections/gemini'+(ctx.state==='missing'?'?state=missing':'?state=error'),ctx.state==='missing'?'Set up Gemini':'Review Gemini settings',ctx.state==='missing'?'button primary':'text-link')}</div>`;
    }
    const pending=['queued','submitting','rendering','paused','unknown'].includes(ctx.state);
    const messages={
      queued:notice('Request queued','The sample has durable authorization but no provider acceptance has been observed. No real job exists in this study.','','muted'),
      submitting:notice('Submitting the request','Provider acceptance has not been confirmed. Do not submit another request while the outcome is unsettled.','','muted'),
      rendering:notice('Google is rendering the scene','The fictional request has a known provider ID. Keep working; no percentage or finish time is known. No real request was submitted.','','muted'),
      paused:notice('Status tracking is paused','Retrieval stopped after bounded checks. This does not mean rendering failed. Check only the same known provider ID; do not submit another generation.','<button class="button" data-action="resume-retrieval">Check known request status</button>'),
      unknown:notice('The submission outcome is unknown','Google may have accepted the request and charged for it. Review the possible charge and overlap before authorizing any new request.','<button class="button" data-dialog="unknown-scene">Review unknown outcome</button>','error'),
      error:notice('The scene could not be published','Your current scene is unchanged. A failed result does not guarantee that no charge occurred. Another request requires a fresh cost confirmation.','','error'),
      cleanup:notice('Scene saved; remote cleanup needs attention','The local image is available. Retrying deletion of the known remote result does not submit another generation.','<button class="button" data-action="cleanup">Retry cleanup only</button>')
    };
    const outcomes={queued:'Queued · authorization retained',submitting:'Submitting · acceptance unconfirmed',rendering:'Rendering · known provider ID',paused:'Tracking paused · known provider ID',unknown:'Submission unknown · possible charge',error:'Publication failed',cleanup:'Published · cleanup pending'};
    const outcome=outcomes[ctx.state] || (ctx.sceneUnknownAcknowledged?'Unknown attempt acknowledged · possible charge':'Published locally');
    const request=ctx.sceneRequest;
    return `${title}${messages[ctx.state]||''}${ctx.sceneUnknownAcknowledged&&ctx.state==='ready'?notice('Unknown attempt acknowledged','The prior request is not confirmed as failed or canceled. A fresh request requires a new cost confirmation.','','attention'):''}
      <div class="scene-layout"><section>
        <div class="section-head"><h2>Scene direction</h2>${badge('Key present locally','success')}</div>
        <form data-form="scene-direction" class="panel">
          <div class="scene-choices">
            <div class="field"><label for="scene-subject">Subject</label><select id="scene-subject" name="subject"><option value="architecture">Architecture</option><option value="landscape">Landscape</option></select></div>
            <div class="field"><label for="scene-setting">Setting</label><select id="scene-setting" name="setting"><option value="mountains">Mountains</option><option value="coast">Coast</option><option value="desert">Desert</option><option value="forest">Forest</option></select></div>
            <div class="field"><label for="scene-light">Light</label><select id="scene-light" name="light"><option value="overcast">Overcast</option><option value="dawn">Dawn</option><option value="amber">Amber</option><option value="moonlight">Moonlight</option></select></div>
            <div class="field"><label for="scene-palette">Palette</label><select id="scene-palette" name="palette"><option value="charcoal">Charcoal</option><option value="sea-glass">Sea Glass</option><option value="earth">Earth</option><option value="mist">Mist</option></select></div>
          </div>
          <div class="row"><button class="button primary" type="submit">Save direction</button><button class="button" type="button" data-action="discard-direction">Discard changes</button><span id="direction-status" class="muted" role="status">Saved default</span></div>
          <details><summary>Exact prompt</summary><p id="scene-prompt">Create quiet cinematic scenery with minimalist architecture in mountains, soft overcast light and a charcoal palette. Use negative space and a calm center. No people, text, logos or interface elements.</p></details>
        </form>
        <section class="panel scene-request"><h3>Generate a scene</h3><p class="muted">Each request may incur charges. These choices apply to this request, not startup defaults.</p>
          <div class="field"><label for="scene-model">Model</label><select id="scene-model" data-request="model">${[['gemini-nano-banana-2.1','Nano Banana 2.1'],['gemini-3.1-flash-image','Nano Banana 2'],['gemini-3-pro-image','Nano Banana Pro']].map(([value,label])=>`<option value="${value}" ${request.model===value?'selected':''}>${label}</option>`).join('')}</select></div>
          <div class="scene-choices"><div class="field"><label for="scene-ratio">Aspect ratio</label><select id="scene-ratio" data-request="ratio">${['16:9','21:9','4:3','3:2','1:1'].map(value=>`<option ${request.ratio===value?'selected':''}>${value}</option>`).join('')}</select></div><div class="field"><label for="scene-size">Output size</label><select id="scene-size" data-request="size">${['1K','2K'].map(value=>`<option ${request.size===value?'selected':''}>${value}</option>`).join('')}</select></div></div>
          <button class="button" data-dialog="generation" ${pending?'disabled':''}>Review request</button>
        </section>
      </section><section>
        <div class="section-head"><h2>Current scene</h2><button class="button compact" data-action="refresh">Refresh status</button></div>
        <div class="panel scene-current"><img class="scene-preview" src="../backgrounds/${ctx.scene}.jpg" alt="Current sample scene, a quiet landscape"><div><p class="eyebrow">Local image / active</p><p class="muted">The current scene stays visible during generation and failures.</p></div></div>
      </section></div>
      <section class="review-section"><div class="section-head"><h2>Local gallery</h2><span class="eyebrow">Existing study assets / no new generation</span></div><div class="scene-gallery">${[['02','Mountain architecture'],['01','Coastal architecture'],['03','Desert architecture']].map(([id,name])=>`<article class="scene-tile"><img src="../backgrounds/${id}.jpg" alt="${name}"><div><h3>${name}</h3><p>6 Nov 2026 · stored locally</p><button class="button" data-action="use-scene" data-scene="${id}" ${ctx.scene===id?'disabled':''}>${ctx.scene===id?'Active scene':'Use scene'}</button></div></article>`).join('')}</div></section>
      <section><div class="section-head"><h2>Attempt history</h2><span class="eyebrow">Fictional observations</span></div><div class="spec-table"><table><thead><tr><th>Requested</th><th>Observed state</th><th>Next action</th></tr></thead><tbody><tr><td>6 Nov 2026, 09:35 GMT</td><td>${outcome}</td><td>${ctx.state==='unknown'?'Review before any new request':['paused','rendering'].includes(ctx.state)?'Retrieve only the known result':ctx.sceneUnknownAcknowledged?'Fresh cost confirmation required':'Current image preserved'}</td></tr><tr><td>5 Nov 2026, 08:10 GMT</td><td>Published locally</td><td>No action needed</td></tr></tbody></table></div></section>
      `;
  }
  function settings(ctx) {
    return `${heading('05 / Settings','Settings.')}<div class="grid-2"><form class="panel" data-form="idle"><h2>Scenery after inactivity</h2><div class="field"><label for="idle-minutes">Minutes without interaction</label><input id="idle-minutes" name="minutes" type="number" min="1" max="60" value="${ctx.idleMinutes}" required><small>1–60 minutes. Default: 3 minutes.</small></div><button class="button primary" type="submit">Save preference</button><p class="muted" style="margin-top:16px">Escape or inactivity reveals the scenery. It does not lock MONOLITH or stop work.</p></form><form class="panel" data-form="startup"><h2>Automatic startup scenery</h2><label><input type="checkbox" name="startup" ${ctx.startup?'checked':''}>Allow a new scene at startup</label><p class="muted">Opt-in only. Generation may incur Google charges. Automatic startup has a persisted 24-hour cooldown in the product; manual requests always require fresh cost confirmation.</p><button class="button primary" type="submit">Save startup choice</button><p class="muted" style="margin-top:12px">Study only: no generation or production setting changes.</p></form></div><section class="review-section"><h2>Accessibility preferences</h2><p class="muted">Reduced motion and forced colors follow the browser/OS setting. Reduced motion skips the entrance without delaying access. Mouse movement neither wakes nor extends visual focus.</p><button class="button" data-action="scenery">Preview scenery mode</button></section>`;
  }
  function unlock(ctx) {
    return `<section class="threshold owner-threshold" aria-labelledby="view-title">${window.MonolithIdentity.threshold({error:ctx.state==='error'})}</section>${link('#/setup','View first-run setup')}`;
  }
  function setup(ctx) {
    return `<section class="owner-column">${heading('First run / Terminal pairing','Begin on this computer.','Pair this browser before creating the local owner.')}${ctx.state==='expired'?notice('The pairing code has expired','Return to the MONOLITH terminal and request a fresh code. No owner was created.','','error'):ctx.state==='error'?notice('That pairing code was not accepted','Check the code shown in your terminal. Pairing codes are single-use and expire.','','error'):''}<div class="panel"><p class="eyebrow">1 / Pair this browser</p><div class="field"><span>Terminal pairing code</span><div class="masked-field" aria-label="Pairing code, non-editable specimen">MONOLITH—••••</div><small>Static sample, not a valid pairing code.</small></div><p>Only someone with access to this computer’s MONOLITH terminal can start setup.</p><button class="button primary" data-action="pair-demo">Preview paired step</button></div><section class="review-section"><h2>2 / Create the local owner</h2><div class="field"><span>Password and confirmation</span><div class="masked-field" aria-label="Non-editable password specimen">••••••••••••</div></div><div class="notice" data-tone="warning"><strong>No password recovery.</strong><p>If you lose the owner password, the encrypted workspace and credentials cannot be recovered. Keep the password somewhere safe.</p></div><label><input id="loss-acknowledgment" type="checkbox">I understand there is no password recovery.</label><button id="setup-continue" class="button primary" data-action="setup-demo" disabled>Preview owner creation</button></section><p class="muted">Content proof only: both setup steps are shown together. The product reveals password creation only after successful pairing; this preview accepts no credentials.</p></section>`;
  }
  function onboarding(ctx) {
    const steps=['workspace','google','gmail','calendar','review'];
    const step=steps.includes(ctx.query.get('step'))?ctx.query.get('step'):'workspace';
    let content='';
    if(step==='workspace') content=`<h2>Name your first workspace.</h2><p class="muted">Choose an area of life. No integration is required.</p><form data-form="onboarding-workspace"><div class="field"><label for="first-workspace">Workspace name</label><input id="first-workspace" name="name" value="${escape(ctx.workspaces[0]?.name||'')}" placeholder="For example, Studio" maxlength="60" required></div><button class="button primary" type="submit">Continue</button></form>`;
    else if(step==='google') content=`<h2>Set up a Google project.</h2><p class="muted">You can do this later in Connections. Continuing records your progress, not verification of Google’s settings.</p><ol><li>Create a Google project.</li><li>Choose the OAuth consent audience.</li><li>Create a Desktop client.</li><li>Enable Gmail. Calendar remains optional.</li></ol><button class="button primary" data-dialog="credentials-google">Preview client form</button><div class="row">${link('#/onboarding?step=gmail','Continue')}${link('#/onboarding?step=review','Skip Google')}</div>`;
    else if(step==='gmail') content=`<h2>Connect a Gmail account.</h2><p class="muted">The receiving workspace is ${escape(ctx.workspaces[0]?.name||'your named workspace')}. Consent is explicit. Saving Google client settings has not granted access.</p><button class="button primary" data-dialog="connect-google">Preview Gmail consent</button><div class="row">${link('#/onboarding?step=calendar','Continue')}${link('#/onboarding?step=calendar','Skip Gmail')}</div>`;
    else if(step==='calendar') content=`<h2>Calendar, if you want it.</h2><p class="muted">Choose separate read-only Calendar consent and selected calendars for your local day. Skipping does not grant or change access.</p><button class="button primary" data-dialog="calendar-consent">Preview Calendar consent</button><form data-form="onboarding-calendar"><label><input type="checkbox" name="calendar" value="personal" checked>Personal · sample selected calendar</label><p class="muted">A fictional granted state is shown to proof the picker.</p><button class="button" type="submit">Continue to review</button></form>${link('#/onboarding?step=review','Skip Calendar')}`;
    else content=`<h2>A place to begin.</h2><p>Workspace: <strong>${escape(ctx.workspaces[0]?.name||'Not named')}</strong></p><p class="muted">Integration access is illustrative, not verified. Nothing has connected to Google. You can manage real connections later in the product.</p><button class="button primary" data-action="finish-onboarding">Finish setup preview</button>`;
    return `<section class="owner-column">${heading('First-run guide / Resumable','Start with a workspace.')}<nav class="owner-step" aria-label="Setup steps">${steps.map((name,index)=>`<a href="#/onboarding?step=${name}"${name===step?' aria-current="step"':''}>${index+1}. ${name[0].toUpperCase()+name.slice(1)}</a>`).join('')}</nav>${ctx.state==='error'?notice('This step could not be saved','Your entry is still here. Try again or choose the relevant skip action.','','error'):''}<div class="panel">${content}</div></section>`;
  }
  const viewList=[['/home','Home'],['/workspaces','Workspaces'],['/workspaces/studio','Workspace detail'],['/workspaces/studio/integrations','Add integration'],['/accounts/personal/mail','Personal inbox'],['/accounts/studio/mail','Studio inbox'],['/accounts/personal/mail/threads/weekend','Conversation reader'],['/workspaces/studio/github/northline','GitHub activity'],['/connections','Connections overview'],...providers.map(provider=>[`/connections/${provider}`,`${providerNames[provider]} settings`]),['/scenes','Scenes'],['/settings','Focus & scenery'],['/unlock','Owner unlock'],['/setup','Terminal pairing & owner'],['/onboarding','First-run guide'],['/identity','Identity / MONOLITH mark'],['/components','Components'],['/css','CSS legend & source'],['/voice','Voice & content'],['/review','Designer proofing map']];
  function review() {
    const stateProofs=[['/home?state=loading','First read / unknown counts'],['/home?state=zero','Successful read / zero unread in Personal'],['/home?state=empty','No integrations'],['/home?state=error','Retained counts / failed update'],['/accounts/personal/mail?state=stale','Stale retained inbox'],['/accounts/personal/mail?state=offline','Offline / cached content'],['/accounts/personal/mail?state=rate-limit','Rate limit / wait'],['/connections/gmail?state=reconnect','Gmail sign-in required'],['/connections/calendar?state=no-selection','No selected calendars'],['/connections/calendar?state=partial','Partial Calendar results'],['/workspaces/studio/github/northline?state=partial','Partial GitHub snapshot'],['/connections/google?state=error','Unavailable local credentials'],['/scenes?state=unknown','Unknown paid submission'],['/scenes?state=cleanup','Published / cleanup pending'],['/setup?state=expired','Expired terminal pairing'],['/unlock?state=error','Unlock failure'],['/accounts/personal/mail?state=error','Read failure / recovery']];
    const checks=['Hierarchy: the enlarged date and editorial heading orient the day without crowding the register.','Identity: the inline replay stage compares outline and solid on light and dark; solid rises bottom-up with descending negative-space creases, then pauses before the wordmark.','Views: joined glass surfaces, numbered rows and section rules remain coherent at wide and narrow widths.','Accounts: identity remains explicit; no merged inbox, calendar or cross-owner GitHub totals.','Components: default, hover, focus, disabled, invalid and busy treatments are legible.','States: unknown differs from zero; stale, partial, offline and failed results remain honest.','Voice: each warning explains what happened, what remains true and the next action.','Consent: local saves, provider consent and paid requests are distinct.','Keyboard: focus order, modal dismissal, history and scenery wake preserve context.','Accessibility: reduced motion, forced colors, long text and enlarged text remain usable.'];
    return `${heading('MONOLITH / Design proof','A system to proof.','An architectural interface. One MONOLITH mark. Outline and solid treatments. One centered threshold.','<button class="button" data-action="print">Print proof sheet</button>')}
      <p class="muted">People, accounts, messages and service observations are fictional. No real credentials, protected storage, provider connections or paid generation are used.</p>
      <details id="study-limits"><summary>Study limits / intentional differences from the product</summary><div class="stack">
        <p><strong>Repeatable, temporary state.</strong> Dates and times are frozen for proofing. Workspace names, memberships, calendar selections and preferences change only in memory and reset on reload; the study writes nothing to localStorage.</p>
        <p><strong>Sample search.</strong> Search and result context use hash URLs. Search filters the six fictional conversations locally; it does not interpret Gmail search syntax or query a mailbox.</p>
        <p><strong>Credential specimens.</strong> Pairing, unlock and credential fields are non-editable examples. Entry previews do not authenticate, create an owner or access a vault or owner session.</p>
        <p><strong>Scene simulation.</strong> Scenes previews consent and authored request states using three existing local images. It never submits generation, polls Google or creates background jobs.</p>
      </div></details>
      <section class="review-section"><div class="section-head"><h2>01 / Identity</h2>${link('#/identity','Open the identity guide')}</div><p>The <strong>MONOLITH mark</strong> has outline and solid treatments.</p><p class="muted">The identity guide begins with the mark and its four logo cards. Use the dedicated inline replay stage at the bottom to compare outline and solid with light/dark controls. Outline traces upward; solid reveals its silhouette bottom-up with descending negative-space creases. Both share the completed-mark pause, wordmark timing and exit. Replay is manual; reduced motion shows a static proof. These stage controls do not select a treatment for live unlock. The guide also includes 24/32/48px proofs and SVG downloads.</p></section>
      <section class="review-section"><div class="section-head"><h2>02 / View inventory</h2><span class="eyebrow">Native hash links / reload and history</span></div><div class="proof-map">${viewList.filter(([path])=>path!=='/review').map(([path,title],index)=>`<a href="#${path}"><span>${title}</span><span class="eyebrow">${String(index+1).padStart(2,'0')}</span></a>`).join('')}</div></section>
      <section class="review-section"><h2>03 / State proofs</h2><p class="muted">Open the designer controls to choose a state. Its hash URL is shareable. These are authored scenarios, not live health observations.</p><div class="grid-3">${stateProofs.map(([href,text])=>`<a class="panel" href="#${href}">${text}</a>`).join('')}</div></section>
      <section class="review-section"><h2>04 / Interaction proof paths</h2><ol class="lede"><li>Open Identity. Inspect the MONOLITH mark at full and small sizes and download its SVG. In the dedicated inline replay stage, select outline or solid and light or dark, then replay manually. Inspect the bottom-up solid silhouette and descending negative-space creases; reduced motion stays static. These selections affect the stage only. Separately, open unlock to preview its outline entrance.</li><li>Replay entrance. Activate twice; cancel with Escape. Replay, then complete. Verify reduced motion skips the choreography and the working view arrives with an icon-only collapsed sidebar.</li><li>Activate the MONOLITH mark to expand the sidebar itself. On desktop its right edge moves the content; on narrow screens navigation expands above the content. There is no separate drawer, backdrop or focus trap. Tab moves normally from the toggle into navigation and then the working view. The same icon or Escape collapses the sidebar and keeps focus on the icon. Follow a destination, use Back, reload and resize; only one primary navigation exists and it is hidden while collapsed.</li><li>Open Personal inbox. Search “weekend”, open the conversation, expand metadata, then go Back to results. Home remains the active destination.</li><li>Create and rename a workspace, attach an existing account, then remove only that membership. Workspaces remains active in nested views.</li><li>Compare per-account diagnostics, reconnection and global disconnect confirmations in Connections.</li><li>Edit a scene direction. Review cost consent, cancel and confirm the draft survives, then preview an accepted sample.</li><li>Use Escape in a view with a draft. Wake by keyboard or first click; check route, draft and focus. Escape while the sidebar is expanded collapses only the sidebar; Escape inside a dialog closes only that dialog. Open Lock from the sidebar and cancel; focus returns to its icon.</li></ol></section>
      <section class="review-section"><h2>05 / Decisions embodied here</h2><div class="grid-2"><article class="panel"><h3>One architectural shell</h3><p>After unlock, the sidebar contracts to a thin bar holding only the MONOLITH mark at the top: 64px wide, or 48px at 760px and below. The icon expands the same sidebar in place to 224px on desktop, moving the working content rather than covering it. On narrow screens the expanded navigation sits above the content in normal flow. Five numbered destinations and a separate Lock live inside; the same icon collapses it again. Oversized editorial type, numbered account registers, joined glass and fine rules retain the original demo’s character.</p></article><article class="panel"><h3>Still within the product boundary</h3><p>Separate account unread pairs and agendas, independent Calendar consent, grouped GitHub installation snapshots and explicit Lock. No Home message previews, unified inbox, composing or repository writes.</p></article></div></section>
      <section class="review-section"><h2>06 / Designer proof sheet</h2><p class="muted">Checks and notes remain only in this document until reload. Print saves the current sheet through your browser; this is not a stored approval or implementation sign-off.</p><div class="review-metadata"><div class="field"><label for="reviewer">Reviewer</label><input id="reviewer" autocomplete="off" placeholder="Name or initials"></div><div class="field"><label for="review-date">Review date</label><input id="review-date" type="date"></div></div><div class="review-checklist">${checks.map((text,index)=>`<label><input type="checkbox" name="proof-${index}">${text}</label>`).join('')}</div><div class="field" style="margin-top:24px"><label for="review-notes">Proof notes / changes to approve</label><textarea id="review-notes" class="review-notes" placeholder="Record the view/state URL, observation, and requested change. No real account information."></textarea></div><div class="row"><button class="button primary" data-action="print">Print this proof sheet</button>${link('../02-monolith.html','Open original Monolith demo')}</div></section>`;
  }
  function unavailable() {
    return `${heading('Unavailable destination','This view is unavailable.','The account or workspace is not part of this study. No other account’s content is substituted.')}${link('#/workspaces','Go to Workspaces','button primary')}`;
  }
  window.MonolithViews={escape,readySignals,signal,badge,link,heading,notice,empty,accounts,mail,sampleAttachment,viewList,home,workspaces,workspace,integrations,inbox,thread,activity,connections,provider,scenes,settings,unlock,setup,onboarding,review,unavailable};
})();
