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

`notPDF(contentType)`、`serviceWorker`、`notHeld(detail)`、`badStatus(code)`、`differentResponse`、`readFailed(detail)`、`tooLarge(bytes)`、`tabChanged`、`bytesNotPDF`、`pageReplaced`、`timedOut(seconds)`、`damagedReply(detail)`、`stagingFailed(detail)`。缺少目標是 `validate()` 的 usage 錯誤，不在這裡。`notHeld` 只在 fetch 本身 reject 時使用，涵蓋 WebKit 沒持有與 CSP 擋下，兩者在頁面裡都是 `TypeError`，無法區分，訊息照實說；fetch 回答之後的失敗是 `readFailed`。頁面內的錯誤只回報 `e.name`：`e.message` 是 WebKit 的文字，可能帶簽章網址。成功輸出的網址經 `URLText.redactURL`。

### 不需要 Full Disk Access

`save-pdf` 只寫呼叫者指定的檔案，所以不要求 FDA；但 `copyVerified` 的保護資料夾檢查原本假設呼叫者打得開 Safari 的快取資料夾（`pdf-cache` 打得開）。`protectedFoldersMayBeClosed` 只給這個指令：打不開（EPERM、EACCES）時改比對路徑文字，其餘照舊。`pdf-cache` 維持「打不開不算通過」。測試程序持有 FDA，一般單元測試走不到這條路；以 `sandbox-exec` 拒絕讀那個資料夾可以重現（回 EPERM，與 TCC 相同）。

### 回應要是這個網址的完整文件

`only-if-cached` 依網址查，所以腳本要求 status 200（206 不是文件）、不是 redirect、回應網址等於分頁網址（不含 fragment）。這擋不住同網址內容已換的情形：另一個分頁重新載入過、或文件來自 POST 時，存到的可能不是畫面上那一份，而 `%PDF-`、頁面檢查、byte 數都會通過，頁面內也讀不到顯示中的位元組來比對。文件照實說這是「WebKit 為這個網址持有的內容」。

### 先讀網址，腳本再比對

目標解析之後、啟動腳本之前，`--window N --tab-in-window M` 的分頁可能移位，`--first-match` 的 #79 重新解析可能換到同視窗另一個分頁。多一次往返先讀 `location.href`，腳本比對不符就不呼叫 fetch。這不是身分檢查：兩個分頁同網址時分不出來，而那時存到的內容也相同。

## Implementation Contract

**頁面腳本**（`TabPDFReader.startScript(slot:expectedURL:maxBytes:)`，一次 `do JavaScript`，立即返回）：

```
(<sweep>, window.K = { u: <stamp> }, (function(s){
  function fail(code, detail) { s.fail = code; s.detail = detail; s.done = true; }
  function named(e) { return e && e.name ? e.name : 'Error'; }
  if (location.href !== 'EXPECTED') { fail('tab-changed', ''); return; }
  if (document.contentType !== 'application/pdf') { fail('not-pdf', document.contentType); return; }
  if (navigator.serviceWorker && navigator.serviceWorker.controller) { fail('service-worker', ''); return; }
  fetch(location.href, { cache: 'only-if-cached', mode: 'same-origin' })
    .then(function(r){
      if (r.status !== 200) { fail('status', r.status); return null; }
      if (r.redirected || r.url !== location.href.split('#')[0]) { fail('other-response', ''); return null; }
      return r.blob();
    }, function(e){ fail('not-held', named(e)); return null; })
    .then(function(b){ if (!b) return null; s.bytes = b.size;
      if (b.size > MAX) { fail('too-large', '' + b.size); return null; }
      return new Promise(function(res, rej){ var f = new FileReader();
        f.onload = function(){ res(f.result); }; f.onerror = function(){ rej(f.error); }; f.readAsDataURL(b); }); })
    .then(function(u){ if (u === null) return; var i = u.lastIndexOf(','); var t = i < 0 ? '' : u.slice(i + 1); s.text = t; s.len = t.length; s.done = true; })
    .catch(function(e){ fail('read-failed', named(e)); });
})(window.K), 1)
```

**狀態腳本**（`statusScript(slot:)`）回傳封閉格式之一：`gone`、`wait`、`ok:<bytes>:<len>`、`fail:<code>:<detail>`。`parseStatus` 對其他內容一律視為 `damagedReply`。

**流程**（`TabPDFReader.read(target:) async throws -> Read`）：start → 每 100 ms 輪詢，上限 `TabPDFReader.deadlineSeconds = 60` → 依狀態分派 → `SafariBridge.readResultSlot` 讀 base64 → `Data(base64Encoded:)` → 比對 byte 數 → 讀 `s.url`；結束時移除槽（逾時除外，`ResultSlot.removalIsWorthTrying`）。

**輸出**：文字 `<path>  <size> B  <pages> page(s)  from tab <redacted url>`；`--json` 為 `{path,size,pages,source:"tab",url}`。結束碼：成功 0；沒有目標是 usage 錯誤（64，由 `validate()` 擋下，不碰 Safari）；其餘 1。

**測試縫**：頁面腳本在 `FakePage`（JavaScriptCore）裡真的執行，以 shim 提供 `document`、`navigator`、`fetch`、`FileReader`；`DaemonRequestContext.appleScriptRunner` 接到 `FakePage`。

## Risks / Trade-offs

- WebKit 記憶體快取可能被清掉（實測 8 分鐘仍在，更久未測）→ `notHeld` 訊息指引重新顯示分頁或交給使用者，不連網。
- 網站 CSP 可能擋下 fetch（ScienceDirect 未擋）→ 同上。
- 頁面可覆寫 `fetch`、`FileReader`，連 `document.contentType` 也可以，因為檢查跑在同一個頁面世界裡：有腳本的 HTML 頁面騙得過它，CLI 仍會回報 `source: "tab"`，只要位元組通過 `%PDF-` 與頁面檢查。實際顯示 PDF 的文件沒有頁面腳本。威脅模型是失誤，不是惡意頁面；CLI 只複核頁面報的數字（大小上限、base64 長度），不讓它決定這邊的配置。
- `only-if-cached` 不連網是 WebKit 的行為，目前在 Safari 27.2 量到；e2e 以伺服器紀錄為準，新版 Safari 要重跑。
- 50 MB 以上的讀回速度尚未量（`do JavaScript` 分塊）→ e2e 量測，超過上限的情況明確失敗。
- 支援 Range 的伺服器上 WebKit 是否持有完整文件，手動量測時的 fixture 不支援 Range，沒有資料 → e2e 加了一個會回 206 的 fixture；status 200 的要求保證部分內容不會當成文件。ScienceDirect 的分頁（1.2 MB）回 200。
- `file:` 分頁未量：依 Fetch 規格 `same-origin` 會 reject，訊息會是 `notHeld`。
