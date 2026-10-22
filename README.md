# app-itonami-dandori

**dandori（段取り）は、Linear 互換の課題トラッカーです。** itonami dapp として、ブラウザの中だけで動きます。

- Linear からエクスポートした CSV／GraphQL JSON を取り込めます。
- 課題・ワークフロー（状態の型）・優先度・見積・サイクル・SLA を扱えます。
- 同じ 2 形式で書き出せます。
- データはどこにも送信されず、利用者の端末の localStorage にだけ残ります。

公開先（予定）: app.itonami.cloud/dandori/（`network-awai/cloud-itonami` の sites.edn、app org）。
追跡: Linear JUN-286。

この README は**今この repo に何が在って、何が動くか**を書きます。
設計の正本と未実装境界は [`docs/aiueos-dapp.md`](docs/aiueos-dapp.md) にあります。

## 互換の範囲

| 互換である | 互換ではない |
|---|---|
| Linear の CSV エクスポート（列を見出し名で対応づけ、RFC 4180 の引用） | Linear の API への接続（未実装。下記） |
| Linear GraphQL の issues 形 JSON（`data.issues.nodes`） | Linear の内部アルゴリズム（進捗の数え方・自動クローズ等）の再現 |
| 状態の型（triage/backlog/unstarted/started/completed/canceled）・優先度 0〜4・見積 scale・`TEAM-123` 形の identifier | 複数人での同時編集・通知・連携 |

- サイクル進捗の数え方と、知らない状態名の型の推定は **dandori の規則**です（docs に明記）。
- Linear はその権利者の商標です。dandori は互換を名乗るだけで、Linear との提携も同一性も主張しません。

## 何が在るか

| パス | 中身 |
|---|---|
| `aiueos/dandori.edn` | aiueos アプリ記述子（`:aiueos/kind :app`、`:effects #{}`、imports なし） |
| `aiueos/dandori_core.cljk` | 判断コア guest（pure）: 優先度の並び・見積の妥当性・遷移の種類・サイクル進捗・SLA・採番 |
| `aiueos/dandori_core.wasm` (+ `.provenance.edn` `.publication.edn`) | amu の wasm32-browser 産物と出所 |
| `src/dandori/core.cljk` | adapter（guest と同名・同結果の判定）と値モデル |
| `src/dandori/ingest.cljk` / `export.cljk` | Linear CSV・GraphQL JSON の取り込みと書き出し |
| `src/dandori/view.cljk` | 画面（純 hiccup。SSR と Reagent の両方が描く） |
| `site/app.cljk` | ブラウザ側（Re-frame / Reagent、scittle が読む） |
| `site/dandori/page.cljk` | ページの殻（SSR、DADS） |
| `site/site.edn` | 公開物の宣言（cloud-itonami の生成器が読む） |
| `site/vendor/` | React 18.3.1 UMD・scittle 0.8.33（同一オリジン配信。出所と digest は `PROVENANCE.edn`） |
| `test/` | kbb テスト、parity fixture、wasm parity（`guest_parity.mjs`）、合成データ |
| `scripts/build-site.cljk` | 公開物をローカルに組む（プレビュー用。共通クロームは被せない） |
| `bin/dandori-mcp` + `src/dandori/mcp.cljk` | itonami agent 向けの MCP stdio サーバ（tool 5 つ、pure。下記） |

## 動かし方

west レイアウト（`<root>/cloud-itonami/app-itonami-dandori` の隣に `<root>/kotoba-lang/…`）を前提にしています。

```sh
npm test                 # kbb: adapter・取り込み・往復・画面
npm run check:guest      # amu check
npm run test:guest       # amu test（:jvm-kir :js :wasm）
npm run build:guest      # wasm を作り直す（provenance も更新される）
npm run test:guest-parity  # wasm を kototama-browser-host-v1 で動かし parity.edn と照合
npm run build:site       # out/site/ に公開物を組む → 静的サーバで開く
npm run mcp              # MCP stdio サーバを起動する（stdin から JSON-RPC）
```

2026-10-22 の実測値は docs/aiueos-dapp.md の「実測」にあります。

- adapter + MCP: 34 tests / 283 assertions / 0 failures
- guest: 24/24
- wasm parity: 73/73

## itonami agent から使う（MCP）

`bin/dandori-mcp` は stdio の MCP サーバです。itonami agent（`kotoba-lang/itonami-agent`）や Hermes の profile から tool として使えます。

profile の `config.yaml` の設定例（パスは west レイアウトでの実際の置き場所にしてください）:

```yaml
mcp_servers:
  dandori:
    command: kbb
    args: ["/Users/<you>/github/cloud-itonami/app-itonami-dandori/bin/dandori-mcp"]
```

agent からは `mcp__dandori__<tool>` という名前で見えます。

| tool | 入力 | 出力 |
|---|---|---|
| `dandori_import` | `text`（Linear の CSV か GraphQL issues JSON、5 MiB まで）、`format`（`auto`／`csv`／`graphql-json`） | `teams`（状態と見積設定）、`issues`（Linear GraphQL 形のノード）、`warnings` |
| `dandori_export` | `issues`（`dandori_import` の出力）、`format`（`csv`／`graphql-json`） | `text`（取り込み直すと同じ課題になる） |
| `dandori_cycle_progress` | `issues`（`[{state_type, estimate}]`）、`unestimated_weight` | `permille`、`completed_scope`、`scope` |
| `dandori_check_estimate` | `scale`、`value`、`allow_zero`、`extended` | `valid`、`allowed` |
| `dandori_sla_status` | `now`、`medium_at`、`high_at`、`breach_at`（epoch ms か ISO-8601） | `status`（`ok`／`medium-risk`／`high-risk`／`breached`） |

- **しないこと**: 送信・保存・本家 Linear API への接続。tool は入力テキストを受けて結果を返すだけです。
- **入力の不正**: JSON-RPC の error ではなく、tool の結果（`isError: true`、本文 `{"error": "<名前>"}`）で返ります。
- **判定**: 画面と同じ adapter（`src/dandori/*.cljk`）が行います。wasm guest は読み込みません。guest との一致は parity 表（73 行）で担保しています。
- **起動のしかた**: agent は呼び出しのたびにサーバを 1 つ起動し、3 行（initialize・initialized・要求）を送って stdin を閉じます。サーバは EOF で exit 0 します。
- **cwd**: どこからでも起動できます。
  - cwd がこの repo でないときは、repo を cwd にして自分を起動し直します。
  - そうすると kbb が `nbb.edn` の pin（`kotoba-lang/text` bc551a3）を、west の兄弟 checkout より先に読みます。その分、起動が 1 回増えます（実測で約 1.3 秒）。
- **書き込むファイル**: 初回の起動に限り、kbb が依存のキャッシュ（`.nbb/.cache`、gitignore 済み）を repo に作ります。このときの「Downloading dependencies...」は stdout に出ますが、agent のクライアントは JSON でない行を読み飛ばします。それ以外のファイルは書きません。
- **peer run**: itonami agent は peer run で MCP を使いません（itonami-agent README）。

## 未実装（要点）

- **aiueos の session／grant への配線**は未実装です（kaikei と同じ段階）。画面の判定は adapter（cljc）で、guest との一致は parity fixture で担保しています。
- **分散状態**（ADR 0005 の mon／ito／nuno）は設計だけです。今は 1 ブラウザの localStorage に閉じます。
- **Linear API への直接接続**は未実装で、ブロッカーがあります。
  - 共通ブローカー `kotoba-lang/wasm-webcomponent/src/kotoba-client-runtime.js` がまだ存在しません。
  - ブローカー着地前に product 側で同意ロジックを書くことは workspace 契約が禁じています。

## ライセンス

AGPL-3.0-or-later（[LICENSE](LICENSE)）。同梱の vendor は各ライセンス（scittle: EPL-1.0、React: MIT）。
