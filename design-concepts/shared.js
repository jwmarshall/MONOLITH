'use strict';
(() => {
  const body = document.body;
  const gate = document.getElementById('gate');
  const app = document.getElementById('app');
  const enter = document.getElementById('enter');
  const brand = document.getElementById('brand');
  const stroke = document.getElementById('brand-stroke');
  const letters = [...brand.querySelectorAll('.wordmark span')];
  const resume = document.getElementById('resume');
  const dialog = document.getElementById('detail-dialog');
  const content = document.getElementById('dialog-content');
  const motion = matchMedia('(prefers-reduced-motion: reduce)');
  let animations = [];
  let sequence = 0;
  let entered = false;
  let lastFocus = null;
  let opener = null;
  let lastActivity = Date.now();
  let idleTimer;
  const state = () => body.dataset.state;
  const stopAnimations = () => {
    animations.forEach(animation => animation.cancel());
    animations = [];
  };
  function setState(next) {
    body.dataset.state = next;
    gate.hidden = next === 'home' || next === 'scenery';
    gate.inert = next !== 'locked';
    app.inert = next !== 'home';
    resume.inert = next !== 'scenery';
    if (next !== 'home') clearTimeout(idleTimer);
  }
  function activity() {
    lastActivity = Date.now();
    clearTimeout(idleTimer);
    if (state() === 'home') idleTimer = setTimeout(scenery, 180000);
  }
  function finish() {
    sequence++;
    stopAnimations();
    entered = true;
    setState('home');
    document.getElementById('home-title').focus({preventScroll: true});
    activity();
  }
  function animate(element, frames, options) {
    const animation = element.animate(frames, {...options, fill: 'both'});
    animations.push(animation);
    return animation.finished.catch(() => {});
  }
  async function unlock() {
    if (state() !== 'locked') return;
    setState('entering');
    enter.blur();
    const token = ++sequence;
    if (motion.matches) return finish();
    const length = stroke.getTotalLength();
    stroke.style.strokeDasharray = String(length);
    const trace = animate(stroke, [{strokeDashoffset: length}, {strokeDashoffset: 0}], {duration: 1350, delay: 200, easing: 'cubic-bezier(.65,0,.35,1)'});
    const flips = letters.map((letter, index) => animate(letter, [{opacity: 0, transform: 'translateY(60%) rotateX(-90deg)'}, {opacity: 1, transform: 'translateY(0) rotateX(0deg)'}], {duration: 600, delay: 1350 + index * 85, easing: 'cubic-bezier(.16,1,.3,1)'}));
    await Promise.all([trace, ...flips]);
    if (token !== sequence) return;
    await animate(brand, [{opacity: 1}, {opacity: 1}], {duration: 250});
    if (token !== sequence) return;
    const exits = letters.map((letter, index) => animate(letter, [{opacity: 1, transform: 'translateY(0) rotateX(0deg)'}, {opacity: 0, transform: 'translateY(-60%) rotateX(90deg)'}], {duration: 600 / 1.8, delay: index * 85 / 1.8, easing: 'cubic-bezier(.7,0,.84,0)'}));
    const erase = animate(stroke, [{strokeDashoffset: 0}, {strokeDashoffset: -length}], {duration: 1350 / 1.8, delay: 550, easing: 'cubic-bezier(.65,0,.35,1)'});
    await Promise.all([...exits, erase]);
    if (token === sequence) finish();
  }
  function reset() {
    sequence++;
    stopAnimations();
    if (dialog.open) dialog.close();
    entered = false;
    lastFocus = null;
    setState('locked');
    enter.focus({preventScroll: true});
  }
  function scenery() {
    if (state() !== 'home' || dialog.open) return;
    lastFocus = document.activeElement;
    setState('scenery');
    resume.focus({preventScroll: true});
  }
  function wake() {
    if (state() !== 'scenery' || !entered) return;
    setState('home');
    if (lastFocus?.isConnected && lastFocus !== document.body) lastFocus.focus({preventScroll: true});
    else document.getElementById('home-title').focus({preventScroll: true});
    activity();
  }
  function openDetails(button) {
    const template = document.getElementById(button.dataset.open);
    if (!(template instanceof HTMLTemplateElement)) return;
    if (!dialog.open) opener = button;
    content.replaceChildren(template.content.cloneNode(true));
    if (!dialog.open) dialog.showModal();
    dialog.querySelector('[data-close]').focus();
  }
  enter.addEventListener('click', unlock);
  resume.addEventListener('click', wake);
  document.addEventListener('click', event => {
    const target = event.target.closest('button, a');
    if (!target) return;
    if (target.matches('[data-replay]')) reset();
    else if (target.matches('[data-scenery]')) scenery();
    else if (target.matches('[data-close]')) dialog.close();
    else if (target.matches('[data-open]')) openDetails(target);
    else if (target.matches('[data-filter]')) {
      const value = target.dataset.filter;
      document.querySelectorAll('[data-filter]').forEach(button => button.setAttribute('aria-pressed', String(button === target)));
      document.querySelectorAll('[data-account]').forEach(row => { row.hidden = value !== 'all' && row.dataset.account !== value; });
    }
  });
  dialog.addEventListener('close', () => {
    if (state() === 'home' && opener?.isConnected) opener.focus({preventScroll: true});
    opener = null;
    activity();
  });
  document.addEventListener('keydown', event => {
    if (dialog.open) return;
    if (event.key === 'Escape') {
      if (state() === 'entering') reset();
      else if (state() === 'home') scenery();
      return;
    }
    if (state() === 'scenery' && !event.metaKey && !event.ctrlKey && !event.altKey && !['Shift', 'Control', 'Alt', 'Meta'].includes(event.key)) wake();
    activity();
  });
  document.addEventListener('pointerdown', () => {
    if (state() === 'scenery') wake();
    activity();
  }, {passive: true});
  ['wheel', 'touchmove', 'scroll'].forEach(type => document.addEventListener(type, activity, {passive: true}));
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && state() === 'home' && Date.now() - lastActivity >= 180000) scenery();
  });
  motion.addEventListener('change', () => { if (motion.matches && state() === 'entering') finish(); });
  setState('locked');
})();
