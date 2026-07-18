# x68drv ドキュメント索引

調査メモと設計の置き場。実装コード（Swift）とは別に、**参照専用のエミュソース解析結果**と **手元イメージ突合** をここに残す。

| 文書 | 内容 |
|------|------|
| [design.md](design.md) | 製品設計（**Product Requirements** / Finder マウント、Goals、PR 計画、Key Decisions） |
| [format-entry-points.md](format-entry-points.md) | XM6 / MPX68K における **HDF・HDS・XDF の入口関数マップ**（移植禁止・仕様抽出のみ） |
| [disk-samples-verification.md](disk-samples-verification.md) | 手元 `disk/` サンプルの **実測突合結果**（サイズ・マジック・パーティション・BPB） |

## 参照ソース（移植しない・**リポジトリ外**）

本リポジトリには含めない。ローカルで隣や別ディレクトリに置いて解析する。`.gitignore` で除外済み。

| 名前 | 用途 | codebase-memory project（ローカル index 時） |
|------|------|-----------------------------------------------|
| XM6 2.06 (`xm6_206s`) | SASI/HDF・フロッピー 2HD の open 条件 | `Users-ring2-Documents-src-x68drv-xm6_206s` |
| MPX68K | XDF ジオメトリ、SCSI/HDS コンテナ・BPB | `Users-ring2-Documents-src-x68drv-MPX68K` |

## ローカルのみ（コミットしない）

| パス | 内容 |
|------|------|
| `disk/` | 実イメージ（`.xdf` / `.hdf` / `.hds`）。検証・ゴールデン用。`.gitignore` 済み |

## 方針メモ

- エミュコードは **読んでオフセットと条件を取るだけ**。x68drv 本体へコピーしない。
- フォーマット仕様の正本は [`design.md`](design.md) の調査セクション + 本ディレクトリの突合メモ。
- 実装は Swift（X68Core + メニューバーアプリ）。
