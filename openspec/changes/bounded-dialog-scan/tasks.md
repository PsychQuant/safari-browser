## 1. 共用基礎
- [x] [P] 1.1 Shared bounded worker：新增單一在途額度與deadline結果隔離，入口保持95ms；BoundedAXWorkerTests及既有BoundedDialogProbeTests驗證busy、late result、交叉互斥與預算。
- [x] [P] 1.2 Complete global scanner：完整辨識0/1/many/incomplete並保留同次button元素；DialogTreeScannerTests覆蓋15窗、讀取失敗、深度/節點上限、WebArea及本文。
## 2. 整合與驗證
- [x] 2.1 Strict command integration：list採800ms worker，dismiss同步完整重讀後按鈕；命令/error測試與未完整不呼叫決策的測試通過。
- [ ] 2.2 完整單元與自有Safari fixture驗證15窗／單一dialog時間及既有30項dialog回歸，同步README/CHANGELOG，獨立審查及PR/issue狀態紀錄。
