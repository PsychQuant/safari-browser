## Context

使用者已決定（#182 decision comment）：分布為 doubly truncated Cauchy，以反函數法抽樣，參數定義在截斷後分布上，界限不得以 clamp 表達。

## Decisions

**抽樣**：令 $F_\mu(x) = \tfrac12 + \tfrac1\pi\arctan\tfrac{x-\mu}{\sigma}$。取 $u \sim \mathrm{U}(F_\mu(a), F_\mu(b))$，$x = \mu + \sigma\tan(\pi(u-\tfrac12))$。每次呼叫固定成本；拒絕抽樣在界限窄時需多次重抽，不採用。$x$ 以 Double 毫秒保留小數，直接換成奈秒，不先取整毫秒（取整會在整數毫秒上形成離散點）。

**由截斷後中位數反解 μ**：截斷後中位數 $h(\mu) = \mu + \sigma\tan\big(\pi(\tfrac{F_\mu(a)+F_\mu(b)}{2}-\tfrac12)\big)$。$h$ 在整條實數線上**不單調**：μ 遠離 [a, b] 時截斷分布趨近均勻，$h$ 折返區間中點。實測 35/35 組參數在全域非單調；限制 $\mu \in [a, b]$ 後 54/54 組單調，且全域極值即出現在 $\mu = a$ 與 $\mu = b$。故二分法只在 $[a, b]$ 上搜尋。目標中位數不在 $[h(a), h(b)]$ 時回報驗證錯誤並列出可達範圍，不默默收斂到端點。預設參數解得 μ ≈ 2611.455 ms。

**亂數**：預設用系統亂數；`--seed` 時用本檔內的 SplitMix64，不新增依賴。抽樣器接受注入的 generator 以便測試。

**介面**：`--jitter` 只接受 `cauchy`（保留日後 `lognormal` 等值）。與位置毫秒、`--for-url`、`--js` 同時出現時在 `validate()` 拒絕，避免猜測語意。參數檢查：$0 \le a < m < b$、$\sigma > 0$，且 $b$ 必須通過既有 `nanoseconds(forMilliseconds:)` 溢位檢查（#153）。

## Validation

抽樣器純函式測試：固定種子下 10⁵ 抽樣全部落在 $(a, b)$、無值等於端點、經驗中位數與目標差距在容許內、同種子同序列；反解測試涵蓋預設值、貼近兩端的中位數與不可達中位數。CLI 解析測試涵蓋互斥與參數錯誤。以小區間（例如 [10, 30] ms）實跑 CLI，確認實際等待時間落在區間內。

## Risks

- 分布統計測試若用真亂數會不穩定，一律固定種子。
- `bounded-wait-conversion`（#153）尚未 archive，同改 `wait` spec；本變更只用 ADDED，不改其 MODIFIED requirement。
