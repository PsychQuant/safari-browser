## Context

實際metadata有47個top-level、78個leaf，其中tab switch與daemon __serve隱藏，公開76個含help/setup/daemon。原72是歷史量測。所有目前值參數缺Swift型別，故不得從defaultValue或名字猜Int/Double；目前只有help的positional為repeating。互斥屬runtime validate，不手工複製。

MCP 2026-07-28改為逐request版本與capabilities metadata；舊client仍需initialize。本變更實作tools核心的dual-era stdio，不實作未宣告的resources/prompts/extensions。

## Goals / Non-Goals

目標：完整公開CLI覆蓋、無schema手工清單、原command執行、RPC不混CLI輸出，未知結果不重播。
非目標：不移除CLI/daemon/exec、不保證MCP比CLI快、不新增mcpb或宣稱FDA自動解決、不自動授權setup/HID/寫入行為。

## Decisions

### Metadata catalog

runtime `SafariBrowser._dumpHelp()`；serializationVersion只接受0，未知kind/name/parsingStrategy明確拒絕。以 `safari.`＋`.`串接command path命名，保持hyphen，collision拒絕。公開leaf全列，含setup/daemon/help；mcp及隱藏分支不列。

InputSchema為JSON Schema 2020-12的object，含`positionals`（依valueName）、`options`（preferred CLI name）及可選UTF-8 `stdin`。每層additionalProperties=false。Flag布林表示true加入該旗標、false省略，不宣稱直接設定Swift欄位值。option/positional是string，repeating是string array（repeatable flag為非負次數）；不猜scalar型別。required沿用isOptional。未知key/錯型別/NUL argv/位置參數缺口在dispatch前失敗。具名value包含短名一律以等號保持字面值（原parser的短名黏接預設不啟用），所有positionals放在`--`之後；stdin單獨傳入worker。CLI validate保留值域/互斥/目標runtime判斷。

### Isolated command worker

新增隱藏`__mcp-exec`，其唯一職責是parseAsRoot原argv並run既有同步/非同步command，拒絕MCP/worker/daemon __serve自遞迴。MCP parent只傳argv及stdin，不複製業務邏輯。POSIX spawn為每個worker建立owned process group，三條pipe分離，無shell。取消/timeout/capture limit停止owned worker group，保留結果不確定性；明確daemon start所建立的detached daemon是既有持久副作用，不宣稱回滾。

每個worker帶internal `SAFARI_BROWSER_MCP_DIRECT=1`及expected Mach-O image UUID。Main僅在expected標記存在時核對目前載入image，更新/不同build即在parser前拒絕；nested exec child也繼承檢查。避免原server的schema對到安裝更新後另一個engine。普通CLI沒有標記，不改路由。MCP direct標記優先於daemon環境/socket自動判斷，explicit daemon工具仍呼叫原command。

Runner預設300秒，可在mcp啟動時配置0.001–86400秒；每stdout/stderr最多2MiB，超出標成不完整且不是成功截斷。stdin最多4MiB、RPC frame最多8MiB。超限、signal、spawn failure、timeout都成為有明確原因的tool error；不自動retry/fallback。非UTF8輸出以標明encoding的base64保留。

### Stdio protocol

MCP只輸出單行JSON-RPC到stdout；CLI輸出只出現在tool result。固定tools集合與分頁（每頁50）由catalog產生，cursor驗證不猜。只允許一個執行中的tool call，額外呼叫回明確未執行的busy tool error；ping/list/discover/cancel可在執行期間處理。取消後不再對該request輸出訊息，EOF會取消並清理在途worker。回覆經獨立有界pump傳送（64frames/16MiB，包含正在寫出的frame），enqueue不等stdout可寫；滿額或write錯誤關閉transport，EOF可直接取消pendingwrites。complete先提交final result後，對已完成request的late cancel不撤銷已提交的結果；仍在active slot的cancel抑制回覆。ID必須string或integer且不能重複in-flight；bool/null/fractional拒絕。

Modern request params._meta需protocolVersion=2026-07-28與clientCapabilities object；每次獨立判斷，不依賴initialize。server/discover回supportedVersions/capabilities/serverInfo，所有modern結果有resultType complete。未知版本用-32022與supported/requested；缺metadata用-32602。Legacy的_meta可含progressToken/extension；只以現代protocol欄位選擇modern驗證，避免把舊meta誤判。Legacy支援2025-06-18/2025-11-25 initialize＋initialized，未知legacy版本協商到2025-11-25；準備前不能執行工具。未宣告能力不提供。未知notification不回覆；JSON批次與畸形request明確拒絕。

Tool result提供stdout/stderr encoding/data、exit_code（未啟動為null）、capture_complete、failure；content先呈現stderr診斷再stdout，isError反映CLI非零或未完成。outputSchema為共用傳輸結果，不聲稱已把每個CLI stdout轉成原生domain schema。metadata/schema不能判定使用者授權或目標安全。

## Implementation Contract

API：JSONValue為Codable/Sendable enum（null/bool/int(Int64)/double/string/array/object）；MCPToolCatalog(metadata:Data)產生tools，invocation(toolName:input:)回argv與stdin；MCPProcessRunner.run(arguments:input:expectedImage:)回MCPCommandResult（raw Data、optional exitCode、cancelled/truncated/failure）。Runner可注入executable與workerPrefix供純測試，不提供RPC override。

驗收：所有76公開leaf與schema都有對照、OptionGroup/required/repeating/字面值/未知格式測試；stdio實際process的legacy/modern/list/call/error/cancel/EOF與輸出隔離；每個tool的安全help routing，代表性的同步/非同步實際command與CLI結果對照，既有整套tests不回歸。不能把只做一小組或手寫schemas視為完成。依賴GUI的副作用仍沿用既有CLI，不用測試去操作使用者的真實表單/帳號。

## Risks / Trade-offs

- dump API experimental → version/kind/parsing guard與schema/argv fixtures，不假裝永遠相容。
- 無scalar型別/互斥metadata →只約束能證明的形狀，保留CLI runtime驗證並回報錯誤。
- command可能崩潰/讀stdin/大量輸出 →隔離worker與bounded pipes，RPC仍可回應。
- 取消不等於撤銷已完成副作用 →不回應已取消request、不重播，文件明示。
- 支援76個tool有context成本 →短abstract與分頁，非縮成少量tool。
- image UUID是build身分，不是額外的惡意binary驗證 →OS簽章及原CLI權限契約維持；變更image要求重啟server。

## Sources

https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning
https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio
https://modelcontextprotocol.io/specification/2026-07-28/server/tools
https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle
本機swift-argument-parser的_dumpHelp與實際serializationVersion0輸出。
