## 1. 基準與獨立協定元件

- [x] 1.1 完成「效能與完整驗收」的起始證據：取得非 live cold/warm 與暫時分段量測、區分 spawn syscall／loader／解析／退出，還原診斷原始碼；核對 #110 已合併／verified 與完成清單，將既有 façade 規格同步作為比較基底，不宣稱新 worker 已完成。
- [x] [P] 1.2 實作「私有有界協定」及 Private worker messages are bounded and correlated：MCPWorkerWire.swift／MCPWorkerWireTests.swift，closed message types、UUID、canonical decimal/base64、frame/input/chunk 上限與固定 termination record；以非法型別／過期 id／精確邊界／部分 frame 的 RED／GREEN 驗證，API 按 design 契約供整合使用。
- [x] [P] 1.3 實作「Executable 身分與原 argv 邊界」的 image probe 部分及 Warm workers honor executable identity and argument admission：MCPExecutableIdentity.swift、MCPWorker.swift 的共用 parser 委派與對應 tests；保留原 thin API，加入 bounded thin/FAT32/FAT64、architecture、截斷／overflow／重複 slice／symlink replacement 的 RED／GREEN，未解析成功不得當成身分相符。

## 2. 程序生命週期與 request 邊界

- [x] 2.1 實作「監督程序與存活管線」及 Supervisor ownership survives controller death：private launcher／supervisor／PID lease，唯一 host writer EOF、worker 繼承 group、固定 status pipe、訊號先於 reap；以 owned custodian/controller/suspended-worker 的真實程序測試驗證 controller 死亡及後代終止，失去 reservation 不再 signal，fd 與 group 無跨代誤用。
- [x] 2.2 實作「CLI request scope 與 stdio 封閉」及 Request state and streams are isolated before reuse：每筆 stdin feeder、stdout/stderr relay、flush/seal/join、fresh probe gate/trace，抽出 CLI 不退出程序的共用執行邊界；保留 help/error bytes，補輸入／輸出／late writer／AX busy retirement 的 RED／GREEN，已知輔助 task 要在可重用之前真正結束。
- [x] 2.3 串接 hidden __mcp-supervise／__mcp-worker 與協定／capture，履行 Persistent workers execute fresh command instances：健康 command 在同 PID 執行多筆，hidden/MCP recursion 拒絕，未知 descendants 或未完成 scope 不重用；actual binary 的重複 wait/help/exec、token、stream、probe budget 與故障 fixtures 通過。
- [x] 2.4 實作「常駐 pair 與單一接納」及 Retirement and recovery never replay uncertain work：MCPPersistentRunner 的 generation、lazy start、idle、crash recovery、cancel/deadline/cap、保留 PID 到最後 signal；真實 marker、partial/wrong-id frame、idle/call race、idle EOF 前置重建、輸出上限、CLD_STOPPED 不誤判退出、late group member 繼續清理與 pending／lost ownership 拒絕新 pair 的測試通過。
- [x] 2.5 整合 MCPCommand／MCPSession 的 default persistent、explicit isolated、idle timeout、runner shutdown 與 pre-send large-argv route；完成「Executable 身分與原 argv 邊界」及 Isolated command worker、Stdio protocol 的修改契約，暖 worker 的實際 replacement／NUL/input limits／EOF idle cleanup／schema/help parity 測試通過。

## 3. 回歸、量測與交付

- [x] 3.1 完成 #110 與新 lifecycle 的完整回歸：actual MCP 的取消、busy/ping、EOF、unread stdout、nested children、explicit daemon detach；以 ownership、frame/correlation、no-replay、idle generation、quiescence 的關鍵變異證明測試能辨識失效，還原後 make test-all 通過。
- [x] 3.2 完成 Persistent worker benefits and regressions are measured：更新 benchmark 的 mode 與 scenario 命名，在同 build／同固定 fixture 比較 cold/warm p50/p95、成功率、PID 重用與 trace overhead；warm p50/p95 未改善就繼續調整，文件保留原始範圍及 cold 成本，不以診斷迴圈代替交付。
- [ ] 3.3 更新 README／CLAUDE.md／CHANGELOG.md 與診斷／task 狀態，六方確認、spectra analyze／validate、規格同步歸檔；各提交引用 #172，PR 附實際證據與限制，verified 後 issue 保留 OPEN。

## 4. R2 完整清理契約修正（#172／#209）

以下為R2新增驗收，既有完成項目保留為當時成果；3.3交付依賴4.1–4.4。

- [ ] 4.1 將原 runner 的 stopped-event 與公開 MCP 預選 host-death 重現納入受控自動測試，向未修改版本取得具名 RED；測試只終止自己 spawn 且持有的程序，觀察實際 worker 終止，不用 host exit 代替。
- [ ] 4.2 實作等 argv／等 environment bytes 的 one-shot supervisor bootstrap、固定 parent metadata、獨立 lease／status 與業務退出碼傳遞；以原 kernel 接納邊界、早期啟動失敗及 host-death RED轉GREEN證明，不縮小公開輸入也不重播。
- [ ] 4.3 履行「一次性 owner 與狀態回傳」：將 explicit isolated／persistent預選／custom fixtures 收斂到可保留的 serial reservation owner，完成真退出判讀、late member 重複清理、bounded pending／lost ownership、取消及shutdown；固定小環境直接驗 private expansion 分支，補 image failure 欄位差異的說明與斷言。
- [ ] 4.4 依「驗收及依賴順序」，完成兩題的必要行為變異、原kernel與雙模式#110回歸，重新建置最終release做同build交錯cold／warm比較，再固定提交跑六方審查；清理或接納仍有缺口不得改成例外宣告PASS。
