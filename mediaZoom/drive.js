// drive.js opens mediaZoom/index.html in headless Chromium, driven over --remote-debugging-pipe (no
// packages needed), exercises MCZbase's /shared/js/media-zoom.js with real mouse, wheel, touch and
// keyboard input, and prints PASS or FAIL for each check.  Run by checkMediaZoom.sh.  The exit status
// is the number of failed checks.
//
// Copyright 2026 President and Fellows of Harvard College
// Licensed under the Apache License, Version 2.0; see LICENSE.
const { spawn } = require("child_process");
const [, , chrome, profile, pageUrl] = process.argv;
const browser = spawn(chrome, ["--headless=new", "--disable-gpu", "--remote-debugging-pipe", "--no-first-run",
	"--allow-file-access-from-files", "--user-data-dir=" + profile, "--window-size=1000,700", "about:blank"],
	{ stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
const toB = browser.stdio[3], fromB = browser.stdio[4];
let buf = "", id = 0; const pending = new Map(); const events = [];
fromB.on("data", (d) => { buf += d; let e; while ((e = buf.indexOf("\0")) >= 0) { const m = JSON.parse(buf.slice(0, e)); buf = buf.slice(e + 1);
	if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.rej(new Error(m.error.message)) : p.res(m.result); } else { events.push(m); } } });
const send = (method, params = {}, sessionId) => new Promise((res, rej) => { const m = { id: ++id, method, params }; if (sessionId) m.sessionId = sessionId; pending.set(m.id, { res, rej }); toB.write(JSON.stringify(m) + "\0"); });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (name, ok, detail) => { if (!ok) failures++; console.log((ok ? "PASS  " : "FAIL  ") + name + (detail !== undefined ? "  [" + detail + "]" : "")); };
(async () => {
	const { targetId } = await send("Target.createTarget", { url: "about:blank" });
	const { sessionId: s } = await send("Target.attachToTarget", { targetId, flatten: true });
	await send("Runtime.enable", {}, s); await send("Page.enable", {}, s);
	await send("Emulation.setDeviceMetricsOverride", { width: 1000, height: 700, deviceScaleFactor: 1, mobile: false }, s);
	await send("Page.navigate", { url: pageUrl }, s); await sleep(800);
	const ev = async (expr) => (await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true }, s)).result.value;
	const rect = (sel) => ev(`(() => { const r = document.querySelector(${JSON.stringify(sel)}).getBoundingClientRect(); return {x: r.left, y: r.top, w: r.width, h: r.height, right: r.right}; })()`);
	const panel = () => ev(`(() => { const p = document.querySelector('.mcz-zoom-panel'); const l = document.querySelector('.mcz-zoom-lens'); if (!p) return null; const v = p.querySelector('.mcz-zoom-view'); const r = p.getBoundingClientRect();
		return {display: p.style.display, left: r.left, right: r.right, top: r.top, w: p.clientWidth, h: p.clientHeight, size: v.style.backgroundSize, pos: v.style.backgroundPosition, hint: p.querySelector('.mcz-zoom-hint').textContent, lens: l.style.display, lensW: parseFloat(l.style.width), loading: p.querySelector('.mcz-zoom-loading').style.display}; })()`);
	const mouse = (type, x, y, extra = {}) => send("Input.dispatchMouseEvent", Object.assign({ type, x, y, button: "none", pointerType: "mouse" }, extra), s);
	const key = async (k, code, keyCode) => { await send("Input.dispatchKeyEvent", { type: "keyDown", key: k, code, windowsVirtualKeyCode: keyCode, text: k.length === 1 ? k : undefined }, s); await send("Input.dispatchKeyEvent", { type: "keyUp", key: k, code, windowsVirtualKeyCode: keyCode }, s); };

	// 1. hover left image: panel on the right, sized 4x but within limits, aspect of the large image
	const L = await rect("#left");
	await mouse("mouseMoved", 5, 650); await mouse("mouseMoved", L.x + L.w / 2, L.y + L.h / 2); await sleep(400);
	let p = await panel();
	check("hover shows panel", p && p.display === "block", p && p.display);
	check("panel to the right of left image", p.left >= L.right, `${p.left} vs ${L.right}`);
	check("panel width 4x image (600 max)", Math.abs(p.w - Math.min(600, L.w * 4)) < 2, p.w);
	check("panel keeps 4:3 aspect", Math.abs(p.w / p.h - 4 / 3) < 0.02, (p.w / p.h).toFixed(3));
	check("zoom 1 shows whole image", p.size === `${p.w}px ${p.h}px`, p.size);
	check("mouse hint names wheel and keys", p.hint.startsWith("Scroll or + / "), p.hint);
	check("no lens at zoom 1", p.lens === "none", p.lens);
	check("loading indicator hidden once loaded", p.loading === "none", p.loading);
	// 2. wheel in: zoom, lens appears, panning follows the pointer
	await mouse("mouseWheel", L.x + L.w / 2, L.y + L.h / 2, { deltaX: 0, deltaY: -100 }); await sleep(150);
	p = await panel();
	check("wheel zooms in", parseFloat(p.size) > p.w + 1, p.size);
	check("lens shown when zoomed", p.lens === "block" && Math.abs(p.lensW - L.w / 1.25) < 1, p.lensW);
	check("zoomed hint shows zoom and arrow keys", /^Zoom ×1\.[23] · arrow keys to move/.test(p.hint), p.hint);
	const scrollY = await ev("window.scrollY");
	check("wheel over image does not scroll page", scrollY === 0, scrollY);
	await mouse("mouseMoved", L.x + 2, L.y + 2); await sleep(100);
	const posTopLeft = (await panel()).pos;
	await mouse("mouseMoved", L.x + L.w - 2, L.y + L.h - 2); await sleep(100);
	const posBottomRight = (await panel()).pos;
	check("panning: top-left shows offset 0 0", posTopLeft === "0px 0px", posTopLeft);
	check("panning: bottom-right moves view", posBottomRight !== posTopLeft && posBottomRight.startsWith("-"), posBottomRight);
	for (let i = 0; i < 40; i++) { await mouse("mouseWheel", L.x + L.w / 2, L.y + L.h / 2, { deltaX: 0, deltaY: -100 }); }
	await sleep(150); p = await panel();
	const maxZoom = parseFloat(p.size) / p.w;
	check("zoom capped at 2 screen px per image px", Math.abs(maxZoom - 1600 * 2 / p.w) < 0.05, maxZoom.toFixed(2));
	// 3. Escape dismisses until the pointer leaves
	await key("Escape", "Escape", 27); await sleep(100);
	check("Escape hides panel", (await panel()).display === "none");
	await mouse("mouseMoved", L.x + L.w / 2 + 3, L.y + L.h / 2); await sleep(100);
	check("stays dismissed while pointer stays", (await panel()).display === "none");
	await mouse("mouseMoved", 5, 650); await mouse("mouseMoved", L.x + L.w / 2, L.y + L.h / 2); await sleep(150);
	check("shows again after leaving and re-entering", (await panel()).display === "block");
	await mouse("mouseMoved", 5, 650); await sleep(100);
	check("pointer leaving hides panel", (await panel()).display === "none");
	// 4. right image at window edge: panel flips left
	const R = await rect("#right");
	await mouse("mouseMoved", R.x + R.w / 2, R.y + R.h / 2); await sleep(150); p = await panel();
	check("panel flips left at window edge", p.display === "block" && p.right <= R.x, `${p.right} vs ${R.x}`);
	await mouse("mouseMoved", 5, 650); await sleep(100);
	// 5. page scroll moves the panel with the image
	await mouse("mouseMoved", L.x + L.w / 2, L.y + L.h / 2); await sleep(100);
	await ev("window.scrollTo(0, 40)"); await sleep(150); p = await panel(); const L2 = await rect("#left");
	check("panel follows page scroll", Math.abs(p.top - Math.max(12, L2.y)) < 1, `${p.top} vs ${L2.y}`);
	await ev("window.scrollTo(0, 0)"); await mouse("mouseMoved", 5, 650); await sleep(100);
	// 5b. keys work for a view opened by hovering, but not while typing or with Ctrl
	await ev("window.addEventListener('keydown', (e) => { window.lastPrevented = e.defaultPrevented; })");
	await ev("document.activeElement && document.activeElement.blur()");
	await mouse("mouseMoved", L.x + L.w / 2, L.y + L.h / 2); await sleep(150);
	await key("+", "Equal", 187); await sleep(100); p = await panel();
	check("+ zooms a hover view (no wheel needed)", parseFloat(p.size) > p.w + 1, p.size);
	const hoverPos = p.pos; await key("ArrowDown", "ArrowDown", 40); await sleep(100);
	check("arrow keys pan a hover view", (await panel()).pos !== hoverPos, (await panel()).pos);
	await key("-", "Minus", 189); await sleep(100);
	check("- zooms a hover view out", parseFloat((await panel()).size) === (await panel()).w, (await panel()).size);
	await send("Input.dispatchKeyEvent", { type: "keyDown", key: "=", code: "Equal", windowsVirtualKeyCode: 187, modifiers: 2 }, s);
	await send("Input.dispatchKeyEvent", { type: "keyUp", key: "=", code: "Equal", windowsVirtualKeyCode: 187, modifiers: 2 }, s); await sleep(100);
	check("Ctrl + left to the browser", (await ev("window.lastPrevented")) === false && parseFloat((await panel()).size) === (await panel()).w);
	await ev("document.getElementById('typing').focus()");
	await key("+", "Equal", 187); await sleep(100);
	check("typing + in a field while hovering types it", (await ev("document.getElementById('typing').value")) === "+" && parseFloat((await panel()).size) === (await panel()).w, await ev("document.getElementById('typing').value"));
	await ev("document.getElementById('typing').blur()");
	await mouse("mouseMoved", 5, 650); await sleep(100);
	// 6. collapsing the container while shown closes it, and it stays closed when expanded
	const C = await rect("#collapsed");
	await mouse("mouseMoved", C.x + C.w / 2, C.y + C.h / 2); await sleep(300);
	check("collapsed-case panel shown", (await panel()).display === "block");
	await ev("document.getElementById('collapseBox').style.display='none'"); await sleep(200);
	check("collapse closes panel", (await panel()).display === "none");
	await mouse("mouseMoved", 5, 650); await sleep(100);
	await ev("document.getElementById('collapseBox').style.display=''"); await sleep(200);
	check("expanding with the pointer elsewhere does not reopen it", (await panel()).display === "none");
	await mouse("mouseMoved", C.x + C.w / 2, C.y + C.h / 2); await sleep(200);
	check("hovering after expanding opens it in place", (await panel()).display === "block" && Math.abs((await panel()).top - C.y) < 1);
	await mouse("mouseMoved", 5, 650); await sleep(100);
	// 7. a large image that fails: closes, and does not reopen
	const B = await rect("#broken");
	await mouse("mouseMoved", B.x + B.w / 2, B.y + B.h / 2); await sleep(500);
	check("failed large image closes panel", (await panel()).display === "none");
	await mouse("mouseMoved", 5, 650); await mouse("mouseMoved", B.x + B.w / 2, B.y + B.h / 2); await sleep(200);
	check("failed large image not retried", (await panel()).display === "none");
	await mouse("mouseMoved", 5, 650); await sleep(100);
	// 8. touch does nothing
	await send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: L.x + L.w / 2, y: L.y + L.h / 2 }] }, s);
	await send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] }, s); await sleep(200);
	check("touch shows nothing", (await panel()).display === "none");
	await ev("location.hash=''; document.activeElement && document.activeElement.blur()");
	// 9. keyboard: Tab focuses the first link and shows the view; + zooms, arrows pan, Escape closes
	await ev("document.body.focus()");
	await key("Tab", "Tab", 9); await sleep(300); p = await panel();
	const active = await ev("document.activeElement.id");
	check("Tab focuses first image link", active === "linkLeft", active);
	check("keyboard focus shows panel", p.display === "block", p.display);
	check("keyboard hint", p.hint.startsWith("+ / "), p.hint);
	await key("+", "Equal", 187); await sleep(100); p = await panel();
	check("+ zooms in", parseFloat(p.size) > p.w + 1, p.size);
	const before = p.pos; await key("ArrowRight", "ArrowRight", 39); await sleep(100);
	check("arrow pans when zoomed", (await panel()).pos !== before, (await panel()).pos);
	await key("Escape", "Escape", 27); await sleep(100);
	check("Escape closes keyboard view", (await panel()).display === "none");
	await key("Tab", "Tab", 9); await sleep(300); p = await panel();
	check("Tab to next link shows its view", p.display === "block" && (await ev("document.activeElement.id")) === "linkRight");
	await key("Tab", "Tab", 9); await key("Tab", "Tab", 9); await key("Tab", "Tab", 9); await sleep(200);
	check("Tab off the links closes view", (await panel()).display === "none");
	// 10. mouse click focus doesn't open the keyboard view; turned off shows nothing
	await ev("document.body.focus(); mczMediaZoom.setEnabled(false)");
	await mouse("mouseMoved", L.x + L.w / 2, L.y + L.h / 2); await sleep(200);
	check("setEnabled(false): hover shows nothing", (await panel()).display === "none");
	await ev("mczMediaZoom.setEnabled(true)"); await mouse("mouseMoved", 5, 650); await mouse("mouseMoved", L.x + L.w / 2, L.y + L.h / 2); await sleep(200);
	check("setEnabled(true): hover shows again", (await panel()).display === "block");
	check("panel aria-hidden", (await ev("document.querySelector('.mcz-zoom-panel').getAttribute('aria-hidden')")) === "true");
	// errors
	const errs = events.filter((m) => m.sessionId === s && (m.method === "Runtime.exceptionThrown" || (m.method === "Runtime.consoleAPICalled" && m.params.type === "error")));
	check("no script errors or console.error", errs.length === 0, errs.map((m) => JSON.stringify(m.params).slice(0, 200)).join(" | "));
	console.log(failures ? failures + " failed" : "all passed");
	process.exitCode = Math.min(failures, 255);
	await send("Browser.close").catch(() => {});
})().catch((e) => { console.log("FAIL  driver: " + e.message); process.exitCode = 255; }).finally(() => browser.kill());
