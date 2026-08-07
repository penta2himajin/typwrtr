# Typwrtr

> Source: README.md @ cdf5f2f03a7cdfa2b4b2be7741daddf313acfdde
>
> [English](./README.md)

ローカル優先の macOS 向け音声入力（ディクテーション）アプリ。ホットキーを押している間話し、離すと整形済みテキストがフォーカス中のフィールドに入る。

名前は “typewriter” から母音を抜いた綴り。

## 現状

製品定義の初期段階。方針は [`docs/product.md`](./docs/product.md)、UX は [`docs/ux-decisions.md`](./docs/ux-decisions.md)、ユースケースは [`docs/use-cases.md`](./docs/use-cases.md)。

音声認識とテキスト整形は **[euhadra](https://github.com/penta2himajin/euhadra)**（プログラマブル ASR フレームワーク）に任せる。本リポジトリはエンドユーザー向けアプリ（Swift シェル + Rust/UniFFI コア）。

## 方針（要約）

- **デフォルトはローカル** — メイン経路にクラウドアカウント不要  
- **ソースは無料** — MIT / Apache-2.0（euhadra に合わせる）  
- **公式ビルドは $5** — 公証済み `.dmg` を Gumroad で配布。再ダウンロード可。アプリ内アカウント・ライセンス認証なし  
- **ネイティブシェル** — macOS は Swift（将来 Windows は WinUI）

## レイアウト

```
docs/           # 製品方針・ユースケース・ハンドオフ / i18n
git-hooks/      # 任意の pre-push フック
AGENTS.md       # エージェント / 貢献者向け規約
```

アプリ本体（Rust コア、Swift macOS）は実装開始とともに追加する。

## ライセンス

MIT。`LICENSE` を参照。公開済みの [euhadra](https://crates.io/crates/euhadra) に合わせて Apache-2.0 とのデュアルにする可能性がある。
