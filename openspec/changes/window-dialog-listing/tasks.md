## 1. 實作
- [x] [P] 1.1 有界每視窗 observation／status、shared scan 相容與 TDD。
- [x] [P] 1.2 documents/tabs rendering 與單次capture、JSON/文字相容測試。
- [x] 1.3 stable window ID 的 DTO／橋接傳遞及整合測試。
## 2. 驗收
- [x] 2.1 文件、回歸、凍結 code review 與 PR。
- [x] 2.2 解鎖後完成真實 per-window marker 與多視窗效能，issue 驗證狀態同步。

Verification: [https://github.com/PsychQuant/safari-browser/pull/158#issuecomment-5648836890](https://github.com/PsychQuant/safari-browser/pull/158#issuecomment-5648836890). Runtime `aea856786db106121f6d7b1cbfb00619bab62797`; GUI `5ca69601ceeba24eb15b28ac1f4cac0e4cc00c9f`. R4 僅診斷傳遞，完整測試與範圍限制見報告。
