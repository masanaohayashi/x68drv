# 参照メモ: DiFinder / L3DiskEx の書込・パーティション仕組み

| 項目 | 内容 |
|------|------|
| 状態 | **参照専用・移植禁止** |
| 対象 | [DiFinder](https://github.com/bml3mk5/DiFinder)（HDD）、[L3DiskEx](https://github.com/bml3mk5/L3DiskEx)（フロッピー） |
| ローカル clone | `~/Documents/src/DiFinder`、`~/Documents/src/L3DiskEx`（x68drv 外） |
| codebase-memory | `Users-ring2-Documents-src-DiFinder` / `Users-ring2-Documents-src-L3DiskEx` |
| 著作権 | Copyright (C) Sasaji — **All Rights Reserved**（フリー利用可だがソース著作権あり・無保証） |
| x68drv 方針 | **コードをコピーしない。** レイアウト・アルゴリズムの理解と、将来実装時のチェックリスト用 |

> この文書は「どう作るか」の設計ではなく、「既存実装が何をしているか」の調査結果である。  
> x68drv の製品方針（当面 RO、将来書込は ordered flush）は [`design.md`](design.md) が正本。

---

## 1. 二つのツールの役割分担

| | **L3DiskEx** | **DiFinder** |
|--|--------------|--------------|
| 主対象 | フロッピーイメージ | **ハードディスクイメージ** |
| Human68k | FAT12 中心 | **FAT12 / FAT16** |
| 備考 | DiFinder README からフロッピーへ誘導 | L3DiskEx README から HDD へ誘導 |

x68drv の HDS/HDF 書込を考えるとき、**直接の参考は DiFinder**。  
XDF/DIM の書込を考えるとき、**L3DiskEx の hu68k + FAT12** も同様に参照する。

---

## 2. DiFinder アーキテクチャ（レイヤ）

```text
ui/                 Finder 的なファイル一覧・import/export 操作
  └─ basicfmt/      DiskBasic + Type + Dir + FAT   ← ファイルシステム
       └─ diskimg/  plain イメージ I/O・IPL/パーティション・セクタ
```

| パッケージ | ノード規模感 | 役割 |
|------------|--------------|------|
| `basicfmt` | 最大 | OS 種別ごとの DIR/FAT/Save/Delete |
| `diskimg` | 中 | コンテナ（plain 等）、パーサ、writer |
| `ui` | 大 | wxWidgets UI |

Human68k 専用の主なシンボル:

- `DiskBasicTypeHU68K` ← **`DiskBasicTypeFAT16BE`** を継承
- `DiskBasicDirItemHU68K` ← MS-DOS 系 dir item の派生
- `ParseHU68KParamOnDisk` … BPB から幾何を確定
- `bootparser` の `BT_HU68K_IPL` / `BT_HU68K_SCSI_IPL`

---

## 3. パーティション / コンテナ（SASI 系 vs SCSI 系）

DiFinder `bootparser.cpp` の構造体（論理の要約）:

### 3.1 共通パーティション entry

```text
st_human68k_partition_1 (16 bytes 前後):
  sig[8]           … パーティション名など
  boot_flags       … 1 byte
  start_block[3]   … 24-bit 開始ブロック（[0]<<16 | [1]<<8 | [2]）
  block_size       … 32-bit（ホスト LE マシンでは SWAP_ON_LE で BE 読み）
```

### 3.2 テーブルヘッダ

```text
st_human68k_partition_h:
  sig[4]
  free_start       … 未使用開始ブロック
  block_size
  limit_size
```

### 3.3 SASI 寄り（`BT_HU68K_IPL`）

| 項目 | 値 |
|------|-----|
| ヘッダ | **オフセット `0x400`** |
| 最初の entry | **`0x410`** |
| entry 走査 | `start_block == 0` で終了 |
| ブロック単位 | ファイルに設定された block size（ヘッダの `block_size`） |

x68drv の **HDF（256 バイト系）** と突き合わせるときの入口候補。

### 3.4 SCSI 寄り（`BT_HU68K_SCSI_IPL`）

| 項目 | 値 |
|------|-----|
| ヘッダ | **オフセット `0x800`** |
| 最初の entry | **`0x810`** |
| 倍率 | `sector_mag = 1024 / 物理セクタサイズ` |
| 解釈 | `start_block *= sector_mag`、`block_size *= sector_mag` |

先頭付近に `st_x68k_scsi_h`（`sig[8]` + `sector_size` BE 等）のレイアウトも定義されている。  
x68drv の **HDS（`X68SCSI1` + 0x800 付近パーティション）** と方向が一致。

### 3.5 x68drv 読取実装との対応

| x68drv | DiFinder 側の近い概念 |
|--------|----------------------|
| `HdsImage` / `X68SCSI1` | `BT_HU68K_SCSI_IPL` + `st_x68k_scsi_h` |
| `HdfImage` / SASI 256 | `BT_HU68K_IPL` 系（0x400 テーブル） |
| パーティション開始 × セクタ | `start_block` × mag |

**差分・注意:** DiFinder は汎用 plain + 複数 boot type 判定。x68drv は XM6/MPX68K 突合で ** magics と固定オフセットを狭く**取っている。将来書込でも「広い DiFinder 検出」ではなく、**既に open できているイメージ幾何を信頼**する方が安全。

---

## 4. Human68k ボリューム幾何（BPB）

`hu68k_bpb_t`（DiFinder）の要点:

| フィールド | エンディアン | 意味 |
|------------|--------------|------|
| `BytsPerSec` | BE | 論理セクタ（HDD 256 / 2HD 1024 等） |
| `SecPerClus` | — | クラスタあたり論理セクタ |
| `NumOfFATs` | — | b7=1 なら FAT16 MS-DOS というコメントあり |
| `RsvdSecCnt` / `RootEntCnt` | BE | 予約・ルートエントリ数 |
| `TotalSecs16` / `TotalSecs32` | BE | 総セクタ |
| `StartSec` / `TotalSecs32` | union | SASI 上の開始 or 拡張総セクタ |

### セクタ倍率（重要）

```text
sector_size_on_os   = BPB.BytsPerSec（BE）
sector_size_on_disk = イメージ物理セクタ
sector_mag          = on_os / on_disk   // 1, 2, or 4 のみ有効扱い

SectorsPerGroup     = mag * SecPerClus
ReservedSectors     = mag * RsvdSecCnt
SectorsPerFat       = mag * SecsOnFAT
…
```

→ **「BPB のセクタ」と「イメージのセクタ」が一致しない**前提がコードに埋め込まれている。  
x68drv 読取が既に mag=1 相当で動いているイメージでも、書込実装時は **両セクタサイズを明示して固定**すること。

### FAT12 vs FAT16 判定

データ領域の最大グループ数が概ね **4086 以上 → FAT16**、未満 → FAT12。  
FAT16 時の説明文字列に **「FAT16 BE」** と明示。

---

## 5. ディレクトリエントリ（32 バイト）

DiFinder `directory_hu68k_t`:

```text
name[8] + ext[3] + type + name2[10] + wtime + wdate + start_group + file_size
```

- MS-DOS 互換スロットに **追加名 `name2[10]`**（Human68k の長いベース名向け）
- `GetFileNamePos` が `name` / `name2` の二段

x68drv の `HumanFileName` / 18.3 系表現と突合するときの参照。

---

## 6. 書込パイプライン（DiFinder の `DiskBasic::SaveFile`）

**コードは移植しない。** 以下は処理の骨格のみ。

```text
SaveFile(istream, dir_item, pitem):
  1. 同名検索
     - 無: 空 dir スロット確保（足りなければ Expand）
     - 有: DeleteFile（上書き）
  2. item をクリアして pitem から名前・属性を Copy
  3. ConvertDataForSave（機種依存の前処理）
  4. SaveData / SaveUnitData:
       a. PrepareToSaveFile
       b. RecalcFileSizeOnSave
       c. HasFreeDiskSize
       d. AllocateUnitGroups(ALLOCATE_GROUPS_NEW)  … FAT 上でチェーン予約
       e. 各グループの各セクタ:
            WriteFile → セクタバッファへデータ
       f. SetFileSize / CalcFileSize
       g. VerifyData（失敗なら DeleteFile で巻き戻し）
       h. AdditionalProcessOnSavedFile
       i. CalcDiskFreeSize
```

### 6.1 `AllocateUnitGroups`（FAT 割当）

骨格:

```text
group = GetEmptyGroupNumber()
while remain > 0:
  SetGroupNumber(group, FINAL)     # いったん終端として予約
  if first: item.SetStartGroup(group)
  next = GetNextEmptyGroupNumber(group)
  if no next or last cluster:
    next = CalcLastGroupNumber(...)
  record sectors for this group
  SetGroupNumber(group, next)      # チェーン接続
  group = next
  remain -= bytes_per_group
on failure:
  DeleteGroups(allocated)          # 巻き戻し
```

- 空きなし: `-1` / `-2`
- 無限ループ防止: `FatEndGroup` を limit に使用
- APPEND 時は既存チェーンへ `ChainGroups`

### 6.2 `WriteFile`（デフォルト実装）

- ストリームからセクタバッファへ `Read`
- 最終セクタで EOF コードが要る機種は特別扱い（Human68k は機種依存）
- 余りは **0 埋め**
- 実イメージへの反映はセクタバッファ経由（dirty → writer）

### 6.3 削除（DiFinder の順序）

`DeleteFile` 概略:

```text
1. type->DeleteGroups(group_items)   # FAT 解放
2. item->Delete()                    # dir スロット削除マーク
3. AdditionalProcessOnDeletedFile
4. CalcDiskFreeSize
```

#### x68drv design.md との差（重要）

| | DiFinder 観測 | x68drv [`design.md`](design.md) 規範 |
|--|---------------|--------------------------------------|
| **delete** | FAT → dir | **dir（0xE5）→ FAT**（幽霊名を残さない） |
| **create** | 割当（FAT 操作）→ データ書込 → dir 更新がパイプライン内で混在 | **data → FAT#1 → FAT#2 → dir → fsync** を明確化 |

将来 x68drv が書込するときは **design.md の順序を優先**する。  
DiFinder は「動く実装の存在証明」であり、クラッシュ時意味論の正本ではない。

---

## 7. L3DiskEx との関係（フロッピー）

- `basicdiritem_hu68k` / `basictype_hu68k` が同様に存在
- HDD パーティション・SCSI mag は DiFinder 側が厚い
- フロッピー書込の詳細が必要になったら L3DiskEx を同じ手順で追記する

---

## 8. x68drv への示唆（実装しない段階の結論）

### すでにあるもの（読取）

- HDS/HDF 入口、BE FAT16、dir 一覧、read、fsck 骨格
- FUSE RO / snapshot

### 書込で足す必要があるもの（DiFinder が証明している単位）

1. **空きクラスタ探索 + チェーン構築**（Allocate 相当）  
2. **dir スロット確保 / 0xE5 削除 / 名前 8+3+name2**  
3. **セクタ単位の data write**  
4. **FAT 二重コピーの更新**  
5. **失敗時の巻き戻し**と **verify**  
6. （任意）フォーマット時 BPB 再生成 — DiFinder にも Create 系あり

### ステージング

| Stage | 内容 | 状態 |
|-------|------|------|
| **A** | CLI inject 1 ファイル（実験フラグ） | **実装済み**（`HddInject` + `x68drv-tool inject --write`） |
| B | 明示 delete / サブディレクトリ / フロッピー | 未着手 |
| C | mkdir / rename | 未着手 |
| D | FUSE experimental-write | 未着手 |

#### Stage A 実装メモ（x68drv）

| 項目 | 内容 |
|------|------|
| API | `HddInject.injectRootFile` / `injectRootFileToURL` |
| CLI | `x68drv-tool inject --write [--overwrite] <image> <host-file> <NAME.EXT> [partition]` |
| 対象 | **HDS/HDF のルートのみ**（サブdir・XDF は対象外） |
| 順序（メモリ上） | データクラスタ → FAT 全コピー → dir entry → ホストへ atomic replace |
| 事前条件 | fsck clean（CLI が enforce） |
| 上書き | 既定拒否、`--overwrite` で旧チェーン解放 + 同スロット再利用 |
| バックアップ | **CLI は作らない**（ユーザーがイメージをコピーすること） |
| テスト | `HddInjectTests` |

### やらないこと

- DiFinder / L3DiskEx の **ソースコピー**
- wx / 独自ライセンス下コードの同梱
- 「全部 DiFinder 互換」をゴールにすること（x68drv は RO マウント CX が本線）

---

## 9. 調査時の入口ファイル一覧

### DiFinder

| パス | 見る内容 |
|------|----------|
| `src/diskimg/bootparser.cpp` | SASI `0x400` / SCSI `0x800` パーティション |
| `src/basicfmt/basictype_hu68k.{h,cpp}` | BPB、FAT12/16 判定、FAT16 BE 継承 |
| `src/basicfmt/basictype_fat16.*` | `Get/SetData16BE` |
| `src/basicfmt/basicfmt.cpp` | `SaveFile` / `SaveUnitData` / `DeleteFile` |
| `src/basicfmt/basictype.cpp` | `AllocateUnitGroups` / デフォルト `WriteFile` |
| `src/basicfmt/basicdiritem_hu68k.*` | 名前フィールド |
| `src/basicfmt/basiccommon.h` | `directory_hu68k_t` |

### L3DiskEx

| パス | 見る内容 |
|------|----------|
| `src/basicfmt/basictype_hu68k.*` | フロッピー Human68k |
| `src/basicfmt/basictype_fat12.*` | FAT12 |

### codebase-memory

```text
project: Users-ring2-Documents-src-DiFinder
  search_graph name_pattern: .*HU68K.*|.*hu68k.*
  get_code_snippet: …DiskBasic.SaveFile / …AllocateUnitGroups / …ParseHU68KParamOnDisk
```

---

## 10. 改訂履歴

| 日付 | 内容 |
|------|------|
| 2026-07-18 | DiFinder/L3DiskEx を clone・index し、書込パイプラインと SASI/SCSI 差を記録（移植禁止） |
