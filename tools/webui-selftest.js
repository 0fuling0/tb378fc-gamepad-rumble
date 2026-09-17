/* 手柄模块的 WebUI 自检：用极简 DOM 桩把 module/webroot/index.html 真跑一遍。
   目的不是替代浏览器，而是抓运行时错误、命令拼装错误与状态文案错误。

   用法：node tools/webui-selftest.js
   退出码 0 = 全部通过；1 = 有失败（build.sh 里会拦下来）。

   这份是从 tb378fc-hyperos-fix-lite 的 tools/webui-selftest.js 改的 ——
   桩和断言风格保持一致，只是场景换成手柄模块的两个开关 / 一张状态卡。 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

/* ---------------------------------------------------------------- DOM 桩 */
class ClassList {
  constructor(node) { this.node = node; this.set = new Set(); }
  _sync() { this.node._className = [...this.set].join(' '); }
  add(...c) { c.forEach(x => x && this.set.add(x)); this._sync(); }
  remove(...c) { c.forEach(x => this.set.delete(x)); this._sync(); }
  contains(c) { return this.set.has(c); }
}

class Node {
  constructor(tag) {
    this.tagName = String(tag || '').toUpperCase();
    this.children = []; this.parent = null;
    this._text = ''; this._className = '';
    this.classList = new ClassList(this);
    this.style = {}; this.dataset = {}; this.attrs = {};
    this.handlers = {};
    this.value = ''; this.disabled = false; this.id = '';
    this.scrollTop = 0; this.scrollHeight = 0;
  }
  get className() { return this._className; }
  set className(v) {
    this._className = v || '';
    this.classList.set = new Set(String(v || '').split(/\s+/).filter(Boolean));
  }
  get textContent() {
    if (this.children.length === 0) return this._text;
    return this.children.map(c => c.textContent).join('');
  }
  set textContent(v) { this._text = String(v == null ? '' : v); this.children = []; }
  appendChild(n) { if (!n) return n; n.parent = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); }
  async fire(type) {
    for (const fn of (this.handlers[type] || [])) await fn({ type });
  }
  querySelector() { return null; }
  querySelectorAll() { return []; }
}

const IDS = {};
/* 所有通过 #id 取到的节点都必须挂到 documentElement 下 —— 否则下面基于遍历的
   allByClass()/switches() 找不到它们。 */
const ROOT = new Node('html');
function nodeForId(id) {
  if (!IDS[id]) { IDS[id] = new Node('div'); IDS[id].id = id; ROOT.appendChild(IDS[id]); }
  return IDS[id];
}

const documentStub = {
  documentElement: ROOT,
  createElement: t => new Node(t),
  querySelector(sel) {
    const m = /^#([\w-]+)$/.exec(sel);
    return m ? nodeForId(m[1]) : null;
  },
  querySelectorAll(sel) {
    // 桩只需要支持 "button" 这一种（setBusy 用它统一置 disabled）
    if (sel !== 'button') return [];
    const out = [];
    (function w(n) { for (const c of n.children) { if (c.tagName === 'BUTTON') out.push(c); w(c); } })(ROOT);
    return out;
  }
};
ROOT.dataset = {};

globalThis.document = documentStub;

/* ---------------------------------------------------------------- 假 ksu.exec */
const CALLS = [];
const CFG = { FIX_GAMEPAD_RUMBLE: 1 };
const STATE = {
  RUMBLE_SETTING: '1', BRIDGE_RUNNING: 1,
  PAD_COUNT: 1, PAD_MAP: '11 /dev/hidraw0',
  VERSION: 'v1.0', MARKERS: ''
};
let JSON_BROKEN = false;

function jsonOut() {
  if (JSON_BROKEN) return '';
  return JSON.stringify(Object.assign({}, CFG, STATE));
}

const ksu = {
  exec: async (cmd) => {
    CALLS.push(cmd);
    if (cmd.includes('--json')) return jsonOut();
    if (cmd.includes('--set')) {
      const m = /--set\s+([A-Za-z_][A-Za-z0-9_]*)\s+(\S+)/.exec(cmd);
      if (m) CFG[m[1]] = Number(m[2]);
      return '已写入 1 项（重启设备后由 service.sh 生效）';
    }
    if (cmd.includes('--once')) return '已发送 1 次：左=255 右=255 时长=1000ms';
    if (cmd.includes('--status')) return 'TB378FC 手柄震动修复  v1.0\n本项开关         : 开';
    return '';
  }
};

globalThis.window = { matchMedia: () => ({ matches: false }), ksu: ksu };
globalThis.ksu = ksu;

/* ---------------------------------------------------------------- 加载被测页面 */
const HTML = fs.readFileSync(path.join(__dirname, '..', 'module', 'webroot', 'index.html'), 'utf8');
const scriptMatch = /<script>([\s\S]*?)<\/script>/.exec(HTML);
if (!scriptMatch) { console.log('✗ index.html 里找不到 <script> 块'); process.exit(1); }
vm.runInThisContext(scriptMatch[1], { filename: 'webroot/index.html' });

/* ---------------------------------------------------------------- 工具 */
const sleep = ms => new Promise(r => setTimeout(r, ms));

function walk(node, pred, out) {
  out = out || [];
  for (const c of node.children) { if (pred(c)) out.push(c); walk(c, pred, out); }
  return out;
}
function allByClass(cls) { return walk(documentStub.documentElement, n => n.classList.contains(cls)); }
function switches() { return allByClass('sw'); }
function pills() { return allByClass('st'); }
function texts(cls) { return allByClass(cls).map(n => n.textContent); }
function callsMatching(re) { return CALLS.filter(c => re.test(c)); }
function btnByText(t) { return allByClass('btn').find(b => b.textContent.includes(t)); }

function expect(errs, cond, msg) { if (!cond) errs.push(msg); }
function report(n, name, errs, okMsg) {
  if (errs.length) { console.log(`✗ 场景 ${n} 失败:`); errs.forEach(e => console.log('   - ' + e)); return 1; }
  console.log(`✓ 场景 ${n} 通过：${okMsg}`);
  return 0;
}

/* ---------------------------------------------------------------- 场景 */
(async () => {
  let failed = 0;

  /* ---- 场景 1：初始渲染 ---- */
  {
    await sleep(60);
    const errs = [];
    const sw = switches();
    expect(errs, sw.length === 1, `应有 1 个开关（① 的），实际 ${sw.length}`);
    expect(errs, sw[0] && sw[0].getAttribute('aria-checked') === 'true', '① 开关初始应为开（aria-checked=true）');
    expect(errs, pills().length === 2, `应有 2 个状态胶囊（①②），实际 ${pills().length}`);
    const n = texts('n').join('|');
    expect(errs, n.includes('打开「输入设备振动」开关'), '缺少 ① 标题');
    expect(errs, n.includes('补发手柄 FF 报告'), '缺少 ② 标题');
    expect(errs, n.includes('手柄与链路'), '缺少 ③ 卡片标题');
    expect(errs, texts('fixed').join('') === '自动', '② 应显示「自动」胶囊（它没有开关）');
    expect(errs, texts('kv').join('').includes('/dev/hidraw0'), '③ 应显示手柄映射');
    expect(errs, callsMatching(/--json/).length >= 1, '启动时应调用一次 --json');
    // 三个编号徽标都在
    expect(errs, texts('num').join('|') === '①|②|③', `编号徽标应为 ①②③，实际 ${texts('num').join('|')}`);
    failed += report(1, '初始渲染', errs, '1 开关 + ①② 状态胶囊 + ③ 手柄与链路');
  }

  /* ---- 场景 2：拨 ① 关 → 必须恰好发一条 --set FIX_GAMEPAD_RUMBLE 0 ---- */
  {
    CALLS.length = 0;
    await switches()[0].fire('click');
    await sleep(60);
    const errs = [];
    const set = callsMatching(/--set/);
    expect(errs, set.length === 1, `应恰好发出 1 条 --set，实际 ${set.length}：${set.join(' / ')}`);
    expect(errs, /--set\s+FIX_GAMEPAD_RUMBLE\s+0/.test(set[0] || ''), `--set 参数不对：${set[0]}`);
    expect(errs, CFG.FIX_GAMEPAD_RUMBLE === 0, '桩里的 config 应被改成 0');
    expect(errs, switches()[0].getAttribute('aria-checked') === 'false', '拨完后 ① 应显示为关');
    failed += report(2, '拨 ① 关', errs, '只发一次 --set，且界面跟随');
  }

  /* ---- 场景 3：拨 ① 开 → --set FIX_GAMEPAD_RUMBLE 1 ---- */
  {
    CALLS.length = 0;
    await switches()[0].fire('click');
    await sleep(60);
    const errs = [];
    const set = callsMatching(/--set/);
    expect(errs, set.length === 1, `应恰好发出 1 条 --set，实际 ${set.length}`);
    expect(errs, /--set\s+FIX_GAMEPAD_RUMBLE\s+1/.test(set[0] || ''), `--set 参数不对：${set[0]}`);
    expect(errs, switches()[0].getAttribute('aria-checked') === 'true', '拨完后 ① 应显示为开');
    failed += report(3, '拨 ① 开', errs, '发出正确的 --set');
  }

  /* ---- 场景 4：「测试震动」必须走 --once，且不能顺带写 config ---- */
  {
    CALLS.length = 0;
    const btn = btnByText('测试震动');
    const errs = [];
    expect(errs, !!btn, '找不到「测试震动」按钮');
    if (btn) {
      await btn.fire('click');
      await sleep(60);
      const once = callsMatching(/--once/);
      expect(errs, once.length === 1, `应恰好发出 1 次 --once，实际 ${once.length}`);
      expect(errs, /--once\s+255\s+255\s+1000/.test(once[0] || ''), `--once 参数不对：${once[0]}`);
      expect(errs, callsMatching(/--set/).length === 0, '测试震动不该顺带发出 --set');
    }
    failed += report(4, '测试震动按钮', errs, '走 --once，不碰 config');
  }

  /* ---- 场景 5：② 的状态文案必须有判别力（四种情形）---- */
  {
    const errs = [];
    const refresh = () => documentStub.querySelector('#refresh').fire('click');

    // (a) 开关关着 → 不该报"未运行"（那是预期行为，不是故障）
    CFG.FIX_GAMEPAD_RUMBLE = 0;
    CALLS.length = 0; await refresh(); await sleep(60);
    let t = pills().map(p => p.textContent).join('|');
    expect(errs, /不会启动/.test(t), `① 关着时 ② 应说"不会启动"，实际：${t}`);
    expect(errs, !/未运行/.test(t), `① 关着时不该报"未运行"（会被误认为故障），实际：${t}`);

    // (b) 开关开着但没有手柄 → 说"等待手柄接入"
    CFG.FIX_GAMEPAD_RUMBLE = 1; STATE.PAD_COUNT = 0; STATE.BRIDGE_RUNNING = 0;
    CALLS.length = 0; await refresh(); await sleep(60);
    t = pills().map(p => p.textContent).join('|');
    expect(errs, /等待手柄接入/.test(t), `没手柄时应说"等待手柄接入"，实际：${t}`);
    expect(errs, !/未运行/.test(t), `没手柄时不该报"未运行"，实际：${t}`);

    // (c) 有手柄 + 在跑 → 运行中
    STATE.PAD_COUNT = 1; STATE.BRIDGE_RUNNING = 1;
    CALLS.length = 0; await refresh(); await sleep(60);
    t = pills().map(p => p.textContent).join('|');
    expect(errs, /运行中/.test(t), `守护进程在跑时应说"运行中"，实际：${t}`);

    // (d) 有手柄 + 没跑 → 这才是真故障，必须报出来
    STATE.BRIDGE_RUNNING = 0;
    CALLS.length = 0; await refresh(); await sleep(60);
    t = pills().map(p => p.textContent).join('|');
    expect(errs, /未运行/.test(t), `有手柄但守护进程没跑时必须报"未运行"，实际：${t}`);
    expect(errs, /重启设备/.test(t), `"未运行"时应给出处置提示，实际：${t}`);

    failed += report(5, '② 状态文案', errs, '四种情形各说各话（关着/没手柄/在跑/真故障）');
  }

  /* ---- 场景 6：开关标签不能被读成"被修对象的运行状态" ----
     真实踩过的坑（Lite 那边）：③ 卡片原来是「停 BPF 监视器  开 · 已停（…）」，
     「开」是"这项修复启用了吗"，紧跟在标题后面却被读成"监视器：开"。 */
  {
    const errs = [];
    CFG.FIX_GAMEPAD_RUMBLE = 1; STATE.PAD_COUNT = 1; STATE.BRIDGE_RUNNING = 1;
    CALLS.length = 0;
    await documentStub.querySelector('#refresh').fire('click');
    await sleep(60);

    const sub = texts('d').join('|');
    expect(errs, /修复已启用/.test(sub), `① 的副标题应写明"修复已启用"，实际：${sub}`);
    // 不能出现孤零零的"开"/"关"当开关标签
    expect(errs, !/(^|\|)\s*开\s*(\||$)/.test(sub), `副标题里不该出现裸的"开"，实际：${sub}`);
    expect(errs, !/(^|\|)\s*关\s*(\||$)/.test(sub), `副标题里不该出现裸的"关"，实际：${sub}`);

    // ① 的副标题靠 vibrate_input_devices 这个标识来认（标题文字在 .n 里，副标题不重复它）
    const line1 = texts('d').find(x => x.includes('vibrate_input_devices'));
    expect(errs, !!line1, `找不到 ① 的副标题，实际：${sub}`);
    expect(errs, line1 && /修复已启用/.test(line1) && /vibrate_input_devices=1/.test(line1),
      `① 副标题应同时说清"修复已启用"和开关值，实际：${line1}`);
    // ② 没有开关，副标题应说明这一点，而不是留空
    const line2 = texts('d').find(x => x.includes('自动运行'));
    expect(errs, !!line2, `② 的副标题应写明"自动运行 · 没有开关"，实际：${sub}`);
    failed += report(6, '开关标签语义', errs, '不会被误读成"被修对象在运行"');
  }

  /* ---- 场景 7：标记文件提示 ---- */
  {
    const errs = [];
    STATE.MARKERS = ' disable-gamerumble';
    CALLS.length = 0;
    await documentStub.querySelector('#refresh').fire('click');
    await sleep(60);
    let m = documentStub.querySelector('#markers').textContent;
    expect(errs, /disable-gamerumble/.test(m) && /优先级高于开关/.test(m), `有标记文件时应提示，实际：${m}`);

    STATE.MARKERS = '';
    CALLS.length = 0;
    await documentStub.querySelector('#refresh').fire('click');
    await sleep(60);
    m = documentStub.querySelector('#markers').textContent;
    expect(errs, /没有 disable-\* 标记文件/.test(m), `没标记文件时也应说明，实际：${m}`);
    failed += report(7, '标记文件提示', errs, '有/无两种情况都有正确文案');
  }

  /* ---- 场景 8：--json 读不到时必须给出可读错误，且不崩 ---- */
  {
    const errs = [];
    JSON_BROKEN = true;
    CALLS.length = 0;
    await documentStub.querySelector('#refresh').fire('click');
    await sleep(60);
    const ver = documentStub.querySelector('#ver').textContent;
    const log = documentStub.querySelector('#log').textContent;
    expect(errs, /读取失败/.test(ver), `读不到状态时 #ver 应显示"读取失败"，实际：${ver}`);
    expect(errs, /读取失败/.test(log), `读不到状态时应写进操作日志，实际日志尾部：${log.slice(-80)}`);
    expect(errs, switches().length === 1, '出错后界面结构不该被破坏');

    JSON_BROKEN = false;
    await documentStub.querySelector('#refresh').fire('click');
    await sleep(60);
    expect(errs, /版本 v1\.0/.test(documentStub.querySelector('#ver').textContent), '恢复后应能正常刷新');
    failed += report(8, '读不到状态', errs, '给出可读错误且能恢复');
  }

  console.log('');
  if (failed) { console.log(`✗ 有 ${failed} 个场景失败`); process.exit(1); }
  console.log('全部场景通过 ✓');
})();
