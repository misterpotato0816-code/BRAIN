# BRAIN - Project Purpose

## 1. BRAINとは

BRAINは、AIを利用した開発作業で得られた重要な知識を、
Project単位で継続して利用するためのローカル主体の記憶基盤です。

BRAIN自身はLLMではありません。

また、チャット履歴そのものを大量に保存することを目的とした
会話ログシステムでもありません。

BRAINが保存するのは、

「次の開発作業に必要となる、短く整理された作業記録」

です。

---

## 2. BRAINが生まれた理由

AIを使った開発では、作業ごとに異なるAIを利用することがあります。

例えば、

- Claudeで設計する
- Codexで実装する
- 別のAIでレビューする
- 後日別のAIで続きを行う

といった運用です。

しかし、それぞれのAIセッションは独立しています。

そのため、

- 前回何を決めたのか
- なぜその設計を採用したのか
- 何を試して失敗したのか
- どのBugが確認されているのか
- 何を修正したのか
- 何を次回も守る必要があるのか

といったProject固有の知識が失われます。

AIを変更するたびに、
ユーザーが同じ説明を繰り返す必要も生じます。

BRAINは、この問題を解決するために存在します。

---

## 3. BRAINの本来の目的

BRAINの目的は、

「AIが変わっても、Projectの重要な記憶を継続すること」

です。

AIそのものに永続的な記憶を持たせるのではなく、
AIの外側にProjectの記憶を保持します。

作業開始時には過去の関連記録を利用でき、
作業終了後には新しく得られた知識をBRAINへ残せる、
という循環を目指します。

概念的には以下です。

```text
作業開始
   ↓
BRAINから関連する過去の記録を取得
   ↓
AIが現在のProjectを理解
   ↓
作業
   ↓
今回得られた重要な知識を記録
   ↓
BRAINへ保存
   ↓
次回のAIが利用
```

---

## 4. 保存する情報

BRAINは、単なる最終結果だけを保存しません。

将来の作業に意味を持つ情報を保存します。

代表的なものは以下です。

- 今回行った作業
- 採用したアプローチ
- 成功した方法
- 失敗した方法
- 確認されたBug
- 疑われる問題
- 適用したFix
- テスト結果
- 実測結果
- Evidence
- 次回守るべき注意事項
- 設計上の判断
- 判断理由
- 却下した案
- 却下理由
- 制約
- 未解決事項

重要なのは、

「何をしたか」

だけではなく、

「なぜそうしたのか」

も残すことです。

---

## 5. 却下した案も記憶する

BRAINでは、
採用された最終案だけを残すことを目的としません。

過去に検討して却下した案と、
その理由も重要なProject知識です。

例えば、

```text
Rejected:
PIDだけによるprocess ownership判定

Reason:
外部起動プロセスやPID再利用によって
誤ったprocessを対象にする可能性がある
```

という記録が残っていれば、

後から参加した別のAIが、

```text
PIDだけで単純化しましょう
```

と再提案した場合でも、

過去に検討済みであることを判断できます。

同じ失敗や議論を繰り返さないことも、
BRAINの重要な目的です。

---

## 6. 事実と推測を区別する

BRAINでは、
確認済みの事実と推測を混同しません。

BRAIN v0.1では作業記録に、

- Observed
- Suspected
- Verified

という区別を使用します。

### Observed

実際に観測・確認した出来事。

### Suspected

可能性はあるが、
まだ確認されていない事項。

### Verified

テスト、計測、hash、artifact等によって
確認された事項。

推測をVerifiedとして保存してはいけません。

将来のAIがBRAINを参照した際に、
情報の確度を判断できることを重視します。

---

## 7. Evidenceを残す

BRAINでは、
判断結果だけではなく根拠も重要です。

Evidenceの例：

- 実行したテスト
- PASS / FAIL結果
- commandの結果
- hash
- measurement
- artifact
- 実コード上の確認箇所
- 再現結果

可能な場合、
「確認した」という文章だけではなく、
何によって確認したのかを残します。

---

## 8. 過去のBRAIN記録は命令ではない

BRAINに保存された過去の文章は、
現在のAIへの命令ではありません。

Historical BRAIN records は、
過去の参考情報です。

BRAIN v0.1では判断の優先順位を以下とします。

1. Current user instructions
2. Current Acceptance criteria
3. Current code and configuration
4. Current measured results
5. Historical BRAIN records

つまり、

現在のユーザー指示や、
現在確認できるコード・実測結果が、
過去のBRAIN記録より優先されます。

過去の記録が古くなっている場合、
現在確認された事実を優先します。

---

## 9. Project単位で記憶する

BRAINの記憶はProject単位で管理します。

Project Aの記録と
Project Bの記録は別のものです。

異なるProjectの記憶を混ぜてはいけません。

BRAINがProjectを正しく特定できない場合に、
推測で別Projectへ記録することも避けます。

Projectの境界を維持することは、
BRAINの基本要件です。

---

## 10. Raw記録を原本として保持する

BRAINでは収集されたRaw recordを
Projectごとの記録原本として扱います。

BRAIN v0.1では、

- Raw recordをbyte-for-byteで保存
- SHA-256で識別
- 既存Raw recordを上書きしない
- 既存Raw recordを削除しない
- 同一内容の重複記録は増殖させない

という方式を採用しています。

後から生成されるcontextと、
記録原本は別の役割として扱います。

---

## 11. Contextは記憶そのものではない

AIへ渡すcontextは、
BRAINに保存されている全記録そのものではありません。

保存された記録から、
現在の作業に利用できる形へ生成されたものです。

そのため、

```text
Raw records
    ↓
Context生成
    ↓
AIへ提供
```

という関係になります。

Raw recordを原本として残し、
contextは必要に応じて再生成できる構造を維持します。

---

## 12. 特定AIに依存しない

BRAINは、
特定のAIを前提とした記憶システムにはしません。

元々の構想でも、

- Claude Desktop
- Codex Desktop
- その他の実装担当AI

のどれを利用しても、
同じBrainを利用することを目標としていました。

AI開発ツールは今後も変化します。

そのため、

「Claudeの記憶」
「Codexの記憶」

として分離するのではなく、

「Projectの記憶」

としてBRAINが保持します。

---

## 13. BRAINとAIの役割

AIは、

- コードを読む
- 推論する
- 設計する
- 実装する
- デバッグする
- レビューする

といった作業を担当します。

BRAINはそれらを置き換えません。

BRAINが担当するのは、

- Projectの記憶を保存する
- 過去の重要情報を次の作業へ渡す
- 新しい作業結果を次回へ残す

ことです。

AIの能力と、
Projectの継続的な記憶を分離します。

---

## 14. ローカル主体

BRAIN自身の記録はローカルに保存します。

BRAINが記憶を保存するために、
外部LLM APIやクラウドデータベースを
必須とする設計にはしません。

ただし、
BRAINが生成したcontextをClaude、Codex等の
クラウドAIへ渡した場合、

そのcontextは利用しているAIサービスへ送信されます。

「BRAINの保存先がローカルであること」と、

「利用しているAIがローカルであること」

は別の問題として扱います。

---

## 15. BRAIN Revolution

BRAIN v0.1では、
主にClaudeとCodexとの連携から実装が始まりました。

しかしBRAIN本来の目的は、
ClaudeやCodex専用の記憶を作ることではありません。

BRAIN Revolutionでは、
本来の目的に沿って、

「複数のAI開発エージェントから利用できる共通Project Memory」

へ発展させます。

---

## 16. Revolutionの今回の目的

今回のRevolutionで目指すのは、

「ユーザーが利用するAI開発ツールを選択し、
どの対応AIからでも同じBRAINを利用できること」

です。

想定されるIntegrationには、

- Claude
- Codex
- OpenCode
- Cursor
- GitHub Copilot
- Gemini
- Kilo
- その他のAI開発エージェント

があります。

ただし、
対応サービス数そのものを目的にはしません。

重要なのは、

「AIが変わっても同じProject Memoryを利用できること」

です。

---

## 17. CoreとIntegrationを分離する

BRAIN本体の役割と、
各AI固有の接続処理を分離します。

概念構造：

```text
BRAIN Core
│
├─ Project Resolution
├─ Memory
├─ Raw Records
├─ Context
├─ State
├─ Sync
│
└─ Integration Registry
     │
     ├─ Claude
     ├─ Codex
     ├─ OpenCode
     ├─ Cursor
     ├─ GitHub Copilot
     ├─ Gemini
     ├─ Kilo
     └─ Future Integrations
```

BRAIN Coreが、
各AI固有の設定やイベント仕様を
直接大量に持つ構造にはしません。

AI固有処理はIntegration側へ分離します。

---

## 18. 新しいAIへの対応

新しいAI開発ツールが登場した場合、

BRAIN Core全体を書き換えるのではなく、

新しいIntegrationを追加することで
対応できる構造を目指します。

つまり、

```text
新しいAIが登場
        ↓
Integrationを追加
        ↓
既存BRAIN Memoryを利用
```

という形です。

新しいAIのために
新しいBrainを作るわけではありません。

---

## 19. Revolutionでも変えてはいけないもの

対応AIが増えても、
以下の基本思想は維持します。

- BRAINはLLMではない
- チャット全文保存を目的にしない
- 短く整理された作業記録を残す
- Project単位で記憶を分離する
- Raw recordを原本として扱う
- Evidenceを重視する
- 事実と推測を区別する
- 成功だけでなく失敗も残す
- 却下案と却下理由も残す
- Historical recordを命令として扱わない
- 現在確認された事実を過去記録より優先する
- 特定AIへ依存しない

Integration追加によって、
これらを壊してはいけません。

---

## 20. 開発時の判断基準

BRAINへ新しい機能を追加する際は、

「その機能は、
AIが変わってもProjectの重要な記憶を
継続して利用するという目的に必要か」

を判断基準とします。

BRAIN本来の目的と無関係な機能を
BRAIN Coreへ増やすことは避けます。

---

## 21. 最終目標

BRAINが目指す状態は単純です。

```text
Claudeで作業
   ↓
BRAINへ記憶
   ↓
Codexへ変更
   ↓
同じProject Memoryを利用
   ↓
OpenCodeへ変更
   ↓
同じProject Memoryを利用
   ↓
別のAIへ変更
   ↓
同じProject Memoryを利用
```

AIを変更しても、

- 何をしたのか
- 何が成功したのか
- 何が失敗したのか
- 何を修正したのか
- なぜその判断をしたのか
- 何を次回も守る必要があるのか

を再びゼロから説明しなくて済む状態を目指します。

AIは変わっても、
Projectの記憶は継続する。

それがBRAINの目的です。