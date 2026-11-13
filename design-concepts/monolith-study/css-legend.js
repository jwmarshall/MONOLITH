'use strict';
/* The annotated stylesheet owns token names, values and usage. This view reads it. */
window.MonolithCSS = (() => {
  const sources = [
    ['tokens.css', 'Foundations / public tokens'],
    ['study.css', 'Shared elements and product primitives'],
    ['identity.css', 'Identity and architectural composition'],
    ['components.css', 'Component specimens'],
    ['voice.css', 'Voice specimens'],
    ['css-legend.css', 'CSS reference layout']
  ];
  const cache = new Map();
  async function source(file, signal) {
    if (cache.has(file)) return cache.get(file);
    const response = await fetch(new URL(file, document.baseURI), {signal});
    if (!response.ok) throw new Error(`${file} could not load (${response.status}).`);
    const text = await response.text();
    cache.set(file, text);
    return text;
  }
  function view() {
    return `<article class="css-sheet" aria-labelledby="view-title">
      <header class="view-head"><div><p class="eyebrow">MONOLITH / CSS reference</p><h1 id="view-title" tabindex="-1">The rules.<br>The real thing.</h1><p class="lede">One annotated foundation. Live values, working specimens and the CSS that renders this study. A design contract for the rebrand—not a claim that the application has migrated.</p></div><a class="button" href="tokens.css" download>Download token CSS</a></header>
      <section class="css-section" aria-labelledby="css-contract-title"><header class="section-head"><h2 id="css-contract-title">01 / Design contract</h2><span class="eyebrow">Structure before decoration</span></header>
        <div class="css-contract-grid">
          <div><h3>One working plane.</h3><p>Scenery is atmosphere, never the reading surface. Join account-separated registers on neutral glass with open sides, boundary rules and quieter internal dividers. No nested floating cards or decorative shadows.</p></div>
          <div><h3>One owner per decision.</h3><p><code>tokens.css</code> owns public values and their usage comments. Shared selectors own controls; composition owns layout; specimen files own examples only. Reuse the existing selector before adding a variant. One parent owns each gap.</p></div>
          <div><h3>Meaning survives appearance.</h3><p>Color is a small signal, paired with words and shape. Preserve account identity, observed freshness and recovery. Empty, unknown, stale, disabled and failed are different states. Escape reveals scenery; only Lock protects storage.</p></div>
        </div>
        <details class="css-inset"><summary>Implementation rules / responsive, accessible, maintainable</summary><ul class="css-rules">
          <li><strong>Typography:</strong> local Space Grotesk for reading, system monospace for registers. Normal tracking and sentence case for prose; fixed identity presets are not fluid page headings. Long messages wrap within the reading measure.</li>
          <li><strong>Responsive:</strong> the product shell changes at 760px; secondary dense grids simplify at 1080px and 440px. Specimen-only breakpoints (1000/800/600px) serve demonstrations, not extra product modes. CSS custom properties cannot drive media queries; keep these literal thresholds beside the affected layout.</li>
          <li><strong>Interaction:</strong> native links navigate; native buttons act. Name the scope of destructive actions. Keep a visible reason beside disabled controls, retain a visible keyboard focus ring, and use at least 44px action targets. Dialogs restore focus; do not add custom keyboard traps to ordinary navigation.</li>
          <li><strong>Contrast:</strong> require 4.5:1 for ordinary text, 3:1 for large text and essential control boundaries. Decorative dividers need not meet control contrast. Validate the actual scenery/glass composite; token swatches alone are not contrast certification.</li>
          <li><strong>Motion and output:</strong> no essential meaning depends on animation. Reduced motion and print show completed signals and identity; forced colors uses system colors and removes scenery. Identity choreography and signal cycle timings belong to their canonical artwork, not generic UI transition tokens.</li>
          <li><strong>Extension:</strong> add a shared token only for a reusable design decision, with a usage comment and a real consumer. Keep <code>--brand-mark-size</code>, <code>--brand-wordmark-size</code>, <code>--brand-tracking</code>, <code>--brand-ground</code>, <code>--signal-size</code>, <code>--signal-motion</code> and specimen measurement variables local to their owners. Do not turn every pixel or animation frame into a global API.</li>
        </ul></details>
      </section>
      <section class="css-section" aria-labelledby="css-render-title"><header class="section-head"><h2 id="css-render-title">02 / Rendered style</h2><span class="eyebrow">Actual shared selectors / fictional content</span></header>
        <div class="css-render-grid"><div class="css-specimen"><p class="eyebrow">A01 / Personal / Gmail</p><h3>A quiet place to read.</h3><p class="css-reading">The landscape stays behind the work. A clear heading, readable copy and a fine rule are enough to give the ordinary details their place.</p><p class="badge" data-tone="success">${window.MonolithViews.signal('healthy')}Calendar read succeeded · sample</p><div class="row"><button class="button primary" type="button" data-dialog="example">Save selection</button><button class="button" type="button" data-dialog="example">Refresh status</button><a class="text-link" href="#/components">Inspect components</a></div></div>
        <div class="css-specimen"><div class="field"><label for="css-sample-field">Workspace name / specimen</label><input id="css-sample-field" value="Studio" aria-describedby="css-field-help"><small id="css-field-help">Editable locally. Nothing is saved or sent.</small></div><div class="field"><label for="css-invalid-field">Invalid field / specimen</label><input id="css-invalid-field" value="" aria-invalid="true" aria-describedby="css-invalid-help"><small class="error" id="css-invalid-help">Enter a workspace name.</small></div><button class="button" type="button" disabled aria-describedby="css-disabled-help">Save selection</button><p id="css-disabled-help" class="css-caption">Unavailable while this sample account needs reconnection.</p></div></div>
      </section>
      <section class="css-section" aria-labelledby="css-token-title"><header class="section-head"><h2 id="css-token-title">03 / Complete token legend</h2><span class="eyebrow">Declared CSS → active computed value</span></header>
        <div class="css-toolbar"><div class="field"><label for="css-token-search">Find a token or usage</label><input id="css-token-search" type="search" placeholder="Try focus, reading, space…"></div></div>
        <p id="css-token-status" class="css-inset css-caption" role="status">Loading the annotated token source…</p><div id="css-token-groups"></div>
        <details class="css-inset"><summary>Scoped variables and output overrides / live stylesheet inventory</summary><p class="css-caption">These declarations are local presets, specimen knobs, artwork controls or accessibility overrides—not additional global foundations. Selectors and conditions below come from the loaded stylesheets, including the six canonical signal sources.</p><div id="css-local-vars" class="css-table-wrap" tabindex="0" role="region" aria-label="Scoped CSS variable inventory"></div></details>
      </section>
      <section class="css-section" aria-labelledby="css-source-title"><header class="section-head"><h2 id="css-source-title">04 / CSS source</h2><span class="eyebrow">The stylesheet itself / no copied snippets</span></header><div class="css-inset"><div class="field"><label for="css-source-picker">Stylesheet</label><select id="css-source-picker">${sources.map(([file,label]) => `<option value="${file}">${file} / ${label}</option>`).join('')}</select></div><p class="css-caption">Load order: tokens → shared primitives → component specimens → voice → identity composition → this reference. Output-mode overrides remain with their selectors. The six signal SVGs own their embedded motion CSS; inspect or download them in Components.</p><p id="css-source-status" role="status"></p><pre class="css-source" tabindex="0" aria-label="Selected CSS source"><code id="css-source-code"></code></pre></div></section>
    </article>`;
  }
  function element(tag, text, className) {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
  }
  function table(headers) {
    const node = element('table');
    const row = node.createTHead().insertRow();
    headers.forEach(text => { const th = element('th',text); th.scope='col'; row.append(th); });
    node.createTBody();
    return node;
  }
  function mount(root) {
    if (!root.querySelector('.css-sheet')) return () => {};
    const controller = new AbortController();
    const {signal} = controller;
    const status = root.querySelector('#css-token-status');
    const groupsNode = root.querySelector('#css-token-groups');
    const search = root.querySelector('#css-token-search');
    const picker = root.querySelector('#css-source-picker');
    const sourceCode = root.querySelector('#css-source-code');
    const sourceStatus = root.querySelector('#css-source-status');
    let entries = [];
    let groups = [];
    let sourceVersion = 0;
    let legendReady = false;
    function update() {
      if (!legendReady) return;
      const computed = getComputedStyle(document.body);
      const query = search.value.trim().toLowerCase();
      let shown = 0;
      for (const entry of entries) {
        const value = computed.getPropertyValue(entry.name).trim();
        entry.current.textContent = value || 'Not set in this context';
        entry.row.hidden = !`${entry.name} ${entry.usage} ${entry.group} ${entry.value}`.toLowerCase().includes(query);
        if (!entry.row.hidden) shown++;
      }
      groups.forEach(({section,rows}) => { section.hidden = rows.every(entry=>entry.row.hidden); });
      status.textContent = `${shown} of ${entries.length} declarations · Charcoal · computed values reflect the active output mode.`;
    }
    function showTokens(text) {
      const parsed = [];
      let group;
      for (const line of text.split('\n')) {
        const heading = line.match(/^\/\* @group (.+) \*\/$/);
        if (heading) { group = {name:heading[1],entries:[]}; parsed.push(group); }
        const token = line.match(/^\s*(--[\w-]+):\s*(.+?);\s*\/\* (.+) \*\/\s*$/);
        if (/^\s*--[\w-]+\s*:/.test(line) && (!token || !group)) throw new Error('A token is missing its group or usage annotation. Inspect tokens.css.');
        if (token && group) group.entries.push({name:token[1],value:token[2],usage:token[3],group:group.name});
      }
      if (!parsed.length || parsed.some(group=>!group.entries.length)) throw new Error('Token annotations are incomplete. Inspect tokens.css.');
      const fragment = document.createDocumentFragment();
      entries = []; groups = [];
      for (const group of parsed) {
        const section = element('section',undefined,'css-token-group');
        section.append(element('h3',group.name));
        const wrap = element('div',undefined,'css-table-wrap');
        wrap.tabIndex=0; wrap.setAttribute('role','region'); wrap.setAttribute('aria-label',`${group.name} tokens`);
        const grid = table(['Token / usage','Declared value','Active value']);
        for (const entry of group.entries) {
          const row=grid.tBodies[0].insertRow();
          const label=row.insertCell(); label.append(element('code',entry.name),element('p',entry.usage,'css-caption'));
          row.insertCell().append(element('code',entry.value));
          const current=element('code');
          const cell=row.insertCell();
          if (CSS.supports('color',getComputedStyle(document.body).getPropertyValue(entry.name).trim())) {
            const chip=element('i',undefined,'css-color-chip');
            chip.setAttribute('aria-hidden','true'); chip.style.backgroundColor=`var(${entry.name})`; cell.append(chip);
          }
          cell.append(current);
          entries.push(Object.assign(entry,{row,current}));
        }
        wrap.append(grid); section.append(wrap); fragment.append(section);
        groups.push({section,rows:group.entries});
      }
      groupsNode.replaceChildren(fragment);
      legendReady = true;
      update();
    }
    function inventory() {
      const grid=table(['Owner / condition','Local declaration']);
      function walk(rules, owner) {
        for (const rule of rules) {
          if (rule.style) for (const name of rule.style) if (name.startsWith('--')) {
            const row=grid.tBodies[0].insertRow();
            row.insertCell().append(element('code',`${owner} / ${rule.selectorText}`));
            row.insertCell().append(element('code',`${name}: ${rule.style.getPropertyValue(name).trim()}`));
          }
          if (rule.cssRules) walk(rule.cssRules,`${owner} / ${rule.conditionText || rule.name || 'group'}`);
        }
      }
      for (const sheet of document.styleSheets) {
        if (sheet.href?.endsWith('/tokens.css')) continue;
        const owner=sheet.href ? new URL(sheet.href).pathname.split('/').pop() : 'Inline signal artwork';
        walk(sheet.cssRules,owner);
      }
      root.querySelector('#css-local-vars').replaceChildren(grid);
    }
    async function showSource() {
      const version=++sourceVersion;
      sourceCode.textContent=''; sourceStatus.textContent=`Loading ${picker.value}…`;
      try {
        const text=await source(picker.value,signal);
        if (signal.aborted || version!==sourceVersion) return;
        sourceCode.textContent=text;
        sourceStatus.textContent=`${picker.value} · ${text.split('\n').length} lines · read directly from the served file`;
      } catch (error) {
        if (signal.aborted || version!==sourceVersion) return;
        sourceStatus.textContent=`${error.message} `;
        const retry=element('button','Retry stylesheet','button'); retry.type='button';
        retry.addEventListener('click',showSource,{once:true,signal}); sourceStatus.append(retry);
      }
    }
    async function loadTokens() {
      legendReady = false;
      status.textContent='Loading the annotated token source…';
      try {
        const text=await source('tokens.css',signal);
        if (signal.aborted) return;
        showTokens(text); inventory();
      } catch (error) {
        if (signal.aborted) return;
        legendReady = false;
        status.textContent=`${error.message} `;
        const retry=element('button','Retry token legend','button'); retry.type='button';
        retry.addEventListener('click',loadTokens,{once:true,signal}); status.append(retry);
      }
    }
    search.addEventListener('input',update,{signal});
    picker.addEventListener('change',showSource,{signal});
    const forced=matchMedia('(forced-colors: active)');
    forced.addEventListener('change',update,{signal});
    window.addEventListener('beforeprint',update,{signal});
    window.addEventListener('afterprint',update,{signal});
    loadTokens(); showSource();
    return () => controller.abort();
  }
  return {view,mount};
})();
