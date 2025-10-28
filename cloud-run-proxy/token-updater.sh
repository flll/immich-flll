#!/bin/bash -e

UPDATE_INTERVAL=3000
TOKEN_FILE="/tmp/gcloud_token"
LOG_FILE="/tmp/token-updater.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "トークン更新スクリプトを開始しました"

log "初回トークン取得中..."
gcloud auth print-identity-token --audiences="${CLOUD_RUN_ML_URL}" | tr -d '\n' > "$TOKEN_FILE" 2>/dev/null || {
    log "エラー: 初回トークン取得に失敗しました"
    exit 1
}
log "初回トークン取得完了"

while true; do
    sleep "$UPDATE_INTERVAL"
    
    log "トークンを更新中..."
    if gcloud auth print-identity-token --audiences="${CLOUD_RUN_ML_URL}" | tr -d '\n' > "$TOKEN_FILE" 2>/dev/null; then
        log "トークン更新成功"
    else
        log "エラー: トークン更新に失敗しました（既存のトークンを保持します）"
    fi
done

