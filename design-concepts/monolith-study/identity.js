'use strict';
/* Original authored MONOLITH mark. Static design study only. */
window.MonolithIdentity = (() => {
  const logo = {
    name:'MONOLITH mark',
    description:'A planar strip changes direction around a narrow crease. Square edges and an open underside give the outline volume without adding shading.',
    path:'M20 64L50 20H82L52 64ZM20 64L52 84L82 40V20M52 64V84',
    drawing:{outline:['M52 84L20 64L50 20H66','M52 84L82 40V20H66'],inner:['M82 20L52 64L20 64','M52 64V84']}
  };
  const mark = (className = '') => `<svg class="monolith-mark ${className}" viewBox="0 0 104 104" fill="none" aria-hidden="true"><path d="${logo.path}"/></svg>`;
  const inverseMark = (className = '', cutoutId = '') => {
    const silhouette = 'M20 64L50 20H82V40L52 84Z';
    const creases = 'M20 64H52L82 20M52 64V84';
    return `<svg class="monolith-mark monolith-mark--inverse ${className}" viewBox="0 0 104 104" aria-hidden="true">${cutoutId?`<defs><mask id="${cutoutId}" maskUnits="userSpaceOnUse" x="0" y="0" width="104" height="104" style="mask-type:luminance;forced-color-adjust:none"><rect width="104" height="104" fill="#fff"/><path d="${creases}" fill="none" style="stroke:#000"/></mask></defs>`:''}<path class="inverse-face" d="${silhouette}"${cutoutId?` mask="url(#${cutoutId})"`:''}/>${cutoutId?'':`<path class="inverse-crease" d="${creases}" fill="none"/>`}</svg>`;
  };
  const drawingPaths = layer => logo.drawing[layer].map(path=>`<path class="draw-path" pathLength="1" d="${path}"/>`).join('');
  function entranceMark(solid = false, id = 'motion-solid') {
    if (!solid) return `<svg class="monolith-mark" viewBox="0 0 104 104" fill="none" aria-hidden="true"><g data-layer="outline">${drawingPaths('outline')}</g><g data-layer="inner">${drawingPaths('inner')}</g></svg>`;
    return `<svg class="monolith-mark monolith-mark--inverse" viewBox="0 0 104 104" aria-hidden="true"><defs style="forced-color-adjust:none"><clipPath id="${id}-rise"><rect data-reveal width="104" height="104"/></clipPath><mask id="${id}-incise" maskUnits="userSpaceOnUse" x="0" y="0" width="104" height="104" style="mask-type:luminance"><rect width="104" height="104" fill="#fff"/><g data-layer="inner" class="motion-incisions">${drawingPaths('inner')}</g></mask></defs><g clip-path="url(#${id}-rise)"><path class="inverse-face" d="M20 64L50 20H82V40L52 84Z" mask="url(#${id}-incise)"/></g></svg>`;
  }
  // Both the full-screen unlock and the inline proof use this exact choreography.
  async function playEntrance(lockup, animate, current) {
    const svg = lockup.querySelector('svg');
    const letters = [...lockup.querySelectorAll('.wordmark span')];
    const trace = (path,duration,delay) => animate(path,[{strokeDashoffset:1,opacity:0},{strokeDashoffset:1,opacity:1,offset:.001},{strokeDashoffset:0,opacity:1}],{duration,delay,easing:'cubic-bezier(.45,0,.2,1)'});
    const reveal = svg.querySelector('[data-reveal]');
    await Promise.all([
      ...(reveal ? [animate(reveal,[{transform:'translateY(104px)'},{transform:'translateY(0)'}],{duration:1600,delay:180,easing:'cubic-bezier(.45,0,.2,1)'})] : [...svg.querySelectorAll('[data-layer=outline] path')].map(path=>trace(path,1600,180))),
      ...[...svg.querySelectorAll('[data-layer=inner] path')].map((path,index)=>trace(path,index?500:1100,index?1850:1100)),
      ...letters.map((letter,index)=>animate(letter,[{opacity:0,transform:'translateY(60%) rotateX(-90deg)'},{opacity:1,transform:'translateY(0) rotateX(0deg)'}],{duration:600,delay:2600+index*85,easing:'cubic-bezier(.16,1,.3,1)'}))
    ]);
    if (!current()) return;
    await animate(lockup,[{opacity:1},{opacity:1}],{duration:360});
    if (!current()) return;
    await Promise.all([
      animate(svg,[{opacity:1,transform:'translateY(0)'},{opacity:0,transform:'translateY(-12px)'}],{duration:900,delay:150,easing:'cubic-bezier(.65,0,.35,1)'}),
      ...letters.map((letter,index)=>animate(letter,[{opacity:1,transform:'translateY(0) rotateX(0deg)'},{opacity:0,transform:'translateY(-60%) rotateX(90deg)'}],{duration:600/1.8,delay:index*85/1.8,easing:'cubic-bezier(.7,0,.84,0)'}))
    ]);
  }
  function motionStage() {
    return `<section class="identity-motion" aria-labelledby="identity-motion-title">
      <header class="section-head"><div><p class="eyebrow">Identity / unlock motion</p><h2 id="identity-motion-title">One entrance. Two treatments.</h2></div><span class="eyebrow">Manual replay / no loop</span></header>
      <div class="identity-motion-controls">
        <label for="motion-treatment">Treatment<select id="motion-treatment"><option value="outline">Outline</option><option value="solid">Solid</option></select></label>
        <label for="motion-polarity">Polarity<select id="motion-polarity"><option value="dark">Light on dark</option><option value="light">Dark on light</option></select></label>
        <button type="button" class="button primary" id="motion-play">Replay unlock animation</button>
        <button type="button" class="button" id="motion-stop" disabled>Stop animation</button>
      </div>
      <div id="identity-motion-stage" class="identity-motion-stage identity-logo-proof--dark" data-state="ready" role="img" aria-label="MONOLITH outline unlock animation, light on dark">
        <div class="identity-motion-lockup brand-lockup">${mark()}<span class="brand-wordmark" aria-hidden="true">MONOLITH</span></div>
      </div>
      <p id="motion-status" class="identity-motion-status" role="status">Ready. Choose a treatment and replay; nothing plays automatically.</p>
      <div class="identity-motion-notes"><div><h3>Outline / opposing strokes</h3><p>The contour rises from the bottom point. The creases descend from the top corner. The complete mark rests before the wordmark turns into place.</p></div><div><h3>Solid / rise and incise</h3><p>The silhouette reveals from bottom to top as the negative-space creases descend. Both polarities use the same timing, pause, wordmark and lift-away exit. No shading or moving faces.</p></div><p>About 5.2 seconds per replay. Escape or Stop restores the complete mark. Changing treatment or polarity stops playback. Reduced motion and print show the completed identity. This stage previews motion only; it does not authenticate or open storage. The full unlock screen retains the outline treatment.</p></div>
    </section>`;
  }
  function threshold({gate=false,error=false} = {}) {
    return `<div class="threshold-body">
        <div class="threshold-meta"><span>Private workspace</span><span>Locked</span></div>
        <div class="threshold-center">
          <div class="threshold-lockup brand-lockup">${mark()}<h1 id="${gate?'gate-title':'view-title'}" class="brand-wordmark" tabindex="-1">MONOLITH</h1></div>
          <p class="threshold-intro">Preview the transition into the workspace.</p>
          ${error?'<div class="notice" data-tone="error" role="status"><strong>Couldn’t unlock MONOLITH.</strong><p>Check your owner password and try again. No protected content has been opened.</p></div>':''}
          <div class="threshold-access"><div class="field"><span id="${gate?'gate':'owner'}-password-label">Owner password</span><div class="masked-field" role="img" aria-labelledby="${gate?'gate':'owner'}-password-label" aria-describedby="${gate?'gate':'owner'}-password-note">••••••••••••<span aria-hidden="true">↗</span></div><small id="${gate?'gate':'owner'}-password-note">Non-editable specimen. Do not enter a real password.</small></div>
          <button ${gate?'id="enter"':'data-action="unlock-demo"'} class="button primary threshold-enter">Preview unlock <span aria-hidden="true">↗</span></button>
          <p class="threshold-recovery">No password recovery in the product.<br>This preview does not authenticate or open a vault.</p></div>
        </div>
        <div class="threshold-bottom"><a class="text-link" href="#/identity">View the identity guide <span aria-hidden="true">↗</span></a></div>
      </div>`;
  }
  function identity() {
    return `<header class="view-head"><div><p class="eyebrow">MONOLITH / Identity</p><h1 id="view-title" tabindex="-1">A different<br> kind of solid.</h1><p class="lede">One mark. Two opposing gestures. An ascending contour, descending creases and a deliberate wordmark entrance.</p></div><a class="button primary" href="#/unlock">Open the unlock screen <span aria-hidden="true">↗</span></a></header>
      <section class="identity-selected" aria-labelledby="identity-mark-title">
        <div class="identity-selected-copy">
          <div class="identity-mark-intro"><p class="eyebrow">Identity / Outline and Solid</p><h2 id="identity-mark-title">The MONOLITH mark</h2><p>${logo.description}</p></div>
          <div class="identity-mark-details"><p>Outline and Solid describe treatments, not different identities. Solid artwork fills the same silhouette with the foreground color; its inner creases match the neutral proof background or cut through to scenery in the compact sidebar. Both polarities retain the shared lockup geometry. Each card below pairs the display lockup with its 24px, 32px and 48px icon proofs. Light and dark are artwork-reproduction proofs, not interface themes; the working interface stays Charcoal.</p><div class="row"><button type="button" class="button" id="motion-jump">Explore unlock motion</button><button class="text-link identity-download" data-action="download-logo">Download outline SVG</button></div><a class="text-link" href="#/home">See the architectural Home <span aria-hidden="true">↗</span></a></div>
        </div>
        <div class="identity-selected-mark">
          ${[['dark','Light on dark'],['light','Dark on light']].map(([tone,label],index)=>`<figure class="identity-logo-proof identity-logo-proof--outline identity-logo-proof--${tone}"><div class="brand-lockup" role="img" aria-label="MONOLITH outline mark, ${label.toLowerCase()}">${mark()}<span class="brand-wordmark" aria-hidden="true">MONOLITH</span></div><figcaption>0${index+1} / Outline <span>${label}</span></figcaption><div class="identity-proof-sizes" role="group" aria-label="Outline icon sizes, ${label.toLowerCase()}">${[24,32,48].map(size=>`<span>${mark(`size-${size}`)}<small>${size}px</small></span>`).join('')}</div></figure>`).join('')}
          ${[['dark','Light on dark'],['light','Dark on light']].map(([tone,label],index)=>`<figure class="identity-logo-proof identity-logo-proof--${tone}"><div class="brand-lockup" role="img" aria-label="MONOLITH solid mark, ${label.toLowerCase()}">${inverseMark()}<span class="brand-wordmark" aria-hidden="true">MONOLITH</span></div><figcaption>0${index+3} / Solid <span>${label}</span></figcaption><div class="identity-proof-sizes" role="group" aria-label="Solid icon sizes, ${label.toLowerCase()}">${[24,32,48].map(size=>`<span>${inverseMark(`size-${size}`)}<small>${size}px</small></span>`).join('')}</div></figure>`).join('')}
        </div>
      </section>
      <section class="identity-system" aria-labelledby="identity-token-title">
        <header class="section-head"><div><p class="eyebrow">Identity / specification</p><h2 id="identity-token-title">Fixed lockups / shared tokens</h2></div><a class="identity-system-source text-link" href="#/css">tokens.css / foundations<br>identity.css / composition</a></header>
        <p class="identity-system-intro">Two approved lockups. Fixed geometry. Layout can reflow; the identity never shrinks, wraps or changes tracking.</p>
        <div class="identity-preset-grid">
          <article class="identity-preset"><header><span class="eyebrow">01 / Display</span><h3>The signature.</h3><p>Identity · Components · Unlock · Entrance</p></header><div class="identity-preset-preview brand-lockup" role="img" aria-label="Display lockup">${mark()}<span class="brand-wordmark" aria-hidden="true">MONOLITH</span></div><code>.brand-lockup</code><dl><div><dt>Mark <code>--brand-display-mark-size</code></dt><dd>104px</dd></div><div><dt>Wordmark <code>--brand-display-wordmark-size</code></dt><dd>24px</dd></div><div><dt>Tracking <code>--brand-display-tracking</code></dt><dd>0.22em</dd></div><div><dt>Stacked gap <code>--brand-display-gap</code></dt><dd>24px</dd></div></dl></article>
          <article class="identity-preset"><header><span class="eyebrow">02 / Compact</span><h3>The masthead.</h3><p>Solid sidebar mark · 44px icon button target</p></header><div class="identity-preset-preview"><div class="brand-lockup brand-lockup--compact" role="img" aria-label="Compact lockup with solid mark">${inverseMark('', 'identity-compact-cutout')}<span class="brand-wordmark" aria-hidden="true">MONOLITH</span></div></div><code>.brand-lockup--compact</code><dl><div><dt>Mark <code>--brand-compact-mark-size</code></dt><dd>32px</dd></div><div><dt>Wordmark <code>--brand-compact-wordmark-size</code></dt><dd>15px</dd></div><div><dt>Tracking <code>--brand-compact-tracking</code></dt><dd>0.16em</dd></div><div><dt>Horizontal gap <code>--brand-compact-gap</code></dt><dd>10px</dd></div></dl></article>
        </div>
        <div class="identity-foundations"><div><p class="eyebrow">Shared foundations</p><h3>Same DNA. Every size.</h3><p>Use <code>.brand-wordmark</code> inside the approved lockup. The compact sidebar keeps its 44px button target around the 32px icon; the 10px gap starts at that target’s edge.</p></div><dl><div><dt>Typeface <code>--brand-font-family</code></dt><dd>Space Grotesk <small>Locally hosted</small></dd></div><div><dt>Weight / line-height <code>--brand-font-weight / --brand-line-height</code></dt><dd>500 / 1.2</dd></div><div><dt>Stroke <code>--brand-stroke-width</code></dt><dd>2.4 <small>SVG units · square caps</small></dd></div><div><dt>Clear space <code>--brand-clear-space</code></dt><dd>16px <small>Minimum outside display lockups</small></dd></div><div><dt>Icon-only scale <code>--brand-icon-small / medium / large</code></dt><dd>24 / 32 / 48px</dd></div><div><dt>Solid color pair <code>--brand-proof-dark / --brand-proof-light</code></dt><dd>Foreground fill <small>Inner creases match the proof background</small></dd></div></dl></div>
        <footer class="identity-system-rules"><div><span class="eyebrow">Keep fixed</span><p>Proportions, weight, tracking, clear space and the SVG safe field. Motion reveals the artwork without deforming its planes; completed geometry matches the static display lockup.</p></div><div><span class="eyebrow">Never override</span><p>No viewport-based type, extra letter gaps, synthetic weights, stretched geometry or page-specific brand sizing. Ordinary product-name mentions remain reading text, not wordmarks.</p></div></footer>
      </section>
      <section class="identity-rules"><div><p class="eyebrow">01 / Construction</p><h2>One shape. Two treatments.</h2><p>104-unit square. A fine 2.4-unit stroke with square caps defines the outline. Solid reproduction fills the outer silhouette in the foreground color and cuts the same inner creases into it. No gradients, shading, borrowed monograms or decorative containers. Preserve the built-in safe field and 16px display clear space.</p></div><div><p class="eyebrow">02 / Motion</p><h2>Two opposing gestures.</h2><p>The outline contour or solid silhouette rises from the bottom point. Interior creases descend from the top corner and branch toward the base. The completed mark rests before eight MONOLITH letters turn into place, then lifts and fades. Use the inline stage to compare both treatments and polarities. Reduced motion shows the complete identity without choreography.</p></div><div><p class="eyebrow">03 / Use</p><h2>A name with structure.</h2><p>MONOLITH in uppercase for the identity. Ordinary sentence case for controls. Call the symbol the MONOLITH mark, with no separate name. It appears at the threshold and compact masthead; it never becomes a loading spinner or provider-health icon.</p></div></section>
      ${motionStage()}`;
  }
  return {logo,mark,inverseMark,entranceMark,playEntrance,threshold,identity};
})();
