#!/bin/bash -e
# Immich MLモデルセットアップスクリプト
# モデルダウンロード + GCSアップロードを1回で実行
# モデルを変更する場合、一度modelsディレクトリを削除して実行してください


CLIP_MODEL_NAME="XLM-Roberta-Large-ViT-H-14__frozen_laion5b_s13b_b90k"
FACIAL_MODEL_NAME="antelopev2"
MODELS_DIR="./models"
DOCKER_IMAGE="python:3.11-slim"
PROJECT_ID="lll-fish"
REGION="us-central1"
BUCKET_NAME="immich-ml-models"

print_success() {
    echo -e "\033[32m✓ $1\033[0m"
}

print_info() {
    echo -e "\033[34mℹ $1\033[0m"
}

print_warning() {
    echo -e "\033[33m⚠ $1\033[0m"
}

print_error() {
    echo -e "\033[31m✗ $1\033[0m"
}

print_debug() {
    echo -e "\033[90m🔍 $1\033[0m"
}

print_header() {
    echo -e "\033[1;36m=== $1 ===\033[0m"
}

check_docker() {
    print_info "Dockerの確認中..."
    
    if ! command -v docker &> /dev/null; then
        print_error "Dockerがインストールされていません"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        print_error "Dockerデーモンが起動していません"
        exit 1
    fi
    
    print_success "Dockerの確認完了"
}

check_gcp_tools() {
    print_info "GCPツールの確認中..."
    
    if ! command -v gcloud &> /dev/null; then
        print_error "gcloud CLIがインストールされていません"
        exit 1
    fi
    
    if ! command -v gsutil &> /dev/null; then
        print_error "gsutilがインストールされていません"
        exit 1
    fi
    
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
        print_error "gcloudが認証されていません。gcloud auth loginを実行してください"
        exit 1
    fi
    
    print_success "GCPツールの確認完了"
}

set_project() {
    print_info "GCPプロジェクトを設定中: ${PROJECT_ID}"
    gcloud config set project "${PROJECT_ID}"
    print_success "プロジェクト設定完了"
}

prepare_directory() {
    print_info "モデルディレクトリを準備中: ${MODELS_DIR}"
    
    mkdir -p "$MODELS_DIR"
    
    if [ ! -w "$MODELS_DIR" ]; then
        print_error "モデルディレクトリに書き込み権限がありません: ${MODELS_DIR}"
        exit 1
    fi
    
    print_success "モデルディレクトリの準備完了"
}

download_models() {
    PYTHON_SCRIPT=$(mktemp)
    cat > "$PYTHON_SCRIPT" << 'EOF'
from huggingface_hub import snapshot_download
import os

def add_prefix_if_needed(model_name):
    if '/' not in model_name:
        return f'immich-app/{model_name}'
    return model_name

clip_model = add_prefix_if_needed('XLM-Roberta-Large-ViT-H-14__frozen_laion5b_s13b_b90k')
facial_model = add_prefix_if_needed('antelopev2')

print(f'CLIP model: {clip_model}')
print(f'FACIAL model: {facial_model}')

print('CLIPモデルをダウンロード中...')
snapshot_download(
    clip_model,
    cache_dir='/models/clip/XLM-Roberta-Large-ViT-H-14__frozen_laion5b_s13b_b90k',
    local_dir='/models/clip/XLM-Roberta-Large-ViT-H-14__frozen_laion5b_s13b_b90k'
)

print('Facial recognitionモデルをダウンロード中...')
snapshot_download(
    facial_model,
    cache_dir='/models/facial-recognition/antelopev2',
    local_dir='/models/facial-recognition/antelopev2'
)

print('モデルのダウンロードが完了しました！')
EOF

    print_info "Dockerコンテナを起動中..."
    docker run --rm \
        --network host \
        -v "$(pwd)/${MODELS_DIR}:/models" \
        -v "${PYTHON_SCRIPT}:/script.py" \
        "$DOCKER_IMAGE" \
        bash -c "
            apt-get update && \
            apt-get install -y python3-pip && \
            pip install huggingface_hub && \
            python3 /script.py
        "
    
    rm -f "$PYTHON_SCRIPT"
    
    print_success "モデルダウンロード完了"
}

verify_download() {
    print_info "ダウンロード結果を確認中..."
    
    CLIP_PATH="${MODELS_DIR}/clip/${CLIP_MODEL_NAME}"
    FACIAL_PATH="${MODELS_DIR}/facial-recognition/${FACIAL_MODEL_NAME}"
    
    if [ -d "$CLIP_PATH" ] && [ -d "$FACIAL_PATH" ]; then
        print_success "CLIPモデル: $CLIP_PATH"
        print_success "Facial recognitionモデル: $FACIAL_PATH"
        
        CLIP_SIZE=$(du -sh "$CLIP_PATH" | cut -f1)
        FACIAL_SIZE=$(du -sh "$FACIAL_PATH" | cut -f1)
        print_info "CLIPモデルサイズ: $CLIP_SIZE"
        print_info "Facial recognitionモデルサイズ: $FACIAL_SIZE"
        
        print_success "すべてのモデルが正常にダウンロードされました"
    else
        print_error "モデルのダウンロードに失敗しました"
        exit 1
    fi
}

create_bucket() {
    print_info "GCSバケットを作成中: ${BUCKET_NAME}"
    
    if gsutil ls -b "gs://${BUCKET_NAME}" &> /dev/null; then
        print_warning "バケット ${BUCKET_NAME} は既に存在します"
    else
        gsutil mb -p "${PROJECT_ID}" -c STANDARD -l "${REGION}" "gs://${BUCKET_NAME}"
        print_success "バケット作成完了: gs://${BUCKET_NAME}"
    fi
}

list_local_models() {
    local model_type=$1
    local models=()
    
    if [ -d "${MODELS_DIR}/${model_type}" ]; then
        for dir in "${MODELS_DIR}/${model_type}"/*; do
            if [ -d "$dir" ]; then
                models+=("$(basename "$dir")")
            fi
        done
    fi
    
    printf '%s\n' "${models[@]}"
}

list_gcs_models() {
    local model_type=$1
    local models=()
    
    if gsutil ls -b "gs://${BUCKET_NAME}" &> /dev/null; then
        local gcs_dirs=$(gsutil ls "gs://${BUCKET_NAME}/${model_type}/" 2>/dev/null | grep "/$" || true)
        
        for dir in $gcs_dirs; do
            local model_name=$(basename "$dir")
            if [ -n "$model_name" ]; then
                models+=("$model_name")
            fi
        done
    fi
    
    printf '%s\n' "${models[@]}"
}

sync_models_to_gcs() {
    print_info "ローカルとGCS間のモデル同期を開始..."
    
    local deleted_count=0
    local uploaded_count=0
    local skipped_count=0
    
    for model_type in "clip" "facial-recognition"; do
        print_info "=== ${model_type} モデルの同期中 ==="
        
        local local_models=($(list_local_models "$model_type"))
        local gcs_models=($(list_gcs_models "$model_type"))
        
        for gcs_model in "${gcs_models[@]}"; do
            local found=false
            for local_model in "${local_models[@]}"; do
                if [ "$gcs_model" = "$local_model" ]; then
                    found=true
                    break
                fi
            done
            
            if [ "$found" = false ]; then
                print_warning "GCS側の古いモデルを削除中: ${model_type}/${gcs_model}"
                gsutil -m rm -r "gs://${BUCKET_NAME}/${model_type}/${gcs_model}"
                print_success "削除完了: ${model_type}/${gcs_model}"
                ((deleted_count++))
            fi
        done
        
        for local_model in "${local_models[@]}"; do
            local found=false
            for gcs_model in "${gcs_models[@]}"; do
                if [ "$local_model" = "$gcs_model" ]; then
                    found=true
                    break
                fi
            done
            
            if [ "$found" = false ]; then
                print_info "新しいモデルをアップロード中: ${model_type}/${local_model}"
                gsutil -m rsync -r "${MODELS_DIR}/${model_type}/${local_model}" "gs://${BUCKET_NAME}/${model_type}/${local_model}"
                print_success "アップロード完了: ${model_type}/${local_model}"
                ((uploaded_count++))
            else
                print_debug "スキップ（既に同期済み）: ${model_type}/${local_model}"
                ((skipped_count++))
            fi
        done
    done
    
    echo ""
    print_header "同期結果サマリー"
    print_info "削除されたモデル: ${deleted_count}"
    print_info "アップロードされたモデル: ${uploaded_count}"
    print_info "スキップされたモデル: ${skipped_count}"
    
    if [ $deleted_count -eq 0 ] && [ $uploaded_count -eq 0 ]; then
        print_success "すべてのモデルが既に同期されています"
    else
        print_success "モデルの同期が完了しました"
    fi
}

upload_models() {
    print_info "モデルをGCSにアップロード中（差分のみ）..."
    
    print_info "CLIPモデルをアップロード中..."
    gsutil -m rsync -r "${MODELS_DIR}/clip" "gs://${BUCKET_NAME}/clip"
    
    print_info "Facial recognitionモデルをアップロード中..."
    gsutil -m rsync -r "${MODELS_DIR}/facial-recognition" "gs://${BUCKET_NAME}/facial-recognition"
    
    print_success "モデルアップロード完了"
}

verify_upload() {
    print_info "同期結果を確認中..."
    
    local gcs_clip_models=($(list_gcs_models "clip"))
    local gcs_facial_models=($(list_gcs_models "facial-recognition"))
    
    echo ""
    print_header "GCS上のモデル一覧"
    
    if [ ${#gcs_clip_models[@]} -gt 0 ]; then
        print_info "CLIPモデル:"
        for model in "${gcs_clip_models[@]}"; do
            echo "  - ${model}"
        done
    else
        print_warning "CLIPモデルがGCSに存在しません"
    fi
    
    if [ ${#gcs_facial_models[@]} -gt 0 ]; then
        print_info "Facial recognitionモデル:"
        for model in "${gcs_facial_models[@]}"; do
            echo "  - ${model}"
        done
    else
        print_warning "Facial recognitionモデルがGCSに存在しません"
    fi
    
    echo ""
    print_success "同期確認完了"
}

show_cloud_run_info() {
    print_info "Cloud Run設定情報:"
    echo ""
    echo "バケット名: ${BUCKET_NAME}"
    echo "マウントパス: /cache"
    echo ""
    echo "Cloud Run Web UIで以下の設定を行ってください:"
    echo "1. イメージ: ghcr.io/immich-app/immich-machine-learning:v2.1.0-cuda"
    echo "2. ボリュームマウント:"
    echo "   - ボリューム名: immich-models"
    echo "   - ボリュームタイプ: Cloud Storage"
    echo "   - バケット: ${BUCKET_NAME}"
    echo "   - マウントパス: /cache"
    echo ""
}

main() {
    print_header "Immich MLモデルセットアップスクリプト（統合版）を開始"
    
    check_docker
    check_gcp_tools
    set_project
    
    prepare_directory
    download_models
    verify_download
    
    create_bucket
    sync_models_to_gcs
    verify_upload
    show_cloud_run_info
    
    print_success "セットアップ完了！"
    print_info "ローカルでMLコンテナを起動する場合:"
    print_info "  docker-compose -f machine-learning.docker-compose.yml up -d"
}

show_help() {
    echo "Immich MLモデルセットアップスクリプト（統合版）"
    echo ""
    echo "使用方法:"
    echo "  $0                 # モデルをダウンロードしてGCSに同期"
    echo "  $0 --help         # このヘルプを表示"
    echo ""
    echo "機能:"
    echo "  - Dockerコンテナでモデルをダウンロード（checksum検証・スキップ機能付き）"
    echo "  - GCSバケットを作成"
    echo "  - インテリジェント同期:"
    echo "    * ローカルとGCSのモデルを比較（ディレクトリ名ベース）"
    echo "    * GCS側の古いモデルを自動削除（費用削減）"
    echo "    * 新しいモデルのみアップロード"
    echo "    * 既に同期済みのモデルはスキップ"
    echo "  - Cloud Run設定の案内表示"
    echo ""
    echo "設定:"
    echo "  PROJECT_ID: ${PROJECT_ID}"
    echo "  REGION: ${REGION}"
    echo "  BUCKET_NAME: ${BUCKET_NAME}"
    echo "  MODELS_DIR: ${MODELS_DIR}"
    echo "  DOCKER_IMAGE: ${DOCKER_IMAGE}"
    echo ""
    echo "前提条件:"
    echo "  - Dockerがインストールされ、起動している"
    echo "  - gcloud CLIがインストールされ、認証済み"
    echo "  - ${MODELS_DIR} に書き込み権限がある"
    echo ""
    echo "使用例:"
    echo "  1. 初回実行: すべてのモデルをダウンロード＆アップロード"
    echo "  2. 2回目以降（変更なし）: スキップメッセージが表示される"
    echo "  3. モデル変更後: 古いモデルを削除し、新しいモデルをアップロード"
}

if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    show_help
    exit 0
fi

main "$@"
