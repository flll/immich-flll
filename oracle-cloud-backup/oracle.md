# OCI CLI Token Does Not Refresh During Long Multipart Uploads

## Issue Summary

OCI CLI continues to use the same session token throughout long-running multipart upload operations, causing `401 NotAuthenticated` errors when the token expires after 60 minutes.

## Environment

- **OCI CLI**: oracle/oci-cli:20251029
- **Authentication**: `--auth security_token`
- **Operation**: `oci os object put` with multipart upload
- **File Size**: ~180GB (1463 parts @ 128MB)
- **Upload Duration**: 40+ minutes

## Problem Details

The CLI reads the session token from `security_token_file` once at startup and reuses it for all subsequent API calls throughout the entire upload operation, even when the operation exceeds the token's 60-minute validity period.

<details>
<summary>Actual command used (click to expand)</summary>

```sh
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

### Attempted Workaround: 30-Minute Session Refresh

To work around this issue, we implemented a script that runs `oci session refresh` every 30 minutes in the background, but **this did not solve the problem**.

<details>
<summary>Implemented refresh code (click to expand)</summary>

```bash
refresh_oci_session() {
    local refresh_interval=1800  # 30 minutes (1800 seconds)
    
    while true; do
        sleep "${refresh_interval}"
        
        print_info "Refreshing OCI session..."
        
        if docker run --rm \
            --user $(id -u):$(id -g) \
            -v "${OCI_CONFIG_DIR}:/oracle/.oci" \
            "${OCI_CLI_IMAGE}" \
            session refresh --region "${OCI_REGION}" >/dev/null 2>&1; then
            print_success "OCI session refresh completed"
        else
            print_warning "OCI session refresh failed"
        fi
    done
}
# Run in background
refresh_oci_session &
```

</details>

**Root cause**: Even though `oci session refresh` updates the `security_token_file`, **the already-running `oci os object put` process does not reload the updated token** and continues using the old token loaded at startup.

## Evidence from Logs

Throughout the 40-minute upload, all requests used the identical token:

```
Token issued: iat=1762488166 (04:23:06 UTC)
Token expires: exp=1762491766 (05:23:06 UTC) - 60 minutes later
First request: 04:23:06 GMT - Success
Last success: 05:02:XX GMT
First 401 error: 05:02:47 GMT - After ~40 minutes
```

All API calls contain the same `keyId="ST$eyJraWQiOi...` JWT token, confirming that no token refresh occurred.

## Real-World Use Case and Problem Flow

### Typical Large File Upload Flow

```r
[Step 1] Log in to OCI Console via browser and generate session token
    ↓
    Token issued: 2025-11-07 04:23:06 UTC
    Token expires: 2025-11-07 05:23:06 UTC (60 minutes later)
    Saved to security_token_file
    
[Step 2] Start oci os object put command
    ↓
    File size: 180GB
    Part size: 128MB
    → Split into 1463 parts total
    
[Step 3] Multipart upload processing (15 parallel)
    ↓
    Part 1/1463 upload - Using token ✓
    Part 2/1463 upload - Using SAME token ✓
    Part 3/1463 upload - Using SAME token ✓
    ...
    Part 800/1463 upload - Using SAME token ✓
    ...
    [~40 minutes elapsed - Token has 20 minutes remaining]
    ...
    Part 1200/1463 upload - Using SAME token ✓
    ...
    [60 minutes elapsed - Token expired]
    ↓
    Part 1349/1463 upload - 401 Unauthorized ✗
    Part 1350/1463 upload - 401 Unauthorized ✗
    
[Step 4] Upload failed
    ↓
    Error: NotAuthenticated
    Result: 263 parts incomplete, upload interrupted
    Time spent: ~40 minutes
```

### Core Problem

**All 1463 API calls use the same token loaded at startup**

- Token loading: **Once only** at process startup
- Token reloading: **None**
- Token expiration check: **None**
- Result: Any operation exceeding 60 minutes **will always fail**

---

## Proposed Solutions

**We request implementation of automatic token refresh in OCI CLI:**

1. **Automatic Token Refresh (Priority)**: Monitor JWT `exp` claim and automatically reload `security_token_file` before expiration (every 10-45 minutes)
2. **Configurable Token Lifetime**: Allow users to configure token lifetime via IAM policies (extend from 60 to 90-120 minutes)
3. **Improved Error Handling**: Automatically retry with updated token when 401 errors occur

**Why API Key Authentication is not acceptable**: Storing long-lived credentials on disk increases the attack surface. Session tokens are designed for temporary operations (like scheduled backups) and are the security-preferred method.

---

## Related Resources

- **Authentication Related Code**: https://github.com/search?q=repo%3Aoracle%2Foci-cli%20--auth%20security_token&type=code
- **Token Authentication Documentation**: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/clitoken.htm

**Affected Users**: Automated backup systems, low-bandwidth network environments, and all users performing operations lasting more than 60 minutes