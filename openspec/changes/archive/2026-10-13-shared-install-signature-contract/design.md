## Context
#139 已在 PR #147 verified，本批以其分支為基底。#119/#121 的 atomic install 已存在；#122 的提示已部分改成 install-signed，但分類仍以路徑可污染的 contains() 判斷，必須修根本原因。

## Goals / Non-Goals
Goals：共用 durability 真相來源、保留細緻 guard 契約、移除過時入口並補完整安裝證據。
Non-Goals：不替使用者授權 FDA、不覆寫其已安裝 binary、不改預設 ad-hoc 安裝、不做 notarization。實測在自有 fixture 安裝目錄進行；實際 FDA 僅讀取確認可用性，若仍需人工授權則明列阻擋，不以單元測試代替。

## Decisions
1. 新增 Sources/SafariBrowser/Utilities/SignatureAssessment.swift，直接使用 Security API 回傳 typed verdict：API unavailable、unsigned、invalid seal、ad-hoc、missing entitlement、unknown DR shape、unsatisfied DR、durable(shape, DR)。所有 policy（包括 all-architectures、resource exclusion、opaque quoted requirement patterns、CFBoolean entitlement）留在此一來源。Guard 只處理參數、顯示與退出碼；CodeSigningState 消費相同 verdict，不執行 codesign -dvv。
2. Guard 保留獨立可執行檔。共用 build helper 產生臨時單一 Swift source（shared source＋去 shebang 的 CLI wrapper），再 swiftc 編譯；沒有簽入第二份 source 複本。Mutation gate 使用同一 helper 產出的實際完整 source，所有既有 mutant declaration 保留且 gate 仍必須全部 killed；CLI 文件標頭維持退出碼唯一來源。
3. CodeSigningState 改以 durable/adHoc/unknown 語意輸出指引；durable 仍須維持相同簽署 identity 與 requirement，改 identity 不保證既有授權。Unknown 不會把路徑中的 Authority 文字當證據。
4. 移除 sign-developer-id（無 automation caller），所有現在有效的 remediation 指向 install-signed。歷史 archive 不重寫；in-flight local-data 設計更新且保留不改預設 install 的原始理由。
5. Install regression 使用 Makefile 的實際 recipes、可控 binary fixture、獨立 INSTALL_DIR。覆寫時持有舊 inode／執行 fixture，驗證新 inode 與新版本可執行；失敗注入需保留原先 binary。signed case 使用已有測試 identity，缺 identity 時明確缺驗證，不能宣稱通過。

## Family-wide scope
Guard 的兩個 validity calls、DR 與 entitlement policy；CodeSigningState.current/state/guidance 及所有測試；Makefile guard build 與 mutation baseline/mutant compile；install/install-signed 與舊 target；build-and-install spec 和未 archive local-data artifacts。

## Risks / Trade-offs
抽出邏輯可能改變退出順序，必須保留 ad-hoc 先於 entitlement／DR 的現有語意。Guard mutation 宣告不能因搬檔而消失。公開 make target 刪除有相容性成本，README/CHANGELOG 明確記錄改用 install-signed。實際 FDA 狀態是環境驗收，不把未知當 pass。

## Verification
先重現含 Authority 字樣的 unsigned 路徑誤判，再跑 Security fixture 與 CLI/guard 一致性測試。strict signature、全部 mutation、atomic install regression、完整 test-all、六位獨立交叉審查；逐 issue 對應舊實作與新增修正。
