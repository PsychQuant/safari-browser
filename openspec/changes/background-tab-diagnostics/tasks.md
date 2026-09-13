## 1. 元件與整合
- [x] [P] 1.1 背景觀測 helper／DTO 與 TDD，嚴格輸出解析、matcher、readonly/bounded query。
- [x] [P] 1.2 建立自有 fixture 的背景 dialog GUI 驗收腳本，鎖定拒絕與安全清理。
- [x] 1.3 在 ResolvedScriptTarget／JS timeout／empty getText 接入 helper，注入測試證明保留原錯誤及優先順序。
## 2. 驗收
- [x] 2.1 README、相關回歸、嚴格規格驗證與凍結交叉審查。
- [x] 2.2 解鎖後完成真實 pending-background-dialog 驗收，PR／issue 狀態同步。

Verification: [https://github.com/PsychQuant/safari-browser/pull/158#issuecomment-5648836890](https://github.com/PsychQuant/safari-browser/pull/158#issuecomment-5648836890). Runtime `aea856786db106121f6d7b1cbfb00619bab62797`; GUI `5ca69601ceeba24eb15b28ac1f4cac0e4cc00c9f`. R4 僅診斷傳遞，完整測試與範圍限制見報告。
