# BRAIN（日本語）

英語版 `README.md` と同じ仕様です。両者に差異がある場合は英語版を正とします。

## BRAINとは

BRAINは、開発作業で得られた重要知識をプロジェクト単位で保持する、ローカル主体の記憶基盤です。対応AI（Claude、Codex、OpenCode、Cursor、GitHub Copilot CLI、Gemini CLI — 「Integration」参照）での作業終了時に、フックが短い作業記録の作成をアシスタントへ依頼します。BRAINは記録をプロジェクトごとに保管し、後のセッション開始時に最新のものを背景資料として渡します。

## BRAINでないもの

BRAINはLLMではなく、独自の知能を持ちません。常駐動作せず、クラウドサービスを呼びません。保存・注入する履歴は参考資料であり、非権威的と明示されます。指示・現行事実・コマンドとして扱われることはありません。

## 動作要件

- Windows
- PowerShell 7（`pwsh`）

## インストール

フォルダを任意の場所へコピー／cloneし、まず自分が使うAIを確認します（読み取り専用の一覧表示）：

```powershell
.\integrations\brain-setup.ps1 -Action Integrations
```

各エントリは検証状態を報告します。Provider単位は `Spec-validated`（公開仕様＋sandbox simulation 準拠）であり、live で証明された Capability は各 Integration 節に列挙します。完全な live 往復を主張する adapter はありません。

使う Integration ごとに導入する方式（推奨）か、全 enabled を一括導入します：

```powershell
.\integrations\brain-setup.ps1 -Action Install -Integration claude
.\integrations\brain-setup.ps1 -Action Install -Integration cursor
```

```powershell
.\integrations\brain-setup.ps1 -Action Install
```

引数なし `Install`（`-Integration` なし）は、**全 enabled Integration**（無効化しない限り Codex・Claude・OpenCode・Cursor・Copilot CLI・Gemini CLI）へ一括収束します。各 Integration は自分の成果物だけを変更し、変更前には必ずタイムスタンプ付き backup を取得します（「バックアップと復元」参照）：

- Codex：`%USERPROFILE%\.codex\hooks.json`
- Claude：`%USERPROFILE%\.claude\settings.json`
- OpenCode：`%USERPROFILE%\.config\opencode\plugins\brain.js`（`opencode.jsonc` は編集しません）
- Cursor：`%USERPROFILE%\.cursor\hooks.json`（user-level のみ。project の `.cursor/` や Rules には触れません）
- Copilot CLI：`%USERPROFILE%\.copilot\hooks\brain.json`（`COPILOT_HOME` リダイレクト対応。repository ファイルには触れません）
- Gemini CLI：`%USERPROFILE%\.gemini\settings.json`（`GEMINI.md`・instructions・skills・MCP 設定には触れません）

各ファイルには他設定・他フックに触れず BRAIN の hook エントリだけを追加します。ファイルが存在しない場合は新規作成します（存在しなかった旨の backup marker を残すため、`Restore` で再び削除されます）。

## 初回実行・検証

```powershell
.\brain.ps1 version
.\integrations\brain-setup.ps1 -Action Status
```

`version` は BRAIN 製品版・作業記録形式版・BRAIN root を表示します。`Status` は `pwsh` 可用性と provider・event ごとの BRAIN 管理 hook 数を報告します。変更は一切行いません。

## プロジェクト登録

```powershell
.\brain.ps1 register -ProjectPath 'C:\Projects\Example'
```

`register` だけが `config/projects.json` へ project を追加します。他コマンド（`init`・`collect`・`context`・`sync`）は未登録 project を拒否します。登録後はそのディレクトリ配下のどこから実行しても、 registered project root へ解決されます。

登録**できない**もの：

- 登録済み project の配下ディレクトリ（子ディレクトリ）、
- 登録済み project を含むディレクトリ（親ディレクトリ）、
- trusted root（後述）、
- ドライブ／ボリュームルート（例：`E:\`）、
- BRAIN root およびその配下。

同一 path・同一 id の再登録は無害で `REGISTERED_ALREADY` を返すだけです。同一 path の別 id、同一 id の別 path は拒否されます。入子禁止は意図的です：2つの project 木を1つの記憶へ統合する（どちらの向きも）と、project 別管理の意味がなくなります。

## 自動プロジェクト登録

Codex/Claude の hook 導入済みで、作業ディレクトリが trusted root 配下の場合、session の project は自動登録・初期化されます。手動の `register`／`init` は不要です。trusted roots は `config/trusted-roots.json` で設定します：

```json
{
  "format_version": "0.1",
  "trusted_roots": [
    "C:\\Projects"
  ]
}
```

自動登録は trusted root 配下の未登録ディレクトリにだけ適用されます。BRAIN root とその配下、trusted root 自体、全 trusted root 外、trusted root から作業ディレクトリまでの間に reparse point（junction／symlink）を含む場合は対象外です。明示登録済み project は trusted roots に関係なく動作します。`config/trusted-roots.json` が欠落・不正な場合は自動登録は無効です。hook 失敗は常に fail open です — BRAIN の問題で AI session が止まる・壊れることはありません。

## 通常利用

| コマンド | 内容 |
|---|---|
| `register -ProjectPath <path> [-ProjectId <id>]` | project ディレクトリを登録（任意カスタム id、小文字英数字/`._-`）。 |
| `init -ProjectPath <path>` | 登録済み project に `.brain/` がなければ作成。 |
| `collect -ProjectPath <path>` | `.brain/outbox` の新規記録を検証して `store/raw` へ複写。 |
| `context -ProjectPath <path> [-MaxRecords N] [-MaxContextBytes N]` | 保存記録から `.brain/context.md` を再生成（既定：最新10件・32 KiB）。 |
| `sync -ProjectPath <path>` | `init`・`collect`・`context` をまとめて実行。 |
| `version`（または `-Version`） | BRAIN 版・記録形式版・BRAIN root を表示。 |

登録済み project 内で BRAIN が書くのは以下だけです：

```text
.brain/
  project.json
  outbox/
  context.md
```

作業記録は `templates/work-record.md` の形式で `.brain/outbox/` へ直接置きます。各記録は必須 front matter と8セクションが必要で、各セクションは `[Observed]`・`[Suspected]`・`[Verified]` ラベルの1行箇条書きを1件以上含みます。

収集動作：

- 記録は収集前に検証されます。
- Raw 記録は `store/raw/<project-id>/<sha256>.md` へバイト単位で保存されます。
- 既存 Raw 記録の上書き・削除はしません。
- 同一内容は SHA-256 照合後に何もしません（no-op）。
- outbox 記録の移動・削除はしません。
- `context.md` は検証済み最新 Raw 記録から決定的に生成されます。
- ローカル単一 writer lock が registry・raw・context の同時更新を防ぎます。
- Markdown 内容を実行することはありません。
- 秘密鍵ブロック・bearer 認証ヘッダ・明らかな secret 代入を含む記録は拒否されます。credential・token・cookie・秘密鍵・個人データを作業記録に入れないでください。

Context 上限の既定は最新10件・32 KiB です。必要な場合だけ変更します：

```powershell
.\brain.ps1 context -ProjectPath 'C:\Projects\Example' -MaxRecords 20 -MaxContextBytes 65536
```

## 更新（Update）

```powershell
.\integrations\brain-setup.ps1 -Action Update
```

BRAIN の hook エントリをその場で置換します。BRAIN 管理ハンドラ（旧 `BRAIN v0.1 ...` 含む）を認識して置換するため、繰返し実行は Integration・event ごとに BRAIN ハンドラ1件へ必ず収束し、重複を作りません。他設定は不変です。変更不要なら `changed=false` を報告し、書込・backup とも行いません。単一 Integration の更新は `-Integration <id>` を付けます。

## 修復（Repair）

```powershell
.\integrations\brain-setup.ps1 -Action Repair
```

よくある問題（`pwsh` 欠落、BRAIN ファイル欠落、`projects.json`／`trusted-roots.json` 読取不可、hook 設定読取不可、legacy エントリ、重複・欠落ハンドラ、第三者ファイル競合など `brain.js`）を報告します。安全に直せるもの（解析でき、所有するファイルのエントリ）は `Update` と同じ方式で再同期します。解析不能ファイルは報告して skip し、書き換えません。

## アンインストール（Uninstall）

```powershell
.\integrations\brain-setup.ps1 -Action Uninstall
```

BRAIN 自身の hook エントリ**だけ**を削除します — Codex/Claude 設定に加え、管理対象の OpenCode plugin ファイル（`plugins/brain.js`、BRAIN 管理 marker 付きのみ）も対象です。他設定・非 BRAIN エントリは完全温存です。単一 Integration は `-Integration <id>` を付けます。

記憶データは**削除しません**。以下は残ります：

- `config/projects.json`（project 登録）
- `config/trusted-roots.json`（trusted roots）
- `config/integrations.json`（provider 有効/無効）
- `store/raw`（全作業記録）
- 各登録 project の `.brain` ディレクトリ

記憶自体を消す場合は自分で削除します — 例：`store/raw`・`config/projects.json`・各 project の `.brain` フォルダ。

## バックアップと復元

```powershell
.\integrations\brain-setup.ps1 -Action Backup
.\integrations\brain-setup.ps1 -Action Restore
```

`Install`・`Update`・`Repair`・`Uninstall` は変更前に設定ファイルを backup します（`<元ファイル>.brain-backup-<yyyyMMdd-HHmmssfff>`）。`Restore` は最新の一致 backup（または Codex/Claude 用の明示 `-CodexBackupPath`／`-ClaudeBackupPath`）を live ファイルへ戻し、その前に現ファイルを safety backup します。backup が「元々不存在」を記録している場合、`Restore` は live ファイルを再び削除します。

これらは**設定 backup 専用**です — hook 設定を守るもので、BRAIN 記憶データではありません。記憶の backup は `store/raw` と `config/projects.json` を自分で複写します。

## バージョン

```powershell
.\brain.ps1 version
```

BRAIN 製品版（`VERSION` ファイル）と作業記録形式版は別管理です。記録形式は `0.1` のまま — BRAIN 更新で既存記録の形状は変わらず、`store/raw` の移行も不要です。

## Integration（汎用基盤）

BRAIN Core は AI 固有知識を持ちません。各 AI は `integrations/providers/` の小さな adapter 定義（1 Integration 1ファイル、例：`codex.ps1`）で記述され、`lib/brain-integrations.ps1` の registry が検出します。将来の追加（Kilo・Z Code・custom）は定義1件＋テストで対応でき、Core は不変です。

```powershell
.\integrations\brain-setup.ps1 -Action Integrations
.\integrations\brain-setup.ps1 -Action Disable -Integration codex
.\integrations\brain-setup.ps1 -Action Enable -Integration claude
.\integrations\brain-setup.ps1 -Action Install -Integration claude
```

`Integrations` は全 Integration の有効 flag・設定 path・event・検証状態を列挙します。Provider 単位は `Spec-validated`（公開仕様＋sandbox simulation 準拠）で、live 証明済み Capability は各 Integration 節に列挙します。完全 live loop 主張の adapter はありません。`Enable`／`Disable` は `config/integrations.json` へ保存します（欠落＝全 enabled のため既存導入は継続動作）。`Install`・`Update`・`Repair` は無効 Integration を skip し設定に触れません。`Uninstall`・`Backup`・`Restore` は無効でも処理します（BRAIN 自分の除去と設定 backup は安全な掃除であり新規配線ではないため）。`Status` は有効 flag を報告します。未知 id は明確エラー（`Unknown integration: <id>. Known integrations: ...`）で他に波及しません。旧 `integrations/install-hooks.ps1` ラッパは Codex/Claude の Install 専用で2者のみ報告します — それ以外は `brain-setup.ps1` を使います。

## OpenCode（Desktop / CLI）

ファイル型 Integration です。Desktop・CLI とも同一 opencode server が動作し、global plugin ディレクトリ（`~/.config/opencode/plugins/`）の local plugin を自動読込するため、1 Integration で両対応し、`opencode.jsonc` は編集しません（OpenCode は設定を merge します）。

```powershell
.\integrations\brain-setup.ps1 -Action Install -Integration opencode
.\integrations\brain-setup.ps1 -Action Status -Integration opencode
.\integrations\brain-setup.ps1 -Action Uninstall -Integration opencode
```

Install は小さな bridge plugin（`brain.js`、BRAIN 管理 marker 付き）を global plugin ディレクトリへ複写します。実行時は bridge が `brain-hook.ps1 -Provider opencode` を呼戻して既存 Core フローを使います：

- `session.created`（＋初メッセージ時の lazy start。`--continue`／`--session` resume は event が飛ばないためこれで補完）が project を解決し、`.brain/context.md` を次 user メッセージへ1回だけ追記。
- `tool.execute.after` が session を dirty 化。
- `session.idle` が TUI プロンプトへの pre-fill（`appendPrompt`）＋toast で作業記録を要求 — 自動送信はしないためループ不能。
- `session.deleted` は記録済みなら pending 記録を sync。

上書き・削除は BRAIN 管理 marker 始まりのファイルだけ。sibling plugin や自前の `brain.js` は不変（`conflict-plugin:opencode` 報告）。既知制限：turn 終端を block する hook がないため記録要求は pre-fill（強制ではない）、resume session の context は次メッセージ時。

検証：spec-validated（導入済み plugin API 型＋sandbox simulation。Desktop/CLI 実機 run なし）。

## Cursor

native `hooks.json` 形式（flat event別 command list）の hook 型 Integration です。BRAIN が管理するのは **user-level**（`~/.cursor/hooks.json`）だけ — project の `.cursor/hooks.json` は version 管理下の repository 内にあり、Cursor Rules は命令面のため両方とも不触（履歴は非権威な参考資料であり続け、rules 化しません）。

```powershell
.\integrations\brain-setup.ps1 -Action Install -Integration cursor
.\integrations\brain-setup.ps1 -Action Status -Integration cursor
.\integrations\brain-setup.ps1 -Action Uninstall -Integration cursor
```

既存 `brain-hook.ps1` フローによる実行時動作：

- `sessionStart` が project を解決（`workspace_roots` 経由）し、現 `.brain/context.md` を `additional_context` で返却。
- `postToolUse` が session を dirty 化（Write/Delete 系 tool）。
- `stop` が作業記録要求を `followup_message` で返却し、Cursor が次 user メッセージとして自動投入（BRAIN 要求上限と Cursor `loop_limit` で有界）。記録後は次 `stop` で無出力 sync。
- `sessionEnd` は記録済みなら pending 記録を sync。

既知制限：`stop` は次メッセージへ自動投入されます（BRAIN 要求上限と `loop_limit` 5 で有界）。shell 駆動・subagent 経由の編集は dirty 化しません（Write/Delete 系のみ）。

検証：spec-validated が基本。Install/Status/Uninstall/Restore、`SessionStart`／context 注入、`PostToolUse` dirty 化、`SessionEnd` は 2026-09-04 に live 検証済み（Desktop session＋CLI `-p` run）。`Stop`／record 往復は spec-validated のまま。

`Status` は `candidate_roots`・`selected_root`・`selection_reason` も Integration ごとに報告するため、複数候補 root 解決を点検できます。テスト・dry run は `-SandboxDir <dir>` で全成果物を redirect できます（精密 override：hook JSON は `-ConfigPath`、plugin は `-PluginPath`）。

## GitHub Copilot（CLI）

native Copilot CLI hooks 形式（`powershell`＋`timeoutSec` の flat event別エントリ）の hook 型 Integration です。BRAIN が管理するのは user-level 1ファイル（`~/.copilot/hooks/brain.json`、`COPILOT_HOME` リダイレクト対応）のみ — repository ファイル・custom instructions・skills・MCP 設定には触れません（履歴は非権威な参考資料であり続け、恒久命令にしません）。

```powershell
.\integrations\brain-setup.ps1 -Action Install -Integration copilot
.\integrations\brain-setup.ps1 -Action Status -Integration copilot
.\integrations\brain-setup.ps1 -Action Uninstall -Integration copilot
```

既存 `brain-hook.ps1` フローによる実行時動作：

- `SessionStart` が project を解決し、現 `.brain/context.md` を `additionalContext` で返却。
- `PostToolUse` が session を dirty 化（create/edit 系 tool）。
- `Stop`（agentStop）が作業記録要求を `decision: block` で返却し、CLI が次 turn として投入（BRAIN 要求上限と CLI runaway guard で有界）。記録後は次 stop で無出力 sync。
- `SessionEnd` は記録済みなら pending 記録を sync。

意図的未登録：`preToolUse`／`permissionRequest`（command hook は fail-closed で hook 異常が tool を拒否するため。BRAIN が session を壊してはならない）、prompt hook、VS Code Chat hook（別 Preview 系）、JetBrains hook（公式 reference なし）、cloud-agent hook（repo-commit・Linux 専用 sandbox）。

既知制限：shell 駆動・subagent 経由の編集は dirty 化しません（create/edit 系のみ）。hook 動作には CLI 導入が必要です。

検証：spec-validated が基本。Install/Status/Uninstall/Restore は 2026-09-04 に live 検証済み（CLI 1.0.82）。model lifecycle は spec-validated のまま：live CLI 経路は組織により POLICY BLOCKED のため live model session は存在しません。

## Gemini CLI

native hooks 形式（ms 単位 `timeout` の nested event別グループ）の hook 型 Integration です。BRAIN が管理するのは user-level `~/.gemini/settings.json` の hooks のみ — project ファイル・`GEMINI.md`・instructions・skills・MCP 設定には触れません（履歴は非権威な参考資料であり続け、恒久命令にしません）。

```powershell
.\integrations\brain-setup.ps1 -Action Install -Integration gemini-cli
.\integrations\brain-setup.ps1 -Action Status -Integration gemini-cli
.\integrations\brain-setup.ps1 -Action Uninstall -Integration gemini-cli
```

既存 `brain-hook.ps1` フローによる実行時動作：

- `SessionStart` が project を解決し、現 `.brain/context.md` を `hookSpecificOutput.additionalContext` で返却。
- `AfterTool` が session を dirty 化。
- `AfterAgent` が作業記録要求を `decision: deny` で返却し、要求付き retry turn を強制（BRAIN 要求上限と `stop_hook_active` で有界）。記録後は次 turn で無出力 sync。
- `SessionEnd` は記録済みなら pending 記録を sync（CLI 仕様上 best-effort）。

既知制限：`AfterTool` に tool matcher なし（全 tool が dirty 化するが要求は有界のため問題なし）、`BeforeTool` は意図的未登録（deny 出力が tool を block するため）。live run 2026-09-04（CLI 0.58.0、API-key 認証）：`SessionStart` と `AfterTool` は context 注入・dirty 化つきで発火。`AfterAgent`／`SessionEnd` は非対話（`-p`）run では CLI が起動しなかったため、record loop は対話 session 依存。

検証：spec-validated が基本。`SessionStart`／`AfterTool`／Install／Status／Uninstall／Restore は 2026-09-04 に live 検証済み（CLI 0.58.0）。`AfterAgent`／`SessionEnd`／record 往復は spec-validated のまま。

## トラブルシューティング

| 症状 | 確認点 |
|---|---|
| hook が発火しない | `-Action Status` を実行。`pwsh` が `PATH` にあり、event ごとの handler 数が1であること。 |
| `Project is not registered` | `brain.ps1 register` で project ディレクトリ（またはその上位の登録済みディレクトリ）を登録。 |
| `... cannot be registered as a project` | 登録済み project の親・子・trusted root・ドライブルート・BRAIN root（配下含む）を登録しようとしている — 上記「プロジェクト登録」参照。 |
| session 開始時に context が出ない | project の `.brain/context.md` の存在を確認。手動で `brain.ps1 sync -ProjectPath <path>` を実行。 |
| 古い・重複 hook エントリ | `-Action Repair` を実行。 |
| `conflict-*` 報告・skip される install | 第三者ファイルが対象名を占有（例：自前の `brain.js`）。BRAIN は上書きしない — 管理させたい場合は自分で rename/remove。 |
| `invalid-json`・解析不能 config | `Repair`／`Uninstall` は解析不能ファイルを書き換えず skip。自分で修正・復元して再実行。 |
| 未知 integration id | エラーに既知 id 一覧が出る。綴り確認か `-Action Integrations` で列挙。 |
| 新しい tool で hook が無反応 | 未知 `-Provider` 値は hook ログに記録して無視（fail-open）。`%LOCALAPPDATA%\BRAIN-v0.1\hook-state\brain-hook.log` を確認。 |
| hook ログの場所は？ | `%LOCALAPPDATA%\BRAIN-v0.1\hook-state\brain-hook.log` |

hook は常に fail open です：BRAIN 内部で問題が起きても hook は正常終了し、AI session は継続します。

## プライバシー

BRAIN の記録は自分のマシンにだけ保存し、自発的に外部送信しません。ただし session 開始時に履歴 context を Claude・Codex 等の AI サービスへ注入すると、その context はプロンプトの残りと一緒にサービスへ送信されます。自分で打った内容と同様です。

作業記録 validator は明らかな秘密鍵ブロック・bearer token・鍵らしい代入を拒否しますが、単純パターン検査であり保証ではありません — あらゆる secret を検出できるわけではありません。credential・token・個人データを作業記録に入れないでください。

## ライセンス

ライセンス: Proprietary / Source Available
無料利用・ソース閲覧可。無断再配布・転売・改変版配布は禁止。

BRAIN は Mostly Works による Source Available / Proprietary ソフトウェアです。オープンソースソフトウェアではありません。利用とソース閲覧は無料、無断再配布・転売・改変版配布は禁止です。`LICENSE.ja.md`（正文）と `LICENSE`（英語参考訳）を参照。連絡先: brainbucket000@gmail.com。

## テスト

```powershell
pwsh -NoProfile -File .\tests\run-all.ps1
```

全テストは sandbox 実行です：`run-all` がテストファイルごとに fresh な `BRAIN_TEST_SANDBOX` を割り当て、`brain-setup`／`brain-hook` は gate 有効中すべての解決済み Integration 対象をその配下へ強制します — テストが path 指定を忘れても新規 Integration が実 user profile へ漏れません。sandbox 外への書込はディスク接触前に `TEST SAFETY VIOLATION` で fail-closed します。`run-all` は各テスト前後で canary（`~/.claude`・`~/.codex`・`~/.config/opencode`・`~/.cursor`・BRAIN `config`・`store/raw` を read-only 監視）を snapshot し、差分で run 全体を FAIL させます。精密 override として `-SandboxDir`（全体）・`-ConfigPath`（hook JSON）・`-PluginPath`（plugin）が残っています。
