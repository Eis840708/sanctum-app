# SANCTUM Internal Alpha｜測試者必讀

## 安裝前

1. 使用 Android 7.0（API 24）或以上裝置。
2. 如已安裝 SANCTUM，先清理或備份純合成測試資料；不要假設 Alpha 更新一定保留資料。
3. 核對 APK SHA-256：`1A6667ADEC3A84BEEF559B87B509A9B87239EC7B9006CBC36F668CBF1D4BD266`。
4. Android 如要求允許未知來源，只為本次已核對 APK 暫時開啟，安裝後可關閉。

Windows PowerShell 核對：

```powershell
Get-FileHash -Algorithm SHA256 .\sanctum-1.6.0-alpha.1+7-ff82345-release.apk
```

ADB 原地更新：

```powershell
adb install -r .\sanctum-1.6.0-alpha.1+7-ff82345-release.apk
```

## 安全規則

- 只使用合成資料；禁止真實 Vault 或任何真實秘密。
- 不要把 APK、備份檔、恢復碎片或測試紀錄上載至公開平台。
- 正式 Alpha 啟用 `FLAG_SECURE`；畫面擷取全黑屬正常安全行為。
- UI 證據請用另一部相機拍攝實體裝置，只顯示合成資料，並避開通知及個人資料。
- 遇到資料損毀、無法解鎖、疑似明文洩漏、繞過鎖定或持續崩潰，立即停止測試並回報。

## 建議合成資料

- 網站：`Alpha Test`
- 用戶名：`test@example.com`
- 密碼：`Test123456!`
- 日記：`今天是 SANCTUM Alpha 合成測試。`
- 財務：收入 `100.00`、支出 `25.50`

測試完成後刪除以上記錄、備份與恢復碎片。

## 已知限制

- 只開放繁港、繁台、簡中、英文、日文及韓文。
- 法文、德文、西班牙文及拉丁文尚未完成，已從語言選單隱藏。
- v3 裝置直接轉移停用；請測 backup／restore，不要把 transfer 當成可用功能。
- iOS 尚未驗證。
- 產品尚未完成真人第三方安全／密碼學審核。

