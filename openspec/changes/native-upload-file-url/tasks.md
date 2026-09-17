## 1. 獨立基礎元件

- [x] [P] 1.1 實作有界剪貼簿 lease（FileURLClipboard）供 Upload file via file dialog 使用；以私人 pasteboard 的多項目／多型別、file URL、快照拒絕、還原與較新內容保留測試，先 RED 再 GREEN。
- [x] [P] 1.2 實作單一原生腳本（NativeUploadScript）與實際選取完成檢查，履行 Native file confirmation authorization 與 Native upload does not mistake existing selection for completion、Native file timestamp representation is verified with WebKit；以 script compile、目標／截止／剪貼簿拒絕及 metadata 判定測試確認沒有 HID／default-button fallback。

## 2. CLI 整合

- [x] 2.1 整合上傳 lease 與腳本，履行 Upload command accepts full TargetOptions on all execution paths、Explicit opt-in for interfering operations 與 Interference warning on stderr；以 interpreter 順序、錯誤／逾時、原有路由及 JS 大小上限測試驗證相容行為。
- [x] 2.2 更新 help、CHANGELOG、盤點與 file-upload／non-interference 規格，精確描述 AX、焦點、剪貼簿與完成語意；執行 Spectra validate 與文件交叉檢查。

- [x] 2.3 履行 Native upload records delivery before page handlers consume the input 與 Native upload rejects directory selectors：以真實 WebKit 先重現 change handler 清空／替換／改 URL、負時間小數邊界，補初始化及開啟前 webkitdirectory 拒絕測試，再修正事件快照與完成檢查；同步修正文檔。

程序註記：1.1／1.2 初始子代理的 missing-type 編譯失敗不算行為 RED；第一次元件變異案例在初版之後補做。舊程式整合測試與後續缺陷回歸先 RED 再修正的紀錄保留，不能宣稱全程先測後寫。

- [x] 2.4 補齊 Native upload records delivery before page handlers consume the input 的 input 事件順序與面板關閉等待：真實 WebKit 先重現 input handler 三種變動，實際 AppleScript adapter 先重現 sheet 尚在分支，再同時監聽 input／change，交付後只讀等待並禁止再次確認。

## 2A. #169 原生選取與 worker

- [x] [P] 2.5 實作有界原生選取讀取器，履行 Native upload proves the selected path before confirmation；以 provider 測試驗證三種模式、file-reference URL、隱藏 Unicode 路徑、歧義與節點／深度／時間拒絕，保證不送 UI 動作。
- [x] [P] 2.6 實作固定請求的內部上傳 worker，履行 Native upload worker accepts only a bound request；以無 GUI 測試驗 schema／大小／父程序／image／deadline 拒絕及主執行緒橋接與明確診斷。
- [ ] 2.7 完成原生證據與確認整合，履行 Native upload proves the selected path before confirmation 與 Native upload worker accepts only a bound request；以 interpreter／CLI 測試驗未知、變更及已交付不確認、錯誤 sentinel、逾時、MCP owned group 與 trace 相容，並以自有 GUI／相同 fixture 基準驗 IPC 與等待。

## 3. 實際驗證與交付

- [ ] 3.1 執行完整 make test-all 及自有 GUI 特殊路徑、不同起始資料夾、大檔、焦點／錯誤／逾時案例；核對實際檔名／內容、自有面板清理及剪貼簿還原。
- [ ] 3.2 完成六方 review、修正所有阻擋項、更新 Implementation Complete 與 PR #163；通過後依既有授權合併並核對合併樹。
