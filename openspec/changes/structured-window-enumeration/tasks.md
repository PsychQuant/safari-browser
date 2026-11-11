## 1. Source form 的解析與轉換

- [x] 1.1 [P] 「線上格式採用 AppleScript source form，兩條路徑各自產生」的解析半邊：`AppleScriptValue`（`list` / `text` / `integer` / `missingValue` / `other`）與 `AppleScriptSourceForm.parse(_:)`，以 UTF-8 位元組掃描（不以 `Character`），字串只認 `\"` 與 `\\` 兩種跳脫，原子只認十進位整數與 `missing value`，其餘原子為 `other`，結尾不能有多餘內容，空字串丟錯。先寫 `AppleScriptSourceFormTests`（巢狀 list、`"` 後接 U+0301、CR/LF/NUL/GS/RS 在字串內、`2.147483647E+9` 與 `«class doub»` 都是 `other`、未結束的字串、不認得的跳脫、多餘的 `}`）看它失敗，再實作到全部通過。
- [x] 1.2 「Both execution paths produce the enumeration in AppleScript source form」的轉換半邊：`AppleScriptSourceForm.render(_ descriptor:)` 把 list、文字、整數（`typeSInt32`）、`missing value` 轉成與 `osascript -s s` 位元組相同的文字，其他型別輸出 `«class xxxx»`；依「孤立代理依 osascript 的規則截斷」在 `"` / `\` 處分段、每段截在第一個孤立代理。驗證：新測試以同一份 AppleScript 常值腳本（全 BMP 分段、emoji/ZWJ/tag、`"`/`\`/GS/RS 後接組合字元、孤立代理表格、整數、`missing value`、`{}`、`{{}}`）分別跑真的 `osascript -s s` 與 `NSAppleScript`，斷言位元組相同；另以固定種子的隨機字串（含孤立代理）比對 200 組。

## 2. 列舉的解碼與錯誤

- [x] 2.1 「錯誤沿用 windowEnumerationCorrupt」：恢復 `SafariBrowserError.windowEnumerationCorrupt(reason:)`，說明改寫成結構化輸出的版本（不提 U+FFFD）；恢復 6c07d65 拿掉的 `enumerationFailureNote` 種類「the list came back malformed」與 `EnumerationFailureNoteTests.testTheFailureNoteNamesTheKindOfFailureOnly` 的那組案例（斷言不含原因文字）。驗證：`EnumerationFailureNoteTests` 先失敗後通過。
- [x] 2.2 「The enumeration decoder fails closed」與「解碼器保留與丟掉的檢查」：`SafariBridge.decodeWindowEnumeration(_:) throws -> [WindowInfo]` 取代 `parseWindowEnumeration`，實作 design.md 列的七項檢查，`missing value` 解成 `""` / nil，0 分頁視窗的 `currentTabIndex` 為 1，profile 由視窗名稱解析。先寫 `WindowEnumerationDecoderTests`：正常清單（含 0 分頁視窗、無 id、無名稱）、`{}` 是零個視窗、`""` 被拒絕、規格表格的每一列被拒絕、每個拒絕的原因不含任何字串內容（字串裡放哨兵 `SECRET`）。
- [x] 2.3 「Page text cannot forge enumeration rows」：以 AppleScript 常值做出與列舉同形的清單，標題與視窗名稱放入 #355 量到的偽造紀錄（RS + tab 99 的紀錄 + RS）、Diagnosis 的 A–E 型、`"`、`\`、CR、LF、組合字元，經 `osascript -s s` 與 `NSAppleScript` + `render` 兩條路徑解碼。驗證：`WindowEnumerationTransportTests` 斷言兩條路徑的 `[WindowInfo]` 相同、分頁數等於真實分頁數、標題原樣保留、profile 與 window id 不變。
- [x] 2.4 「Page text cannot forge enumeration rows」的真機新證據（issue 留言 6743483662）：Safari 把標題截在 1000 個 UTF-16 單位、切開代理對。`AppleScriptSourceForm.render` 改為直接讀 descriptor 的 `utxt` 位元組，不經過 Swift `String`（其 `utf16` 檢視已把孤立代理換成 U+FFFD）。驗證：`WindowEnumerationTransportTests` 新增「`a` × 999 + 孤立 U+D83D」的兩分頁視窗，兩條路徑都列出 2 個分頁、標題為 999 個 `a`、window id 4711 與 profile 保留，`flattenWindowsToDocuments` / `jsonRows` 兩列，`pickNativeTarget` 以 `--url` 與 `--window-id 4711 --profile 個人` 都選到；`decodeWindowEnumeration` 的拒絕表補上「網址比標題少」一列（變異檢查 equal-lists 存活所補）。

## 3. 列舉腳本

- [x] 3.1 「The window enumeration returns one structured record per window」與「列舉腳本回傳每個視窗一筆的 AppleScript list」：`listAllWindowsScript` 改成回傳 `{{w, winID, winName, currentIdx, urls, names}, …}`，0 分頁視窗 `{w, winID, winName, 0, {}, {}}`，沒有視窗回 `{}`；移除逐分頁串接與 GS/RS。保留 `set windowCount to count of windows`、#180 的整批讀取、`urls2` 以 `considering case` 比較、逐分頁退路。驗證：先改寫 `ZeroTabWindowGuardTests` 與 `WindowEnumerationBatchingTests` 的結構釘選（恰好兩個 `set end of output to {w,` 發射點、兩者元素數相同為 6、空殼在 `else` 路徑且不讀 `current tab`、`currentIdx` 是 guard 內第一句、整批讀取與 `urls = urls2`、退路只出現在 `if not stable then` 之後、腳本內沒有 `character id`），看它們失敗再改腳本；加一個 `NSAppleScript` 編譯檢查。

## 4. 兩條執行路徑的接線

- [x] 4.1 「只有被要求時 daemon 才轉成 source form」的 daemon 端：`CompileCache.execute(source:renderSourceForm:)` 在 main actor 上轉換並放進 `ExecutionResult.sourceForm`；`applescript.execute` 讀 `resultForm`（`sourceForm` 才轉換、沒有則照舊、其他值回 `status: error`、`errorKind: badRequest`）。驗證：handler 測試（不需 Safari）對 `return {1, "a\"b", missing value}` 帶 `resultForm` 時輸出等於 `osascript -s s`，不帶時輸出不變，`resultForm: "bogus"` 回 badRequest。
- [x] 4.2 in-process 與 client 端：`DaemonRequestContext.appleScriptSourceFormRunner`，`exec.runScript` 經同一個 helper 同時裝好 `appleScriptRunner` 與它；`executeAppleScriptViaDaemon` 可帶 `resultForm`；`SafariBridge.runAppleScriptSourceForm` 依序用 source form runner、`appleScriptRunner`、router（daemon 帶 `resultForm`，stateless 用 `osascript -s s -e`）。驗證：helper 測試在 helper 內以 `runAppleScriptSourceForm` 跑常值腳本、解碼成功；router 測試的 stateless 閉包收到 `["-s", "s", "-e", …]`。
- [x] 4.3 `listAllWindows()` 改走 `runAppleScriptSourceForm` + `decodeWindowEnumeration`。驗證：`DocumentsCommand` 的 `--json` 測試（假 Safari）鍵與列不變；一個假 Safari 回 `""` 的測試確認指令失敗而不是列出零個視窗。

## 5. 測試假資料

- [x] 5.1 [P] 「測試假資料由單一 helper 產生」：新增 `Tests/SafariBrowserTests/FakeEnumeration.swift`（自己實作 `"` / `\` 跳脫），把 `DialogListingRenderingTests`、`WindowIndexResolverTests`、`ResolverConvergenceTests`、`WindowIDCommandTests`、`JSCommandRoundTripTests`、`TargetIdentityTests`、`PreCompiledScriptsTests`、`ExecSharedTargetTests`、`WindowPinFakeSafari`、`MissFakeSafari`、`ZeroTabWindowGuardTests` 的 GS/RS 假列舉全部改用它；只為舊 4/5/6 欄相容而存在的測試改寫成新格式下的對應（無名稱、無 id）或刪除並在 commit 說明。驗證：一個測試斷言 helper 輸出 = `render` 輸出 = 真 `osascript -s s` 輸出；`grep` 確認 Tests 裡沒有剩下以 GS/RS 組列舉的地方。

## 6. 文件

- [x] 6.1 [P] 「Document not found surfaces discoverable error」的規格句恢復「a malformed list」（`openspec/specs/document-targeting/spec.md`，於 archive 時由 delta 帶入）；CHANGELOG #362 那一行恢復「a malformed list」並新增 #355 的 Unreleased 條目；`CLAUDE.md` 的列舉段落與 `listAllWindowsScript` 的 doc comment 改寫成結構化格式（量測數字指向 design.md）。驗證：內容審閱；`grep` 確認沒有殘留「These bytes do not appear in percent-encoded URLs」與 U+FFFD 替換的說法。

## 7. 驗收

- [x] 7.1 完整 `swift test`，回報測試數、略過數與失敗數；MCP 程序計時測試若失敗（#318/#332），單獨重跑並兩次都回報。
- [x] 7.2 變異檢查：解碼器七項檢查、空字串拒絕、孤立代理截斷、`resultForm` 分支、`-s s` 參數各拿掉一次，記下哪個具名測試失敗。
- [ ] 7.3 真 Safari 驗收（不在本次執行範圍，orchestrator 執行）：重讀 #355 的偽造標題 fixture 與一個長標題 fixture，`documents --json` 列數等於分頁數、標題原樣；量 Safari 是否截斷長標題（已量：1000 個 UTF-16 單位，issue 留言 6743483662），並加上截在代理對中間的標題（`a` × 999 + 😀）：兩列、標題為 999 個 `a`、window id 保留、`--window-id` 選得到。尚未執行：本次執行不碰 Safari。

## 8. Verify 第二輪的修正

- [x] 8.1 daemon 對 `resultForm: "sourceForm"` 回空字串（沒有 stamp、通過握手的舊 daemon，#320）時，`runAppleScriptSourceForm` 丟 `protocolError`，router 印一行 `[daemon fallback: …]` 改走 stateless（唯讀腳本才能重跑）；design.md 的握手說法與 Migration Plan 更正。驗證：當時的 `SourceFormEndToEndTests.testADaemonThatIgnoresTheResultFormFallsBackToTheStatelessPath`（第三輪隨送出後重跑一起刪除，改由 `testADaemonWithoutTheCapabilityIsNotAskedAndTheStatelessPathRuns` 取代）。（第三輪由 9.1 取代：改成送出前檢查握手宣告的能力，送出後不再重跑。）
- [x] 8.2 `resultForm` 有出現但不是字串時回 `badRequest`。驗證：`SourceFormDaemonPathTests.testAResultFormThatIsNotAStringIsABadRequest`。
- [x] 8.3 有分頁而目前分頁索引超出 1…分頁數時，列出該視窗所有分頁、沒有目前分頁、`currentTabIndex` 為 0；重複 window id 仍失敗；`windowEnumerationCorrupt` 的訊息改說視窗或分頁可能在讀取途中改變。驗證：`WindowEnumerationDecoderTests.testACurrentTabOutsideTheTabsMarksNoTabCurrent`、`testAWindowWithoutACurrentTabStillResolvesAndListsWithoutAMarker`（`--window-id` / `--window N --tab-in-window` / `--url` 都明確切換到分頁、`documents` 沒有 `*`、`is_current` 全為 false）。
- [x] 8.4 規格與解碼器說明：列與 window id 只取決於結構，profile 由視窗名稱解析（預設 profile 視窗的名稱是頁面標題，#364）。驗證：內容審閱。
- [x] 8.5 規格的「字元不變」限縮到解碼後的值與 `--json`；text-mode 跳脫另案 #369。CHANGELOG 改成只有 U+001D/U+001E 在 text-mode 有變化。驗證：內容審閱。
- [x] 8.6 design.md 移除 `runTargetedAppleScript` 的 `try?` 舊說法。驗證：`grep` 無殘留。
- [x] 8.7 `PreCompiledScriptsTests` 兩個以 `""` 回答列舉的假 Safari 改回 `{}`，其中一個斷言清單不是失敗說明。驗證：該測試。
- [x] 8.8 `render` 只把 `utxt` 寫成字串，原始 `utf8` / `TEXT` 資料寫成 `«class …»`；規格的位元組相同限縮到列舉會回傳的值，並記下整數型別原始資料的例外。驗證：`SourceFormEndToEndTests.testRawTextDataIsOpaqueOnBothPaths`。
- [x] 8.9 CHANGELOG 的孤立代理說法與規格一致。驗證：內容審閱。
- [x] 8.10 design.md 記下 daemon 回覆上限的餘裕約為舊格式的一半（頁面控制的反斜線在 wire 上 4 bytes），超過時 daemon 路徑結果未知、stateless 不受影響。驗證：內容審閱。
- [x] 8.11 CHANGELOG 與 design.md 記下 window id 達 2^29 時列舉失敗。驗證：內容審閱。

## 9. Verify 第三輪的修正

- [x] 9.1 「Daemon announces its capabilities in the handshake」與「Client requires a capability before sending a request that needs it」：daemon 在 v2 握手的 `protocol.capabilities` 宣告 `"sourceForm"`；source form 請求與 `exec.runScript` 在送出前檢查，沒有宣告就丟 `missingCapability`（fallback 行指向 `safari-browser daemon stop`），改走 stateless／逐步執行；拿掉第二輪的空回覆送出後重跑，空回覆交給解碼器而失敗。驗證：`SourceFormEndToEndTests` 的 `testTheHandshakeAnnouncesTheSourceFormCapability`、`testADaemonWithoutTheCapabilityIsNotAskedAndTheStatelessPathRuns`、`testAnEmptyAnswerFromACapableDaemonIsAnErrorNotARerun`、`testExecDoesNotSendAScriptToADaemonWithoutTheCapability`。
- [x] 9.2 `checkWindowID` 的清單：只有沒有分頁的視窗印 `(0 tabs)`，有分頁而沒有目前分頁印 `(unknown)`。驗證：`WindowEnumerationDecoderTests.testAWindowIDMissListsAWindowWithoutACurrentTabAsUnknown`。
- [x] 9.3 只有目前分頁索引大於分頁數時算「沒有目前分頁」；有分頁而小於 1 仍失敗。驗證：`testACurrentTabOutsideTheTabsMarksNoTabCurrent`、`testACurrentTabBelowOneOnAWindowWithTabsStillFails`。
- [x] 9.4 `windowEnumerationCorrupt` 的建議依原因分三種（`WindowEnumerationProblem`）。驗證：`testTheMessageMatchesTheReason`。
- [x] 9.5 用語：CHANGELOG（只有 `documents` 的 text-mode 有變化；競態的實際變化是指定分頁的目標會切到 tab 1；舊 daemon 改為握手能力）、解碼器說明、design.md 的重複 id 說法與 exec、Migration Plan、`documents` 圖例、規格情境的具名 profile 視窗、CLAUDE.md 的握手說明。驗證：內容審閱；`DocumentsCommandTests.testLegendLineExplainsAsteriskAndPointsToJSON`。

## 10. Verify 第四輪的修正

- [x] 10.1 兩個 Python 套件的假 daemon（`Tests/daemon-peer-disconnect-test.py`、`Tests/command-pacing-test.py`）的握手加上 `capabilities: ['sourceForm']`；「Client requires a capability before sending a request that needs it」寫明能力檢查先於 #202 的大小檢查。驗證：跑 `daemon-peer-disconnect-test.py`；`command-pacing-test.py` 先讀碼確認沒有子測試會碰到 Safari，再在拒絕 Apple event 的 `sandbox-exec` 下跑。
- [x] 10.2 fallback 行、design.md、規格與 CHANGELOG 改成 `safari-browser daemon stop` 再 `safari-browser daemon start`。驗證：`SourceFormEndToEndTests` 的兩個 fallback 測試斷言兩個指令都在。
- [x] 10.3 文件寫明 #304 之前的已安裝 release 也宣告 `1.0.0+unknown(source)`。驗證：內容審閱。
- [x] 10.4 `exec` 對舊 daemon 印一行，再加每個要列舉的步驟各一行；Migration Plan 改成所有 `exec.runScript` 都不送。驗證：內容審閱。
- [x] 10.5 只有實數的 window id（`.real`）得到 2^29 的建議，其他種類是形狀問題；規格、程式與 `testTheMessageMatchesTheReason` 一致。驗證：該測試與 `AppleScriptSourceFormTests.testOtherAtomsAreOpaque`。
- [x] 10.6 競態情境分三類寫明（切換分頁的原生路徑指令、`screenshot` 拒絕、文件範圍的 JS 不變）。驗證：內容審閱。
- [x] 10.7 「Daemon-routed execution when available」（script-exec）加上能力條件；CLAUDE.md 的 failure modes、exec 段落與握手說明；design.md Interface；tasks.md 8.1；規格的 `windowEnumerationCorrupt(reason:kind:)`；persistent-daemon delta 寫明能力清單不是呼叫端身分驗證。驗證：`spectra validate`、內容審閱。

