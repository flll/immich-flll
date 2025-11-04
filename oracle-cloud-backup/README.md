# Immich OCI Archive Storage 暗号化バックアップソリューション

Oracle Cloud Infrastructure (OCI) の Archive Storage を使用して、Immich のバックアップを圧縮・暗号化してクラウドにアップロードするための自動化ソリューションです。

## 📋 概要

- **バックアップ対象**: Immich リポジトリ全体（約300GB）
- **圧縮方式**: tar.gz形式
- **暗号化方式**: OpenSSL AES-256-GCM（認証付き暗号化）
- **バックアップ先**: OCI Archive Storage（米国リージョン）
- **実行方式**: Docker Compose によるフォアグラウンド実行
- **認証方式**: ブラウザベースの認証（Session Authentication）

## 🎯 特徴

- **強力な暗号化**: AES-256-GCM（認証付き暗号化、改ざん検知機能付き）
- **自動除外**: サムネイル、エンコード済みビデオ、モデルファイルなど再生成可能なファイルを自動除外
- **高圧縮率**: tar.gz形式で約50%の圧縮率
- **高速アップロード**: 並列アップロード（10スレッド）とチャンクサイズ最適化（128MB）
- **デバッグログ**: 詳細なログ出力で進捗確認が可能
- **世代管理**: タイムスタンプ付きファイル名で複数世代のバックアップを保持可能

## 📦 必要要件

- Docker と Docker Compose がインストールされていること
- Oracle Cloud のアカウント（無料枠で利用可能）
- ブラウザでの OCI ログインが可能な環境
- 十分なディスク空き容量（一時的に圧縮ファイル分が必要）

## 🚀 使用方法

### 1. 初回セットアップ

#### ステップ 1: ディレクトリに移動

```bash
cd /mnt/hdd_blue/immich-app/oracle-cloud-backup
```

#### ステップ 2: OCI 認証（初回のみ）

初回実行時はブラウザで OCI にログインする必要があります：

```bash
# 対話的に認証を実行（初回のみ）
docker run --rm -it \
  -v $(pwd)/oci:/root/.oci \
  ghcr.io/oracle/oci-cli:20251029@sha256:ee374e857a438a7a1a4524c1398a6c43ed097c8f5b1e9a0e1ca05b7d01896eb6 \
  oci session authenticate --region us-ashburn-1
```

ブラウザが開くので、OCI にログインしてください。認証情報は `oci/` ディレクトリに保存されます。

### 2. バックアップの実行

#### 方法 A: Docker Compose で実行（推奨）

```bash
# フォアグラウンドで実行
docker compose run --rm oci-backup
```

実行すると以下の順序で処理が進みます：

1. **OCI 認証確認**: 既存の認証情報を確認、必要に応じて再認証
2. **パスコード入力**: バックアップを暗号化するためのパスコードを2回入力
3. **圧縮**: tar.gz形式で圧縮（除外パターン適用）
4. **暗号化**: OpenSSL AES-256-GCM で暗号化
5. **アップロード**: OCI Archive Storage にアップロード
6. **クリーンアップ**: ローカルの暗号化ファイルを削除するか選択

#### 方法 B: スクリプトを直接実行

```bash
# フォアグラウンドで実行
./backup.sh
```

### 3. 進捗確認

バックアップの進捗は以下の方法で確認できます：

```bash
# 最後のバックアップログを確認
cat oci/last_backup.log

# リアルタイムでログを監視（別のターミナルで）
tail -f oci/last_backup.log
```

## 🔐 暗号化について

### パスコードの入力

スクリプト実行時に対話的にパスコードを入力します：

```
パスコードを入力してください: [入力は非表示]
パスコードを再入力してください: [入力は非表示]
```

**重要**:
- パスコードは画面に表示されません
- パスコードは2回入力して確認します
- パスコードはファイルに保存されません
- **パスコードを忘れると復号化できません。必ず安全に保管してください**

### 暗号化方式の詳細

- **アルゴリズム**: AES-256-GCM
- **キー導出**: PBKDF2
- **特徴**:
  - 認証付き暗号化（AEAD: Authenticated Encryption with Associated Data）
  - 改ざん検知機能付き
  - 業界標準の強力な暗号化方式

## 📥 バックアップの復元

### ステップ 1: OCI からバックアップをダウンロード

1. [OCI コンソール](https://cloud.oracle.com/)にログイン
2. **Storage** → **Buckets** を選択
3. バケット名（デフォルト: `immich-backup`）をクリック
4. バックアップファイル（`immich-backup-YYYY-MM-DD-HHMMSS.tar.gz.enc`）を選択
5. **Archive Storage からの復元**:
   - ファイルを選択して「Restore」をクリック
   - 復元には最大4時間かかります
   - 復元完了後、ダウンロードが可能になります
6. ダウンロードボタンをクリックしてローカルに保存

### ステップ 2: バックアップの復号化と解凍

ダウンロードしたファイルを復号化して解凍します：

```bash
# 1. 復号化（パスコードの入力が求められます）
openssl enc -d -aes-256-gcm -pbkdf2 \
  -in immich-backup-2025-11-04-183000.tar.gz.enc \
  -out immich-backup.tar.gz

# 2. 解凍
tar xzf immich-backup.tar.gz -C /path/to/restore/

# または、ワンライナーで実行
openssl enc -d -aes-256-gcm -pbkdf2 \
  -in immich-backup-2025-11-04-183000.tar.gz.enc | \
  tar xz -C /path/to/restore/
```

**注意**:
- バックアップ作成時に設定したパスコードが必要です
- パスコードが間違っている場合、復号化は失敗します
- 解凍先に十分な空き容量があることを確認してください

### 完全な復元例

```bash
# 作業ディレクトリを作成
mkdir -p ~/immich-restore
cd ~/immich-restore

# OCI からダウンロードしたファイルがある場合
# 1. 復号化と解凍を同時に実行
openssl enc -d -aes-256-gcm -pbkdf2 \
  -in ~/Downloads/immich-backup-2025-11-04-183000.tar.gz.enc | \
  tar xz

# 2. 復元されたファイルを確認
ls -lh

# 3. Immich の元の場所に復元（必要に応じて）
sudo rsync -av ./ /mnt/hdd_blue/immich-app/
```

## 📁 ディレクトリ構造

```
oracle-cloud-backup/
├── backup.sh              # メインバックアップスクリプト
├── docker-compose.yml     # Docker Compose設定
├── README.md              # このファイル
├── .gitignore             # Git除外設定
└── oci/                   # OCI認証情報とログ（Gitで除外）
    ├── config             # OCI CLI設定
    ├── sessions/          # セッション認証トークン
    ├── namespace          # OCIネームスペース
    ├── compartment        # コンパートメントID
    ├── last_backup.log    # 最後のバックアップログ
    └── temp/              # 一時ファイル（暗号化ファイル）
```

## ⚙️ 設定のカスタマイズ

デフォルト設定は以下の通りです。必要に応じて変更できます。

### 環境変数での設定

実行時に環境変数として指定：

```bash
export OCI_REGION=us-phoenix-1
export OCI_BUCKET_NAME=my-immich-backup
docker compose run --rm oci-backup
```

または、`docker-compose.yml` の `environment` セクションで設定を変更できます。

### 除外パターンのカスタマイズ

`backup.sh` の `EXCLUDE_PATTERNS` 配列を編集して、除外するディレクトリを変更できます：

```bash
EXCLUDE_PATTERNS=(
    "photos/backups"
    "photos/encoded-video"
    "photos/thumbs"
    "photos/profile"
    "models"
    # 追加のパターンをここに記述
)
```

## 🔧 トラブルシューティング

### 認証エラーが発生する

**症状**: `ServiceError: Authentication failed` などのエラー

**解決策**:
```bash
# 既存の認証情報を削除
rm -rf oci/sessions oci/config

# 再認証
docker run --rm -it \
  -v $(pwd)/oci:/root/.oci \
  ghcr.io/oracle/oci-cli:20251029@sha256:ee374e857a438a7a1a4524c1398a6c43ed097c8f5b1e9a0e1ca05b7d01896eb6 \
  oci session authenticate --region us-ashburn-1
```

### 復号化に失敗する

**症状**: `bad decrypt` エラー

**原因**: パスコードが間違っている、またはファイルが破損している

**解決策**:
```bash
# 正しいパスコードを入力しているか確認
# ファイルの整合性を確認（再ダウンロード）

# ダウンロードしたファイルのサイズを確認
ls -lh immich-backup-*.tar.gz.enc

# OCI上のファイルサイズと比較
```

### 圧縮中にディスク容量不足

**症状**: `No space left on device` エラー

**解決策**:
```bash
# ディスク使用量を確認
df -h

# 一時ファイルを削除
rm -rf oci/temp/*

# Dockerイメージとコンテナのクリーンアップ
docker system prune -a
```

### アップロードが失敗する

**症状**: アップロード中にエラーが発生

**解決策**:
```bash
# ネットワーク接続を確認
ping oracle.com

# ログを確認
cat oci/last_backup.log

# 暗号化ファイルが存在する場合、再度アップロードを試行
# （backup.shの最後の部分を手動で実行）
```

## 📊 バックアップ除外ディレクトリ

以下のディレクトリは再生成可能なため、バックアップから除外されます：

| ディレクトリ | 理由 | サイズ削減効果 |
|------------|------|--------------|
| `photos/backups` | 既存のバックアップ | 大 |
| `photos/encoded-video` | エンコード済みビデオ（再生成可能） | 非常に大 |
| `photos/thumbs` | サムネイル（再生成可能） | 大 |
| `photos/profile` | プロフィール画像（再生成可能） | 小 |
| `models` | MLモデル（再ダウンロード可能） | 中〜大 |

これらを除外することで、バックアップサイズを大幅に削減できます。

### 圧縮率の目安

- **元のサイズ**: 300GB
- **除外後**: 約150GB〜200GB
- **圧縮後**: 約75GB〜100GB（圧縮率 50%）
- **実際の圧縮率**: データの内容により変動します

## 🔐 セキュリティ

- **パスコードの保護**: パスコードはメモリ内のみ（ファイル・環境変数に保存しない）
- **認証情報の保護**: `oci/` ディレクトリは `.gitignore` で Git から除外されています
- **読み取り専用マウント**: Immich データは読み取り専用でマウントされます
- **セッション認証**: 短期トークンを使用し、定期的な再認証が必要です
- **暗号化ファイルのみ保存**: クラウドには暗号化されたファイルのみ保存

### セキュリティのベストプラクティス

1. **強力なパスコードを使用**: 最低16文字、大小英数字+記号を含める
2. **パスコードを安全に保管**: パスワードマネージャーや安全な場所に記録
3. **定期的な認証更新**: OCI セッショントークンの有効期限に注意
4. **バックアップのテスト**: 定期的に復元テストを実施

## 💰 コストについて

OCI Archive Storage の料金（2025年時点の目安）：

### 圧縮前（除外後）
- **データサイズ**: 約150-200GB
- **ストレージ**: $0.0026 per GB/月
- **月額コスト**: $0.39 - $0.52/月

### 圧縮後（実際の保存サイズ）
- **データサイズ**: 約75-100GB
- **ストレージ**: $0.0026 per GB/月
- **月額コスト**: $0.20 - $0.26/月
- **年間コスト**: 約 $2.40 - $3.12

### その他の料金
- **データ転送（アップロード）**: 無料
- **データ取り出しリクエスト**: $0.024 per GB（緊急時のみ）
- **最小保管期間**: 90日

**コスト削減効果**: 圧縮により約50%のストレージコスト削減

## ⏱️ 所要時間

### バックアップ作成
- **圧縮・暗号化**: 1〜3時間（データサイズによる）
- **アップロード**: 数時間〜1日（ネットワーク速度による）
- **合計**: 4〜24時間程度

### バックアップ復元
- **Archive Storage からの復元**: 最大4時間（OCI側の処理）
- **ダウンロード**: 1〜数時間（ネットワーク速度による）
- **復号化・解凍**: 30分〜2時間

## 📚 参考リンク

- [Oracle Cloud Infrastructure - Object Storage](https://docs.oracle.com/en-us/iaas/Content/Object/home.htm)
- [OCI CLI リファレンス](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/)
- [Archive Storage について](https://docs.oracle.com/en-us/iaas/Content/Archive/Concepts/archivestorageoverview.htm)
- [OpenSSL 暗号化ドキュメント](https://www.openssl.org/docs/man3.0/man1/openssl-enc.html)
- [Immich 公式ドキュメント](https://docs.immich.app/)

## 🆘 よくある質問（FAQ）

### Q: パスコードを忘れてしまいました

**A**: 残念ながら、パスコードを忘れた場合は復号化できません。AES-256-GCM は非常に強力な暗号化方式のため、パスコード無しでの復号化は事実上不可能です。必ずパスコードを安全に保管してください。

### Q: バックアップは何世代保持されますか？

**A**: タイムスタンプ付きファイル名で保存されるため、手動で削除しない限りすべての世代が保持されます。古いバックアップは OCI コンソールから手動で削除できます。

### Q: バックアップ中にエラーが発生した場合は？

**A**: スクリプトはエラー時に停止します。ログファイル（`oci/last_backup.log`）を確認してエラーの原因を特定し、問題を解決後に再実行してください。

### Q: 暗号化ファイルはローカルに残しておくべきですか？

**A**: ディスク容量に余裕がある場合は残しておくことを推奨します。OCI からのダウンロードには時間がかかるため、ローカルにコピーがあると復元が高速になります。

### Q: 定期的な自動バックアップは可能ですか？

**A**: パスコード入力が必要なため、完全自動化は難しいです。ただし、以下の方法で半自動化できます：
1. パスコードを安全な方法で環境変数として設定
2. cron ジョブでスクリプトを定期実行

（セキュリティリスクがあるため推奨しません）

## 📝 ライセンス

このバックアップソリューションは自由に使用・改変できます。

---

**作成日**: 2025年11月4日  
**対象**: Immich v2.2.0  
**OCI CLI**: v20251029  
**暗号化**: OpenSSL AES-256-GCM
