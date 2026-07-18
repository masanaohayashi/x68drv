# x68drv ドキュメント索引

製品設計・実装計画・フォーマット実測メモの置き場。

| 文書 | 内容 |
|------|------|
| [design.md](design.md) | 製品設計（Product Requirements / Finder マウント、Goals、Key Decisions） |
| [implementation-plan.md](implementation-plan.md) | 実装フェーズ計画 & タスクリスト |
| [disk-samples-verification.md](disk-samples-verification.md) | 手元 `disk/` サンプルのサイズ・マジック・パーティション・BPB 実測 |
| [distribution.md](distribution.md) | Hardened Runtime + 公証（App Sandbox なし・直配布） |

## ローカルのみ（コミットしない）

| パス | 内容 |
|------|------|
| `disk/` | 実イメージ（`.xdf` / `.hdf` / `.hds`）。検証用。`.gitignore` 済み |

## 方針

- フォーマット仕様の正本は [`design.md`](design.md) と本ディレクトリの突合メモ。
- 実装は Swift（X68Core + メニューバーアプリ）。
