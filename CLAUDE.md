# SANCTUM 項目記憶（CLAUDE.md）

> 由 Codex 移植至 Claude 的交接文件。每次開新對話時先讀本文件。
> 最後更新：2026-07-20

## 項目簡介

Sanctum — 離線加密私人保險庫 APP（密碼 + 私密日記 + 個人財務），本機優先、無帳戶。
Flutter / Riverpod / Hive / go_router，版本 `1.5.0+6`。
階段：功能原型 / Alpha。**Android 公開發布：未授權／停止。**

## 檔案位置

- APP 程式碼：`C:\dev\sanctum_new`（git repo，initial commit `34a883b`；工作樹有大量未 commit 修改，**不得清除、覆蓋或整體回退**）
  - Flutter 入口：`lib/`（core / features / shared / main.dart）
  - Android：`android/`、測試：`test/`、設定：`pubspec.yaml`
  - 核心加密檔：`lib/core/crypto/crypto_service.dart`、`lib/core/crypto/shamir_service.dart`、`lib/core/storage/vault_service.dart`
- 項目文件、工作指令、QA 報告與證據：`C:\Users\EISEI\OneDrive\Documents\story book`
  - 總體規劃：`SANCTUM_項目總體規劃_2026-07-14.md`
  - 修改紀錄：`SANCTUM修改改善紀錄.md`
  - 官網檔案：`index.html`、`sanctum.html` 等
  - 募資：`Sanctum_募資計劃書.docx`、`Sanctum_募資策略與進度表.md`

## 工作模式（四部門制）

項目以「工作指令 → 執行 → 提交 → QA 驗收 → 總監批核」流程運作，角色：項目總監、製作方、獨立檢測（QA）、項目秘書、整理員（2026-07-21 新設：檔案歸檔與受控清除，歸檔優先、刪除須總監批核＋擁有人確認，repo 完全禁區；指令編號 `ORG-XXX`）。所有指令與證據存於 story book 資料夾，命名如 `DEV-P0-XX`、`SEC-AND-XXX`、`REL-AND-XXX`、`QA-...`。

### 跨部門交付格式（所有角色必守）

Eis 以「一對話一角色」方式運作七個部門對話，靠複製貼上傳遞文件。任何要交去另一個部門對話嘅嘢——派工、提交通知、完成回報、覆核指令、建議書、批核請求——都必須輸出成**可直接 COPY 嘅 code block**：block 外寫目標部門名，block 內放完整可貼文字（含檔案完整路徑同交付／覆核要求）。多個部門逐個列。實際 deliverable 照樣寫入 story book，block 係 cover note。純向 Eis 匯報現況唔使 block，但只要提出「應叫某部門做 X」就要即場出 block。

## 目前進行中：DEV-P0-03（P0 設計閘門）

Vault 加密架構、金鑰生命週期與資料格式完整審查。
- **Phase A 已於 2026-07-21 正式批核通過**（`DEV-P0-03-Phase-A-批核決定-v1.md`）：QA PASS（66/66、48/48 重算相符）→ 總監五關抽查全過 → 批核。八項 finding 維持「未通過／待修正」直至 Phase B 修復驗證
- **Phase B 設計階段已開放（實作未開放）**：設計方案須逐項回應 V-01…V-08＋全記錄加密＋Argon2id；工作基線 Option 2（隨機 DEK＋password KEK＋domain-separated subkeys，條件式）；閘門：設計 → QA 審查 → 總監批核 → 先開實作
- 已完成（07-21）：erratum-01 留檔（CORR-A2-01 結案）；`DEV-P0-03-B1` Phase B 設計方案已提交（story book `DEV-P0-03-Phase-B-design\` 七檔，總監 hash 抽查吻合）
- **Phase B 設計已有條件批核**（`DEV-P0-03-Phase-B-design-批核決定-v1.md`，07-21）：QA 審查 CONDITIONAL（DR-01 Shamir 校驗用 SHA-256(密碼) 係爆破 oracle、DR-02 set_mac_key 未定案、DR-03/04/05 建議）
- 總監裁定：Option 2 **正式選定**；Argon2id 參數方向接納（真機 API24 量測係實作硬性交付）；**搜尋／排序採 in-memory 處理，blind-index 剔出 Phase B**；DR-01 方向指引＝分割隨機 DEK／全熵 recovery key 而非主密碼；DR-05 取「綁介面＋來源檢查」兩樣都要
- design v1.1 已交、**QA delta 覆核 PASS（07-21，無新增條件項）→ Phase B 實作正式開放**（開放日 2026-07-21）；DR-01 以「分割全熵 R＋commit=SHA-256(R)」根源解決，DR-02 取消 set_mac_key 改 commit 權威＋CRC32 誠實標註
- **已下達 `DEV-P0-03-B2` 實作工作指令（07-21）——首次授權修改產品加密程式碼**：
  - **B2-0 基線保護係硬閘**：建 `feat/vault-v3` 分支、現有 26 個工作樹修改分組 commit 保全、before manifest、**禁 `git reset --hard`／`checkout --`／`clean`**，完成後書面確認先可開工
  - 分批：B2-1 crypto 基礎＋Argon2id（限 07-25，含**真機 API24 量測硬性交付**）→ B2-2 fail-closed＋migration（V-03/V-04 必須同批，限 07-29）→ B2-3 restore/transfer 事務化（V-01 P0，限 08-01）→ B2-4 biometric＋Shamir（限 08-05）→ B2-5 全記錄加密＋in-memory 搜尋（限 08-08）
  - 逐批 QA 驗收＋總監批核先開下一批；設計凍結，發現缺陷須停手上報，禁自行偏離；每批須附測試（順帶償還測試覆蓋技術債）
- 待辦：秘書 TRUN 補記＋外部備份
- Phase A 原限制喺實作開放前繼續生效（只讀產品加密程式、合成資料、restore/transfer 禁真實 Vault）
- 指令：`DEV-P0-03-vault-cryptography-architecture-review-work-order-v1.md`
- 總監決定：`DEV-P0-03-Phase-A-security-tool-block-director-decision-v1.md`、`DEV-P0-03-Phase-A-reconciliation-director-decision-v1.md`
- Phase A 已於 2026-07-21 提交（無逾期），兩套證據（Codex 套 67 檔＋獨立套 28 檔）總監裁決**合併採用**
- 八項 finding 總監正式定級（2026-07-21）：V-01 restore 清庫先於驗證 **P0**、V-02 transfer import 清庫+deleteAll 先於驗證 **P1**、V-03 `_safeDecrypt()` fail-open **P1**、V-05 biometric raw key 非 auth-bound **P1**、V-04 migration 誤標損壞密文 P2（與 V-03 連動可升 P1）、V-06 無 AAD 跨欄位 swap P2、V-07 Shamir 全份集中 P2、V-08 Shamir share 無 MAC 靜默錯 secret P2（作派生用即升 P1）
- 下一步：QA 對合併證據包驗收 → 總監批核 → 決定 Phase B 開放
- 已下達（2026-07-21）：製作方 `DEV-P0-03-A2`（合併證據索引＋提交 QA，期限 07-22 18:00）；秘書 `SEC-NOTION-TDR-002`（八項 finding 定級登記＋AES-256 發布門檻登記＋備份，期限 07-23 18:00；TDR-001 如未建成限 07-23 12:00 補完）
- QA 已發提交前驗收要求通知（`QA-DEV-P0-03-Phase-A-submission-requirements-notice-v1.md`）；總監以協調通知（`DEV-P0-03-Phase-A-director-coordination-notice-QA-v1.md`）確認標準、更正過時觀察、擴充 QA 範圍至 B 套＋合併索引；V-01/V-02 即時安全通報已於 07-21 發出（E 節條件已滿足）
- 用戶決定（2026-07-21）：項目目前無任何對外宣稱（修正階段）；「AES-256 全加密」係上線／公告前嘅 release gate——全記錄加密完成並驗收先可上線及使用該宣稱（對應 P1 目標「全記錄加密＋Argon2id」）

### Phase A 硬性限制

- 不得修改產品加密程式、資料格式或使用者工作樹
- 測試只可用合成 Vault / 合成密碼 / 一次性 fixture
- Backup restore 與 device transfer import：內部未驗收，禁止真實 Vault 使用
- 暫停「2-Layer Backup / 安全還原 / 安全裝置轉移」等對外宣稱

## 已完成里程碑

- DEV-P0-01：strings.dart 修復，analyze 0 error 0 warning（餘 134 info）
- DEV-P0-02：Android build 統一（namespace / 唯一 MainActivity / FLAG_SECURE）
- SEC-AND-001：分享圖片匯入安全修復，QA 兩輪 correction 後總監正式批核
- REL-AND-API24-01:API24 release 驗證，總監批核

## 已知技術債

- 大量 `withOpacity` deprecated（改 `withValues(alpha:)`）
- 測試覆蓋不足：只有 crypto smoke test；欠 vault 建立/解鎖、備份 export/import、transfer、收據 parser 測試
- 備份 schema 未正式版本化（現時 `version: 2.0`）
- 保險庫部分財務欄位、標籤及 metadata 仍為明文（P1 目標：全記錄加密 + Argon2id）

## 常用指令

```powershell
C:\dev\flutter\bin\flutter.bat analyze
C:\dev\flutter\bin\flutter.bat test
```

## 語言

與用戶溝通用繁體中文（廣東話語氣可）；文件用繁體中文。
