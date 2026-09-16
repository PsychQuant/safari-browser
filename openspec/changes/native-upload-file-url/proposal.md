## Problem

#101 的原生上傳仍依賴 Go-to-Folder 鍵盤序列；面板未出現或焦點變更會造成 #67 的失敗。原生 file URL 剪貼簿與具名 AX 動作已完成特殊路徑實測，可正式取代此序列。

## Root Cause

檔案路徑以文字而非檔案 URL 交給系統，必須額外叫出路徑輸入 sheet；成功也未以頁面實際選取結果驗證。

## Proposed Solution

原生上傳改用完整剪貼簿快照、NSURL 物件、AX Paste 與必要時具名 Upload。單一有界腳本綁定原視窗、頁面與 input，驗證完成後才回報成功；錯誤與逾時仍還原可確認屬於本次的剪貼簿。

## Success Criteria

- 原生上傳沒有鍵盤／滑鼠事件及 Go-to-Folder 路徑。
- 隱藏／特殊字元路徑、大檔案、完整 targeting 與 JS 上限契約維持。
- 失去焦點、身分變更、選取不符、額外面板及逾時均明確失敗，不重送確認。
- 使用者剪貼簿多項目／型別可還原，較新內容可保留；警告仍在原生干擾前送往 stderr。

## Capabilities

### New Capabilities

無。

### Modified Capabilities

- `file-upload`: 原生 file URL Paste、具名確認、選取結果驗證與剪貼簿生命週期。
- `non-interference`: 原生上傳改成焦點／面板／剪貼簿干擾，保留具名例外但不再宣稱控制鍵盤。

## Impact

UploadCommand、上傳專用剪貼簿 helper、Swift 回歸與本機驗收腳本、CLI 說明、docs/operation-paths.md、CHANGELOG 與上述兩份規格。PDF 路徑由 #102 獨立處理。
