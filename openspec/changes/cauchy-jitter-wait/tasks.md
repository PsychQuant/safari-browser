## 1. 抽樣器
- [x] 1.1 抽樣器測試先失敗：界內、無端點值、中位數、種子重現、μ 反解（含不可達）
- [x] 1.2 實作反函數抽樣、μ 在 [a, b] 上的二分反解、SplitMix64

## 2. CLI
- [x] 2.1 解析與 validate 測試先失敗：預設值、互斥、參數錯誤、上界溢位
- [x] 2.2 WaitCommand 接上 `--jitter` 與參數，實跑小區間確認等待時間

## 3. 文件與收尾
- [x] 3.1 README、CHANGELOG
- [x] 3.2 `make test` 全綠、spectra validate、issue 狀態同步

## 4. 跨模型補審修正

既有 [x] 是先前快照的歷史完成紀錄；本節完成前不得視為已驗收。原「缺符號」編譯失敗不是行為 RED，新增回歸須實際執行並失敗。

- [x] [P] 4.1 完整可達中位數與穩定反解：修改 TruncatedCauchy 與其測試，履行 Wait for a randomized duration，先重現界外 location 的可達中位數被拒，再以獨立 CDF／分位數檢查及反解範圍測試驗證；數值耗盡明確失敗而非固定中位數後備。
- [x] [P] 4.2 奈秒可表示性與等待轉換：修改 WaitCommand 與新的 JitterNanosecondTests，履行 Wait for a randomized duration，先重現 sub-nanosecond 輸入被接受，再驗零／單量子區間拒絕、整數與小數界限、UInt64 邊界及實際 sleep 參數。配合 sampler 的 throws API。
- [x] 4.3 更新 README／CHANGELOG／spec 的可達範圍、量化與種子保證；Spectra analyze/validate、完整測試與最終快照審查通過後更新 PR。

驗收紀錄：2026-09-27 修正後執行 `make test-all` exit 0（1253 XCTest、24 Swift Testing、66 smoke、簽章 49 PASS / 2 身分需求略過）；六方對 61e0780 程式碼審查 CODE PASS。最終差異僅文件與註解。Spectra validate 有效、analyze 無發現。原簽章失敗與系統 Python 缺少 waitid 的診斷紀錄保留，未宣稱已找出簽章失敗根因。

## 5. 參數使用性（#186）
- [x] 5.1 測試先失敗：預設 scale 隨區間推導、近乎固定的警告、`--max` 超過一小時需 `--allow-long-wait`
- [x] 5.2 實作並更新 README、CHANGELOG、spec
- [ ] 5.3 更新至修正後 #182，涵蓋奈秒量化警告案例，重新測試與六方審查。
