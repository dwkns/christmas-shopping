// Inline SVG drawings for the install guide. Colours come from CSS classes in style.css,
// so the drawings follow light and dark mode.
window.InstallIllustrations = (() => {
  const svg = (body) => `<svg class="ill" viewBox="0 0 280 168" role="img" aria-hidden="true">${body}</svg>`;
  // App icon: red rounded square with a white tree.
  const icon = (x, y, s = 40) => `
    <g transform="translate(${x} ${y}) scale(${s / 512})">
      <rect width="512" height="512" rx="112" class="ill-red"/>
      <path d="M256 96 L356 236 H310 L386 336 H326 L406 426 H106 L186 336 H126 L202 236 H156 Z" fill="#fff"/>
      <circle cx="256" cy="86" r="22" fill="#ffd60a"/>
    </g>`;
  const ring = (cx, cy, r) => `<circle cx="${cx}" cy="${cy}" r="${r}" class="ill-ring"/>`;
  const box = (x, y, w, h) => `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="10" class="ill-ring"/>`;
  const finger = (x, y) => `<g transform="translate(${x} ${y})"><circle r="11" class="ill-touch"/><circle r="5" class="ill-touch-core"/></g>`;
  const lines = (x, y, n, w = 160) => Array.from({ length: n }, (_, i) =>
    `<rect x="${x}" y="${y + i * 14}" width="${w - (i % 3) * 30}" height="7" rx="3.5" class="ill-line"/>`).join("");
  const shareGlyph = (x, y, cls = "ill-blue-s") => `<path transform="translate(${x} ${y})" d="M0 -9v13m0-13-4.5 4.5M0 -9l4.5 4.5M-6.5 -1h-1.5v10h16v-10h-1.5" fill="none" class="${cls}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`;
  const plusSquare = (x, y) => `<g transform="translate(${x} ${y})"><rect x="-8" y="-8" width="16" height="16" rx="4" fill="none" class="ill-text-s" stroke-width="1.8"/><path d="M0 -4v8M-4 0h8" class="ill-text-s" stroke-width="1.8" stroke-linecap="round"/></g>`;
  const t = (x, y, s, txt, cls = "ill-text", w = 400, anchor = "start") =>
    `<text x="${x}" y="${y}" font-size="${s}" font-weight="${w}" text-anchor="${anchor}" class="${cls}">${txt}</text>`;

  // 1. Safari toolbar with the Share button.
  const share = svg(`
    <rect x="20" y="8" width="240" height="152" rx="18" class="ill-card"/>
    ${lines(40, 28, 5, 170)}
    <rect x="20" y="110" width="240" height="50" rx="0" class="ill-bar"/>
    <rect x="20" y="140" width="240" height="20" rx="18" class="ill-bar"/>
    <path d="M52 128l-7 7 7 7" fill="none" class="ill-blue-s" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="M90 128l7 7-7 7" fill="none" class="ill-dim-s" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>
    ${shareGlyph(140, 136)}
    <path d="M180 128h10a4 4 0 0 1 4 4v8M180 128h-6v14h20" fill="none" class="ill-blue-s" stroke-width="2"/>
    <rect x="218" y="127" width="15" height="15" rx="3" fill="none" class="ill-blue-s" stroke-width="2"/>
    ${ring(140, 134, 17)}
    ${finger(152, 148)}
  `);

  // 2. Share sheet with "Add to Home Screen".
  const addToHome = svg(`
    <rect x="20" y="8" width="240" height="152" rx="18" class="ill-bg2"/>
    <rect x="34" y="20" width="212" height="34" rx="10" class="ill-card"/>
    ${t(48, 42, 12, "Copy")}
    <rect x="34" y="62" width="212" height="88" rx="10" class="ill-card"/>
    ${t(48, 84, 12, "Add to Reading List")}
    <rect x="48" y="94" width="184" height="1" class="ill-line"/>
    ${t(48, 113, 12, "Add to Home Screen", "ill-text", 600)}
    ${plusSquare(222, 109)}
    <rect x="48" y="123" width="184" height="1" class="ill-line"/>
    ${t(48, 141, 12, "Edit Actions…", "ill-blue")}
    ${box(38, 96, 204, 26)}
    ${finger(196, 118)}
  `);

  // 3. "Add to Home Screen" confirmation with the Add button.
  const confirm = svg(`
    <rect x="20" y="8" width="240" height="152" rx="18" class="ill-bg2"/>
    ${t(36, 34, 12, "Cancel", "ill-blue")}
    ${t(140, 34, 12, "Add to Home Screen", "ill-text", 600, "middle")}
    ${t(244, 34, 12, "Add", "ill-blue", 700, "end")}
    ${ring(232, 30, 17)}
    <rect x="34" y="50" width="212" height="56" rx="10" class="ill-card"/>
    ${icon(44, 58, 40)}
    ${t(96, 76, 13, "Xmas List", "ill-text", 600)}
    ${t(96, 94, 10, "netlify.app", "ill-dim")}
    <rect x="34" y="114" width="212" height="34" rx="10" class="ill-card"/>
    ${t(48, 135, 12, "Open as Web App")}
    <rect x="206" y="122" width="30" height="18" rx="9" class="ill-green"/>
    <circle cx="227" cy="131" r="7" fill="#fff"/>
    ${finger(244, 44)}
  `);

  // 4. App Library: touch and hold the icon, choose "Add to Home Screen".
  const tile = (x, y, cls) => `<rect x="${x}" y="${y}" width="22" height="22" rx="6" class="${cls}"/>`;
  const appLibrary = svg(`
    <rect x="20" y="8" width="240" height="152" rx="18" class="ill-bg2"/>
    <rect x="34" y="18" width="212" height="22" rx="11" class="ill-card"/>
    ${t(140, 33, 10, "App Library", "ill-dim", 500, "middle")}
    <rect x="34" y="50" width="62" height="62" rx="14" class="ill-card"/>
    ${tile(40, 56, "ill-t1")}${tile(68, 56, "ill-t2")}${tile(40, 84, "ill-t3")}${tile(68, 84, "ill-t4")}
    <rect x="34" y="118" width="62" height="34" rx="14" class="ill-card"/>
    ${tile(40, 124, "ill-t2")}${tile(68, 124, "ill-t1")}
    <rect x="104" y="50" width="62" height="62" rx="14" class="ill-card"/>
    ${icon(110, 56, 22)}${tile(138, 56, "ill-t3")}${tile(110, 84, "ill-t4")}${tile(138, 84, "ill-t1")}
    ${ring(121, 67, 15)}
    <rect x="144" y="62" width="120" height="74" rx="12" class="ill-menu"/>
    ${t(152, 82, 10, "Add to Home Screen", "ill-text", 600)}
    <rect x="152" y="90" width="104" height="1" class="ill-line"/>
    ${t(152, 106, 10, "Share App")}
    <rect x="152" y="114" width="104" height="1" class="ill-line"/>
    ${t(152, 128, 10, "Delete App", "ill-danger")}
    ${box(147, 67, 114, 22)}
    ${finger(121, 78)}
  `);

  // 5. Home Screen with the icon.
  const app = (x, y, cls) => `<rect x="${x}" y="${y}" width="34" height="34" rx="9" class="${cls}"/>`;
  const homeScreen = svg(`
    <rect x="20" y="8" width="240" height="152" rx="18" class="ill-wall"/>
    ${app(44, 22, "ill-t1")}${app(94, 22, "ill-t2")}${app(144, 22, "ill-t3")}${app(194, 22, "ill-t4")}
    ${app(44, 72, "ill-t3")}${app(94, 72, "ill-t4")}${icon(144, 72, 34)}${app(194, 72, "ill-t2")}
    ${t(161, 120, 9, "Xmas List", "ill-white", 600, "middle")}
    ${ring(161, 89, 23)}
    ${finger(170, 100)}
    <rect x="34" y="130" width="212" height="22" rx="11" class="ill-dock"/>
  `);

  // Android: browser ⋮ menu.
  const androidMenu = svg(`
    <rect x="20" y="8" width="240" height="152" rx="18" class="ill-card"/>
    <rect x="20" y="8" width="240" height="36" rx="18" class="ill-bar"/>
    <rect x="36" y="18" width="170" height="16" rx="8" class="ill-line"/>
    <g class="ill-text-f"><circle cx="234" cy="19" r="2.2"/><circle cx="234" cy="26" r="2.2"/><circle cx="234" cy="33" r="2.2"/></g>
    ${ring(234, 26, 13)}
    ${lines(40, 60, 6, 170)}
    ${finger(244, 38)}
  `);

  // Android: Install app.
  const androidInstall = svg(`
    <rect x="20" y="8" width="240" height="152" rx="18" class="ill-card"/>
    ${lines(36, 26, 8, 120)}
    <rect x="120" y="14" width="132" height="120" rx="10" class="ill-menu"/>
    ${t(134, 38, 11, "New tab")}
    ${t(134, 62, 11, "Bookmarks")}
    ${t(134, 86, 11, "Install app", "ill-text", 600)}
    ${t(134, 110, 11, "Settings")}
    ${box(124, 70, 124, 24)}
    ${finger(222, 90)}
  `);

  return { share, addToHome, confirm, appLibrary, homeScreen, androidMenu, androidInstall };
})();
