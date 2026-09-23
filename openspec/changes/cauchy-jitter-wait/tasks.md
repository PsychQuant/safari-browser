## 1. 抽樣器
- [x] 1.1 抽樣器測試先失敗：界內、無端點值、中位數、種子重現、μ 反解（含不可達）
- [x] 1.2 實作反函數抽樣、μ 在 [a, b] 上的二分反解、SplitMix64

## 2. CLI
- [x] 2.1 解析與 validate 測試先失敗：預設值、互斥、參數錯誤、上界溢位
- [x] 2.2 WaitCommand 接上 `--jitter` 與參數，實跑小區間確認等待時間

## 3. 文件與收尾
- [x] 3.1 README、CHANGELOG
- [x] 3.2 `make test` 全綠、spectra validate、issue 狀態同步

## 4. 參數使用性（#186）
- [x] 4.1 測試先失敗：預設 scale 隨區間推導、近乎固定的警告、`--max` 超過一小時需 `--allow-long-wait`
- [x] 4.2 實作並更新 README、CHANGELOG、spec
