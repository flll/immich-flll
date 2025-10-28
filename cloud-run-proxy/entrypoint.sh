#!/bin/bash -e

if [ -f /secrets/service-account-key.json ]; then
  gcloud auth activate-service-account --key-file=/secrets/service-account-key.json
  echo "サービスアカウント認証成功"
else
  echo "エラー: サービスアカウントキーが見つかりません"
  exit 1
fi

if [ -z "$CLOUD_RUN_ML_URL" ]; then
  echo "エラー: CLOUD_RUN_ML_URL環境変数が設定されていません"
  exit 1
fi
echo "Cloud Run URL: $CLOUD_RUN_ML_URL"

envsubst '${CLOUD_RUN_ML_URL}' < /cloud-run-proxy/nginx.conf.template > /etc/nginx/nginx.conf

/cloud-run-proxy/token-updater.sh &

echo "初回トークン取得..."
for i in {1..30}; do
  if [ -f /tmp/gcloud_token ] && [ -s /tmp/gcloud_token ]; then
    echo "初回トークン取得完了"
    break
  fi
  sleep 1
done

if [ ! -f /tmp/gcloud_token ] || [ ! -s /tmp/gcloud_token ]; then
  echo "エラー: 初回トークン取得に失敗しました"
  kill $TOKEN_UPDATER_PID 2>/dev/null || true
  exit 1
fi

echo "nginxを起動中（ポート3003）..."
exec nginx -c /etc/nginx/nginx.conf -g "daemon off;"
