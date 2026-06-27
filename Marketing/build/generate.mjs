// Generates 6 story-driven HyperFrames marketing videos for the Datadog Assistant:
// 3 narratives x 2 orientations (landscape 1920x1080, tiktok 1080x1920).
//
//   1. detect-triage        — catch the alert the moment it fires (menu + live metric)
//   2. impossible-to-ignore — banner + sound + critical modal escalation
//   3. alert-to-fix         — service context + deploy correlation + one-click actions
//
// One component design-system + one shared GSAP timeline per story; orientation is
// CSS-only so each story's landscape and TikTok cuts stay in lockstep. Audio (a
// synthesized music bed + bundled SFX) is mixed in at render via <audio> clips.
import { mkdirSync, writeFileSync, copyFileSync, rmSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");      // Marketing/
const BUILD_ASSETS = resolve(__dirname, "assets");
const GSAP = resolve(__dirname, "../../node_modules/gsap/dist/gsap.min.js");
const DUR = 16.5;

const ORIENTATIONS = [
  { key: "landscape", cls: "landscape", w: 1920, h: 1080 },
  { key: "tiktok", cls: "vertical", w: 1080, h: 1920 },
];

/* ------------------------------ shared markup ----------------------------- */
const appleSvg = `<svg viewBox="0 0 814 1000"><path fill="currentColor" d="M788 341c-6 4-109 62-109 190 0 148 130 200 134 201-1 3-21 71-69 141-43 61-88 122-156 122s-86-40-165-40c-77 0-104 41-167 41s-107-57-157-126C41 783 0 668 0 559c0-175 114-268 226-268 60 0 110 41 147 41 36 0 92-43 160-43 26 0 119 2 180 90zM554 159c32-38 54-90 54-143 0-7-1-15-2-21-51 2-112 34-149 77-29 33-56 85-56 138 0 8 1 16 2 19 3 1 8 1 13 1 46 0 104-31 138-71z"/></svg>`;
const battSvg = `<svg width="42" height="20" viewBox="0 0 26 13"><rect class="sym" x="1" y="1.5" width="20" height="10" rx="3" fill="none" stroke="currentColor" stroke-width="1.1"/><rect class="sym" x="2.6" y="3.1" width="14" height="6.8" rx="1.4"/><rect class="sym" x="22.4" y="4.5" width="1.7" height="4" rx=".8"/></svg>`;
const wifiSvg = `<svg width="26" height="20" viewBox="0 0 17 13"><path class="sym" d="M8.5 1.2C5.3 1.2 2.4 2.5 .4 4.6l1.3 1.3C3.4 4.1 5.8 3 8.5 3s5.1 1.1 6.8 2.9l1.3-1.3C14.6 2.5 11.7 1.2 8.5 1.2z"/><path class="sym" d="M8.5 5.1c-2 0-3.8.8-5.1 2.1l1.3 1.3C5.6 7.6 6.9 7 8.5 7s2.9.6 3.8 1.5l1.3-1.3C12.3 5.9 10.5 5.1 8.5 5.1z"/><circle class="sym" cx="8.5" cy="10.6" r="1.7"/></svg>`;
const searchSvg = `<svg width="22" height="20" viewBox="0 0 15 15"><circle cx="6.3" cy="6.3" r="4.6" fill="none" stroke="currentColor" stroke-width="1.3"/><line x1="9.7" y1="9.7" x2="13.4" y2="13.4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>`;
const ccSvg = `<svg width="24" height="20" viewBox="0 0 16 15"><rect x="1" y="2" width="14" height="4.6" rx="2.3" fill="none" stroke="currentColor" stroke-width="1.1"/><rect x="1" y="8.4" width="14" height="4.6" rx="2.3" fill="none" stroke="currentColor" stroke-width="1.1"/><circle class="sym" cx="5" cy="4.3" r="1.5"/><circle class="sym" cx="11" cy="10.7" r="1.5"/></svg>`;
const cursorSvg = `<svg class="curarrow" viewBox="0 0 24 24"><path d="M5 2 L5 19 L9.4 14.7 L12.4 21 L14.9 19.9 L11.9 13.8 L18.4 13.6 Z" fill="#fff" stroke="rgba(0,0,0,0.55)" stroke-width="1.2" stroke-linejoin="round"/></svg>`;

const dockApps = ["🧭", "📨", "📅", "🎵", "📷", "💬", "⚙️", "🗂"];
function dock() {
  return `<div id="dock">${dockApps.map((a) => `<span class="dapp">${a}</span>`).join("")}</div>`;
}

function stage(calmIcon) {
  // calmIcon true => menu-bar shows 🐶 calm + green dot; alert layer hidden until timeline flips it
  return `
      <div id="desktop">
        <div id="blob1" class="blob"></div>
        <div id="blob2" class="blob"></div>
        <div id="blob3" class="blob"></div>
        <div id="grain"></div>
        <div id="vignette"></div>
      </div>
      <div id="menubar">
        <span class="apple">${appleSvg}</span>
        <span class="appname">Finder</span>
        <span class="m">File</span><span class="m">Edit</span><span class="m">View</span><span class="m">Go</span>
        <span class="spacer"></span>
        <div class="status" id="status">
          <div class="ddwrap">
            <span class="ddicon" id="icon-calm">🐶</span>
            <span class="ddicon alert" id="icon-alert">‼️&nbsp;3</span>
          </div>
          ${battSvg}${wifiSvg}${searchSvg}${ccSvg}
          <span class="clock">Thu 11 Jun&nbsp;&nbsp;9:41 AM</span>
        </div>
      </div>
      ${dock()}
      <div id="flash"></div>`;
}

function caption(id, inAt, outAt, text, track) {
  const dur = (outAt + 0.45 - inAt).toFixed(2);
  return `      <div id="${id}" class="cap clip" data-start="${inAt}" data-duration="${dur}" data-track-index="${track}"><span class="pill">${text}</span></div>`;
}
function captionTweens(captions) {
  return captions
    .map(
      (c) => `      tl.from("#${c[0]}", { y: 30, opacity: 0, duration: 0.45, ease: "power3.out" }, ${c[1]});
      tl.to("#${c[0]}", { y: -18, opacity: 0, duration: 0.3, ease: "power2.in" }, ${c[2]});
      tl.set("#${c[0]}", { opacity: 0 }, ${(c[2] + 0.35).toFixed(2)});`
    )
    .join("\n");
}
function brand(title, start) {
  return `      <div id="brand" class="clip" data-start="${start.toFixed(2)}" data-duration="${(DUR - start).toFixed(2)}" data-track-index="14">
        <div class="bmark">🐶</div>
        <h1>${title}</h1>
        <div class="brow"><span class="bdot"></span>Datadog Assistant</div>
        <div class="burl">github.com/mxnyawi/datadog-assistant</div>
      </div>`;
}
function title(text, start = 0, dur = 3.0) {
  return `      <div id="title" class="clip" data-start="${start}" data-duration="${dur}" data-track-index="1">
        <div class="tmark">🐶</div>
        <h1>${text}</h1>
      </div>`;
}

/* sparkline (inline svg) for menu rows */
function miniSpark(points, cls = "") {
  return `<svg class="mspark ${cls}" viewBox="0 0 60 20" preserveAspectRatio="none"><polyline points="${points}" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/></svg>`;
}

/* big animated metric area chart for the context panel */
function metricGraph() {
  const pts = [
    [10, 102], [37, 98], [64, 92], [91, 94], [118, 85], [145, 87],
    [172, 72], [199, 65], [226, 52], [253, 40], [280, 30], [310, 23],
  ];
  const line = "M" + pts.map((p) => `${p[0]},${p[1]}`).join(" L");
  const area = line + " L310,120 L10,120 Z";
  return `
        <div class="graphwrap">
          <svg class="graph" viewBox="0 0 320 130" preserveAspectRatio="none">
            <defs>
              <linearGradient id="areaGrad" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stop-color="#ff6b6b" stop-opacity="0.55"/>
                <stop offset="100%" stop-color="#ff6b6b" stop-opacity="0.02"/>
              </linearGradient>
            </defs>
            <line class="thresh" x1="0" y1="30" x2="320" y2="30"/>
            <path id="gArea" class="garea" d="${area}"/>
            <path id="gLine" class="gline" d="${line}" pathLength="1"/>
            <circle id="gDot" class="gdot" cx="310" cy="23" r="5"/>
          </svg>
          <div class="threshlbl">crit 90</div>
          <div class="gval"><span id="gnum">0.0</span><span class="gunit">% CPU</span></div>
        </div>`;
}

/* ------------------------------ component CSS ----------------------------- */
const CSS = `
  * { margin:0; padding:0; box-sizing:border-box; -webkit-font-smoothing:antialiased; }
  html, body { overflow:hidden; background:#000; }
  body { font-family:"Inter","Helvetica Neue",system-ui,sans-serif; }
  #root { position:relative; overflow:hidden; color:#fff; }

  /* ---- desktop ---- */
  #desktop { position:absolute; inset:0;
    background:
      radial-gradient(60% 50% at 78% 8%, rgba(255,255,255,0.10) 0%, transparent 55%),
      radial-gradient(70% 55% at 82% 112%, #3a2080 0%, transparent 60%),
      radial-gradient(72% 62% at 12% 96%, #0f3a63 0%, transparent 58%),
      radial-gradient(55% 45% at 58% 32%, #4a1d96 0%, transparent 52%),
      linear-gradient(158deg, #0a0a1c 0%, #15203c 52%, #1a1430 100%); }
  .blob { position:absolute; border-radius:50%; opacity:0.55; }
  #blob1 { width:42%; aspect-ratio:1; left:-8%; bottom:-12%; background:radial-gradient(circle,#7a3ce8 0%,transparent 70%); }
  #blob2 { width:46%; aspect-ratio:1; right:-10%; top:-14%; background:radial-gradient(circle,#2569d8 0%,transparent 70%); }
  #blob3 { width:34%; aspect-ratio:1; left:40%; top:50%; background:radial-gradient(circle,#b14cd8 0%,transparent 72%); opacity:0.32; }
  #grain { position:absolute; inset:-50%; opacity:0.05; pointer-events:none;
    background-image:url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='120' height='120'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/></filter><rect width='100%25' height='100%25' filter='url(%23n)'/></svg>");
    background-size:240px 240px; }
  #vignette { position:absolute; inset:0; pointer-events:none;
    background:radial-gradient(120% 120% at 50% 45%, transparent 52%, rgba(0,0,0,0.55) 100%); }

  /* ---- menu bar ---- */
  #menubar { position:absolute; top:0; left:0; right:0; height:46px; z-index:50;
    display:flex; align-items:center; padding:0 22px; font-size:21px; font-weight:500;
    color:#fff; background:rgba(26,26,32,0.78); }
  #menubar .apple { width:19px; height:23px; margin-right:24px; color:#fff; }
  #menubar .apple svg { width:19px; height:23px; vertical-align:-4px; }
  #menubar .appname { font-weight:700; margin-right:24px; }
  #menubar .m { margin-right:24px; opacity:.92; }
  #menubar .spacer { flex:1; }
  #menubar .status { display:flex; align-items:center; gap:19px; font-weight:400; }
  #menubar .status .sym { fill:currentColor; }
  #menubar .clock { font-weight:400; letter-spacing:.2px; }
  .ddwrap { position:relative; width:78px; height:34px; }
  .ddicon { position:absolute; top:0; left:0; height:34px; padding:0 10px; border-radius:8px;
    font-weight:700; letter-spacing:.3px; display:flex; align-items:center; gap:5px;
    font-size:22px; white-space:nowrap; }
  #icon-alert { background:rgba(255,80,80,0.32); box-shadow:0 0 0 1px rgba(255,90,90,0.4); opacity:0; }

  /* ---- dock ---- */
  #dock { position:absolute; bottom:16px; left:50%; transform:translateX(-50%); height:74px;
    display:flex; align-items:center; gap:14px; padding:0 18px; border-radius:22px;
    background:rgba(46,46,56,0.55);
    border:1px solid rgba(255,255,255,0.18); box-shadow:0 18px 50px rgba(0,0,0,0.4); z-index:8; }
  .dapp { width:54px; height:54px; border-radius:14px; display:flex; align-items:center;
    justify-content:center; font-size:32px;
    background:linear-gradient(160deg,rgba(255,255,255,0.22),rgba(255,255,255,0.06));
    box-shadow:inset 0 1px 0 rgba(255,255,255,0.3), 0 6px 14px rgba(0,0,0,0.25); }

  /* ---- glass panels ---- */
  .panel { position:absolute; background:rgba(37,37,43,0.97);
    border-radius:18px; padding:10px; border:1px solid rgba(255,255,255,0.16);
    box-shadow:0 0 0 1px rgba(0,0,0,0.55), 0 28px 80px rgba(0,0,0,0.6); font-size:22px; color:#f4f4f6; z-index:20; }
  .mi { display:flex; align-items:center; gap:11px; padding:8px 15px; border-radius:10px;
    line-height:1.35; white-space:nowrap; overflow:hidden; }
  .mi .grow { flex:1; overflow:hidden; text-overflow:ellipsis; }
  .mi.header { font-weight:700; font-size:.78em; letter-spacing:.6px; color:rgba(255,255,255,0.5); padding:9px 15px 4px; }
  .mi.sumline { font-weight:600; }
  .mi.hi { background:linear-gradient(180deg,#2f78ef,#2569d8); color:#fff; box-shadow:0 4px 14px rgba(37,105,216,0.5); }
  .mi.dim { color:rgba(255,255,255,0.5); }
  .sep { height:1px; background:rgba(255,255,255,0.14); margin:7px 14px; }
  .dot { width:13px; height:13px; border-radius:50%; flex-shrink:0; }
  .dot.red { background:#ff5a5a; box-shadow:0 0 10px rgba(255,90,90,0.8); }
  .dot.yel { background:#ffcf4a; } .dot.grn { background:#34d058; } .dot.gry { background:#8a8a92; }
  .mspark { width:60px; height:20px; flex-shrink:0; opacity:.85; }
  .mspark.red { color:#ff7a7a; } .mspark.yel { color:#ffcf4a; } .mspark.grn { color:#34d058; }
  .badge-n { margin-left:auto; font-size:.82em; opacity:.6; font-variant-numeric:tabular-nums; }

  /* context rows + graph */
  .ctxrow { display:flex; align-items:center; gap:12px; padding:7px 16px; line-height:1.4; }
  .ctxrow .k { opacity:.62; } .ctxrow .v { font-weight:600; }
  .chip { display:inline-flex; align-items:center; gap:6px; padding:7px 14px; border-radius:999px;
    font-weight:600; font-size:.82em; background:rgba(120,90,230,0.26); border:1px solid rgba(150,120,255,0.4); }
  .chips { display:flex; flex-wrap:wrap; gap:9px; padding:8px 16px 12px; }
  .hostchip { display:inline-block; padding:5px 13px; border-radius:8px; font-family:ui-monospace,monospace;
    font-size:.8em; background:rgba(255,255,255,0.08); border:1px solid rgba(255,255,255,0.12); margin:2px 4px 2px 0; }
  .graphwrap { position:relative; margin:6px 16px 12px; height:170px; }
  .graph { width:100%; height:100%; display:block; }
  .graph .thresh { stroke:#ff5a5a; stroke-width:1.5; stroke-dasharray:5 5; opacity:.8; }
  .graph .garea { fill:url(#areaGrad); opacity:0; }
  .graph .gline { fill:none; stroke:#ff7a7a; stroke-width:3; stroke-linecap:round; stroke-linejoin:round;
    stroke-dasharray:1; stroke-dashoffset:1; }
  .graph .gdot { fill:#fff; stroke:#ff5a5a; stroke-width:3; opacity:0; }
  .threshlbl { position:absolute; top:6px; right:0; font-size:.66em; color:#ff8a8a; font-weight:700; }
  .gval { position:absolute; left:2px; bottom:2px; font-weight:800; font-variant-numeric:tabular-nums; }
  .gval #gnum { font-size:1.5em; } .gunit { opacity:.6; font-size:.8em; margin-left:4px; }
  .deploy { display:flex; align-items:center; gap:10px; padding:10px 15px; border-radius:11px; font-weight:700;
    color:#ffe1a8; background:rgba(255,150,40,0.16); border:1px solid rgba(255,170,60,0.45); transform-origin:50% 50%; }

  /* banner */
  .banner { position:absolute; display:flex; gap:16px; align-items:center; color:#fff; z-index:30;
    background:rgba(44,44,50,0.95); border-radius:24px;
    padding:18px 22px; border:1px solid rgba(255,255,255,0.16); box-shadow:0 16px 54px rgba(0,0,0,0.5); }
  .banner .appicon { width:60px; height:60px; border-radius:14px; flex-shrink:0; font-size:34px;
    background:linear-gradient(145deg,#7a3ce8,#632ca6); display:flex; align-items:center; justify-content:center;
    box-shadow:inset 0 2px 0 rgba(255,255,255,0.25); }
  .banner .t { font-size:22px; font-weight:700; } .banner .s { font-size:19px; opacity:.72; margin-top:1px; }
  .banner .b { font-size:20px; opacity:.92; margin-top:2px; }
  .banner .when { position:absolute; top:15px; right:22px; font-size:16px; opacity:.5; }

  /* modal + scrim */
  #scrim { position:absolute; inset:0; background:rgba(0,0,0,0.6); opacity:0; z-index:35; }
  .modal { position:absolute; border-radius:24px; padding:36px 34px 28px; text-align:center; color:#fff; z-index:40;
    background:rgba(48,48,54,0.98); border:1px solid rgba(255,255,255,0.18);
    box-shadow:0 0 0 1px rgba(0,0,0,0.7), 0 44px 120px rgba(0,0,0,0.75); }
  .modal .bigicon { width:118px; height:118px; margin:0 auto 18px; font-size:70px; border-radius:27px;
    background:linear-gradient(145deg,#7a3ce8,#632ca6); display:flex; align-items:center; justify-content:center;
    box-shadow:0 8px 26px rgba(0,0,0,0.45); }
  .modal .badge { position:absolute; top:120px; left:50%; margin-left:26px; width:52px; height:52px;
    display:flex; align-items:center; justify-content:center; font-size:48px; transform-origin:50% 50%;
    text-shadow:0 3px 5px rgba(0,0,0,0.5); }
  .modal h1 { font-size:25px; font-weight:800; margin-bottom:10px; }
  .modal p { font-size:21px; line-height:1.5; opacity:.85; margin-bottom:22px; }
  .modal .btn { display:block; width:100%; padding:13px 0; border-radius:13px; font-size:22px; font-weight:600; margin-top:11px;
    background:rgba(255,255,255,0.14); }
  .modal .btn.primary { background:linear-gradient(180deg,#2f78ef,#2569d8); box-shadow:inset 0 2px 0 rgba(255,255,255,0.2); }
  .modal .nag { margin-top:16px; font-size:15px; opacity:.45; }

  /* cursor + toast */
  .curarrow { position:absolute; width:42px; height:42px; right:34px; top:50%; margin-top:-21px; z-index:60;
    pointer-events:none; }
  .clickring { position:absolute; right:30px; top:50%; width:34px; height:34px; margin-top:-17px; border-radius:50%;
    border:3px solid #4d9bff; opacity:0; z-index:59; }
  .toast { position:absolute; display:flex; align-items:center; gap:10px; color:#fff; font-weight:700; font-size:23px;
    padding:15px 24px; border-radius:15px; z-index:45; box-shadow:0 16px 44px rgba(0,0,0,0.5);
    background:linear-gradient(180deg,#2f78ef,#2569d8); }
  .toast.green { background:linear-gradient(180deg,#34c759,#28a745); }

  /* title / brand / caption / toplabel / flash */
  #title, #brand { position:absolute; inset:0; display:flex; flex-direction:column; align-items:center;
    justify-content:center; text-align:center; z-index:46; }
  #title .tmark, #brand .bmark { border-radius:34px; background:linear-gradient(145deg,#7a3ce8,#632ca6);
    display:flex; align-items:center; justify-content:center;
    box-shadow:0 20px 54px rgba(122,60,232,0.55), inset 0 2px 0 rgba(255,255,255,0.25); }
  #title .tmark { width:148px; height:148px; font-size:86px; margin-bottom:30px; }
  #title h1 { font-size:84px; font-weight:800; letter-spacing:-1.5px; max-width:84%; line-height:1.05; }
  #brand .bmark { width:160px; height:160px; font-size:94px; margin-bottom:30px; }
  #brand h1 { font-size:74px; font-weight:800; letter-spacing:-1.5px; max-width:86%; line-height:1.06; }
  #brand .brow { display:flex; align-items:center; gap:12px; font-size:34px; font-weight:600; opacity:.85; margin-top:18px; }
  #brand .bdot { width:30px; height:30px; border-radius:8px; background:linear-gradient(145deg,#7a3ce8,#632ca6); }
  #brand .burl { font-size:26px; font-weight:600; opacity:.5; margin-top:26px; letter-spacing:.3px; }

  .cap { position:absolute; text-align:center; z-index:44; }
  .cap .pill { display:inline-block; padding:14px 34px; border-radius:999px; font-weight:700; letter-spacing:-0.4px;
    background:rgba(13,13,21,0.82); border:1px solid rgba(255,255,255,0.14);
    box-shadow:0 10px 30px rgba(0,0,0,0.4); }
  #toplabel { display:none; }
  #flash { position:absolute; inset:0; background:#fff; opacity:0; z-index:70; pointer-events:none; }
  #redflash { position:absolute; inset:0; background:radial-gradient(circle at 50% 40%, rgba(255,60,60,0.55), rgba(255,0,0,0.15)); opacity:0; z-index:36; pointer-events:none; }
`;

const LANDSCAPE = `
  #title h1 { font-size:90px; } #brand h1 { font-size:80px; }
  .cap { left:0; right:0; bottom:78px; font-size:46px; }
  .panel.center, .modal { left:50%; }
  #menu { width:600px; top:150px; left:50%; margin-left:-300px; transform-origin:50% 0; }
  #ctx { width:640px; top:120px; left:50%; margin-left:-320px; transform-origin:50% 0; }
  #svc { width:900px; top:165px; left:50%; margin-left:-450px; transform-origin:50% 0; }
  #fly { width:470px; top:150px; left:50%; margin-left:-235px; transform-origin:50% 0; }
  #modal { width:520px; top:150px; margin-left:-260px; transform-origin:50% 50%; }
  #bannerA { top:90px; right:60px; width:640px; } #bannerB { top:224px; right:60px; width:640px; }
  #toastA { top:622px; left:50%; margin-left:-250px; } #toastB { top:700px; left:50%; margin-left:-250px; }
`;

const VERTICAL = `
  #dock { display:none; }
  #title h1 { font-size:80px; } #brand h1 { font-size:76px; }
  #brand .brow { font-size:40px; } #brand .burl { font-size:30px; }
  #toplabel { display:flex; align-items:center; justify-content:center; gap:16px; position:absolute; top:150px;
    left:0; right:0; padding:0 60px; text-align:center; font-weight:800; font-size:52px; letter-spacing:-1px; z-index:44; opacity:0; }
  #toplabel .dot { width:60px; height:60px; border-radius:16px; flex-shrink:0; font-size:38px;
    background:linear-gradient(145deg,#7a3ce8,#632ca6); display:flex; align-items:center; justify-content:center; }
  .cap { left:0; right:0; bottom:320px; font-size:58px; padding:0 50px; }
  .panel { font-size:32px; border-radius:26px; padding:14px; }
  .mi { padding:13px 24px; gap:16px; } .mi.header { padding:14px 24px 6px; } .sep { margin:9px 22px; }
  .dot { width:18px; height:18px; } .mspark { width:84px; height:28px; }
  .ctxrow { padding:11px 26px; gap:18px; } .chips { padding:12px 24px 16px; gap:14px; }
  .chip { padding:10px 20px; } .hostchip { padding:8px 18px; }
  .graphwrap { height:300px; margin:10px 26px 18px; } .gval #gnum { font-size:1.5em; }
  .deploy { padding:15px 24px; border-radius:15px; }
  .banner { border-radius:34px; padding:26px 30px; gap:22px; }
  .banner .appicon { width:88px; height:88px; border-radius:21px; font-size:50px; }
  .banner .t { font-size:34px; } .banner .s { font-size:27px; } .banner .b { font-size:30px; } .banner .when { font-size:24px; top:24px; right:32px; }
  .modal { border-radius:32px; padding:50px 42px 38px; }
  .modal .bigicon { width:156px; height:156px; font-size:92px; border-radius:36px; margin-bottom:26px; }
  .modal .badge { top:158px; margin-left:40px; width:70px; height:70px; font-size:64px; }
  .modal h1 { font-size:36px; } .modal p { font-size:31px; } .modal .btn { font-size:31px; padding:18px 0; border-radius:18px; }
  .modal .nag { font-size:22px; }
  .curarrow { width:60px; height:60px; right:44px; margin-top:-30px; } .clickring { width:48px; height:48px; right:40px; margin-top:-24px; }
  .toast { font-size:33px; padding:20px 32px; border-radius:20px; }

  #menu { width:860px; top:540px; left:50%; margin-left:-430px; transform-origin:50% 0; }
  #ctx { width:880px; top:480px; left:50%; margin-left:-440px; transform-origin:50% 0; }
  #svc { width:980px; top:560px; left:50%; margin-left:-490px; transform-origin:50% 0; }
  #fly { width:720px; top:560px; left:50%; margin-left:-360px; transform-origin:50% 0; }
  #modal { width:760px; top:560px; left:50%; margin-left:-380px; transform-origin:50% 50%; }
  #bannerA { top:430px; left:50%; margin-left:-460px; width:920px; } #bannerB { top:640px; left:50%; margin-left:-460px; width:920px; }
  #toastA { top:1180px; left:50%; margin-left:-340px; } #toastB { top:1300px; left:50%; margin-left:-340px; }
`;

/* --------------------------------- stories -------------------------------- */
function spark(seed) { // tiny deterministic rising polyline for menu rows
  const ys = [16, 14, 15, 12, 13, 9, 10, 6, 4];
  return ys.map((y, i) => `${i * 7.5},${y + (seed % 3)}`).join(" ");
}

const STORIES = [
  {
    slug: "01-detect-and-triage",
    mood: "tense",
    title: "Know the moment it breaks",
    brandLine: "Catch it the moment it fires",
    label: "At-a-glance triage",
    hero: `
      <div id="menu" class="panel center clip" data-start="3.5" data-duration="4.2" data-track-index="3">
        <div class="mi sumline"><span class="grow">📊 3 alerting · 1 warn · 47 ok · 1 muted</span></div>
        <div class="sep"></div>
        <div class="mi header"><span class="grow">🔥 INCIDENTS (1)</span></div>
        <div class="mi"><span class="dot red"></span><span class="grow">SEV-1 · Checkout flow down</span></div>
        <div class="sep"></div>
        <div class="mi header"><span class="grow">ALERTING (3)</span></div>
        <div class="mi hi"><span class="dot red"></span><span class="grow">High CPU on prod-web</span>${miniSpark(spark(0), "")}</div>
        <div class="mi"><span class="dot red"></span><span class="grow">P95 latency — checkout-api</span>${miniSpark(spark(1), "red")}</div>
        <div class="mi"><span class="dot red"></span><span class="grow">5xx rate — payments</span>${miniSpark(spark(2), "red")}</div>
        <div class="sep"></div>
        <div class="mi header"><span class="grow">WARNING (1)</span></div>
        <div class="mi"><span class="dot yel"></span><span class="grow">Disk space — db-primary</span>${miniSpark(spark(1), "yel")}</div>
        <div class="sep"></div>
        <div class="mi dim"><span class="dot grn"></span><span class="grow">OK (47)</span><span class="badge-n">▸</span></div>
        <div class="mi dim"><span class="dot gry"></span><span class="grow">MUTED (1)</span><span class="badge-n">▸</span></div>
      </div>
      <div id="ctx" class="panel center clip" data-start="7.8" data-duration="5.2" data-track-index="4">
        <div class="mi sumline"><span class="dot red"></span><span class="grow">High CPU on prod-web</span></div>
        <div class="sep"></div>
        <div class="ctxrow"><span class="k">🎯 Priority</span><span class="v">P1 — critical</span></div>
        <div class="ctxrow"><span class="k">⏱ Triggered</span><span class="v">23m ago</span></div>
        ${metricGraph()}
        <div class="ctxrow"><span class="k">📟 Triggered on</span><span class="v">2 hosts</span></div>
        <div class="hostwrap" style="padding:0 16px 10px"><span class="hostchip">host:prod-web-1</span><span class="hostchip">host:prod-web-2</span></div>
      </div>
      <div id="redflash"></div>`,
    captions: [
      ["c1", 4.0, 7.0, "Every monitor, grouped by state"],
      ["c2", 8.2, 12.4, "Priority, a live metric, the threshold — and the hosts that fired"],
    ],
    audio: [
      ["notification", 3.55, 2.46, 0.5],
      ["whoosh-short", 7.65, 0.57, 0.4],
      ["ping", 11.0, 1.32, 0.45],
      ["sparkle", 12.95, 1.8, 0.4],
    ],
    tl: `
      /* S2: alert fires + menu */
      flash(3.45);
      tl.to("#icon-calm", { opacity: 0, duration: 0.18 }, 3.4); tl.set("#icon-calm", { opacity: 0 }, 3.6);
      tl.fromTo("#icon-alert", { opacity: 0, scale: 0.5 }, { opacity: 1, scale: 1, duration: 0.4, ease: "back.out(2.2)" }, 3.4);
      tl.to("#status", { x: -7, duration: 0.05, repeat: 7, yoyo: true, ease: "none" }, 3.45); tl.set("#status", { x: 0 }, 3.9);
      tl.to("#redflash", { opacity: 0.5, duration: 0.12 }, 3.45); tl.to("#redflash", { opacity: 0, duration: 0.6 }, 3.6);
      tl.from("#menu", { y: -30, opacity: 0, scale: 0.92, duration: 0.5, ease: "back.out(1.3)" }, 3.5);
      tl.from("#menu .mi, #menu .sep", { opacity: 0, x: 16, duration: 0.35, stagger: 0.03, ease: "power2.out" }, 3.7);
      tl.to("#menu", { opacity: 0, scale: 0.96, duration: 0.3, ease: "power2.in" }, 7.15); tl.set("#menu", { opacity: 0 }, 7.45);
      /* S3: drill into the alert + live graph */
      flash(7.6);
      tl.from("#ctx", { y: -26, opacity: 0, scale: 0.93, duration: 0.5, ease: "back.out(1.3)" }, 7.8);
      tl.from("#ctx .mi, #ctx .sep, #ctx .ctxrow", { opacity: 0, x: 14, duration: 0.3, stagger: 0.05, ease: "power2.out" }, 8.0);
      /* draw the metric line + area, count value, breach the threshold */
      tl.to("#gLine", { strokeDashoffset: 0, duration: 1.9, ease: "power1.inOut" }, 9.3);
      tl.to("#gArea", { opacity: 1, duration: 1.9, ease: "power1.in" }, 9.3);
      tl.to(gstate, { v: 97.2, duration: 1.9, ease: "power1.inOut", onUpdate: () => { gnum.textContent = gstate.v.toFixed(1); } }, 9.3);
      tl.to("#redflash", { opacity: 0.42, duration: 0.12 }, 10.95); tl.to("#redflash", { opacity: 0, duration: 0.7 }, 11.1);
      tl.fromTo("#gDot", { opacity: 0, scale: 0 }, { opacity: 1, scale: 1, duration: 0.35, ease: "back.out(2.5)" }, 11.0);
      tl.to("#gDot", { scale: 1.5, duration: 0.4, repeat: 3, yoyo: true, ease: "sine.inOut" }, 11.4);
      tl.from(".hostchip", { opacity: 0, y: 12, scale: 0.8, duration: 0.35, stagger: 0.12, ease: "back.out(2)" }, 11.4);
      tl.to("#ctx", { opacity: 0, scale: 0.96, duration: 0.3, ease: "power2.in" }, 12.6); tl.set("#ctx", { opacity: 0 }, 12.9);
      flash(12.85);`,
  },
  {
    slug: "02-impossible-to-ignore",
    mood: "urgent",
    title: "Impossible to ignore",
    brandLine: "Alerts impossible to ignore",
    label: "Can't-miss alerts",
    hero: `
      <div id="bannerA" class="banner clip" data-start="3.0" data-duration="4.2" data-track-index="5">
        <div class="appicon">🐶</div>
        <div><div class="t">🔴 ALERT — Datadog</div><div class="s">Datadog Assistant</div><div class="b">High CPU on prod-web</div></div>
        <div class="when">now</div>
      </div>
      <div id="bannerB" class="banner clip" data-start="4.4" data-duration="2.9" data-track-index="6">
        <div class="appicon">🐶</div>
        <div><div class="t">🟢 Recovered — Datadog</div><div class="s">Datadog Assistant</div><div class="b">P95 latency — checkout-api</div></div>
        <div class="when">2m ago</div>
      </div>
      <div id="scrim"></div>
      <div id="modal" class="modal clip" data-start="7.45" data-duration="5.45" data-track-index="40">
        <div class="bigicon">🐶</div>
        <span class="badge">⚠️</span>
        <h1>🔴 P1 ALERT — Datadog</h1>
        <p>SEV-1 · Checkout flow down<br>5xx rate — payments</p>
        <div class="btn primary">Open in Datadog 🔗</div>
        <div class="btn">Dismiss</div>
        <div class="nag">stays on screen · re-nags every 10 min until you act</div>
      </div>
      <div id="redflash"></div>`,
    captions: [
      ["c1", 3.4, 6.7, "A banner and a sound for every alert — and recovery"],
      ["c2", 7.9, 12.4, "A P1? A modal that won't let you look away"],
    ],
    audio: [
      ["notification", 3.05, 2.46, 0.55],
      ["chime", 4.45, 2.5, 0.45],
      ["riser", 6.4, 10.03, 0.16],
      ["impact-bass-1", 7.45, 2.12, 0.6],
    ],
    tl: `
      /* S2: banners */
      tl.fromTo("#bannerA", { x: 520, opacity: 0 }, { x: 0, opacity: 1, duration: 0.55, ease: "power3.out" }, 3.0);
      tl.fromTo("#bannerB", { x: 520, opacity: 0 }, { x: 0, opacity: 1, duration: 0.55, ease: "power3.out" }, 4.4);
      tl.to("#bannerA", { x: 520, opacity: 0, duration: 0.4, ease: "power3.in" }, 6.9); tl.set("#bannerA", { opacity: 0 }, 7.3);
      tl.to("#bannerB", { x: 520, opacity: 0, duration: 0.4, ease: "power3.in" }, 6.9); tl.set("#bannerB", { opacity: 0 }, 7.3);
      /* icon to alert during the escalation */
      tl.to("#icon-calm", { opacity: 0, duration: 0.18 }, 7.3); tl.set("#icon-calm", { opacity: 0 }, 7.5);
      tl.fromTo("#icon-alert", { opacity: 0, scale: 0.5 }, { opacity: 1, scale: 1, duration: 0.4, ease: "back.out(2.2)" }, 7.3);
      /* S3: critical modal slams in */
      tl.to("#scrim", { opacity: 1, duration: 0.4 }, 7.2);
      tl.to("#redflash", { opacity: 0.6, duration: 0.1 }, 7.45); tl.to("#redflash", { opacity: 0, duration: 0.7 }, 7.6);
      tl.fromTo("#modal", { scale: 0.6, opacity: 0 }, { scale: 1, opacity: 1, duration: 0.5, ease: "back.out(1.7)" }, 7.45);
      tl.to("#status", { x: -6, duration: 0.05, repeat: 9, yoyo: true, ease: "none" }, 7.5); tl.set("#status", { x: 0 }, 8.0);
      tl.from("#modal .badge", { scale: 0, rotation: -45, duration: 0.4, ease: "back.out(2.5)" }, 7.85);
      tl.to("#modal .btn.primary", { boxShadow: "0 0 0 3px rgba(79,155,255,0.7), inset 0 2px 0 rgba(255,255,255,0.2)", duration: 0.5, repeat: 3, yoyo: true, ease: "sine.inOut" }, 9.0);
      tl.to("#modal", { scale: 0.95, opacity: 0, duration: 0.3, ease: "power2.in" }, 12.6); tl.set("#modal", { opacity: 0 }, 12.9);
      tl.to("#scrim", { opacity: 0, duration: 0.4 }, 12.6); tl.set("#scrim", { opacity: 0 }, 13.0);
      flash(12.85);`,
  },
  {
    slug: "03-alert-to-fix",
    mood: "uplift",
    title: "From alert to fix in seconds",
    brandLine: "From alert to fix in seconds",
    label: "Act in one click",
    hero: `
      <div id="svc" class="panel center clip" data-start="3.0" data-duration="5.3" data-track-index="3">
        <div class="mi header"><span class="grow">🧭 SERVICE CONTEXT — checkout-api</span></div>
        <div class="chips">
          <span class="chip">🔗 Repo</span><span class="chip">📖 Runbook</span><span class="chip">📊 Dashboard</span><span class="chip">📟 On-call</span>
        </div>
        <div class="sep"></div>
        <div class="mi header"><span class="grow">🚀 RECENT DEPLOYS</span></div>
        <div class="mi dim"><span class="grow">checkout v2.3.0 · 2h ago</span></div>
        <div class="deploy" id="deploy-hot"><span class="grow">🚀 checkout v2.3.1 — shipped 12m before this alert</span></div>
      </div>
      <div id="fly" class="panel center clip" data-start="8.3" data-duration="4.7" data-track-index="4">
        <div class="mi sumline"><span class="dot red"></span><span class="grow">High CPU on prod-web</span></div>
        <div class="sep"></div>
        <div class="mi"><span class="grow">🔗 Open in Datadog</span></div>
        <div class="mi"><span class="grow">🎫 Create Jira ticket</span></div>
        <div class="sep"></div>
        <div class="mi" id="act-mute"><span class="grow">🔇 Mute 1 hour</span>${cursorSvg}<span class="clickring"></span></div>
        <div class="mi"><span class="grow">🔇 Mute 4 hours</span></div>
        <div class="mi"><span class="grow">🔇 Mute 24 hours</span></div>
        <div class="mi"><span class="grow">🔇 Mute forever</span></div>
      </div>
      <div id="toastA" class="toast clip" data-start="10.6" data-duration="2.4" data-track-index="7">🔇 Muted 1 hour · prod-web</div>
      <div id="toastB" class="toast green clip" data-start="11.4" data-duration="1.6" data-track-index="8">🎫 Jira DDOG-482 created</div>`,
    captions: [
      ["c1", 3.4, 7.6, "Datadog already knows the repo, runbook — and the deploy that did it"],
      ["c2", 8.6, 12.4, "Mute, ticket, or open — one click"],
    ],
    audio: [
      ["whoosh-short", 2.95, 0.57, 0.4],
      ["ping", 5.6, 1.32, 0.45],
      ["whoosh-short", 8.25, 0.57, 0.4],
      ["click", 10.5, 0.37, 0.6],
      ["pop", 10.6, 0.72, 0.5],
      ["pop", 11.4, 0.72, 0.5],
      ["sparkle", 13.0, 1.8, 0.4],
    ],
    tl: `
      /* S2: service context + deploy correlation */
      tl.from("#svc", { y: -28, opacity: 0, scale: 0.93, duration: 0.5, ease: "back.out(1.3)" }, 3.0);
      tl.from("#svc .mi, #svc .sep", { opacity: 0, x: 14, duration: 0.3, stagger: 0.05, ease: "power2.out" }, 3.2);
      tl.from("#svc .chip", { scale: 0, opacity: 0, duration: 0.3, stagger: 0.07, ease: "back.out(2)" }, 3.6);
      tl.from("#deploy-hot", { opacity: 0, y: 14, duration: 0.4, ease: "power3.out" }, 5.3);
      tl.to("#deploy-hot", { scale: 1.04, duration: 0.45, repeat: 3, yoyo: true, ease: "sine.inOut" }, 5.6);
      tl.to("#svc", { opacity: 0, scale: 0.96, duration: 0.3, ease: "power2.in" }, 7.9); tl.set("#svc", { opacity: 0 }, 8.2);
      flash(8.2);
      /* S3: action flyout + cursor click + toasts */
      tl.from("#fly", { y: -26, opacity: 0, scale: 0.93, duration: 0.5, ease: "back.out(1.3)" }, 8.3);
      tl.from("#fly .mi, #fly .sep", { opacity: 0, x: 14, duration: 0.3, stagger: 0.04, ease: "power2.out" }, 8.5);
      tl.fromTo(".curarrow", { x: -130, y: -90, opacity: 0 }, { x: 0, y: 0, opacity: 1, duration: 0.7, ease: "power2.inOut" }, 9.4);
      tl.to("#act-mute", { backgroundColor: "rgba(47,120,239,0.95)", color: "#ffffff", duration: 0.18 }, 10.5);
      tl.to(".curarrow", { scale: 0.82, duration: 0.09, yoyo: true, repeat: 1, ease: "power2.inOut" }, 10.5);
      tl.fromTo(".clickring", { scale: 0.4, opacity: 0.9 }, { scale: 1.8, opacity: 0, duration: 0.5, ease: "power2.out" }, 10.5);
      tl.fromTo("#toastA", { y: 40, opacity: 0 }, { y: 0, opacity: 1, duration: 0.4, ease: "back.out(1.5)" }, 10.6);
      tl.fromTo("#toastB", { y: 40, opacity: 0 }, { y: 0, opacity: 1, duration: 0.4, ease: "back.out(1.5)" }, 11.4);
      tl.to("#fly", { opacity: 0, scale: 0.96, duration: 0.3, ease: "power2.in" }, 12.6); tl.set("#fly", { opacity: 0 }, 12.9);
      tl.to("#toastA", { opacity: 0, duration: 0.3 }, 12.6); tl.set("#toastA", { opacity: 0 }, 12.9);
      tl.to("#toastB", { opacity: 0, duration: 0.3 }, 12.6); tl.set("#toastB", { opacity: 0 }, 12.9);
      tl.to("#brand .bmark", { boxShadow: "0 20px 70px rgba(52,199,89,0.6), inset 0 2px 0 rgba(255,255,255,0.25)", duration: 0.6 }, 13.2);
      flash(12.85);`,
  },
];

/* ------------------------------- assembler -------------------------------- */
function sharedTimeline(story) {
  return `
      /* helpers */
      function flash(t) { tl.fromTo("#flash", { opacity: 0 }, { opacity: 0.85, duration: 0.1, ease: "power2.out" }, t); tl.to("#flash", { opacity: 0, duration: 0.35, ease: "power2.in" }, t + 0.1); tl.set("#flash", { opacity: 0 }, t + 0.45); }

      /* ambient drift + grain */
      tl.to("#blob1", { x: 110, y: -50, duration: 8, repeat: 1, yoyo: true, ease: "sine.inOut" }, 0);
      tl.to("#blob2", { x: -100, y: 60, duration: 8, repeat: 1, yoyo: true, ease: "sine.inOut" }, 0);
      tl.to("#blob3", { x: 60, y: -70, scale: 1.15, duration: 8, repeat: 1, yoyo: true, ease: "sine.inOut" }, 0);
      tl.to("#grain", { x: 60, y: 40, duration: 0.5, repeat: ${Math.floor(DUR / 0.5) - 1}, ease: "steps(1)" }, 0);

      /* intro title */
      tl.from("#title .tmark", { scale: 0.6, opacity: 0, duration: 0.6, ease: "back.out(1.7)" }, 0.15);
      tl.from("#title h1", { y: 50, opacity: 0, duration: 0.55, ease: "power3.out" }, 0.38);
      tl.to("#title", { opacity: 0, scale: 1.06, duration: 0.35, ease: "power2.in" }, 2.6);
      tl.set("#title", { opacity: 0 }, 3.0);
      tl.to("#toplabel", { opacity: 1, duration: 0.4 }, 2.7);

      /* captions */
${captionTweens(story.captions)}

      ${story.tl}

      /* outro brand lockup */
      tl.from("#brand .bmark", { scale: 0.6, opacity: 0, duration: 0.6, ease: "back.out(1.7)" }, 13.05);
      tl.from("#brand h1", { y: 44, opacity: 0, duration: 0.55, ease: "power3.out" }, 13.25);
      tl.from("#brand .brow", { y: 24, opacity: 0, duration: 0.5, ease: "power3.out" }, 13.5);
      tl.from("#brand .burl", { opacity: 0, duration: 0.6, ease: "power2.out" }, 13.85);
      tl.to("#toplabel", { opacity: 0, duration: 0.4 }, 12.7);`;
}

function audioTags(story) {
  let i = 0;
  const bed = `      <audio id="bed" src="assets/bgm/bed.wav" data-start="0" data-duration="${DUR}" data-track-index="18" data-volume="0.5"></audio>`;
  const sfx = story.audio
    .map(([name, at, dur, vol]) => {
      const tag = `      <audio id="sfx${i}" src="assets/sfx/${name}.mp3" data-start="${at}" data-duration="${dur}" data-track-index="${20 + i}" data-volume="${vol}"></audio>`;
      i++;
      return tag;
    })
    .join("\n");
  return bed + "\n" + sfx;
}

function needsGraph(story) { return story.hero.includes("metricGraph") || story.hero.includes('id="gLine"'); }

function buildHTML(orient, story) {
  const css = CSS + (orient.cls === "vertical" ? VERTICAL : LANDSCAPE);
  const graphInit = story.hero.includes('id="gLine"')
    ? `      const gstate = { v: 0 }; const gnum = document.getElementById("gnum");`
    : "";
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=${orient.w}, height=${orient.h}" />
    <title>Datadog Assistant — ${story.title}</title>
    <script src="./vendor/gsap.min.js"></script>
    <style>
      html, body, #root { width:${orient.w}px; height:${orient.h}px; }
${css}
    </style>
  </head>
  <body>
    <div id="root" class="${orient.cls}" data-composition-id="main"
         data-start="0" data-duration="${DUR}" data-width="${orient.w}" data-height="${orient.h}">
${stage()}
      <div id="toplabel"><span class="dot">🐶</span><span>${story.label}</span></div>
${title(story.title)}
${story.hero}
${story.captions.map((c) => caption(c[0], c[1], c[2], c[3], 2)).join("\n")}
${brand(story.brandLine, 13.0)}
${audioTags(story)}
    </div>
    <script>
      window.__timelines = window.__timelines || {};
      const tl = gsap.timeline({ paused: true });
${graphInit}
${sharedTimeline(story)}
      window.__timelines["main"] = tl;
    </script>
  </body>
</html>
`;
}

/* --------------------------------- emit ----------------------------------- */
// clean old per-feature dirs from v1
for (const o of ["landscape", "tiktok"]) {
  const d = resolve(ROOT, o);
  if (existsSync(d)) rmSync(d, { recursive: true, force: true });
}

let count = 0;
for (const orient of ORIENTATIONS) {
  for (const story of STORIES) {
    const dir = resolve(ROOT, orient.key, story.slug);
    mkdirSync(resolve(dir, "vendor"), { recursive: true });
    mkdirSync(resolve(dir, "renders"), { recursive: true });
    mkdirSync(resolve(dir, "assets", "sfx"), { recursive: true });
    mkdirSync(resolve(dir, "assets", "bgm"), { recursive: true });
    writeFileSync(resolve(dir, "index.html"), buildHTML(orient, story));
    copyFileSync(GSAP, resolve(dir, "vendor", "gsap.min.js"));
    // bed
    const moodFile = { tense: "tense", urgent: "urgent", uplift: "uplift" }[story.mood];
    copyFileSync(resolve(BUILD_ASSETS, "bgm", moodFile + ".wav"), resolve(dir, "assets", "bgm", "bed.wav"));
    // sfx (dedup)
    const used = new Set(story.audio.map((a) => a[0]));
    for (const s of used) copyFileSync(resolve(BUILD_ASSETS, "sfx", s + ".mp3"), resolve(dir, "assets", "sfx", s + ".mp3"));
    writeFileSync(resolve(dir, "meta.json"), JSON.stringify({ id: "main", name: `ddog-${orient.key}-${story.slug}` }, null, 2));
    writeFileSync(resolve(dir, "hyperframes.json"), JSON.stringify({ $schema: "https://hyperframes.heygen.com/schema/hyperframes.json", paths: { blocks: "compositions", components: "compositions/components", assets: "assets" } }, null, 2));
    count++;
    console.log("wrote", `${orient.key}/${story.slug}`);
  }
}
console.log(`\nGenerated ${count} story compositions.`);
