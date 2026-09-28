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

- [x] [P] 2.8 私有完成憑證：履行 Native upload completion rejects page state forgery，以真實 RED 重現 selection 修改、global 替換與外露 listener 偽造；閉包私有 metadata 驗證及原生 receipt 完整比對後，測試 observer 所見 metadata 不符時不釋出 token、裸 OK 不接受、toString 不洩露 token、cleanup 仍可刪除狀態。
- [x] [P] 2.9 自有負向與效能驗證：準備 Tests/native-upload-live.py 的 owned fixture runner（success/cancel/timeout 與分段 trace），以 11 項無 GUI harness 測試確認失敗／未知／未觀察面板不得計入成功，並檢查腳本與唯讀剪貼簿 helper 編譯；實際 GUI 與等效 System Events／AX 比較留在 3.1。

- [x] 2.10 釐清 private receipt 的事件觀察範圍：以真實 WebKit 重現較早 capture listener 改寫 FileList；區分可防的完成 state 偽造與頁面在觀察前修改檔案資料，保留既有錯誤 metadata 拒絕測試，修正規格及文件過度承諾。

- [x] [P] 2.11 以實際暫存路徑驗證 parent/probe 正規化契約，證實或反證 R2 的 /private 前綴拒絕疑慮，保留 symlink 置換拒絕測試。
- [x] [P] 2.12 確認公告必須回傳成功才可 AXPress；以 AppleScript adapter 驗 logger 拒絕時零確認、Swift bridge 及純函式測試驗 deadline／clipboard／標題拒絕，統一大小寫語意。

- [x] [P] 2.13 封閉原生 target constraint：以 NativeUploadTargetConstraint 和純函式／Codable 測試履行 Native upload preserves requested target constraints，驗四種 matcher、carried profile、未知／錯誤欄位拒絕及 positional nil。
- [x] [P] 2.14 捕捉前原條件守衛：為固定 NativeUploadScript 加 bridge 條件分支，使用真正 AppleScript adapter 證明非匹配 candidate 在 activation／input 前拒絕，無 constraint 不新增查詢。
- [x] 2.15 串接 typed constraint、request／worker／UploadCommand，補 lifecycle、schema 與 ObjC bridge 測試，確認原始條件未在 resolver 後遺失。

## 3. 實際驗證與交付

- [ ] 3.1 執行完整 make test-all 及自有 GUI 特殊路徑、不同起始資料夾、大檔、焦點／錯誤／逾時案例；核對實際檔名／內容、自有面板清理及剪貼簿還原，並記錄同 fixture System Events／直接 AX 查詢結果與等待差異。
- [ ] 3.2 完成六方 review、修正所有阻擋項、更新 Implementation Complete 與 PR #163；通過後依既有授權合併並核對合併樹。
