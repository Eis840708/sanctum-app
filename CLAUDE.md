# SANCTUM 項目記憶（CLAUDE.md）

> 每次開新對話先讀本檔。詳細歷史／決定緣由喺 `story book\PROJECT-LOG.md`（只喺需要追溯時先讀，唔使每次讀）。
> 最後更新：2026-07-22

## 項目簡介

Sanctum — 離線加密私人保險庫 APP（密碼＋私密日記＋個人財務），本機優先、無帳戶。
Flutter / Riverpod / Hive / go_router，版本 `1.5.0+6`。階段：功能原型／Alpha。**Android 公開發布：未授權／停止。**

## 檔案位置

- APP 程式碼：`C:\dev\sanctum_new`（git repo；工作樹有大量未 commit 修改，**不得清除、覆蓋或整體回退**；實作分支 `feat/vault-v3`）
  - 核心加密檔：`lib/core/crypto/crypto_service.dart`、`lib/core/crypto/shamir_service.dart`、`lib/core/storage/vault_service.dart`（基線 hash：`8d972ffb…`／`fe42c2ed…`／`1c4a80ed…`）
  - v3 新實作：`lib/core/crypto/v3/`（新舊並存）
- 項目文件／指令／QA 報告／證據：`C:\Users\EISEI\OneDrive\Documents\story book`
  - 總體規劃 `SANCTUM_項目總體規劃_2026-07-14.md`；詳細歷史 `PROJECT-LOG.md`

## 工作模式（七角色制）

流程：**工作指令 → 執行 → 提交 → QA 驗收 → 總監批核**。角色：總監、製作方、獨立檢測(QA)、秘書、整理員(ORG-XXX)、官網設計師、募資策劃。指令與證據存 story book，命名 `DEV-P0-XX`／`SEC-AND-XXX`／`REL-AND-XXX`／`QA-…`／`ORG-XXX`。

**跨部門交付格式（所有角色必守）**：任何要交去另一對話嘅嘢（派工、提交通知、完成回報、覆核指令、建議、批核請求）必須輸出成**可直接 COPY 嘅 code block**——block 外寫目標部門名，block 內放完整可貼文字（含檔案完整路徑＋交付／覆核要求）。純向 Eis 匯報唔使 block；一提出「應叫某部門做 X」即出 block。

## 當前狀態（2026-07-22）

- **DEV-P0-03 Phase A、Phase B 設計：已批核。Phase B 實作進行中（分支 `feat/vault-v3`）。**
- 八項 finding V-01…V-08 已定級（P0×1：V-01；P1×3：V-02/V-03/V-05；P2×4：V-04/V-06/V-07/V-08，V-04/V-08 有連動/升級條款），**全部維持「未通過／待修正」**直至各批修復經 QA 驗收。
- B2 分五批：B2-1（已批核）→ B2-2（已批核，2026-07-22，V-03/V-04＋NFC＋雙軌守衛，QA PASS＋總監深驗）→ **B2-3（已開放，V-01 P0 restore/transfer 事務化，限 08-01）** → B2-4（biometric＋Shamir，限 08-05）→ B2-5（全記錄加密＋in-memory 搜尋，限 08-08）。逐批 QA 驗收＋總監批核先開下一批。
- **B2-3 結構轉折**：首次授權修改核心三檔之 `vault_service.dart`（只准 restore/transfer 方法：`importFromBackup`/`importTransfer`），其餘核心檔仍零改動；開工前出 before hash。事務化硬性：驗證先於任何破壞性操作→staging→atomic commit→rollback，任何失敗現有 vault 原封不動。QA 加倍嚴格：餵壞備份確認現有 vault 唔會被清（缺此即 RETURN）。
- 設計凍結：實作以 design v1.0＋v1.1 為準，發現缺陷停手上報，禁自行偏離。

## 生效中控制／基線

- **禁區**：`git reset --hard`／`checkout --`／`clean` 全程禁；核心三檔非經批次授權不得改；工作樹既有使用者修改不得損。
- **B2 analyze 驗收基線**（排除 vendored 後量測）：error 0 絕對／warning ≤2（pre-existing，B2 不處理）／info ≤162／**新增檔本身 0 issue**。
- **禁真實 Vault**：全部測試用合成資料。
- **release gate**：「AES-256 全加密」＝全記錄加密＋Argon2id 完成並驗收前，不上線、不對外宣稱；實體 ARM API24 Argon2id 量測上線前必辦；Argon2id 安全下限 19MiB/t2/p1 不得突破。
- 對外宣稱暫停中（2-Layer Backup／安全還原／安全裝置轉移／AES-256 全加密）；項目目前無任何對外宣稱（修正階段）。
- vendored `unorm_dart` 0.3.2 版本凍結，升級須總監批准（視為 KDF 相容性變更）。

## 常設紀律

- **摘要數字紀律**：提交中任何引自證據檔嘅數字／hash 必須提交前由證據檔直讀核對，聲明附「已逐項對照」。
- **日期紀律**：文件日期用產出當日實際日期，跨日重新確認；已誤植編號保留加註。
- **模型分層**（省 token）：機械工（秘書登記、整理員盤點、純文件搬遷）用快模型；crypto 設計／實作／QA 深驗／總監批核用最強模型。
- **登記／裁定精簡**：秘書逐批（非逐事件）埋單登記＋備份；總監純確認／追認類用短格式，唔使每次成份正式文件；已被 hash 釘死嘅嘢信 hash、唔全文重讀，只有 crypto 實作深驗。

## 已知技術債

- `passwords_screen.dart` 2 warning（`unused_local_variable`／`unnecessary_cast`，使用者修改檔，B2 完成後另立小任務）。
- 測試覆蓋不足（B2 各批順帶償還）。
- ~~`withOpacity` deprecated~~：**已清（2026-07-22 實測 lib/ 內 0 個）**。

## crypto（B2）之後嘅緊急事項

> 詳見 `story book\DEV-P0-03-post-crypto-priorities-v1.md`。三大樽頸：
> ① 實體 ARM API24 Argon2id 量測（release gate，需 Eis 提供實體機）；② CI 自動化（現時完全冇 `.github/workflows`）；③ 簽名改 CI secret 供應（現時本機 `android/app/release.jks`）。
> 之後：B2-5 全加密收尾（解 release gate）→ Internal Alpha → UX 大改（P2）→ iOS 平台驗證 → 獨立第三方安全審核 → 私隱政策／商店素材。

## 常用指令

```powershell
C:\dev\flutter\bin\flutter.bat analyze
C:\dev\flutter\bin\flutter.bat test
```

## 語言

與用戶溝通用繁體中文（廣東話語氣可）；文件用繁體中文。
