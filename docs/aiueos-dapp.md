# dandori 課題トラッキング dapp — aiueos 上の分散型設計

状態: 設計 + 第 1 スライス実装（2026-10-22）。正本はこの文書。
追跡: Linear JUN-286。参照実装: `cloud-itonami/kaikei`（docs/aiueos-dapp.md + aiueos/）。
統合マップ: `network-awai/network-awai-apex` docs/dapp-architecture-map.md §3（1 repo = 1 スライスの 5 点）。

## 目標

dandori を「サーバに課題を置かない分散型 dapp」として実現する。

- Linear と互換なのは**データ形式**: CSV／GraphQL のエクスポート、状態の型、優先度の数、見積の scale、identifier の形。
- 実行面は aiueos（kotoba-lang/aiueos）、配布面は itonami.app plane（ADR 0005）。
- 中央 DB は持たない。
- 今は 1 ブラウザの localStorage に閉じる。分散は下の「未実装境界」に書く設計の段階。

## 層構成

| 層 | 実体 | 状態 |
|---|---|---|
| 判断コア（guest） | `aiueos/dandori_core.cljk` — priority-rank / estimate-valid? / closed? / active? / transition-kind / cycle-progress-permille / sla-status / next-number。`:effects #{}` の pure 計算 | **実装済み・実測**（下記） |
| アプリ記述子 | `aiueos/dandori.edn`（kaikei.edn 形、`:aiueos/kind :app`、imports なし） | **実装済み**。aiueos session/grant への配線は未実装 |
| adapter | `src/dandori/core.cljk` — guest と同名・同結果の判定 + 値モデル（team・状態・課題・コメント） | **実装済み・実測**（kbb） |
| 取り込み／書き出し | `src/dandori/ingest.cljk`（Linear CSV・GraphQL JSON）、`src/dandori/export.cljk`（同じ 2 形式） | **実装済み・実測**（往復で値が変わらない） |
| 画面 | `src/dandori/view.cljk`（純 hiccup）+ `site/app.cljk`（Re-frame / Reagent、scittle）+ `site/dandori/page.cljk`（SSR の殻、DADS） | **実装済み・ブラウザで実測** |
| 状態 | 課題は localStorage（`itonami.dandori.v1`）だけ。1 ブラウザに閉じる | **実装済み** |
| agent 統合（MCP） | `bin/dandori-mcp` + `src/dandori/mcp.cljk` — stdio MCP、tool 5 つ（import／export／cycle_progress／check_estimate／sla_status）。pure（送信・保存なし）、判定は adapter | **実装済み・実測**（kbb stdio テスト、itonami-agent の MCP クライアントで discover／call） |
| 分散状態 | ADR 0005 の cell `mon` / history `ito` / network `nuno` | **未実装**（設計のみ、下記） |
| 本家 API 直結 | Linear GraphQL API への直接接続（利用者の同意を operation ごとに取る） | **未実装・ブロッカーあり**（下記） |

## 判断の規則（dandori のもの）

Linear の値をそのまま整数にして判定する。

- state type: `triage=0` `backlog=1` `unstarted=2` `started=3` `completed=4` `canceled=5`
- priority: `0=No priority` `1=Urgent` … `4=Low`
- scale: `notUsed=0` `exponential=1` `fibonacci=2` `linear=3` `tShirt=4`

判定の規則は dandori が採るもので、**Linear の内部アルゴリズムの再現を主張しない**。

- **サイクル進捗** `cycle-progress-permille`
  - buffer は `[type estimate]×n`。
  - Canceled は scope から外す。
  - estimate 0 は未見積として `unestimated-weight` で数える。
    - guest は「明示の 0」と「未見積」を区別できない。adapter も同じ buffer を作るので両者は一致する。
  - 結果は千分率（整数）で、不正な buffer（奇数長・負の見積・範囲外の型）は -1。
  - 画面は unestimated-weight = 1 で表示する。
- **遷移の種類** `transition-kind`: 0 no-op / 1 start / 2 complete / 3 cancel / 4 reopen（閉じた状態 → 開いた状態）/ 5 other。
  - adapter の `set-state` はこれで時刻欄を動かす。
    - start → `started-at`（未設定なら）
    - complete → `completed-at`
    - cancel → `canceled-at`
    - reopen → completed-at・canceled-at を外す
- **見積の妥当性** `estimate-valid?`
  - exponential は 1,2,4,8,16（拡張で 32,64）。
  - fibonacci と tShirt は 1,2,3,5,8（拡張で 13,21）。
  - linear は 1..5（拡張で 6,7）。
  - 0 は allow-zero のときだけ。notUsed は何も受けない。
- **SLA** `sla-status`: Linear の slaMediumRiskAt / slaHighRiskAt / slaBreachesAt を epoch ミリ秒で受け、0 ok / 1 medium / 2 high / 3 breached を返す。0 は「未設定」。
- **CSV の状態の型**
  - Linear の CSV は状態の型を持たない。
  - 既定の状態名（Triage/Backlog/Todo/In Progress/In Review/Done/Canceled/Duplicate）と照合し、外れたら名前の手掛かりで推定する。
    - 例: "QA" → started、"Shipped" → completed、"Won't fix" → canceled。
  - どれにも当たらなければ backlog（進行中・完了に数えない側）に倒す。
  - dandori が書き出す CSV は末尾の `Status Type` 列で型を持ち帰る（Linear 側の取り込みは知らない列を無視する）。

## 実測（2026-10-22、このスライスで実行したもの）

amu は `kotoba-lang/amu` 74ca4aa6 の `bin/amu`。

- `amu check aiueos/dandori_core.cljk` → `:ok true`, `:effects #{}`、exports 17。
- `amu test aiueos/dandori_core.cljk` → **24/24 passed**（test 8 本 × targets `[:jvm-kir :js :wasm]`）。
  - 期待値を 1 つ変えた写しでは 21/24 FAILED になり、3 target とも落ちることを確かめた。
- `amu compile aiueos/dandori_core.cljk --target wasm32-browser --output aiueos/dandori_core.wasm`
  - 出力: WebAssembly MVP module 7,143 bytes（sha256 `c10ad6af51841afbd3633f9b6fb12b584912431a6c084117a35646a9bada66ce`）と provenance／publication の sidecar。
  - 23 definitions。
- **wasm parity**: `node test/guest_parity.mjs` → **73/73 rows match**。
  - test/fixtures/parity.edn の全行を、コンパイル済み wasm で kototama-browser-host-v1（`amu/runtime/browser-host.mjs` の typed host）を通して実行した。
  - digest は publication の sha256 で固定している。
- **adapter**: `npm test`（kbb）→ **22 tests, 183 assertions, 0 failures**。内訳:
  - 同じ表の全行照合と関数別件数
  - 値モデル
  - Linear CSV（RFC 4180 の引用・改行・`""`）と GraphQL JSON の取り込み
  - JSON／CSV の往復（JSON は無損失。CSV は SLA 時刻とコメント以外が一致）
  - SSR に関数が混ざらないこと
- テストは `kotoba-lang/text` の origin/main（bc551a3）でも通る。
  - ローカル checkout は WIP ブランチだった。そのブランチは split に文字列を渡せるが main は regex だけなので、regex に揃えた。
- **ブラウザ**（built-in browser、ローカルの静的サーバ、`scripts/build-site.cljk` で組んだ公開物）:
  - サンプル読み込み → 一覧／ボード → 課題選択 → 状態変更（started-at が入る）→ ラベル編集 → CSV 貼り付け取り込み → チーム切替 → 再読み込みで localStorage から復元、を実行した。
  - GraphQL JSON 取り込みと 2 形式の書き出しを、ブラウザ上の scittle 実行で確かめた。
  - console エラーなし。
  - 375px 幅で横スクロールなし。
  - 読み込みはローカルで約 0.6 秒（scittle が 6 つの .cljs を順に取得・評価する）。

### agent 統合（MCP、2026-10-22、Linear JUN-297）

- `bin/dandori-mcp` を、itonami agent と同じ 3 行（initialize・initialized・要求）で駆動して確かめた（`test/mcp_stdio_test.cljk`）:
  - cwd が `/` と repo の両方で tools/list に 5 tool が出る。
  - tools/call の結果が正しい。
  - stdout は JSON-RPC の行だけ。
  - EOF で exit 0。
  - 不正入力は `isError`。
- tool 単体のテスト（`test/dandori/mcp_test.cljk`）:
  - fixture の CSV／GraphQL JSON で import → export → import が一致した（GraphQL 由来を CSV で往復する組は、CSV が SLA とコメントを持たないので比べない）。
  - サイクル進捗・見積・SLA・5 MiB 上限を確かめた。
- adapter と合わせて **34 tests, 283 assertions, 0 failures**（`kotoba-lang/text` bc551a3）。
- **itonami-agent の MCP クライアント**（`kotoba-lang/itonami-agent` main 709c948 の `itonami.agent.mcp`、`git archive` で取り出したもの）で実測した:
  - `discover` が `mcp__dandori__dandori_import` ほか 5 つを返し、errors は空。
  - `call dandori_cycle_progress` → `{"permille":750,"completed_scope":3,"scope":4}`。
  - `call dandori_check_estimate`（fibonacci, 4）→ `{"valid":false,"allowed":[1,2,3,5,8]}`。
  - 不正な時刻は `{"error":"{\"error\":\"invalid-time\",…}"}` として agent に返る。
- 未実測: 推論 rail（murakumo）を使った実際の agent turn の中で、モデルが tool を選んで呼ぶところ。

## 実測した「動かない」／未実装境界（このスライスで解消していない）

- **aiueos への配線は未実装**（kaikei と同じ）。
  - `aiueos/dandori.edn` を session/grant（`apps/session` の app catalog、ADR-0080 の grant 経路）に載せた実行はしていない。kotoba-lang/aiueos 側の作業になる。
  - ブラウザの画面は wasm guest ではなく adapter（同じ規則の cljc）で判定している。両者の一致は parity fixture（73 行）で担保している。
- **分散状態は 1 行も実装していない**（設計のみ）。ADR 0005 への割り当て:
  - cell `mon`: team（DNA）ごとの entry 規則。課題の作成・状態遷移・見積を entry にし、その検証関数を guest の判定に置く。
    - 遷移 = transition-kind
    - 見積 = estimate-valid?
    - 採番 = next-number
  - history `ito`: 利用者ごとの署名付き source chain。課題の変更を append-only に積む。
  - network `nuno`: team ごとの同期。
    - CRDT 的な自動マージは採らない。
    - identifier の衝突（同じ番号の同時採番）は判定側で検出する。
  - 今は localStorage だけで、1 ブラウザに閉じる。端末間の共有は、書き出した JSON／CSV を持ち運ぶことでしかできない。
- **Linear API 直結は未実装・ブロッカー**。本家の GraphQL API へ利用者の操作として直接つなぐには、次のものが要る（workspace の Kotoba end-user app 契約）。
  - `kotoba-lang/wasm-webcomponent/src/kotoba-client-runtime.js`（`kotoba.app.client-runtime.v1` の記述子検証と operation ブローカー）
  - operation ごとの同意
  - このブローカーは repo に存在しない（2026-10-22 確認。`src/` に該当ファイル無し）。
  - product 側に検証・同意ロジックの写しを置くことは契約が禁じているので、ブローカーが着地するまで接続しない。
  - 今の取り込みは、利用者が Linear から自分で書き出したファイルを読むだけ。
- **CSV の制約**: Linear の CSV と同じく SLA の時刻とコメントを持たない。ラベル名にカンマを含むと、Labels 列で分かれてしまう。
- **ブラウザの読み込み**
  - scittle はソースを実行時に解釈する。数千件規模のエクスポートでの速度は測っていない。
  - 本番の公開物（app.itonami.cloud）は network-awai/cloud-itonami の生成器が作り、ここでは確認していない。
    - 共通クロームの注入と IPFS／IPNS 公開は統括側の作業。

## 次の一手（優先順）

1. cloud-itonami の sites.edn（app org）に載せて公開する（統括、JUN-286）。
2. aiueos 側で `:app/dandori` を app catalog に載せ、grant 経路で guest を起動する。
3. ブラウザの判定を wasm guest に寄せる。
   - kototama-browser-host-v1 で dandori_core.wasm を読み、adapter の判定を置き換える。
   - parity fixture はそのまま回帰テストになる。
4. ブローカー着地後に、Linear GraphQL API への直結を operation 単位の同意つきで足す。
5. ADR 0005 の mon／ito／nuno に沿った複製。

## 実行 host と ABI

- guest は vector パラメータを使うため、**KIR v4 / `kotoba.typed/externref-v1`**（typed-value ABI）になる。
- 実行 host は **kototama-browser-host-v1**（amu selfhost、`amu/runtime/browser-host.mjs` の typed ホスト）。
- `test/guest_parity.mjs` は vector 引数を `typedValues.vectorI64` で渡す。
- aiueos の Chicory kernel ホストは typed ホストを持たない。kaikei の docs に書かれたとおり、kernel 経路では名前付き link 拒否になる見込み（このスライスでは試していない）。
