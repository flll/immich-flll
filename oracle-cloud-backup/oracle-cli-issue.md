# OCI CLI - Token Refresh Not Implemented for Long-Running Operations

## Report To
Oracle OCI CLI Development Team (GitHub: oracle/oci-cli)

---

## Issue Title
**OCI CLI Does Not Refresh Session Tokens During Long-Running Multipart Uploads**

---

## Issue Summary

The OCI CLI (`oci os object put`) does not automatically refresh session tokens during long-running multipart uploads, causing authentication failures when operations exceed the token lifetime. The CLI uses the same token throughout the entire operation, even when the token approaches expiration.

---

## Environment

- **OCI CLI Version**: 3.69.0
- **Oracle Python SDK Version**: 2.162.0
- **Python Version**: 3.9.20
- **Platform**: Linux x86_64 (Docker container)
- **Container Image**: `ghcr.io/oracle/oci-cli:latest`
- **Authentication Method**: `--auth security_token`
- **Operation**: `oci os object put` with multipart upload

---

## Steps to Reproduce

1. Authenticate using session token:
```bash
oci session authenticate --region us-ashburn-1
```

2. Start a large multipart upload that takes > 45 minutes:
```bash
docker run --rm \
    -v "${OCI_CONFIG_DIR}:/oracle/.oci" \
    -v "${TEMP_DIR}:/backup" \
    ghcr.io/oracle/oci-cli:latest \
    os object put \
    --bucket-name my-bucket \
    --namespace my-namespace \
    --file /backup/large-file.tar.gz.enc \
    --name large-file.tar.gz.enc \
    --storage-tier Archive \
    --part-size 128 \
    --parallel-upload-count 15 \
    --auth security_token \
    --region us-ashburn-1 \
    --debug
```

3. Observe that upload begins successfully but fails after ~40-50 minutes with 401 errors

---

## Expected Behavior

The CLI should:
1. Monitor the session token expiration time
2. Automatically refresh the token before it expires (e.g., at 45 minutes for a 60-minute token)
3. Use the refreshed token for subsequent upload_part operations
4. Continue the multipart upload without interruption

---

## Actual Behavior

The CLI:
1. ❌ Uses the same token for the entire operation
2. ❌ Does not monitor token expiration
3. ❌ Does not attempt to refresh the token
4. ❌ Fails with 401 errors when token expires

---

## Evidence from Debug Logs

### Token Used Throughout Operation

All HTTP requests use the **same token ID** (`jti`):

**Initial Request (04:23:06 UTC):**
```
keyId="ST$eyJ...{
  "iat": 1762488166,
  "exp": 1762491766,
  "jti": "23ab9347-9e5d-44a4-8dcc-89f7cd5a7c74"
}..."
```

**Request at 04:30:00 UTC (~7 minutes later):**
```
keyId="ST$eyJ...{
  "jti": "23ab9347-9e5d-44a4-8dcc-89f7cd5a7c74"
}..."
```

**Request at 05:00:00 UTC (~37 minutes later):**
```
keyId="ST$eyJ...{
  "jti": "23ab9347-9e5d-44a4-8dcc-89f7cd5a7c74"
}..."
```

**Same `jti` value proves no token refresh occurred.**

### Error When Token Expires

```
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Casper realm="AUTH_casper"

oci.exceptions.ServiceError: {
  'status': 401, 
  'code': 'NotAuthenticated', 
  'message': 'The required information to complete authentication was not provided.',
  'operation_name': 'upload_part',
  'timestamp': '2025-11-07T05:02:47.289107+00:00'
}
```

### Timeline

```
04:23:06 UTC - Token issued (exp: 05:23:06)
04:23:06 UTC - Upload begins
04:52:00 UTC - First upload completes (~29 min)
04:52:00 UTC - Retry begins
05:02:47 UTC - 401 errors start appearing
05:21:00 UTC - Second upload completes (~29 min)
05:23:06 UTC - Token expires

Total time without refresh: 58 minutes
Token lifetime: 60 minutes
Result: Authentication failure
```

---

## Root Cause Analysis

### Code Path Investigation

Based on the error traceback and SDK behavior:

```python
# File: oci/object_storage/transfer/internal/multipart_object_assembler.py
# Line 608: upload method

def upload(self, retry_strategy=None, progress_callback=None):
    # Multipart upload starts
    pool.map(lambda part_tuple: self._upload_part(...))
    # Each part uses the SAME token from initial authentication
    # No token refresh logic exists
```

### Problem

1. **Token loaded once**: At CLI initialization
2. **No expiration monitoring**: CLI doesn't check `exp` field
3. **No refresh logic**: No code path to obtain new token
4. **Long-running operations**: Multipart uploads can exceed token lifetime

---

## Impact

### Affected Operations

All long-running CLI operations with session tokens:
- ✗ Large multipart uploads (> 45 minutes)
- ✗ Bulk file operations
- ✗ Database export/import
- ✗ Any operation exceeding 45 minutes (safe margin)

### User Impact

1. **Unexpected Failures**: Operations fail without warning
2. **Wasted Resources**: Time, bandwidth, and compute wasted
3. **Poor User Experience**: Users must manually manage tokens
4. **Security vs. Usability**: Users forced to choose API keys over secure tokens

---

## Proposed Solutions

### Solution 1: Automatic Token Refresh ⭐ **Recommended**

Implement automatic token refresh in the CLI:

```python
class SessionTokenRefresher:
    def __init__(self, config, refresh_margin=900):  # 15 min margin
        self.config = config
        self.refresh_margin = refresh_margin
        self.current_token = None
        self.token_expiry = None
    
    def get_token(self):
        if self.needs_refresh():
            self.refresh_token()
        return self.current_token
    
    def needs_refresh(self):
        if not self.token_expiry:
            return True
        time_until_expiry = self.token_expiry - time.time()
        return time_until_expiry < self.refresh_margin
    
    def refresh_token(self):
        # Call session refresh endpoint
        # Update self.current_token and self.token_expiry
        pass
```

**Benefits:**
- ✅ Transparent to users
- ✅ Works for all long-running operations
- ✅ Maintains security (still uses session tokens)
- ✅ No user code changes required

---

### Solution 2: Token Expiration Warnings

Add warnings when token is approaching expiration:

```
WARNING: Session token will expire in 10 minutes
Consider refreshing token for long-running operations
Run: oci session refresh
```

**Benefits:**
- ✅ User awareness
- ✅ Simple implementation
- ✅ Backward compatible

**Limitations:**
- ⚠️ Manual intervention required
- ⚠️ Cannot refresh during active multipart upload

---

### Solution 3: Pre-Upload Validation

Check token lifetime before starting large uploads:

```python
def validate_token_lifetime(file_size, token_expiry):
    estimated_time = estimate_upload_time(file_size)
    time_until_expiry = token_expiry - time.time()
    
    if estimated_time > time_until_expiry:
        raise TokenLifetimeError(
            f"Upload estimated at {estimated_time}s but token expires in {time_until_expiry}s"
        )
```

**Benefits:**
- ✅ Fail-fast approach
- ✅ Clear error message
- ✅ Saves wasted upload time

**Limitations:**
- ⚠️ Estimation may be inaccurate
- ⚠️ Still requires manual intervention

---

### Solution 4: Multipart Upload Resume

Implement resume capability for failed uploads:

```bash
# Upload fails at part 1200/1463
# CLI saves state to ~/.oci/uploads/upload_id.state

# User refreshes token
oci session refresh

# Resume upload
oci os object put --resume upload_id
```

**Benefits:**
- ✅ No wasted work
- ✅ Handles any interruption
- ✅ User-controlled

**Limitations:**
- ⚠️ Complex implementation
- ⚠️ State management required

---

## Recommended Implementation Priority

### Phase 1: Immediate (High Priority)
1. **Token expiration warnings** - Simple, helps users immediately
2. **Pre-upload validation** - Fail-fast, clear error messages

### Phase 2: Short-term (High Priority)
3. **Automatic token refresh** - Solves root cause
4. **Documentation updates** - Document limitations and workarounds

### Phase 3: Long-term (Medium Priority)
5. **Multipart upload resume** - Robustness improvement
6. **Token lifetime configuration** - User control

---

## Code Changes Required

### Files to Modify

1. `oci_cli/cli_util.py`
   - Add token expiration monitoring
   - Add token refresh logic

2. `oci/auth/security_token_signer.py`
   - Implement automatic refresh
   - Add expiration tracking

3. `oci/object_storage/transfer/internal/multipart_object_assembler.py`
   - Inject token refresher
   - Check token before each part upload

4. `services/object_storage/src/oci_cli_object_storage/objectstorage_cli_extended.py`
   - Add pre-upload validation
   - Add expiration warnings

---

## Comparison with Other CLI Tools

| CLI Tool | Auto Token Refresh | Warning | Pre-flight Check |
|----------|-------------------|---------|------------------|
| **OCI CLI** | ❌ No | ❌ No | ❌ No |
| AWS CLI | ✅ Yes | ✅ Yes | ⚠️ Partial |
| Azure CLI | ✅ Yes | ✅ Yes | ✅ Yes |
| GCP CLI | ✅ Yes | ✅ Yes | ✅ Yes |

**OCI CLI lags behind other major cloud CLIs in token lifecycle management.**

---

## Testing Recommendations

### Test Cases

1. **Basic Refresh Test**
   - Upload file taking 70 minutes
   - Verify token refreshes at 45 minutes
   - Verify upload completes successfully

2. **Multiple Refresh Test**
   - Upload file taking 130 minutes
   - Verify multiple refreshes occur
   - Verify upload completes successfully

3. **Refresh Failure Test**
   - Simulate refresh failure
   - Verify graceful error handling
   - Verify clear error message

4. **Edge Cases**
   - Token expires during refresh
   - Network interruption during refresh
   - Concurrent operations with shared token

---

## Related Issues

- [#68 - Not able to access buckets/objects from OCI CLI](https://github.com/oracle/oci-cli/issues/68)
- [#514 - OCI Authentication Error](https://github.com/oracle/oci-cli/issues/514)

These issues report 401 authentication errors, likely related to the same root cause.

---

## Minimal Reproduction Script

```bash
#!/bin/bash

# Create a large test file (10GB)
dd if=/dev/zero of=large-test-file.bin bs=1M count=10240

# Authenticate with session token
oci session authenticate

# Start upload (will fail after ~45 minutes)
oci os object put \
    --bucket-name test-bucket \
    --namespace test-namespace \
    --file large-test-file.bin \
    --name large-test-file.bin \
    --storage-tier Archive \
    --part-size 128 \
    --parallel-upload-count 15 \
    --auth security_token \
    --debug 2>&1 | tee upload.log

# Check for 401 errors
grep "401 Unauthorized" upload.log
```

---

## Additional Context

This issue affects users who:
- Follow security best practices (prefer session tokens over API keys)
- Upload large files (> 100GB)
- Use Archive storage tier (slower uploads)
- Run automated backup operations
- Have organizational security policies prohibiting persistent credentials

---

## Requested Actions

We respectfully request the OCI CLI team to:

1. **Acknowledge** this issue as a legitimate bug/limitation
2. **Prioritize** implementation of automatic token refresh
3. **Provide** a timeline for fix/enhancement
4. **Document** current limitations in official documentation
5. **Consider** the proposed solutions outlined above

---

## Contact

Full debug logs and additional evidence available upon request.

**Thank you for maintaining OCI CLI. We believe this enhancement will significantly improve the tool's usability and security posture.**

