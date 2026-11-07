// runner.js：注入台北通服務頁，執行任務腳本中的 click、fill、read、wait 步驟。
//
// Dart 端（task_runner_service.dart）每次頁面載入完成後注入本檔，再逐步呼叫：
//   await controller.callAsyncJavaScript(
//     functionBody: 'return await window.__tpRunner.run(step);',
//     arguments: {'step': step},
//   );
// 成功：回傳 { ok: true, value }；value 只有 read 步驟才有內容。
// 失敗：回傳 { ok: false, code, message }，不丟例外，Dart 端不用解析 JS 錯誤字串。
//   code：not_found（等不到元素）、bad_step（步驟格式錯誤）、failed（其他錯誤）
//
// 步驟格式（關鍵字 {plate} 等由呼叫端先替換好，本檔不處理）：
//   { "click": <定位> }
//   { "fill":  { ...<定位>, "value": "ABC-123" } }
//   { "read":  { ...<定位>, "all"?: true, "pairs"?: true } }
//                                        all：回傳陣列；等到逾時仍沒有符合的元素時回傳 []（例如查無資料），
//                                        不算失敗，所以用 all 時建議把 timeoutMs 設短一點
//   { "wait":  <定位> }                  只等元素出現，不操作（例如等換頁完成）
// 定位（擇一，依序嘗試 selector → near → text）：
//   { "text": "查詢" }                   畫面上看得到的文字；先找完全相符，再找包含
//   { "near": "AAA-8888" }               某段提示文字之後的第一個輸入框；也比對 placeholder、label
//   { "selector": ".base-button" }       CSS selector，前兩種不適用時才用
//   共用選項："index": 0（第幾個符合的元素）、"timeoutMs": 8000
//
// 示範服務站是 Vue 單頁應用：按下查詢後在同一份頁面內換路由，不會觸發 onLoadStop，
// 所以每一步都先等目標元素出現，不依賴頁面載入事件。
(() => {
  const VERSION = 2;
  if (window.__tpRunner && window.__tpRunner.version >= VERSION) return;

  const HIGHLIGHT = '4px solid #F5BA4B';
  const HIGHLIGHT_MS = 800;
  const POLL_MS = 200;
  const DEFAULT_TIMEOUT_MS = 8000;

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();

  // 看得到才算：有尺寸、沒被隱藏，而且水平方向在畫面內（排除滑出畫面的分頁）。
  function isVisible(el) {
    if (!el.isConnected) return false;
    const style = getComputedStyle(el);
    if (style.visibility === 'hidden' || style.display === 'none') return false;
    const rect = el.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) return false;
    return rect.right > 0 && rect.left < window.innerWidth;
  }

  const visibleAll = (selector) => [...document.querySelectorAll(selector)].filter(isVisible);

  const CLICKABLE = 'button, a, label, input, select, [role="button"], [onclick]';
  const FIELD = 'input:not([type="radio"]):not([type="checkbox"]):not([type="hidden"]), textarea';

  // 文字相符的元素中，取最深的一層（避免整個區塊因為包含該文字而被選中）。
  function deepest(list) {
    return list.filter((el) => !list.some((other) => other !== el && el.contains(other)));
  }

  function byText(text) {
    const want = norm(text);
    const all = visibleAll('body *').filter((el) => !['SCRIPT', 'STYLE'].includes(el.tagName));
    let hits = deepest(all.filter((el) => norm(el.innerText) === want));
    if (hits.length === 0) {
      hits = deepest(all.filter((el) => norm(el.innerText).includes(want)));
      hits.sort((a, b) => norm(a.innerText).length - norm(b.innerText).length);
    }
    return hits;
  }

  function byNear(text) {
    const want = norm(text);
    // 1. placeholder、aria-label 直接相符
    const direct = visibleAll(FIELD).filter((el) =>
      norm(el.placeholder).includes(want) || norm(el.getAttribute('aria-label')).includes(want));
    if (direct.length) return direct;
    // 2. 提示文字之後（文件順序）的第一個輸入框；<label for> 優先用它指向的欄位
    const hints = deepest(visibleAll('body *').filter((el) => norm(el.innerText).includes(want)));
    const fields = visibleAll(FIELD);
    const found = [];
    for (const hint of hints) {
      if (hint.tagName === 'LABEL' && hint.control && isVisible(hint.control)) {
        found.push(hint.control);
        continue;
      }
      const next = fields.find((f) => hint.compareDocumentPosition(f) & Node.DOCUMENT_POSITION_FOLLOWING);
      if (next) found.push(next);
    }
    return [...new Set(found)];
  }

  function locateAll(target) {
    if (!target || typeof target !== 'object') return [];
    if (target.selector) return visibleAll(target.selector);
    if (target.near) return byNear(target.near);
    if (target.text) return byText(target.text);
    return [];
  }

  async function find(target, { all = false } = {}) {
    const timeoutMs = target.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const list = locateAll(target);
      if (all && list.length) return list;
      const el = list[target.index ?? 0];
      if (el) return el;
      if (Date.now() >= deadline) {
        const desc = target.selector || target.near || target.text;
        throw Object.assign(new Error(`找不到要操作的元素：${desc}`), { code: 'not_found' });
      }
      await sleep(POLL_MS);
    }
  }

  async function highlight(el) {
    el.scrollIntoView({ block: 'center', behavior: 'instant' });
    const prev = { outline: el.style.outline, offset: el.style.outlineOffset };
    el.style.outline = HIGHLIGHT;
    el.style.outlineOffset = '2px';
    await sleep(HIGHLIGHT_MS);
    return () => {
      el.style.outline = prev.outline;
      el.style.outlineOffset = prev.offset;
    };
  }

  // 用原生 setter 設值，Vue／React 的 v-model 才會收到 input 事件。
  function setValue(el, value) {
    const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // 把「標籤｜值」兩欄的列解析成物件；只有一欄有字的列當成標題。
  function readPairs(el) {
    const out = {};
    for (const row of el.querySelectorAll('*')) {
      if (row.children.length !== 2) continue;
      const [k, v] = [...row.children].map((c) => norm(c.innerText));
      if (!k || out[k] !== undefined) continue;
      if (v) out[k] = v;
      else if (!out.title) out.title = k;
    }
    return out;
  }

  function readValue(el, opts) {
    if (opts.pairs) return readPairs(el);
    if (el.matches(FIELD)) return el.value;
    return norm(el.innerText);
  }

  async function run(step) {
    try {
      const type = ['click', 'fill', 'read', 'wait'].find((key) => step && step[key]);
      if (!type) return { ok: false, code: 'bad_step', message: '不支援的步驟：' + JSON.stringify(step) };
      const target = step[type];

      if (type === 'wait') {
        await find(target);
        return { ok: true, value: null };
      }

      if (type === 'read' && target.all) {
        let list = [];
        try {
          list = await find(target, { all: true });
        } catch (error) {
          if (error.code !== 'not_found') throw error;
        }
        return { ok: true, value: list.map((el) => readValue(el, target)) };
      }

      let el = await find(target);
      if (type === 'click') el = el.closest(CLICKABLE) || el;
      const restore = await highlight(el);
      let value = null;
      try {
        if (type === 'click') el.click();
        if (type === 'fill') {
          el.focus();
          setValue(el, String(target.value ?? ''));
          el.blur();
        }
        if (type === 'read') value = readValue(el, target);
      } finally {
        restore();
      }
      return { ok: true, value };
    } catch (error) {
      return { ok: false, code: error.code || 'failed', message: String(error.message || error) };
    }
  }

  window.__tpRunner = { version: VERSION, run, locateAll };
})();
