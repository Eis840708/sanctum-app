# SANCTUM Internal Alpha｜白名單測試入口

本頁只供獲授權的 Android Internal Alpha 測試者使用。這不是公開版本，請勿轉發 APK、備份檔、恢復碎片、測試相片或影片。

## 候選版本

- App：SANCTUM
- 版本：`1.6.0-alpha.1+7`
- Package：`com.sanctum.vault`
- App source pin：`ff82345aba7d03a3aa2f74b2f3f088e72e8828f8`
- APK SHA-256：`1A6667ADEC3A84BEEF559B87B509A9B87239EC7B9006CBC36F668CBF1D4BD266`
- Signing certificate SHA-256：`78c3aa6baea917b5861ef8699938fb831075b5e924dd77c614c800faddc1721c`
- QA：Internal Alpha Conditional Pass；文件條件已納入測試說明

## 開始測試

1. 從本 Private repository 的 `SANCTUM Internal Alpha 1.6.0-alpha.1+7` Release 下載派發 ZIP。
2. 核對 ZIP 與 APK 的 SHA-256；不一致就停止安裝並回報。
3. 先讀 [TESTER-GUIDE.md](TESTER-GUIDE.md)。
4. 按 [CHECKLIST.md](CHECKLIST.md) 測試，只可使用合成假資料。
5. 發現問題時複製 [BUG-REPORT-TEMPLATE.md](BUG-REPORT-TEMPLATE.md) 回報。

## 重要界線

- 只批准 Android 白名單 Internal Alpha；iOS 尚未驗證。
- 禁止輸入真實密碼、日記、財務、相片或身份資料。
- 正式 Alpha 啟用系統截圖保護；截圖、錄屏或 ADB screencap 全黑屬正常。
- v3 直接裝置轉移目前停用；換機只測加密 backup／restore。
- 本次測試不等於公開發布批准，亦不代表已完成真人第三方安全或密碼學審核。

