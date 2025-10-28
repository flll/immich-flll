#!/bin/bash -e

# .envファイルをGCPシークレットマネージャーにアップロードするスクリプト
# 使用方法: ./upload-env-to-gcp-secrets.sh [SECRET_NAME] [.env_FILE_PATH]

DEFAULT_PROJECT_ID="lll-fish"
DEFAULT_SECRET_NAME="immich-env"
DEFAULT_ENV_FILE=".env"

print_success() {
    echo -e "\033[32m✓ $1\033[0m"
}

print_error() {
    echo -e "\033[31m✗ $1\033[0m"
}

print_info() {
    echo -e "\033[34mℹ $1\033[0m"
}

print_warning() {
    echo -e "\033[33m⚠ $1\033[0m"
}

print_debug() {
    echo -e "\033[90m🔍 $1\033[0m"
}

print_header() {
    echo -e "\033[1;36m=== $1 ===\033[0m"
}

show_help() {
    echo "使用方法: $0 [SECRET_NAME] [ENV_FILE_PATH]"
    echo ""
    echo "引数:"
    echo "  SECRET_NAME    シークレットの名前 (デフォルト: $DEFAULT_SECRET_NAME)"
    echo "  ENV_FILE_PATH  .envファイルのパス (デフォルト: $DEFAULT_ENV_FILE)"
    echo ""
    echo "例:"
    echo "  $0                              # デフォルト設定で実行"
    echo "  $0 my-secret                    # シークレット名を指定"
    echo "  $0 my-secret /path/to/.env      # 両方を指定"
    echo ""
    echo "前提条件:"
    echo "  - gcloud CLIがインストールされていること"
    echo "  - GCPプロジェクト '$DEFAULT_PROJECT_ID' にアクセス権限があること"
    echo "  - シークレットマネージャーのAPIが有効になっていること"
}

SECRET_NAME="${1:-$DEFAULT_SECRET_NAME}"
ENV_FILE="${2:-$DEFAULT_ENV_FILE}"

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

print_info "GCPシークレットマネージャーへの.envアップロードを開始します..."
print_info "プロジェクト: $DEFAULT_PROJECT_ID"
print_info "シークレット名: $SECRET_NAME"
print_info "環境ファイル: $ENV_FILE"

if [[ ! -f "$ENV_FILE" ]]; then
    print_error ".envファイルが見つかりません: $ENV_FILE"
    exit 1
fi

print_success ".envファイルが見つかりました"

if ! command -v gcloud &> /dev/null; then
    print_error "gcloud CLIがインストールされていません"
    print_info "インストール方法: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

print_success "gcloud CLIが見つかりました"

CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null || echo "")
if [[ "$CURRENT_PROJECT" != "$DEFAULT_PROJECT_ID" ]]; then
    print_warning "現在のプロジェクト ($CURRENT_PROJECT) が指定されたプロジェクト ($DEFAULT_PROJECT_ID) と異なります"
    print_info "プロジェクトを切り替えています..."
    gcloud config set project "$DEFAULT_PROJECT_ID"
    print_success "プロジェクトを $DEFAULT_PROJECT_ID に設定しました"
fi

if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
    print_error "GCPにログインしていません"
    print_info "ログインしてください: gcloud auth login"
    exit 1
fi

print_success "認証状態を確認しました"

print_info "シークレットマネージャーAPIが有効か確認しています..."
if ! gcloud services list --enabled --filter="name:secretmanager.googleapis.com" --format="value(name)" | grep -q "secretmanager.googleapis.com"; then
    print_warning "シークレットマネージャーAPIが有効になっていません"
    print_info "APIを有効化しています..."
    gcloud services enable secretmanager.googleapis.com
    print_success "シークレットマネージャーAPIを有効化しました"
else
    print_success "シークレットマネージャーAPIは既に有効です"
fi

TEMP_FILE=$(mktemp)
cat "$ENV_FILE" > "$TEMP_FILE"

if gcloud secrets describe "$SECRET_NAME" &>/dev/null; then
    print_warning "シークレット '$SECRET_NAME' は既に存在します"
    read -p "上書きしますか？ (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "アップロードをキャンセルしました"
        rm -f "$TEMP_FILE"
        exit 0
    fi
    
    print_info "既存のシークレットに新しいバージョンを追加しています..."
    gcloud secrets versions add "$SECRET_NAME" --data-file="$TEMP_FILE"
    print_success "シークレット '$SECRET_NAME' に新しいバージョンを追加しました"
    
    print_info "過去のバージョンを破棄しています..."
    LATEST_VERSION=$(gcloud secrets versions list "$SECRET_NAME" --limit=1 --format="value(name)" | sed 's/.*\/versions\///')
    ENABLED_VERSIONS=$(gcloud secrets versions list "$SECRET_NAME" --filter="state:ENABLED" --format="value(name)" | sed 's/.*\/versions\///')
    
    DESTROYED_COUNT=0
    for VERSION in $ENABLED_VERSIONS; do
        if [[ "$VERSION" != "$LATEST_VERSION" ]]; then
            print_info "バージョン $VERSION を破棄しています..."
            gcloud secrets versions destroy "$VERSION" --secret="$SECRET_NAME" &>/dev/null
            ((DESTROYED_COUNT++))
        fi
    done
    
    if [[ $DESTROYED_COUNT -gt 0 ]]; then
        print_success "$DESTROYED_COUNT 個の過去のバージョンを破棄しました"
    else
        print_info "破棄する過去のバージョンはありませんでした"
    fi
else
    print_info "新しいシークレット '$SECRET_NAME' を作成しています..."
    gcloud secrets create "$SECRET_NAME" --data-file="$TEMP_FILE"
    print_success "シークレット '$SECRET_NAME' を作成しました"
fi

rm -f "$TEMP_FILE"

print_info "シークレットの詳細情報:"
gcloud secrets describe "$SECRET_NAME" --format="table(name,createTime,labels)"

LATEST_VERSION=$(gcloud secrets versions list "$SECRET_NAME" --limit=1 --format="value(name)")
print_info "最新バージョン: $LATEST_VERSION"

print_info "最新バージョンを'new'エイリアスに割り当てています..."
LATEST_VERSION_NUMBER=$(echo "$LATEST_VERSION" | sed 's/.*\/versions\///')
gcloud secrets update "$SECRET_NAME" --update-version-aliases="new=$LATEST_VERSION_NUMBER"
print_success "最新バージョン ($LATEST_VERSION_NUMBER) を'new'エイリアスに割り当てました"

print_success ".envファイルのGCPシークレットマネージャーへのアップロードが完了しました！"

echo ""
print_info "シークレットを使用する方法:"
echo "  # 最新バージョンの値を取得"
echo "  gcloud secrets versions access latest --secret=\"$SECRET_NAME\""
echo ""
echo "  # 'new'エイリアスを使用して値を取得"
echo "  gcloud secrets versions access new --secret=\"$SECRET_NAME\""
echo ""
echo "  # 環境変数として設定"
echo "  export \$(gcloud secrets versions access latest --secret=\"$SECRET_NAME\" | tr '\n' ' ')"
echo ""
echo "  # 'new'エイリアスを使用して環境変数として設定"
echo "  export \$(gcloud secrets versions access new --secret=\"$SECRET_NAME\" | tr '\n' ' ')"
