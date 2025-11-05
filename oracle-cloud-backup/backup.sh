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
# 暗号化方式: OpenSSL AES-256-GCM (認証付き暗号化)
#
# 注意: このスクリプトは長時間実行されます（圧縮とアップロードのため）
#=============================================================================

# クリーンアップ関数
cleanup() {
    if [ -n "${BACKUP_PASSWORD:-}" ]; then
        unset BACKUP_PASSWORD
    fi
    if [ -n "${BACKUP_PASSWORD_CONFIRM:-}" ]; then
        unset BACKUP_PASSWORD_CONFIRM
    fi
}

# エラーハンドラ
trap cleanup EXIT

# カラー出力関数（update-machine-learning.shから採用）
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

print_header() {
    echo -e "\033[1;36m=== $1 ===\033[0m"
}

# 設定値
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCI_DIR="${SCRIPT_DIR}/oci"
OCI_CONFIG_DIR="${OCI_DIR}"
IMMICH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="${OCI_DIR}/temp"

# OCI設定（デフォルト値）
OCI_REGION="us-ashburn-1"
OCI_HOME_REGION="${OCI_HOME_REGION:-}"  # 空の場合は動的に取得
OCI_BUCKET_NAME="immich-backup"
OCI_COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-}"
OCI_NAMESPACE="${OCI_NAMESPACE:-}"

# OCI CLIイメージ
OCI_CLI_IMAGE="ghcr.io/oracle/oci-cli:20251029@sha256:ee374e857a438a7a1a4524c1398a6c43ed097c8f5b1e9a0e1ca05b7d01896eb6"

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
)

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
print_info "暗号化方式: OpenSSL AES-256-GCM"
echo ""

# OCI認証の確認と実行
print_header "OCI認証"
if [ -f "${OCI_CONFIG_DIR}/config" ] && [ -d "${OCI_CONFIG_DIR}/sessions/DEFAULT" ] 2>/dev/null; then
    print_info "既存の認証情報が見つかりました。確認中..."

    # トークンの有効期限チェック（簡易的）
    if docker run --rm \
        --user $(id -u):$(id -g) \
        -v "${OCI_CONFIG_DIR}:/oracle/.oci" \
        "${OCI_CLI_IMAGE}" \
        iam region list --auth security_token >/dev/null 2>&1; then
        print_success "認証情報は有効です"
    else
        print_warning "認証情報の有効期限が切れています。再認証が必要です"
        rm -rf "${OCI_CONFIG_DIR}/sessions"
        rm -f "${OCI_CONFIG_DIR}/config"
    fi
fi

if [ ! -f "${OCI_CONFIG_DIR}/config" ]; then
    print_info "ブラウザでOCIにログインしてください..."
    print_warning "このプロセスには数分かかる場合があります"
    echo ""

    if docker run --rm -it \
        --user $(id -u):$(id -g) \
        -v "${OCI_CONFIG_DIR}:/oracle/.oci" \
        -p 8181:8181 \
        "${OCI_CLI_IMAGE}" \
        session authenticate --region "${OCI_REGION}" --profile-name DEFAULT; then
        print_success "OCI認証が完了しました"
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
        # tenancy情報からホームリージョンキーを取得
        set +e
        HOME_REGION_KEY=$(docker run --rm \
            --user $(id -u):$(id -g) \
            -v "${OCI_CONFIG_DIR}:/oracle/.oci" \
            "${OCI_CLI_IMAGE}" \
            iam tenancy get \
            --tenancy-id "${OCI_TENANCY_ID}" \
            --auth security_token \
            --query 'data."home-region-key"' \
            --raw-output 2>&1)
        HOME_REGION_EXIT=$?
        set -e
        
        if [ ${HOME_REGION_EXIT} -eq 0 ] && [ -n "${HOME_REGION_KEY}" ]; then
            # リージョンキーをリージョン名に変換
            case "${HOME_REGION_KEY}" in
                KIX) OCI_HOME_REGION="ap-osaka-1" ;;
                NRT) OCI_HOME_REGION="ap-tokyo-1" ;;
                IAD) OCI_HOME_REGION="us-ashburn-1" ;;
                PHX) OCI_HOME_REGION="us-phoenix-1" ;;
                LHR) OCI_HOME_REGION="uk-london-1" ;;
                FRA) OCI_HOME_REGION="eu-frankfurt-1" ;;
                AMS) OCI_HOME_REGION="eu-amsterdam-1" ;;
                YYZ) OCI_HOME_REGION="ca-toronto-1" ;;
                SYD) OCI_HOME_REGION="ap-sydney-1" ;;
                GRU) OCI_HOME_REGION="sa-saopaulo-1" ;;
                ICN) OCI_HOME_REGION="ap-seoul-1" ;;
                BOM) OCI_HOME_REGION="ap-mumbai-1" ;;
                ZRH) OCI_HOME_REGION="eu-zurich-1" ;;
                JED) OCI_HOME_REGION="me-jeddah-1" ;;
                YUL) OCI_HOME_REGION="ca-montreal-1" ;;
                HYD) OCI_HOME_REGION="ap-hyderabad-1" ;;
                MEL) OCI_HOME_REGION="ap-melbourne-1" ;;
                *) 
                    print_warning "未知のリージョンキー: ${HOME_REGION_KEY}"
                    OCI_HOME_REGION="${OCI_REGION}" 
                    ;;
            esac
            print_success "ホームリージョン: ${OCI_HOME_REGION} (${HOME_REGION_KEY})"
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

    # 方法1: os ns get で直接取得（最も正統的な方法）
    print_info "方法1: os ns get でネームスペースを取得中..."

    NS_GET_OUTPUT=$(docker run --rm \
        --user $(id -u):$(id -g) \
        -v "${OCI_CONFIG_DIR}:/oracle/.oci" \
        "${OCI_CLI_IMAGE}" \
        os ns get --auth security_token --region "${OCI_REGION}" 2>&1)
    NS_GET_EXIT=$?

    if [ ${NS_GET_EXIT} -eq 0 ]; then
        OCI_NAMESPACE=$(echo "${NS_GET_OUTPUT}" | grep -o '"data" *: *"[^"]*"' | head -1 | cut -d'"' -f4)

        if [ -n "${OCI_NAMESPACE}" ]; then
            print_success "ネームスペース取得成功（方法1）: ${OCI_NAMESPACE}"
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

        print_warning "方法1でのネームスペース取得に失敗。方法2を試行します..."
    fi
fi

# 方法2: ダミーリクエストでエラーメッセージから正しいネームスペースを抽出
if [ -z "${OCI_NAMESPACE}" ]; then
    print_info "方法2: エラーメッセージからネームスペースを抽出中..."

    # 存在しないバケットで意図的にエラーを起こし、正しいネームスペースを得る
    NS_TEST_OUTPUT=$(docker run --rm \
        --user $(id -u):$(id -g) \
        -v "${OCI_CONFIG_DIR}:/oracle/.oci" \
        "${OCI_CLI_IMAGE}" \
        os bucket get \
        --bucket-name "__namespace_discovery_test__" \
        --namespace "test" \
        --auth security_token \
        --region "${OCI_REGION}" 2>&1)

    # エラーメッセージから正しいネームスペースを抽出
    # "namespace of the account ('axmroep1pvtu')" というパターンを探す
    OCI_NAMESPACE=$(echo "${NS_TEST_OUTPUT}" | \
        grep -o "namespace of the account ('[^']*')" | \
        cut -d"'" -f2)

    if [ -n "${OCI_NAMESPACE}" ]; then
        print_success "ネームスペース取得成功（方法2）: ${OCI_NAMESPACE}"
        echo "export OCI_NAMESPACE=${OCI_NAMESPACE}" > "${OCI_CONFIG_DIR}/namespace"
    fi
fi

# 最終確認：取得に失敗した場合
if [ -z "${OCI_NAMESPACE}" ]; then
    print_error "ネームスペースの自動取得に失敗しました"
    echo ""
    print_warning "以下のコマンドで手動設定してください:"
    echo "  1. OCIコンソールからネームスペースを確認"
    echo "     OCIコンソール → プロファイル（右上）→ Tenancy → Object Storage Namespace"
    echo "  2. 環境変数を設定して再実行"
    echo "     $ export OCI_NAMESPACE='あなたのネームスペース'"
    echo "     $ ./backup.sh"
    echo ""
    exit 1
fi
echo ""

# Compartment IDの取得（未設定の場合）
if [ -z "${OCI_COMPARTMENT_ID}" ]; then
    print_info "コンパートメントIDを取得しています..."
    OCI_COMPARTMENT_ID=$(docker run --rm \
        --user $(id -u):$(id -g) \
        -v "${OCI_CONFIG_DIR}:/oracle/.oci" \
        "${OCI_CLI_IMAGE}" \
        iam compartment list --auth security_token --compartment-id-in-subtree true --limit 1 2>&1 | grep -o '"id" *: *"ocid1.compartment[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -n "${OCI_COMPARTMENT_ID}" ]; then
        print_success "コンパートメントID取得完了"
        echo "export OCI_COMPARTMENT_ID=${OCI_COMPARTMENT_ID}" > "${OCI_CONFIG_DIR}/compartment"
    else
        print_error "コンパートメントIDの取得に失敗しました"
        print_warning "OCI_COMPARTMENT_ID環境変数を手動で設定してください"
        print_info "デバッグ出力を確認中..."
        docker run --rm \
            --user $(id -u):$(id -g) \
            -v "${OCI_CONFIG_DIR}:/oracle/.oci" \
            "${OCI_CLI_IMAGE}" \
            iam compartment list --auth security_token --compartment-id-in-subtree true --limit 1
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

set +e
BUCKET_CHECK_OUTPUT=$(docker run --rm \
    --user $(id -u):$(id -g) \
    -v "${OCI_CONFIG_DIR}:/oracle/.oci" \
    "${OCI_CLI_IMAGE}" \
    os bucket get \
    --bucket-name "${OCI_BUCKET_NAME}" \
    --namespace "${OCI_NAMESPACE}" \
    --auth security_token \
    --region "${OCI_REGION}" 2>&1)
BUCKET_CHECK_EXIT=$?
set -e

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

# パスコードの入力
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

# バックアップ設定の表示
print_header "バックアップ設定"
print_info "除外するディレクトリ:"
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    echo "  - ${pattern}"
done
echo ""
print_info "バックアップファイル名: ${BACKUP_FILENAME}"
print_info "出力先: ${TEMP_DIR}/${BACKUP_FILENAME}"
echo ""

# バックアップの圧縮と暗号化
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

# タイムスタンプの記録
START_TIME=$(date +%s)
echo "開始時刻: $(date '+%Y-%m-%d %H:%M:%S')" | tee "${OCI_DIR}/last_backup.log"

# tar + gzip + OpenSSL暗号化（パイプライン）
print_info "圧縮と暗号化を実行しています..."
echo ""

if tar -czf - -C "${IMMICH_ROOT}" ${EXCLUDE_ARGS} . 2>/dev/null | \
   openssl enc -aes-256-gcm -salt -pbkdf2 -pass pass:"${BACKUP_PASSWORD}" -out "${TEMP_DIR}/${BACKUP_FILENAME}"; then

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
else
    print_error "圧縮または暗号化に失敗しました"
    exit 1
fi

# パスコードをクリア
unset BACKUP_PASSWORD

# OCIへのアップロード
print_header "OCI Archive Storageへのアップロード"
print_info "ファイル: ${BACKUP_FILENAME}"
print_info "サイズ: ${COMPRESSED_SIZE_GB} GB"
print_warning "このプロセスは数時間かかる場合があります"
echo ""

if docker run --rm \
    --user $(id -u):$(id -g) \
    -v "${OCI_CONFIG_DIR}:/oracle/.oci" \
    -v "${TEMP_DIR}:/backup" \
    "${OCI_CLI_IMAGE}" \
    os object put \
    --bucket-name "${OCI_BUCKET_NAME}" \
    --namespace "${OCI_NAMESPACE}" \
    --file "/backup/${BACKUP_FILENAME}" \
    --name "${BACKUP_FILENAME}" \
    --storage-tier Archive \
    --part-size 128 \
    --parallel-upload-count 10 \
    --auth security_token \
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
