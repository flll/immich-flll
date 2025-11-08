# OCI CLI: 長時間のマルチパートアップロード中にトークンがリフレッシュされない問題

## 問題の概要

OCI CLIは、長時間のマルチパートアップロード操作中に同一のセッショントークンを使い続けるため、トークンの有効期限（60分）が切れると`401 NotAuthenticated`エラーが発生します。

## 環境

- **OCI CLI**: 3.69.0
- **Python SDK**: 2.162.0
- **認証方式**: `--auth security_token`
- **操作**: `oci os object put` によるマルチパートアップロード
- **ファイルサイズ**: 約180GB（1463パーツ @ 128MB）
- **アップロード時間**: 40分以上

## 問題の詳細

CLIは起動時に`security_token_file`からセッショントークンを一度だけ読み込み、その後のすべてのAPIコール（アップロード操作全体）で同じトークンを再利用します。これは操作がトークンの60分間の有効期限を超える場合でも変わりません。

<details>
<summary>実際に使用したコマンド（クリックで展開）</summary>

```bash
docker run --rm \
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
    --no-overwrite \
    --part-size 128 \
    --parallel-upload-count 15 \
    --verify-checksum \
    --auth security_token \
    --region "${OCI_REGION}" \
    --debug 2>&1 | tee -a "${OCI_DIR}/last_backup.log"
```

</details>

### 回避策として実装した30分ごとのセッションリフレッシュ

この問題を回避するため、バックグラウンドで30分ごとに`oci session refresh`を実行するスクリプトを実装しましたが、**これでも問題は解決しませんでした**。

<details>
<summary>実装したリフレッシュコード（クリックで展開）</summary>

```bash
refresh_oci_session() {
    local refresh_interval=1800  # 30分（1800秒）
    
    while true; do
        sleep "${refresh_interval}"
        
        print_info "OCIセッションをリフレッシュしています..."
        
        if docker run --rm \
            --user $(id -u):$(id -g) \
            -v "${OCI_CONFIG_DIR}:/oracle/.oci" \
            "${OCI_CLI_IMAGE}" \
            session refresh --region "${OCI_REGION}" >/dev/null 2>&1; then
            print_success "OCIセッションのリフレッシュが完了しました"
        else
            print_warning "OCIセッションのリフレッシュに失敗しました"
        fi
    done
}
# バックグラウンドで実行
refresh_oci_session &
```

</details>

**問題点**: `oci session refresh`コマンドで`security_token_file`を更新しても、**すでに実行中の`oci os object put`プロセスは更新されたトークンを読み込まず**、起動時に読み込んだ古いトークンを使い続けます。

## ログからの証拠

40分間のアップロード全体で、すべてのリクエストが同一のトークンを使用していることを確認：

```
トークン発行時刻: iat=1762488166 (04:23:06 UTC)
トークン有効期限: exp=1762491766 (05:23:06 UTC) - 60分後
最初のリクエスト: 04:23:06 GMT - 成功
最後の成功: 05:02:XX GMT
最初の401エラー: 05:02:47 GMT - 開始から約40分後
```

すべてのAPIコールに同一の`keyId="ST$eyJraWQiOi...`というJWTトークンが含まれており、トークンのリフレッシュが一切行われなかったことが確認できます。

## 実際のユースケースと問題フロー

### 典型的な大容量ファイルアップロードのフロー

```
[ステップ1] ブラウザからOCIコンソールにログインしてセッショントークンを発行
    ↓
    トークン発行時刻: 2025-11-07 04:23:06 UTC
    トークン有効期限: 2025-11-07 05:23:06 UTC (60分後)
    security_token_fileに保存
    
[ステップ2] oci os object put コマンド実行開始
    ↓
    ファイルサイズ: 180GB
    パートサイズ: 128MB
    → 合計1463パーツに分割
    
[ステップ3] マルチパートアップロード処理（並列15）
    ↓
    パート 1/1463 をアップロード - トークン使用 ✓
    パート 2/1463 をアップロード - 同じトークン使用 ✓
    パート 3/1463 をアップロード - 同じトークン使用 ✓
    ...
    パート 800/1463 をアップロード - 同じトークン使用 ✓
    ...
    [約40分経過 - トークン残り20分]
    ...
    パート 1200/1463 をアップロード - 同じトークン使用 ✓
    ...
    [60分経過 - トークン期限切れ]
    ↓
    パート 1349/1463 をアップロード - 401 Unauthorized ✗
    パート 1350/1463 をアップロード - 401 Unauthorized ✗
    
[ステップ4] アップロード失敗
    ↓
    エラー: NotAuthenticated
    結果: 263パーツ未完了のまま処理中断
    所要時間: 約40分
```

### 問題の核心

**1463回のAPIコールすべてが起動時に読み込んだ同一トークンを使用**

- トークン読み込み: プロセス起動時の**1回のみ**
- トークンの再読み込み: **なし**
- トークンの有効期限チェック: **なし**
- 結果: 60分を超える処理は**必ず失敗する**

---

## 提案する解決策

**OCI CLI内に自動トークンリフレッシュの実装を要望します：**

1. **自動トークンリフレッシュ（最優先）**: JWTの`exp`クレームを監視し、有効期限前に`security_token_file`を自動再読み込み（10〜45分ごと）
2. **設定可能なトークン有効期限**: IAMポリシーでユーザーが有効期限を設定可能に（60分→90〜120分）
3. **改善されたエラーハンドリング**: 401エラー時に更新されたトークンで自動リトライ

**なぜAPIキー認証は不適切か**: 長期間有効な認証情報をディスクに保存することは攻撃面を増加させます。セッショントークンは一時的な操作（スケジュールバックアップ等）のために設計されており、セキュリティ上望ましい方法です。

---

## 関連リソース

- **OCI CLI リポジトリ**: https://github.com/oracle/oci-cli
- **認証関連コード**: https://github.com/search?q=repo%3Aoracle%2Foci-cli%20--auth%20security_token&type=code
- **トークン認証ドキュメント**: https://docs.oracle.com/ja-jp/iaas/Content/API/SDKDocs/clitoken.htm

**影響を受けるユーザー**: 自動バックアップシステム、低速ネットワーク環境、30分以上の長時間操作を行うすべてのユーザー