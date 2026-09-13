## 1. 實作
- [x] [P] 1.1 Confirmation traces：file-dialog runner／雙 pipe drain／安全 trace，實際子程序成功、失敗、timeout、大輸出及原錯誤測試。
- [x] [P] 1.2 No replay after dispatch 與 Explicit PDF overwrite：initial lookup/click 分離、replacement 具名且 opt-in；建構／解析／預檢測試及 osacompile。
- [x] [P] 1.3 Explicit opt-in for interfering operations、Native confirmation exception、Native file confirmation authorization 與 Export page as PDF：同步操作盤點／主規格具名例外／授權文件，內容審查保留 untested 證據界線。
## 2. 整合與驗收
- [x] 2.1 PDF/upload/navigateFileDialog 呼叫專用 runner，驗證共用片段仍在單一腳本、跑相關與完整回歸。
- [x] 2.2 自有 Open/Save/Replace 實機驗收，依 Save AX 證據裁定查找 fallback；未實測不得標 verified，不使用 Print 路徑。
- [x] 2.3 凍結審查、PR 與 issue 狀態同步，記錄所有程式碼與 GUI 範圍。
