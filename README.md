# 📸 Immich Self-Hosted Deployment

このリポジトリは、**Immich**（高性能なセルフホスト型写真・動画管理システム）をDocker ComposeとGoogle Cloud Platform (GCP)統合でデプロイするための設定です。

## ✨ 特徴

- 🐳 **Docker Compose**ベースの簡単デプロイ
- ☁️ **GCP Cloud Run**による機械学習処理のオフロード（オプション）
- 🔒 **Tailscale VPN**統合でセキュアなアクセス（オプション）
- 🤖 自動化スクリプトによる簡単なセットアップとメンテナンス
- 🎯 GPUサポート（ローカルML実行時）

## 🏗️ アーキテクチャ

```
┌─────────────────┐
│  Immich Server  │ ← メイン写真管理UI
└────────┬────────┘
         │
    ┌────┴────┐
    │         │
┌───▼───┐ ┌──▼──────┐
│ Redis │ │PostgreSQL│
└───────┘ └──────────┘

┌──────────────────────────────────────┐
│     Machine Learning (選択可能)       │
├──────────────────────────────────────┤
│ オプションA: Cloud Run (推奨)        │
│  └─ Cloud Run Proxy (認証付き)       │
│                                      │
│ オプションB: ローカル (NVIDIA GPU)   │
│  └─ immich-machine-learning         │
└──────────────────────────────────────┘

┌──────────────────────────────────────┐
│     Tailscale VPN (任意)             │
│  └─ すべてのサービスが共有           │
└──────────────────────────────────────┘
```

## 📋 前提条件

### 必須
- **Docker** & **Docker Compose** (v2.0+)
- Linux/macOS環境

### GCP Cloud Run使用時（推奨）
- **Google Cloud CLI** (`gcloud`)
- GCPプロジェクトとBilling有効化

### ローカルML使用時
- **NVIDIA GPU** + **NVIDIA Docker Runtime**

### Tailscale使用時（任意）
- **Tailscaleアカウント**

## 🚀 セットアップ手順

### 1️⃣ リポジトリのクローンと環境変数設定

```bash
git clone https://github.com/flll/immich-flll
cd immich-app

# 環境変数ファイルを作成
cp .env.example .env
```

`.env`ファイルを編集して、以下の値を設定：
- `DB_PASSWORD`: PostgreSQLパスワード（ランダムな文字列に変更）
- `UPLOAD_LOCATION`: 写真の保存先（例: `./photos`）
- `DB_DATA_LOCATION`: データベースの保存先（例: `./postgres`）

### 2️⃣ GCPサービスアカウント設定（Cloud Run使用時）

#### サービスアカウント作成

```bash
# プロジェクトIDを設定（例として lll-fish を使用）
export PROJECT_ID="your-project-id"  # あなたのGCPプロジェクトIDに変更

# プロジェクトを設定
gcloud config set project $PROJECT_ID

# サービスアカウントを作成
gcloud iam service-accounts create immich-ml-invoker \
  --display-name="Immich ML Invoker" \
  --description="Service account for invoking Cloud Run ML service"
```

#### 必要な権限の付与

```bash
export SA_EMAIL="immich-ml-invoker@${PROJECT_ID}.iam.gserviceaccount.com"

# Cloud Run呼び出し権限
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/run.invoker"

# Cloud Storage権限（モデル保存用）
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin"

# Artifact Registry権限（イメージプル用）
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/artifactregistry.reader"

# Secret Manager権限（オプション）
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor"
```

#### サービスアカウントキーのダウンロード

```bash
# キーファイルをダウンロード
gcloud iam service-accounts keys create service-account-key.json \
  --iam-account="${SA_EMAIL}"

# パーミッション確認
ls -l service-account-key.json
```

> ⚠️ **セキュリティ注意**: `service-account-key.json`は機密情報です。Gitにコミットしないでください（`.gitignore`に含まれています）。

### 3️⃣ Machine Learning セットアップ

#### オプションA: Cloud Run（推奨）🌟

**メリット**: GPUなしでも高速、スケーラブル、メンテナンス不要

1. **MLモデルのダウンロードとGCSアップロード**

```bash
./setup-models.sh
```

このスクリプトは以下を自動実行：
- Dockerコンテナ内でHugging FaceからMLモデルをダウンロード
- GCS（Google Cloud Storage）バケット作成
- モデルファイルをGCSにアップロード

2. **Cloud Runサービスのデプロイ**

Cloud Run Web UIまたはgcloudコマンドで以下を設定：

```bash
# Artifact Registryリポジトリ作成（初回のみ）
gcloud artifacts repositories create immich-ml \
  --repository-format=docker \
  --location=us-central1

# イメージをArtifact Registryにクローン
./update-machine-learning.sh
```

**Cloud Run設定（Web UIまたはYAML）**:
- **イメージ**: `us-central1-docker.pkg.dev/${PROJECT_ID}/immich-ml/immich-machine-learning:v2.1.0-cuda`
- **CPU**: 4
- **メモリ**: 16GB
- **GPUタイプ**: NVIDIA L4（推奨）、またはT4
- **GPU数**: 1
- **ボリュームマウント**:
  - タイプ: Cloud Storage bucket
  - バケット: `immich-ml-models`
  - マウントパス: `/cache`
- **環境変数**:
  - `MACHINE_LEARNING_CACHE_FOLDER`: `/cache`
  - その他、`.env`から必要に応じて

3. **.envファイルに追記**

```bash
CLOUD_RUN_ML_URL=https://your-cloud-run-service-url.run.app
```

#### オプションB: ローカルML（NVIDIA GPU必須）

**メリット**: オフライン動作、データが外部に出ない

**要件**: NVIDIA GPU + NVIDIA Container Toolkit

1. **モデルのダウンロード（ローカル用）**

```bash
./setup-models.sh
# GCSアップロードはスキップ可能
```

2. **docker-compose起動時に追加**

```bash
docker-compose -f docker-compose.yml -f machine-learning.docker-compose.yml up -d
```

3. **Immich設定内でMLエンドポイントを設定**
   - 管理画面 → Machine Learning設定
   - URL: `http://127.0.0.1:3003`（Tailscale使用時）

### 4️⃣ Tailscale設定（任意）

Tailscaleは、すべてのコンテナを安全なVPN経由でアクセス可能にします。

#### 使用しない場合

`docker-compose.yml`を編集し、以下の変更を実施：

1. **各サービスの`network_mode`をコメントアウト**し、通常のネットワークに変更：

```yaml
services:
  immich-server:
    # network_mode: service:tailscale  # コメントアウト
    ports:
      - '2283:2283'  # ポート公開を追加
    # ...

  redis:
    # network_mode: service:tailscale  # コメントアウト
    # ...

  database:
    # network_mode: service:tailscale  # コメントアウト
    # ...

  # tailscaleサービス全体をコメントアウト
  # tailscale:
  #   image: tailscale/tailscale:...
  #   ...
```


#### 使用する場合

1. **Tailscale Auth Keyを取得**

[Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys) → Auth Keys → Generate auth key

2. **.envに設定**

```bash
TS_AUTH_KEY=tskey-auth-xxxxxxxxxxxxx
TS_HOSTNAME=immich
TS_EXTRA_ARGS=--advertise-tags=tag:immich
```

3. そのまま起動（`network_mode: service:tailscale`が有効）

### 5️⃣ 起動

```bash
# 基本構成（Immich + PostgreSQL + Redis + Cloud Run Proxy）
docker-compose up -d

# ローカルML使用時
docker-compose -f docker-compose.yml -f machine-learning.docker-compose.yml up -d

# ログ確認
docker-compose logs -f
```

### 6️⃣ アクセス

- **Tailscale使用時**: `http://immich.your-tailnet.ts.net`
- **Tailscale不使用時**: `http://localhost:2283`

初回アクセス時にアカウント作成画面が表示されます。

## 🛠️ ユーティリティスクリプト

### `setup-models.sh`

MLモデルをダウンロードしてGCSにアップロード

```bash
./setup-models.sh
```

**機能**:
- HuggingFaceからCLIPモデルと顔認識モデルをダウンロード
- GCSバケット作成
- モデルファイルをGCSにアップロード
- Cloud Run設定情報を表示

### `upload-env-to-gcp-secrets.sh`

環境変数ファイルをGCP Secret Managerにアップロード

```bash
./upload-env-to-gcp-secrets.sh [SECRET_NAME] [ENV_FILE_PATH]

# 例: デフォルト設定で実行
./upload-env-to-gcp-secrets.sh

# 例: カスタム名で実行
./upload-env-to-gcp-secrets.sh my-immich-env /path/to/.env
```

**機能**:
- `.env`ファイルをSecret Managerに安全に保存
- バージョン管理（上書き時に新バージョン作成）
- 古いバージョンを自動破棄

### `update-machine-learning.sh`

MLイメージを最新バージョンに更新

```bash
./update-machine-learning.sh
```

**機能**:
- GitHub APIから最新のImmichバージョンを取得
- イメージをArtifact Registryにクローン
- `.env`と`docker-compose.yml`を自動更新
- 古いイメージを削除

## 📁 ディレクトリ構造

```
immich-app/
├── .env                        # 環境変数（要作成）
├── .env.example                # 環境変数テンプレート
├── docker-compose.yml          # メインのDocker Compose設定
├── machine-learning.docker-compose.yml  # ローカルML用追加設定
├── proxy.dockerfile            # Cloud Run Proxy用Dockerfile
├── service-account-key.json    # GCPサービスアカウントキー（要作成）
│
├── cloud-run-proxy/            # Cloud Run認証プロキシ設定
│   ├── entrypoint.sh           # プロキシ起動スクリプト
│   ├── nginx.conf.template     # Nginx設定テンプレート
│   └── token-updater.sh        # GCPトークン自動更新
│
├── setup-models.sh             # MLモデルセットアップスクリプト
├── upload-env-to-gcp-secrets.sh  # Secret Manager連携スクリプト
├── update-machine-learning.sh  # MLバージョン更新スクリプト
│
├── models/                     # MLモデル保存先（ローカルML使用時）
├── photos/                     # アップロード写真保存先
├── postgres/                   # PostgreSQLデータ保存先
└── tailscale/                  # Tailscale状態保存先
```

## 🔧 トラブルシューティング

### Cloud Run Proxyが起動しない

**症状**: `cloud-run-proxy`コンテナが起動失敗

**原因と解決策**:
1. **サービスアカウントキーが見つからない**
   ```bash
   ls -l service-account-key.json
   # ファイルが存在し、読み取り可能か確認
   ```

2. **CLOUD_RUN_ML_URLが未設定**
   ```bash
   grep CLOUD_RUN_ML_URL .env
   # 値が設定されているか確認
   ```

3. **権限不足**
   ```bash
   # サービスアカウントにrun.invoker権限があるか確認
   gcloud projects get-iam-policy $PROJECT_ID \
     --flatten="bindings[].members" \
     --filter="bindings.members:serviceAccount:immich-ml-invoker*"
   ```

### PostgreSQLが起動しない

**症状**: `database`コンテナが起動失敗

**解決策**:
```bash
# データディレクトリの権限を確認
ls -ld postgres/

# 権限がない場合は修正
chmod -R 755 postgres/

# 再起動
docker-compose restart database
```

### Tailscale接続ができない

**症状**: Tailscale経由でアクセスできない

**解決策**:
1. **Auth Keyの確認**
   ```bash
   grep TS_AUTH_KEY .env
   # 有効期限が切れていないか確認
   ```

2. **Tailscaleログ確認**
   ```bash
   docker-compose logs tailscale
   ```

3. **Tailscale管理画面でデバイス確認**
   - [Tailscale Admin Console](https://login.tailscale.com/admin/machines)でホスト名が表示されているか

### Machine Learningが遅い

**Cloud Run使用時**:
- GPUが有効になっているか確認
- CPUとメモリが十分か確認（推奨: 4 CPU, 16GB RAM, 1x L4 GPU）

**ローカルML使用時**:
```bash
# GPUが認識されているか確認
docker exec immich_machine_learning nvidia-smi

# コンテナのリソース確認
docker stats immich_machine_learning
```

### モデルのダウンロードが失敗する

**症状**: `setup-models.sh`実行時にエラー

**解決策**:
```bash
# Dockerが起動しているか確認
docker info

# ネットワーク接続確認
curl -I https://huggingface.co

# ディスク容量確認（モデルは数GB必要）
df -h .
```

## 📝 メンテナンス

### バックアップ

```bash
# データベースバックアップ
docker exec immich_postgres pg_dumpall -U postgres > backup.sql

# 写真ファイルバックアップ
tar -czf photos-backup.tar.gz photos/
```

### バージョンアップ

```bash
# MLイメージ更新
./update-machine-learning.sh

# Immich本体更新
# .envのIMMICH_VERSIONを変更後
docker-compose pull
docker-compose up -d
```

### ログローテーション

```bash
# ログサイズ確認
docker-compose logs --tail=0 | wc -l

# 古いログ削除（Dockerログドライバー設定推奨）
docker-compose down
docker system prune -f
docker-compose up -d
```

## 🔗 参考リンク

- [Immich公式ドキュメント](https://docs.immich.app/)
- [Immich GitHub](https://github.com/immich-app/immich)
- [GCP Cloud Run ドキュメント](https://cloud.google.com/run/docs)
- [Tailscale ドキュメント](https://tailscale.com/kb/)

## 📄 ライセンス

このリポジトリの設定ファイルは自由に使用できます。Immich本体のライセンスは[公式リポジトリ](https://github.com/immich-app/immich)を参照してください。

---

**Enjoy your self-hosted photo management! 📸✨**

