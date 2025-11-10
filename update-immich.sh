#!/bin/bash -e

# =============================================================================
# Immichバージョンアップスクリプト
# =============================================================================
#
# 【概要】
# 実行するだけでImmichを最新バージョンに
# アップデートします。GitHubから最新リリースを取得し、設定ファイルも自動更新します。
#
# 【処理フロー】
# [.envファイルから現在のバージョン取得]
#     ↓
# [GitHub APIから最新のImmichバージョン取得]
#     ↓
# [バージョン比較] → 🔄既に最新の場合は正常終了
#     ↓
# [設定ファイル更新]
#     ├─ .env ファイルのIMMICH_VERSION更新
#     ├─ docker-compose.yml のイメージタグ更新
#     └─ machine-learning.docker-compose.yml のイメージタグ更新
#
# 【前提条件】
# - curl, jq コマンドが利用可能
# - .env ファイルにIMMICH_VERSIONが定義済み
#
# =============================================================================

PROJECT_ID="lll-fish"
REGION="us-central1"
REPOSITORY="immich-ml"
IMAGE_NAME="immich-machine-learning"
SOURCE_REGISTRY="ghcr.io/immich-app"
TARGET_REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}"

print_success() {
    echo -e "\033[32m $1\033[0m"
}

print_info() {
    echo -e "\033[34m $1\033[0m"
}

print_warning() {
    echo -e "\033[33m $1\033[0m"
}

print_error() {
    echo -e "\033[31m $1\033[0m"
}

print_header() {
    echo -e "\033[1;36m=== $1 ===\033[0m"
}

ensure_repository_exists() {
    print_info "Artifact Registryリポジトリの存在確認中..."
    
    if gcloud artifacts repositories describe "${REPOSITORY}" --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
        print_success "リポジトリ '${REPOSITORY}' は既に存在します"
    else
        print_info "リポジトリ '${REPOSITORY}' を作成中..."
        gcloud artifacts repositories create "${REPOSITORY}" \
            --repository-format=docker \
            --location="${REGION}" \
            --project="${PROJECT_ID}" \
            --description="Immich Machine Learning images"
        
        if [ $? -eq 0 ]; then
            print_success "リポジトリ '${REPOSITORY}' を作成しました"
        else
            print_error "リポジトリの作成に失敗しました"
            exit 1
        fi
    fi
}

clone_image_to_artifact_registry() {
    local version="$1"
    local source_image="${SOURCE_REGISTRY}/${IMAGE_NAME}:${version}-cuda"
    local target_image="${TARGET_REGISTRY}/${IMAGE_NAME}:${version}-cuda"
    
    print_info "イメージをクローン中..."
    print_info "ソース: ${source_image}"
    print_info "ターゲット: ${target_image}"
    
    print_info "Docker認証を設定中..."
    gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
    
    print_info "イメージをpull中..."
    
    if docker pull --platform linux/amd64 "${source_image}"; then
        print_success "イメージのpullが成功しました"
    else
        print_error "イメージのpullに失敗しました: ${source_image}"
        print_info "ghcr.ioのレート制限またはネットワークエラーの可能性があります"
        exit 1
    fi
    
    # イメージにタグを付与
    print_info "イメージにタグを付与中..."
    docker tag "${source_image}" "${target_image}"
    
    # Artifact Registryにpush
    print_info "Artifact Registryにpush中..."
    docker push "${target_image}"
    
    if [ $? -eq 0 ]; then
        print_success "イメージのクローンが完了しました: ${target_image}"
    else
        print_error "イメージのクローンに失敗しました"
        exit 1
    fi
}

cleanup_old_images() {
    local current_version="$1"
    
    print_info "古いイメージの削除を開始..."
    
    local all_images
    all_images=$(gcloud artifacts docker images list "${TARGET_REGISTRY}/${IMAGE_NAME}" \
        --project="${PROJECT_ID}" \
        --format="value(name)" 2>/dev/null || echo "")
    
    if [ -z "$all_images" ]; then
        print_info "削除対象のイメージが見つかりません"
        return 0
    fi
    
    local deleted_count=0
    while IFS= read -r image_name; do
        local image_version=$(echo "$image_name" | sed "s|.*${IMAGE_NAME}:||" | sed "s|-cuda||")
        
        if [ "$image_version" != "$current_version" ]; then
            print_info "古いイメージを削除中: ${image_name}"
            gcloud artifacts docker images delete "${image_name}" \
                --project="${PROJECT_ID}" \
                --quiet
            
            if [ $? -eq 0 ]; then
                print_success "削除完了: ${image_name}"
                deleted_count=$((deleted_count + 1))
            else
                print_warning "削除に失敗: ${image_name}"
            fi
        fi
    done <<< "$all_images"
    
    if [ $deleted_count -gt 0 ]; then
        print_success "${deleted_count}個の古いイメージを削除しました"
    else
        print_info "削除対象の古いイメージはありませんでした"
    fi
}

set -e
trap 'print_error "スクリプトがエラーで終了しました。行番号: $LINENO"' ERR

main() {
    print_header "Immich MLイメージのバージョンアップを開始"
    
    if [ ! -f ".env" ]; then
        print_error ".envファイルが見つかりません"
        exit 1
    fi
    
    CURRENT_VERSION=$(grep "IMMICH_VERSION=" .env | cut -d'=' -f2)
    print_info "現在のバージョン: ${CURRENT_VERSION}"
    
    print_info "最新バージョンを確認中..."
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/immich-app/immich/releases/latest" | jq -r '.tag_name')
    
    if [ "$LATEST_VERSION" = "null" ] || [ -z "$LATEST_VERSION" ]; then
        print_error "最新バージョンの取得に失敗しました"
        exit 1
    fi
    
    print_info "最新バージョン: ${LATEST_VERSION}"
    
    # バージョン比較（vプレフィックスを除去して比較）
    CURRENT_VERSION_CLEAN=$(echo "$CURRENT_VERSION" | sed 's>v>>')
    LATEST_VERSION_CLEAN=$(echo "$LATEST_VERSION" | sed 's>v>>')
    
    if [ "$CURRENT_VERSION_CLEAN" = "$LATEST_VERSION_CLEAN" ]; then
        print_info "既に最新バージョンです。"
        print_info "Artifact Registryへのイメージクローンのみを実行します。"
    else
        read -p "${CURRENT_VERSION} から ${LATEST_VERSION} にアップデートしますか？ (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "アップデートをキャンセルしました"
            exit 0
        fi
    fi
    
    print_info "Artifact Registryへのイメージクローンを開始..."
    
    ensure_repository_exists
    clone_image_to_artifact_registry "${LATEST_VERSION}"
    cleanup_old_images "${LATEST_VERSION}"
    
    # バージョンが変更された場合のみ設定ファイルを更新
    if [ "$CURRENT_VERSION_CLEAN" != "$LATEST_VERSION_CLEAN" ]; then
        print_info "設定ファイルを更新中..."
        sed -i "s/IMMICH_VERSION=.*/IMMICH_VERSION=${LATEST_VERSION}/" .env
        print_success ".envファイルを更新: IMMICH_VERSION=${LATEST_VERSION}"
        
        if [ -f "docker-compose.yml" ]; then
            sed -i "s|ghcr.io/immich-app/immich-server:\${IMMICH_VERSION}|ghcr.io/immich-app/immich-server:${LATEST_VERSION}|g" docker-compose.yml
            print_success "docker-compose.ymlを更新"
        fi
        
        if [ -f "machine-learning.docker-compose.yml" ]; then
            sed -i "s|ghcr.io/immich-app/immich-machine-learning:\${IMMICH_VERSION}-cuda|ghcr.io/immich-app/immich-machine-learning:${LATEST_VERSION}-cuda|g" machine-learning.docker-compose.yml
            print_success "machine-learning.docker-compose.ymlを更新"
        fi
    else
        print_info "バージョンが変更されていないため、設定ファイルの更新をスキップしました"
    fi
    
    print_success "処理完了！"
    print_info "現在のバージョン: ${LATEST_VERSION}"
    
    if [ "$CURRENT_VERSION_CLEAN" != "$LATEST_VERSION_CLEAN" ]; then
        print_info "コンテナを再起動してください:"
        print_info "  docker-compose -f machine-learning.docker-compose.yml up -d"
        print_info "  docker-compose up -d"
        print_info ""
    fi
    
    print_info "Cloud Runの設定も手動で更新してください:"
    print_info "  - イメージ: ${TARGET_REGISTRY}/${IMAGE_NAME}:${LATEST_VERSION}-cuda"
}

main "$@"
