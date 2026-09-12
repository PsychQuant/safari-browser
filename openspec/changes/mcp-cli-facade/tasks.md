## 1. 基礎與並行元件
- [x] 1.1 JSONValue共用型別：保留string/int/bool/null/array/object差異，JSON roundtrip與非法數值測試通過。
- [x] [P] 1.2 Metadata catalog：全部公開leaf產生schema與literal argv，MCPToolCatalogTests對照76工具、OptionGroup/required/repeating/錯誤與hidden排除。
- [x] [P] 1.3 Isolated command worker的runner：POSIX owned group、stdin/stdout/stderr、取消/timeout/limit與reap，純fixture process tests通過。
- [x] [P] 1.4 Stdio framing：有界newline reader/writer與UTF8/畸形/過大frame，MCP framing tests通過。
## 2. 整合
- [x] 2.1 Stdio protocol：modern/legacy狀態、list/call/ping/discover/cancel/EOF與busy，session測試及真實stdio process測試通過。
- [x] 2.2 Isolated command worker整合：hidden worker重用原command、image guard與MCP direct routing；實際同步/非同步/help/重建拒絕與既有路由測試。
- [x] 2.3 Complete facade verification：完整公開catalog/help routing、原CLI regression、schema/stdio/輸出/cancel/error端到端，README與範圍界線。
- [x] 2.4 凍結提交、獨立交叉審查、PR與issue狀態同步。
