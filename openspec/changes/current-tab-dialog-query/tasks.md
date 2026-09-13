## 1. 探測與命令

- [ ] 1.1 Bounded current-window observation 與 Conservative pending-dialog absence：新增有界 AX 主視窗 context、共用 worker/scanner 的指定根視窗掃描及前後身分檢查；以 fake provider 驗證三態、他窗隔離、inactive/hidden、錯誤／截斷、busy 與 800 ms 期限，並跑既有 scanner/worker/listing 回歸。
- [ ] 1.2 Three-state command contract：註冊 is dialog 與 --json，true/false 退出 0、unknown 退出 2 並回原因；實際 command runner 測試輸出／JSON／退出碼、MCP metadata 與原有 is 子命令相容。

## 2. 實機與收尾

- [ ] 2.1 Live in-flight acceptance：自有 click-confirm fixture 在 click 尚未返回時讓 is dialog 三秒內回 true，驗 clear／handler 僅一次及 guarded recovery；GUI 77 不算通過，所有自有視窗／面板須清理。
- [ ] 2.2 依實際驗收更新 README 的目前視窗與 unknown 邊界，完整回歸、獨立審查、嚴格 Spectra 驗證與 PR／issue 狀態同步；未完成 live acceptance 不標 verified。
