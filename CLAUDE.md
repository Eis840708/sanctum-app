# SANCTUM 項目記憶（CLAUDE.md）

> 每次開新對話先讀本檔。詳細歷史／決定緣由喺 `story book\PROJECT-LOG.md`（只喺需要追溯時先讀，唔使每次讀）。
> 最後更新：2026-07-31（本次僅文檔更新，非實作改動）

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
- B2 分五批：B2-1…B2-5a／**B2-5b 已批核（2026-07-27，HEAD `028ac96`）——crypto 核心收尾**。既有 vault 遷移＋全記錄加密＋in-memory 搜尋完成；QA raw .hive bytes 掃描證 9 secret 全無明文、遷移中斷 4/4 存活、V-06 跨 vault swap fail-closed；總監親跑 test 155/155；crypto/shamir/**models.dart 零改動**（方案 C）、vault_service `60368781`。
- **里程碑：B2 五批 crypto/service 核心全部完成並驗證**。八項 finding crypto 核心均已落地（V-01/02 事務化、V-03 fail-closed、V-04 顯式 migration、V-05 opt-in、V-06 per-field AAD 全欄位、V-07 逐一分發、V-08 envelope+recovery）；全記錄加密軟件部分達標。**但 finding 仍維持「未通過」**，待餘項收斂。
- **⚠ B2-5a「v3」僅金鑰模型（DEK），記錄格式仍 v2**；全記錄加密＝B2-5b；**「AES-256 全加密」release gate 未解除**，對外宣稱維持暫停。
- **B2-5b 硬性**（P0 級遷移風險，比照 B2-3）：既有 vault 遷移＝全記錄加密同一操作；事務化 staging→verify→commitIntent(point of no return)→atomic swap→journal resume；既有 vault 存活＋遷移中斷＝RETURN 級（真 adapter 重現，回歸入 committed suite）；V-06 per-field AAD 綁定；vault_service before `5e775f1d…` 只改授權範圍，crypto/shamir 零改動。
- **B2-5b 型別欄位儲存裁決**（`DEV-P0-03-B2-5b-plan-director-ruling-v1.md`）：製作方揪出 design §3.1（base64-in-string-field/不改 schema）與 §5（加密 double/DateTime/List 型別欄位）**內部矛盾**（base64 塞唔入 typed 欄位）。裁**方案 C**：獨立 v3 加密 box（keyed by id），逐欄位 envelope（V-06 per-field AAD 保留，僅改儲存位置非粒度），舊 typed box/adapter 零改動（models.dart 不改）、最忠於 §3.1 意圖。須出設計增補文件（v1.3-delta：v3=encrypted box／v2=typed box，併 coexistence）守設計凍結。schema_version/field_id 採 design-spec §3.4。
- **B2 收尾後餘項（finding 改判＋release gate 解除前）**：
  - **v3 UI 整合任務**（shamir_screen UI＋seam 1 transfer 密碼＋seam 3 backup UI＋**v3 backup/export**）＝**Internal Alpha 前硬性阻塞**；
  - **⚠ v3 backup release-sequencing 裁定**（`DEV-P0-03-B2-5b-批核決定-及-release-sequencing-裁定-v1.md`）：遷移於 v2 unlock 後**自動觸發**，但 exportVaultJson 仍 v2（v3 vault 匯出會空）＋recovery UI 未接 → **自動遷移不得進入任何 user-facing build（含 Alpha）直至 v3 backup/export＋recovery UI 接妥**。現 pre-release 無真實 vault 無即時風險，但對外 build 前必查；
  - B2-5a-native（V-05 auth-bound native，實體機 bucket）；實體 ARM API24 Argon2id 量測（release gate，實體機 bucket）。
- release gate 完整解除＝全記錄加密（B2-5b✓）＋實體量測（待）；八項 finding 改判待 v3 UI 整合＋B2-5a-native 完成後整體驗證。
- **v3 UI 整合任務**（`DEV-P0-03-v3-UI-integration-work-order-v1.md`，DEV-P0-03-UI，P0/Alpha 前硬性，四子項）：
  - **子項 A（v3 backup/export）已批核並 pin commit**（批核 2026-07-30 `DEV-P0-03-A-批核決定-v1.md`；收尾＋commit 2026-07-31）：SNCB3 雙層容器、header 內嵌 VaultV3Material（§6 採 a，暴力面＝device、Argon2id gated、標準性質無新弱點）、全裝置 round-trip、raw blob 零明文、核心四檔＋vault_v3_keys 零改動、vault_service `905bf85b`。收尾全清：backup-schema 增補已附（`DEV-P0-03-A-backup-schema-v3-delta-v1.md` v1.1-delta）；committed suite 已含全裝置 round-trip＋既有-vault 拒絕存活（QA harness 冗餘已移除、獨有案例併入 producer `vault_v3_backup_real_adapter_test.dart`）；全 suite 180/180、analyze err0/warn2/info162。
  - **子項 B（backup restore UI／接縫3）、C（shamir_screen recovery UI）、D（transfer 收端密碼／接縫1，需 UX 提案）**：待做。
  - UI/UX 設計凍結較寬（安全不變式必守、UX 判斷提案覆核）；使用者資產 UI 檔最小改＋before hash；crypto/shamir/models 零改動。
  - **⚠ release-sequencing 未解除**：子項 A 只解 service 層一環；完全解除待 B＋C 整體驗收。自動遷移維持不得入任何 user-facing build（含 Alpha）。
- **B2-5a 方案已覆核（`DEV-P0-03-B2-5a-plan-director-ruling-v1.md`）**：確認「既有 vault 得 DEK ≡ 重加密 ≡ B2-5b 全記錄加密」耦合。裁**方案 A**：B2-5a 只接 DEK 骨架＋**新 vault** 用 DEK＋unlock 依 meta.version 分流（**v2 走舊路徑零改動零回歸**）＋V-05 auth-bound/V-08 recovery（限 v3 vault）＋coexistence 規格增補（v2/v3 並存須文件化）；**既有 v2 vault 遷移留 B2-5b**（連全記錄加密、V-06 AAD、遷移中斷 RETURN 測試）。
- **B2-5a RETURN 級**（更正 B2-4 §3.3）：v2 解鎖零回歸＋v3 DEK round-trip（非「遷移中斷」，因 B2-5a 無遷移）。Argon2id 用臨時 above-floor 參數（self-describing 可 KEK 升級唔使重加密；floor 19MiB/t2/p1 仍守；release-gate 實體量測不阻塞 B2-5a）。V-05 native＝自寫最小 platform channel（crypto 綁定）＋local_auth（UI 觸發）。限期 07-29。
- **B2-3 里程碑**：V-01（唯一 P0）事務化 restore/transfer 修復完成，QA 真 adapter harness＋總監親跑 test 95/95 雙重證實舊攻擊路徑失效；V-02 同步收尾。vault_service.dart 已改（`9c1316d4`，限 restore/transfer＋unlock resume hook）；真 adapter 回歸測試入 committed suite（fake-only 缺口閉合）。八項 finding 仍維持「未通過」至 B2 全批整體驗收。
- **接縫遺留**：接縫 1（transfer 收端密碼確認）＋接縫 3（backup UI 傳 masterPassword）併「v3 UI 整合」任務，**Internal Alpha 前必完成**。
- **B2-4 結構轉折**：首次授權修改 `shamir_service.dart`（限 V-07/V-08）；開工前出 before hash（`fe42c2ed…`）。V-08 依 design v1.1：分割全熵 R、commit=SHA-256(R)、取消 set_mac_key，combine 顯式報錯。
- **B2-4 DEK 相依排序裁示**（`DEV-P0-03-B2-4-sequencing-ruling-v1.md`）：製作方停手上報「V-05 auth-bound／V-08 還原 均以包裝 DEK 為根基，但 live vault 尚無 DEK（DEK 接入原排 B2-5）」——若強做會用 R 包密碼＝重引 DR-01 oracle。裁採方案 A：**B2-4 只做 DEK-無關部分**（V-07 逐一分發、V-05 opt-in、V-08 crypto 核心 envelope/全熵R/commit/combine顯式報錯，自足可測）；**DEK-綁定部分（V-05 auth-bound wrap DEK、V-08 還原 live 接線）遞延新設地基子步 `B2-5a：DEK live-integration`**。V-05 native auth-bound（KeyStore/CryptoObject）亦排 B2-5a，開工前提迷你依賴評估（傾向自寫最小 platform channel；API24 僅 TEE）。不得以 R wrap 密碼/sessionKey 偏離 v1.1。
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
