#!/bin/bash -e

#=============================================================================
# Immich OCI Archive Storage 暗号化バックアップスクリプト
#=============================================================================
# このスクリプトはImmichのバックアップを圧縮・暗号化して
# Oracle Cloud Infrastructure (OCI)のArchive Storageにアップロードします。
#
# 使用方法:
#   ./backup.sh        - 通常のバックアップを実行
#   ./backup.sh login  - OCI認証のみを実行（初回セットアップ、再認証時に便利）
#
#   1. 初回実行時または'login'モード時にブラウザでOCIにログインします
#   2. パスコードを入力します（暗号化用、通常バックアップ時のみ）
#   3. バックアップが自動的に圧縮・暗号化・アップロードされます（通常モードのみ）
#
# 暗号化方式: OpenSSL AES-256-CBC
#
# 注意: このスクリプトは長時間実行されます（圧縮とアップロードのため）
#=============================================================================

# グローバル変数
OCI_CLI_IMAGE="ghcr.io/oracle/oci-cli:20251105@sha256:353cbadd4c2840869567833d9bd63a170753b73c82236dcc27155666a3cd75dd"
SKIP_BACKUP_CREATION=false
SERVICES_STOPPED=false
DOCKER_COMPOSE_FILE=""

# 設定値
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCI_DIR="${SCRIPT_DIR}/oci"
OCI_CONFIG_DIR="${OCI_DIR}"
IMMICH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="${OCI_DIR}/temp"
DOCKER_COMPOSE_FILE="${IMMICH_ROOT}/docker-compose.yml"

# OCI設定（デフォルト値）
OCI_REGION="us-ashburn-1"
OCI_HOME_REGION="${OCI_HOME_REGION:-}"
OCI_BUCKET_NAME="immich-backup"
OCI_COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-}"
OCI_NAMESPACE="${OCI_NAMESPACE:-}"

# バックアップファイル名（タイムスタンプ付き）
TIMESTAMP=$(date '+%Y-%m-%d-%H%M%S')
BACKUP_FILENAME="immich-backup-${TIMESTAMP}.tar.gz.enc"

# 除外するディレクトリ
EXCLUDE_PATTERNS=(
    "photos/backups"
    "photos/encoded-video"
    "photos/thumbs"
    "photos/profile"
    "models"
    "postgres"
)

# カラー出力関数
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

restart_services() {
    if [ "${SERVICES_STOPPED}" = true ] && [ -n "${DOCKER_COMPOSE_FILE}" ]; then
        print_header "サービスの再起動"
        print_info "Docker Composeサービスを再起動しています..."
        
        if docker compose -f "${DOCKER_COMPOSE_FILE}" start; then
            print_success "サービスの再起動が完了しました"
            SERVICES_STOPPED=false
            
            # ヘルスチェック
            print_info "サービスのヘルスチェックを実行しています（最大5分）..."
            local max_wait=300
            local elapsed=0
            local check_interval=5
            
            while [ ${elapsed} -lt ${max_wait} ]; do
                local all_healthy=true
                
                # 主要サービスのステータスを確認
                for service in immich_server immich_postgres immich_redis; do
                    local status=$(docker inspect --format='{{.State.Health.Status}}' ${service} 2>/dev/null || echo "no-health")
                    
                    if [ "${status}" = "healthy" ] || [ "${status}" = "no-health" ]; then
                        continue
                    else
                        all_healthy=false
                        break
                    fi
                done
                
                if [ "${all_healthy}" = true ]; then
                    print_success "すべてのサービスが正常に起動しました（${elapsed}秒経過）"
                    return 0
                fi
                
                sleep ${check_interval}
                elapsed=$((elapsed + check_interval))
                echo -n "."
            done
            
            echo ""
            print_warning "ヘルスチェックがタイムアウトしましたが、サービスは起動しています"
        else
            print_error "サービスの再起動に失敗しました"
            print_warning "手動でサービスを起動してください: docker compose -f ${DOCKER_COMPOSE_FILE} start"
        fi
        echo ""
    fi
}

stop_services() {
    if [ -z "${DOCKER_COMPOSE_FILE}" ]; then
        print_error "DOCKER_COMPOSE_FILEが設定されていません"
        return 1
    fi
    
    print_header "Docker Composeサービスの停止"
    print_warning "整合性のあるバックアップを作成するため、すべてのサービスを停止します"
    print_warning "サービスは数分〜数十分停止します"
    echo ""
    
    if [ -f "${DOCKER_COMPOSE_FILE}" ]; then
        print_info "サービスを停止しています（タイムアウト: 60秒）..."
        
        if docker compose -f "${DOCKER_COMPOSE_FILE}" stop -t 60; then
            print_success "サービスの停止が完了しました"
            SERVICES_STOPPED=true
            
            # すべてのコンテナが停止したことを確認
            print_info "コンテナの停止状態を確認しています..."
            local max_wait=65
            local elapsed=0
            local all_stopped=false
            
            while [ ${elapsed} -lt ${max_wait} ]; do
                local running_containers=$(docker compose -f "${DOCKER_COMPOSE_FILE}" ps -q --status running 2>/dev/null | wc -l | tr -d ' ')
                
                if [ "${running_containers}" -eq 0 ]; then
                    all_stopped=true
                    break
                fi
                
                sleep 2
                elapsed=$((elapsed + 2))
            done
            
            if [ "${all_stopped}" = true ]; then
                print_success "すべてのコンテナが停止しました"
            else
                print_error "一部のコンテナが停止していません"
                print_warning "バックアップを続行しますが、整合性に問題がある可能性があります"
            fi
        else
            print_error "サービスの停止に失敗しました"
            print_warning "バックアップを中止します"
            return 1
        fi
    else
        print_error "docker-compose.ymlが見つかりません: ${DOCKER_COMPOSE_FILE}"
        print_warning "サービスを停止せずにバックアップを続行します"
        return 1
    fi
    echo ""
    return 0
}

cleanup() {
    # パスワード変数のクリア
    if [ -n "${BACKUP_PASSWORD:-}" ]; then
        unset BACKUP_PASSWORD
    fi
    if [ -n "${BACKUP_PASSWORD_CONFIRM:-}" ]; then
        unset BACKUP_PASSWORD_CONFIRM
    fi
    
    # サービスの再起動（エラー時も実行）
    restart_services
}
trap cleanup EXIT

# OCI CLI実行関数
run_oci_cli() {
    local interactive=false
    local extra_args=""
    
    # 対話的コマンドの判定
    if [[ "$*" =~ (session|setup|authenticate|bootstrap) ]]; then
        interactive=true
        extra_args="-it -p 8181:8181"
    fi
    
    # アップロード時のvolume追加判定
    if [[ "$*" =~ "os object put" ]]; then
        extra_args="${extra_args} -v ${TEMP_DIR}:/backup"
    fi
    
    docker run --rm ${extra_args} \
        --user $(id -u):$(id -g) \
        -v "${OCI_CONFIG_DIR}:/oracle/.oci" \
        "${OCI_CLI_IMAGE}" \
        "$@"
}


# ディレクトリの作成
mkdir -p "${OCI_CONFIG_DIR}"
mkdir -p "${TEMP_DIR}"

# コマンドライン引数の処理
COMMAND="${1:-}"

case "${COMMAND}" in
    login)
        LOGIN_ONLY=true
        ;;
    "")
        LOGIN_ONLY=false
        ;;
    *)
        echo "使用方法: $0 [login]"
        echo ""
        echo "オプション:"
        echo "  (なし)  - 通常のバックアップを実行"
        echo "  login   - OCI認証のみを実行（バックアップは行わない）"
        exit 1
        ;;
esac

print_header "Immich OCI Archive Storage 暗号化バックアップ"
echo ""
print_info "バックアップ元: ${IMMICH_ROOT}"
print_info "OCI リージョン: ${OCI_REGION}"
print_info "バケット名: ${OCI_BUCKET_NAME}"
print_info "暗号化方式: OpenSSL AES-256-CBC"
echo ""

# sudo権限の確保（loginモード以外）
if [ "${LOGIN_ONLY}" = false ]; then
    print_header "sudo権限の確認"
    print_info "バックアップにはroot所有ファイルへのアクセスが必要です"
    echo ""
    
    if sudo -v; then
        print_success "sudo権限を取得しました"
    else
        print_error "sudo権限の取得に失敗しました"
        exit 1
    fi
    echo ""
fi

# 暗号化パスコードの入力（新規バックアップの場合のみ、loginモード以外）
if [ "${LOGIN_ONLY}" = false ] && [ "${SKIP_BACKUP_CREATION}" = false ]; then
    print_header "暗号化パスコードの設定"
    print_warning "バックアップを暗号化するためのパスコードを入力してください"
    print_warning "このパスコードは復号化時に必要です。必ず安全に保管してください"
    echo ""

    while true; do
        read -s -p "パスコードを入力してください: " BACKUP_PASSWORD
        echo ""
        read -s -p "パスコードを再入力してください: " BACKUP_PASSWORD_CONFIRM
        echo ""

        if [ "${BACKUP_PASSWORD}" = "${BACKUP_PASSWORD_CONFIRM}" ]; then
            if [ -z "${BACKUP_PASSWORD}" ]; then
                print_error "パスコードが空です。再度入力してください"
                echo ""
            else
                print_success "パスコードが設定されました"
                unset BACKUP_PASSWORD_CONFIRM
                break
            fi
        else
            print_error "パスコードが一致しません。再度入力してください"
            echo ""
        fi
    done
    echo ""
fi

# OCI認証の確認と実行
print_header "OCI認証"

# Session Token設定が残っている場合の警告
if [ -d "${OCI_CONFIG_DIR}/sessions" ]; then
    print_warning "古いSession Token設定が検出されました"
    print_info "API Key認証に移行するため、古い設定を削除します..."
    rm -rf "${OCI_CONFIG_DIR}/sessions"
fi

if [ -f "${OCI_CONFIG_DIR}/config" ] && { [ -f "${OCI_CONFIG_DIR}/oci_api_key.pem" ] || [ -f "${OCI_CONFIG_DIR}/sessions/DEFAULT/oci_api_key.pem" ]; }; then
    print_info "既存の認証情報が見つかりました。確認中..."

    # API Key認証の確認
    if run_oci_cli iam region list >/dev/null 2>&1; then
        print_success "認証情報は有効です"
        
        # sessions/DEFAULT/にある場合は移動（下位互換性）
        if [ -f "${OCI_CONFIG_DIR}/sessions/DEFAULT/oci_api_key.pem" ] && [ ! -f "${OCI_CONFIG_DIR}/oci_api_key.pem" ]; then
            print_info "APIキーファイルを適切な場所に移動しています..."
            mv "${OCI_CONFIG_DIR}/sessions/DEFAULT/oci_api_key.pem" "${OCI_CONFIG_DIR}/oci_api_key.pem"
            mv "${OCI_CONFIG_DIR}/sessions/DEFAULT/oci_api_key_public.pem" "${OCI_CONFIG_DIR}/oci_api_key_public.pem"
            sed -i 's|/oracle/.oci/sessions/DEFAULT/oci_api_key.pem|/oracle/.oci/oci_api_key.pem|' "${OCI_CONFIG_DIR}/config"
            rm -rf "${OCI_CONFIG_DIR}/sessions"
            print_success "APIキーの配置を完了しました"
        fi
    else
        print_warning "認証情報が無効です。再認証が必要です"
        rm -f "${OCI_CONFIG_DIR}/config"
        rm -f "${OCI_CONFIG_DIR}/oci_api_key.pem"
        rm -f "${OCI_CONFIG_DIR}/oci_api_key_public.pem"
        rm -rf "${OCI_CONFIG_DIR}/sessions"
    fi
fi

if [ ! -f "${OCI_CONFIG_DIR}/config" ] || [ ! -f "${OCI_CONFIG_DIR}/oci_api_key.pem" ]; then
    print_info "ブラウザでOCIにログインしてください..."
    print_warning "このプロセスには数分かかる場合があります"
    print_info "APIキーが自動的に生成され、OCIにアップロードされます"
    echo ""

    if run_oci_cli setup bootstrap --region "${OCI_REGION}"; then
        print_success "OCI認証が完了しました"
        
        # APIキーファイルの再配置（sessions/DEFAULT/から移動）
        if [ -f "${OCI_CONFIG_DIR}/sessions/DEFAULT/oci_api_key.pem" ]; then
            print_info "APIキーファイルを適切な場所に移動しています..."
            
            mv "${OCI_CONFIG_DIR}/sessions/DEFAULT/oci_api_key.pem" "${OCI_CONFIG_DIR}/oci_api_key.pem"
            mv "${OCI_CONFIG_DIR}/sessions/DEFAULT/oci_api_key_public.pem" "${OCI_CONFIG_DIR}/oci_api_key_public.pem"
            
            # configファイルのパスを修正
            sed -i 's|/oracle/.oci/sessions/DEFAULT/oci_api_key.pem|/oracle/.oci/oci_api_key.pem|' "${OCI_CONFIG_DIR}/config"
            
            # sessionsディレクトリを削除
            rm -rf "${OCI_CONFIG_DIR}/sessions"
            
            print_success "APIキーの配置を完了しました"
        fi
        
        print_info "API Key認証が設定され、有効期限なしで使用できます"
    else
        print_error "OCI認証に失敗しました"
        exit 1
    fi
else
    print_success "認証済みです"
fi
echo ""

# テナンシーIDの取得
print_header "OCI設定情報の取得"
if [ -f "${OCI_CONFIG_DIR}/config" ]; then
    OCI_TENANCY_ID=$(grep "^tenancy=" "${OCI_CONFIG_DIR}/config" | cut -d'=' -f2)
    if [ -n "${OCI_TENANCY_ID}" ]; then
        print_success "テナンシーIDを取得しました"
    else
        print_warning "テナンシーIDの取得に失敗しました"
    fi
else
    print_warning "設定ファイルが見つかりません"
fi

# ホームリージョンの取得（未設定の場合）
if [ -z "${OCI_HOME_REGION}" ]; then
    print_info "ホームリージョンを取得しています..."
    
    if [ -n "${OCI_TENANCY_ID}" ]; then
        
        HOME_REGION_KEY=$(run_oci_cli iam tenancy get \
            --tenancy-id "${OCI_TENANCY_ID}" \
            --query 'data."home-region-key"' \
            --raw-output 2>&1 | grep -v '^+' | tail -n1)
        HOME_REGION_EXIT=$?
        
        
        if [ ${HOME_REGION_EXIT} -eq 0 ] && [ -n "${HOME_REGION_KEY}" ]; then
            # リージョンキーをリージョン名に変換（動的検索）
            OCI_HOME_REGION=$(run_oci_cli iam region list --output json 2>&1 | grep -v '^+' | \
                jq -r ".data[] | select(.key == \"${HOME_REGION_KEY}\") | .name")
            
            if [ -z "${OCI_HOME_REGION}" ]; then
                print_warning "リージョンキー '${HOME_REGION_KEY}' が見つかりません。${OCI_REGION}を使用します"
                OCI_HOME_REGION="${OCI_REGION}"
            else
                print_success "ホームリージョン: ${OCI_HOME_REGION} (${HOME_REGION_KEY})"
            fi
        else
            # フォールバック: 現在のリージョンを使用
            print_warning "ホームリージョンの取得に失敗。${OCI_REGION}を使用します"
            OCI_HOME_REGION="${OCI_REGION}"
        fi
    else
        print_warning "テナンシーIDが不明なため、ホームリージョンを${OCI_REGION}に設定します"
        OCI_HOME_REGION="${OCI_REGION}"
    fi
fi
echo ""

# OCI Namespaceの取得（未設定の場合）
if [ -z "${OCI_NAMESPACE}" ]; then
    print_info "OCIネームスペースを取得しています..."

    NS_GET_OUTPUT=$(run_oci_cli os ns get --region "${OCI_REGION}" 2>&1)
    NS_GET_EXIT=$?

    if [ ${NS_GET_EXIT} -eq 0 ]; then
        OCI_NAMESPACE=$(echo "${NS_GET_OUTPUT}" | grep -o '"data" *: *"[^"]*"' | head -1 | cut -d'"' -f4)

        if [ -n "${OCI_NAMESPACE}" ]; then
            print_success "ネームスペース取得成功: ${OCI_NAMESPACE}"
            echo "export OCI_NAMESPACE=${OCI_NAMESPACE}" > "${OCI_CONFIG_DIR}/namespace"
        fi
    else
        # エラーチェック：リージョンがサブスクライブされていない可能性
        if echo "${NS_GET_OUTPUT}" | grep -qi "NotAuthorized\|not subscribed\|not available\|TenantNotFound"; then
            print_error "リージョン '${OCI_REGION}' が利用できません"
            echo ""
            print_header "エラー原因"
            echo "  リージョン '${OCI_REGION}' がサブスクライブされていない可能性があります"
            echo ""
            print_header "解決策"
            echo ""
            print_info "us-ashburn-1 リージョンをサブスクライブしてください："
            echo "  1. OCIコンソール（https://cloud.oracle.com/）にログイン"
            echo "  2. 左上のメニュー → Governance & Administration → Region Management"
            echo "  3. 'US East (Ashburn)' を探して 'Subscribe' ボタンをクリック"
            echo "  4. サブスクライブ完了後（数分かかる場合があります）、このスクリプトを再実行"
            echo ""
            print_info "詳細なエラー情報:"
            echo "${NS_GET_OUTPUT}"
            echo ""
            exit 1
        fi

        print_error "ネームスペースの取得に失敗しました"
        echo ""
        print_warning "以下のコマンドで手動設定してください:"
        echo "  1. OCIコンソールからネームスペースを確認"
        echo "     OCIコンソール → プロファイル（右上）→ Tenancy → Object Storage Namespace"
        echo "  2. 環境変数を設定して再実行"
        echo "     $ export OCI_NAMESPACE='あなたのネームスペース'"
        echo "     $ ./backup.sh"
        echo ""
        print_info "詳細なエラー情報:"
        echo "${NS_GET_OUTPUT}"
        echo ""
        exit 1
    fi
fi
echo ""

# Compartment IDの取得（未設定の場合）
if [ -z "${OCI_COMPARTMENT_ID}" ]; then
    print_info "コンパートメントIDを取得しています..."
    OCI_COMPARTMENT_ID=$(run_oci_cli iam compartment list --compartment-id-in-subtree true --limit 1 2>&1 | grep -o '"id" *: *"ocid1.compartment[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -n "${OCI_COMPARTMENT_ID}" ]; then
        print_success "コンパートメントID取得完了"
        echo "export OCI_COMPARTMENT_ID=${OCI_COMPARTMENT_ID}" > "${OCI_CONFIG_DIR}/compartment"
    else
        print_error "コンパートメントIDの取得に失敗しました"
        print_warning "OCI_COMPARTMENT_ID環境変数を手動で設定してください"
        print_info "デバッグ出力を確認中..."
        run_oci_cli iam compartment list --compartment-id-in-subtree true --limit 1
        exit 1
    fi
fi
echo ""

# ログインのみモードの場合はここで終了
if [ "${LOGIN_ONLY}" = true ]; then
    echo ""
    print_header "ログイン完了"
    print_success "OCI認証情報の取得が完了しました"
    echo ""
    print_info "取得した情報:"
    [ -n "${OCI_TENANCY_ID}" ] && echo "  - テナンシーID: ${OCI_TENANCY_ID}"
    [ -n "${OCI_HOME_REGION}" ] && echo "  - ホームリージョン: ${OCI_HOME_REGION}"
    [ -n "${OCI_NAMESPACE}" ] && echo "  - ネームスペース: ${OCI_NAMESPACE}"
    [ -n "${OCI_COMPARTMENT_ID}" ] && echo "  - コンパートメントID: ${OCI_COMPARTMENT_ID}"
    echo ""
    print_info "認証情報は以下に保存されました:"
    echo "  - ${OCI_CONFIG_DIR}/config"
    echo "  - ${OCI_CONFIG_DIR}/sessions/"
    [ -f "${OCI_CONFIG_DIR}/namespace" ] && echo "  - ${OCI_CONFIG_DIR}/namespace"
    [ -f "${OCI_CONFIG_DIR}/compartment" ] && echo "  - ${OCI_CONFIG_DIR}/compartment"
    echo ""
    print_info "バックアップを実行するには:"
    echo "  ./backup.sh"
    exit 0
fi

# バケットの存在確認
print_header "バケットの確認"
print_info "バケット '${OCI_BUCKET_NAME}' の存在を確認しています..."

BUCKET_CHECK_OUTPUT=$(run_oci_cli os bucket get \
    --bucket-name "${OCI_BUCKET_NAME}" \
    --namespace "${OCI_NAMESPACE}" \
    --region "${OCI_REGION}" 2>&1)
BUCKET_CHECK_EXIT=$?


if [ ${BUCKET_CHECK_EXIT} -eq 0 ]; then
    print_success "バケット '${OCI_BUCKET_NAME}' が見つかりました"
else
    print_error "バケット '${OCI_BUCKET_NAME}' が見つかりません"
    echo ""
    print_header "セットアップ手順"
    echo ""
    print_info "ステップ1: リージョン '${OCI_REGION}' をサブスクライブ"
    echo "  1. OCIコンソール（https://cloud.oracle.com/）にログイン"
    echo "  2. 左上のメニュー → Governance & Administration → Region Management"
    echo "  3. 'US East (Ashburn)' を探して 'Subscribe' ボタンをクリック"
    echo "  4. サブスクライブ完了を待つ（数分かかる場合があります）"
    echo ""
    print_info "ステップ2: バケットを作成"
    echo "  1. OCIコンソールで左上のメニュー → Storage → Buckets"
    echo "  2. 左側のリージョン選択で 'US East (Ashburn)' を選択"
    echo "  3. 'Create Bucket' ボタンをクリック"
    echo "  4. 以下の設定で作成："
    echo "     - Bucket Name: ${OCI_BUCKET_NAME}"
    echo "     - Default Storage Tier: Archive"
    echo "     - Encryption: Encrypt using Oracle managed keys"
    echo "  5. 'Create' ボタンをクリック"
    echo ""
    print_info "セットアップ完了後、このスクリプトを再実行してください"
    echo ""
    exit 1
fi
echo ""

# 既存の暗号化ファイルをチェック
print_header "既存バックアップファイルのチェック"
EXISTING_FILES=$(find "${TEMP_DIR}" -maxdepth 1 -name "*.tar.gz.enc" -type f 2>/dev/null | sort -r)

if [ -n "${EXISTING_FILES}" ]; then
    EXISTING_FILE=$(echo "${EXISTING_FILES}" | head -1)
    EXISTING_FILENAME=$(basename "${EXISTING_FILE}")
    EXISTING_SIZE=$(stat -f%z "${EXISTING_FILE}" 2>/dev/null || stat -c%s "${EXISTING_FILE}" 2>/dev/null)
    EXISTING_SIZE_GB=$(echo "scale=2; ${EXISTING_SIZE} / 1024 / 1024 / 1024" | bc)
    EXISTING_DATE=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "${EXISTING_FILE}" 2>/dev/null || stat -c "%y" "${EXISTING_FILE}" 2>/dev/null | cut -d'.' -f1)
    
    print_warning "既存の暗号化ファイルが見つかりました："
    echo ""
    echo "  ファイル名: ${EXISTING_FILENAME}"
    echo "  サイズ: ${EXISTING_SIZE_GB} GB"
    echo "  作成日時: ${EXISTING_DATE}"
    echo ""
    
    # 複数ファイルがある場合は一覧を表示
    FILE_COUNT=$(echo "${EXISTING_FILES}" | wc -l | tr -d ' ')
    if [ "${FILE_COUNT}" -gt 1 ]; then
        OTHER_COUNT=$((FILE_COUNT - 1))
        print_info "他に ${OTHER_COUNT} 個のファイルがあります（最新のファイルを表示）"
        echo ""
    fi
    
    read -p "このファイルを再アップロードしますか？ (yes/no): " REUPLOAD_CONFIRM
    echo ""
    
    if [ "${REUPLOAD_CONFIRM}" = "yes" ]; then
        print_success "既存のファイルを使用します。圧縮・暗号化をスキップします"
        SKIP_BACKUP_CREATION=true
        BACKUP_FILENAME="${EXISTING_FILENAME}"
        COMPRESSED_SIZE="${EXISTING_SIZE}"
        COMPRESSED_SIZE_GB="${EXISTING_SIZE_GB}"
        echo ""
        print_info "スキップされる処理:"
        echo "  - パスコード入力"
        echo "  - バックアップの圧縮"
        echo "  - ファイルの暗号化"
        echo ""
    else
        print_info "新しいバックアップを作成します"
        echo ""
    fi
else
    print_info "既存の暗号化ファイルは見つかりませんでした"
    echo ""
fi

# バックアップ設定の表示（新規バックアップの場合のみ）
if [ "${SKIP_BACKUP_CREATION}" = false ]; then
    print_header "バックアップ設定"
    print_info "除外するディレクトリ:"
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        echo "  - ${pattern}"
    done
    echo ""
    print_info "バックアップファイル名: ${BACKUP_FILENAME}"
    print_info "出力先: ${TEMP_DIR}/${BACKUP_FILENAME}"
    echo ""
    
    # Docker Composeサービスの停止
    if ! stop_services; then
        exit 1
    fi
fi
# バックアップの圧縮と暗号化（新規バックアップの場合のみ）
if [ "${SKIP_BACKUP_CREATION}" = false ]; then
    print_header "バックアップの作成"
    print_info "このプロセスは長時間（数時間）かかる場合があります"
    print_warning "プロセスを中断しないでください"
    echo ""

    # 除外パターンをtar用に変換
    EXCLUDE_ARGS=""
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        EXCLUDE_ARGS="${EXCLUDE_ARGS} --exclude=${pattern}"
    done

    # 元のサイズを取得
    print_info "バックアップ対象のサイズを計算しています..."
    ORIGINAL_SIZE=$(du -sb "${IMMICH_ROOT}" ${EXCLUDE_ARGS} 2>/dev/null | cut -f1)
    ORIGINAL_SIZE_GB=$(echo "scale=2; ${ORIGINAL_SIZE} / 1024 / 1024 / 1024" | bc)
    print_success "対象サイズ: ${ORIGINAL_SIZE_GB} GB"
    echo ""
    START_TIME=$(date +%s)
    echo "開始時刻: $(date '+%Y-%m-%d %H:%M:%S')" | tee "${OCI_DIR}/last_backup.log"

    # tar + gzip + OpenSSL暗号化（パイプライン）
    print_info "圧縮と暗号化を実行しています..."
    print_info "エラーログ: ${OCI_DIR}/tar_errors.log"
    echo ""

    # エラーログを初期化
    : > "${OCI_DIR}/tar_errors.log"

    if sudo tar -czf - -C "${IMMICH_ROOT}" ${EXCLUDE_ARGS} . 2>&1 | tee -a "${OCI_DIR}/tar_errors.log" | \
       openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"${BACKUP_PASSWORD}" -out "${TEMP_DIR}/${BACKUP_FILENAME}"; then

        # 圧縮後のサイズを取得
        COMPRESSED_SIZE=$(stat -f%z "${TEMP_DIR}/${BACKUP_FILENAME}" 2>/dev/null || stat -c%s "${TEMP_DIR}/${BACKUP_FILENAME}" 2>/dev/null)
        COMPRESSED_SIZE_GB=$(echo "scale=2; ${COMPRESSED_SIZE} / 1024 / 1024 / 1024" | bc)
        COMPRESSION_RATIO=$(echo "scale=1; (1 - ${COMPRESSED_SIZE} / ${ORIGINAL_SIZE}) * 100" | bc)

        echo ""
        print_success "圧縮と暗号化が完了しました"
        print_info "元のサイズ: ${ORIGINAL_SIZE_GB} GB"
        print_info "圧縮後のサイズ: ${COMPRESSED_SIZE_GB} GB"
        print_info "圧縮率: ${COMPRESSION_RATIO}%"
        echo ""
        
        # tarのエラーログをチェック
        if [ -f "${OCI_DIR}/tar_errors.log" ] && [ -s "${OCI_DIR}/tar_errors.log" ]; then
            # tarの正常な出力（ブロック情報など）を除外してエラーのみを抽出
            ERROR_LINES=$(grep -v "^tar: " "${OCI_DIR}/tar_errors.log" | grep -v "^$" | grep -i -E "(error|permission denied|cannot|failed)" || true)
            
            if [ -n "${ERROR_LINES}" ]; then
                print_warning "バックアップ中に以下のエラーが発生しました:"
                echo "${ERROR_LINES}" | head -10
                echo ""
                print_warning "一部のファイルがスキップされた可能性があります"
                print_info "詳細: ${OCI_DIR}/tar_errors.log"
                echo ""
            fi
        fi
    else
        print_error "圧縮または暗号化に失敗しました"
        exit 1
    fi

    # パスコードをクリア
    unset BACKUP_PASSWORD
else
    # 既存ファイル再利用時のログ記録
    START_TIME=$(date +%s)
    echo "開始時刻: $(date '+%Y-%m-%d %H:%M:%S')" | tee "${OCI_DIR}/last_backup.log"
    echo "既存ファイルを再利用: ${BACKUP_FILENAME}" | tee -a "${OCI_DIR}/last_backup.log"
    echo ""
    print_info "既存の暗号化ファイルを使用します"
    print_info "ファイル: ${BACKUP_FILENAME}"
    print_info "サイズ: ${COMPRESSED_SIZE_GB} GB"
    echo ""
fi

# OCIへのアップロード
print_header "OCI Archive Storageへのアップロード"
print_info "ファイル: ${BACKUP_FILENAME}"
print_info "サイズ: ${COMPRESSED_SIZE_GB} GB"
print_warning "このプロセスは数時間かかる場合があります"
echo ""

if run_oci_cli os object put \
    --bucket-name "${OCI_BUCKET_NAME}" \
    --namespace "${OCI_NAMESPACE}" \
    --file "/backup/${BACKUP_FILENAME}" \
    --name "${BACKUP_FILENAME}" \
    --storage-tier Archive \
    --no-overwrite \
    --part-size 128 \
    --parallel-upload-count 15 \
    --verify-checksum \
    --region "${OCI_REGION}" \
    --debug 2>&1 | tee -a "${OCI_DIR}/last_backup.log"; then

    # 終了時刻の記録
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    HOURS=$((DURATION / 3600))
    MINUTES=$(((DURATION % 3600) / 60))
    SECONDS=$((DURATION % 60))

    echo "" | tee -a "${OCI_DIR}/last_backup.log"
    print_success "アップロードが完了しました！"
    echo "終了時刻: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "${OCI_DIR}/last_backup.log"
    echo "所要時間: ${HOURS}時間 ${MINUTES}分 ${SECONDS}秒" | tee -a "${OCI_DIR}/last_backup.log"
    echo "" | tee -a "${OCI_DIR}/last_backup.log"
    
    # アップロード成功後、サービスを再起動
    restart_services
else
    print_error "アップロードに失敗しました"
    echo ""
    print_info "詳細はログファイルを確認してください: ${OCI_DIR}/last_backup.log"
    echo ""
    
    # バケットが存在しない場合のエラーメッセージ
    print_header "バケットの作成方法"
    echo ""
    print_info "バケット '${OCI_BUCKET_NAME}' が存在しない可能性があります"
    echo ""
    print_info "以下の手順でバケットを作成してください："
    echo "  1. OCIコンソール（https://cloud.oracle.com/）にログイン"
    echo "  2. 左上のメニュー → Storage → Buckets"
    echo "  3. 'Create Bucket' ボタンをクリック"
    echo "  4. 以下の設定で作成："
    echo "     - Bucket Name: ${OCI_BUCKET_NAME}"
    echo "     - Default Storage Tier: Archive"
    echo "     - Encryption: Encrypt using Oracle managed keys"
    echo "  5. 'Create' ボタンをクリック"
    echo ""
    print_info "バケット作成後、このスクリプトを再実行してください"
    echo ""
    exit 1
fi

# ローカルの暗号化ファイルを削除
echo ""
print_header "クリーンアップ"
print_info "ローカルの暗号化ファイルを削除しますか？"
print_warning "ファイル: ${TEMP_DIR}/${BACKUP_FILENAME} (${COMPRESSED_SIZE_GB} GB)"
echo ""
read -p "削除する場合は 'yes' と入力してください: " DELETE_CONFIRM

if [ "${DELETE_CONFIRM}" = "yes" ]; then
    rm -f "${TEMP_DIR}/${BACKUP_FILENAME}"
    print_success "ローカルファイルを削除しました"
else
    print_info "ローカルファイルを保持します"
    print_info "場所: ${TEMP_DIR}/${BACKUP_FILENAME}"
fi
echo ""

print_header "完了"
print_success "すべての処理が正常に完了しました"
print_info "バックアップファイル: ${BACKUP_FILENAME}"
print_info "保存先: OCI Archive Storage (${OCI_BUCKET_NAME})"
print_warning "Archive Storageからの取り出しには最大4時間かかります"
print_info "ログファイル: ${OCI_DIR}/last_backup.log"
echo ""
print_info "復号化方法はREADME.mdを参照してください"
echo ""
