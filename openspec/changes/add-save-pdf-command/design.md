## Context

`pdf-cache` 的規格禁止執行 JavaScript 與操作 Safari，且只讀磁碟快取。`no-store` 的 PDF 不在那裡（#338）。量測（Safari 27.2）：

| 情況 | `fetch(location.href, {cache:'only-if-cached', mode:'same-origin'})` | 伺服器新請求 |
|---|---|---|
| fixture，`no-store`，251,053 bytes | 200，SHA-256 與原檔相同 | 0 |
| fixture，`no-store`，52,429,210 bytes | 200，轉 base64 後 69,905,616 字元，第一次輪詢（約 1 秒內）已完成 | 0 |
| fixture，從沒載入的網址 | `TypeError: Load failed` | 0 |
| ScienceDirect 簽章 PDF，載入後約 8 分鐘 | 200，1,220,093 bytes，開頭 `%PDF-` | 不連網 |

PDF 分頁的 Accessibility 樹沒有浮出按鈕，所以那條路要 HID。`save-image --with-cookies` 的 `fetchResourceWithCookies` 用固定全域名稱，正是 #190 修掉的那一類問題，不重用。

## Goals / Non-Goals

**Goals:**

- 分頁顯示中的 PDF，不論是否進磁碟快取，都能存成指定路徑。
- 指令本身不造成任何網路請求，也不合成鍵盤滑鼠事件、不切分頁、不搶焦點。
- 失敗時說清楚原因；任何情況都不退回連網。

**Non-Goals:**

- 嵌在 HTML 裡的 PDF、`pdf-cache` 行為變更、HID 路徑、skill 與 akashic 的更新（見 proposal）。

## Decisions

### 獨立指令 `save-pdf`，不放進 pdf-cache

pdf-cache 的價值是「不碰 Safari」這個可驗證的契約（`PDFCacheTests` 在結構上釘住）。替代方案 `pdf-cache get --from-tab` 要改寫它的第一條 requirement。命名與 `save-image` 對稱。

### 一律 `cache: 'only-if-cached'`，沒有第二條路

腳本裡只有這一個 `fetch`。沒持有就失敗，由使用者決定下一步。替代方案「失敗時改用一般 fetch」會把 #338 要避免的重抓帶回來。

### 受 service worker 控制的頁面拒絕讀取

`navigator.serviceWorker.controller` 存在時，`fetch` 會先交給 service worker，它的回應可能來自網路，「不發請求」就不成立。替代方案是照讀並註明，但那會讓保證變成有條件的；這種情況在 PDF 文件上罕見，拒絕的代價小。

### 位元組經 `ResultSlot` 回傳

頁面把 base64 存進這次呼叫自己的槽（`ResultSlot.make()`），CLI 用既有的 `readResultSlot` 分塊讀回，每塊驗證位置與長度。導頁會讓槽消失，讀取就失敗，不會混到另一份文件。解碼後的 byte 數必須等於頁面報的 `Blob.size`。

### 大小上限 256 MiB

超過就在轉 base64 之前失敗（`tooLarge`）。理由：base64 放大 4/3、每 262,144 字元一次 `do JavaScript`，256 MiB 約 1,365 次往返。上限是常數 `TabPDFReader.maxBytes`。實際速度在 e2e 量測後寫進 CHANGELOG。

### 發布重用 `PDFCacheOutput.copyVerified`

解碼後寫到 `mkdtemp` 建的私有資料夾（0700，檔案 0600，`O_EXCL`），交給 `copyVerified`（帶 `expectedSize`），結束時刪除暫存（`defer`）。讀取前先做一次目的地檢查（`PDFCacheOutput.refuseExistingDestination`），避免傳完 50 MB 才被拒；最終判定仍在 `copyVerified`。

### 目標只解析一次

用 `SafariBridge.resolveToAnchoredTarget`，與 `js` 相同。每次往返沿用同一個錨定目標，分頁變動時 fail-closed。接受 `--profile`：這個指令讀分頁本身，沒有 pdf-cache 的跨 profile 問題（#243）。

### 錯誤是封閉列舉 `SavePDFFailure`

`notPDF(contentType)`、`serviceWorker`、`notHeld(detail)`、`badStatus(code)`、`readFailed(detail)`、`tooLarge(bytes)`、`notScriptable`、`bytesNotPDF`、`pageReplaced`、`timedOut(seconds)`、`damagedReply(detail)`、`stagingFailed(detail)`。缺少目標是 `validate()` 的 usage 錯誤，不在這裡。`notHeld` 只在 fetch 本身 reject 時使用，涵蓋 WebKit 沒持有與 CSP 擋下，兩者在頁面裡都是 `TypeError`，無法區分，訊息照實說；fetch 回答之後的失敗是 `readFailed`。頁面內的錯誤只回報 `e.name`：`e.message` 是 WebKit 的文字，可能帶簽章網址。

### 不需要 Full Disk Access

`save-pdf` 只寫呼叫者指定的檔案，所以不要求 FDA；但 `copyVerified` 的保護資料夾檢查原本假設呼叫者打得開 Safari 的快取資料夾（`pdf-cache` 打得開）。`protectedFoldersByPathOnly` 只給這個指令：只比對路徑文字（`cacheFolderPath` 只解析 home），不開也不 stat 那個資料夾。沒有 FDA 時那是別的 app 的資料，碰了可能跳權限對話框，而非干擾原則不允許；`sandbox-exec` 只重現得了 errno（EPERM），重現不了對話框，所以這裡選擇完全不碰。`pdf-cache` 維持「打不開不算通過」。

### 回應是 WebKit 為文件合成的，不要拿它做保證

離屏 `WKWebView` 量到：伺服器回 404、500、203、206，fetch 一律 200 且只有 `content-disposition`、`content-type` 兩個標頭；經 302 到達的分頁 `redirected:false`；兩個 view 同網址不同內容，各回自己顯示的；`no-store` 的 HTML 文件則回 TypeError。所以這個回應不是 HTTP 回應原樣，而是 PDF 文件自己給的。因此不檢查 `redirected` 與回應網址（第 1 輪加過，走不到，而且 ScienceDirect 本身就走轉址）；`r.status !== 200` 留著給不這樣回答的引擎，但不把它當保證。擋下截斷檔的是 `copyVerified` 的頁面檢查：切在 5% 到 99% 的 PDF 都打不開。Safari 上的行為由 e2e 重量；如果不同，這一節與 README 要改。

### 身分靠 slot，網址不離開頁面

第 1 輪曾先讀 `location.href` 再讓腳本比對，第 2 輪拿掉，有兩個理由。它防不了解析目標到第一次讀網址之間的移位，只是把時間窗往前移；而且把完整簽章網址放進腳本，腳本是 `osascript` 的 argv，也會出現在逾時錯誤訊息與 daemon log。`ResultSlot` 只存在那份文件的 JS 環境裡，啟動腳本之後分頁換了任何東西，下一步就讀不到，這比比對網址更強（同網址的兩個分頁也分得開）。啟動之前的位置與 pattern 語意與其他指令相同，輸出列出讀到的網址給呼叫者核對。頁面只回 protocol、host、path。

### 啟動腳本要回固定字串

WebKit 在 PDF 載入期間不執行任何腳本（`Cannot execute JavaScript in this document`，離屏 WKWebView 量到），`do JavaScript` 什麼都不回。回固定字串而不是數字：數字經 AppleScript 可能印成 `1.0`。沒回 `started` 就是 `notScriptable`，不報成回覆損壞。

## Implementation Contract

**頁面腳本**（`TabPDFReader.startScript(slot:maxBytes:)`，一次 `do JavaScript`，立即返回 `'started'`）：

```
(<sweep>, window.K = { u: <stamp> }, (function(s){
  function fail(code, detail) { s.fail = code; s.detail = detail; s.done = true; }
  function named(e) { return e && e.name ? e.name : 'Error'; }
  var type = document.contentType;
  if (type !== 'application/pdf' && type !== 'text/pdf') { fail('not-pdf', type); return; }
  if (navigator.serviceWorker && navigator.serviceWorker.controller) { fail('service-worker', ''); return; }
  s.shown = location.protocol + '//' + location.host + location.pathname;
  fetch(location.href, { cache: 'only-if-cached', mode: 'same-origin' })
    .then(function(r){
      if (r.status !== 200) { fail('status', r.status); return null; }
      return r.blob();
    }, function(e){ fail('not-held', named(e)); return null; })
    .then(function(b){ if (!b) return null; s.bytes = b.size;
      if (b.size > MAX) { fail('too-large', '' + b.size); return null; }
      return new Promise(function(res, rej){ var f = new FileReader();
        f.onload = function(){ res(f.result); }; f.onerror = function(){ rej(f.error); }; f.readAsDataURL(b); }); })
    .then(function(u){ if (u === null) return; var i = u.lastIndexOf(','); var t = i < 0 ? '' : u.slice(i + 1); s.text = t; s.len = t.length; s.done = true; })
    .catch(function(e){ fail('read-failed', named(e)); });
})(window.K), 'started')
```

**狀態腳本**（`statusScript(slot:)`）回傳封閉格式之一：`gone`、`wait`、`ok:<bytes>:<len>`、`fail:<code>:<detail>`。`parseStatus` 對其他內容一律視為 `damagedReply`。

**流程**（`TabPDFReader.read(target:) async throws -> Read`）：start（沒回 `started` 就是 `notScriptable`）→ 每 100 ms 輪詢，期限從 start 之前算，`TabPDFReader.deadlineSeconds = 60` → 依狀態分派，複核頁面報的數字 → 讀 `s.shown` → `SafariBridge.readResultSlot` 讀 base64 → `Data(base64Encoded:)` → 比對 byte 數；結束時移除槽（分頁不再回應時除外，`ResultSlot.removalIsWorthTrying`）。

**輸出**：文字 `<path>  <size> B  <pages> page(s)  from tab <redacted url>`；`--json` 為 `{path,size,pages,source:"tab",url}`。結束碼：成功 0；沒有目標是 usage 錯誤（64，由 `validate()` 擋下，不碰 Safari）；其餘 1。

**測試縫**：頁面腳本在 `FakePage`（JavaScriptCore）裡真的執行，以 shim 提供 `document`、`navigator`、`fetch`、`FileReader`；`DaemonRequestContext.appleScriptRunner` 接到 `FakePage`。

## Risks / Trade-offs

- WebKit 記憶體快取可能被清掉（實測 8 分鐘仍在，更久未測）→ `notHeld` 訊息指引重新顯示分頁或交給使用者，不連網。
- 網站 CSP 可能擋下 fetch（ScienceDirect 未擋）→ 同上。
- 頁面可覆寫 `fetch`、`FileReader`，連 `document.contentType` 也可以，因為檢查跑在同一個頁面世界裡：有腳本的 HTML 頁面騙得過它，CLI 仍會回報 `source: "tab"`，只要位元組通過 `%PDF-` 與頁面檢查。實際顯示 PDF 的文件沒有頁面腳本。威脅模型是失誤，不是惡意頁面；CLI 只複核頁面報的數字（大小上限、base64 長度），不讓它決定這邊的配置。
- `only-if-cached` 不連網是 WebKit 的行為，目前在 Safari 27.2 量到；e2e 以伺服器紀錄為準，新版 Safari 要重跑。
- 50 MB 以上的讀回速度尚未量（`do JavaScript` 分塊）→ e2e 量測，超過上限的情況明確失敗。
- 線性化 PDF 在支援 Range 的伺服器上才會發 Range 請求，手動量測時的 fixture 不是 → e2e 用 `qpdf --linearize` 的 fixture，Range 數為 0 時明確說沒量到。離屏 WKWebView 上這種情況最後取回完整位元組。
- CSP 擋下 fetch 又設了回報端點時，瀏覽器會把含簽章的完整網址 POST 給網站（離屏 WKWebView 量到）→ 頁面事前讀不到 CSP，擋不了；訊息寫「No request for the document was sent」，README 與規格寫明例外，e2e 量。這違背選這條路的前提（網站看不到這個動作），只在這個條件下成立，由維護者知悉。
- `file:` 分頁未量：依 Fetch 規格 `same-origin` 會 reject，訊息會是 `notHeld`。
