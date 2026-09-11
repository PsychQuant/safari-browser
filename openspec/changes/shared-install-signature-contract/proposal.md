## Why
#119 的安裝流程已實作，但 #122 的執行期仍從 codesign 的文字輸出猜簽章，與 authoritative guard 有兩個答案。#123 的舊 target 與 #124 的過時規範延續錯誤指引，#121 的 inode 修正也需獨立驗證。

## What Changes
- 抽出 Security framework 的共同簽章評估，guard 與 CodeSigningState 共用同一份來源與結果。
- 保留既有 guard 的退出碼、錯誤分類、資源政策與 18 個 mutant；建置及 mutation 工具使用組合後的實際來源。
- FDA 指引明確說明同一 identity-bound requirement 才能維持重建後授權，採 install-signed 單一步驟。
- 移除已無實際 caller 的 sign-developer-id target，同步目前有效文件；歷史 archive 保留原文。
- 驗證 install/install-signed 的 staging、原子替換、失敗保留既有 binary 與舊 inode 持有者不被影響。

## Capabilities
### New Capabilities
- `install-signature-contract`: 共用簽章判斷與可驗證的安裝邊界。
### Modified Capabilities
無。#124 另同步既有 build-and-install 的過時文字，使其符合已出貨 install-signed 行為。

## Impact
CodeSigningState、共用 SignatureAssessment、獨立 guard、Makefile、signature/mutation/build helper、安裝 regression、build-and-install 規範及現有 local-safari-data-query artifacts。這批涵蓋 #119 #121 #122 #123 #124。
