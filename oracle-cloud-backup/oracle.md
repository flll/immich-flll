# OCI CLI Token Does Not Refresh During Long Multipart Uploads

## Issue Summary

OCI CLI continues to use the same session token throughout a long-running multipart upload operation, causing `401 NotAuthenticated` errors when the token expires (60 minutes).

## Environment

- **OCI CLI**: 3.69.0
- **Python SDK**: 2.162.0
- **Authentication**: `--auth security_token`
- **Operation**: `oci os object put` with multipart upload
- **File Size**: ~180GB (1463 parts @ 128MB)
- **Upload Duration**: 40+ minutes

## Problem

The CLI reads the session token from `security_token_file` once at startup and reuses it for all subsequent API calls during the entire upload operation, even when the operation exceeds the token's 60-minute validity period.

## Evidence from Logs

All requests throughout the 40-minute upload use the identical token:

```
Token issued: iat=1762488166 (04:23:06 UTC)
Token expires: exp=1762491766 (05:23:06 UTC) - 60 minutes later
First request: 04:23:06 GMT - Success
Last success: 05:02:XX GMT
First 401 error: 05:02:47 GMT - After ~40 minutes
```

All API calls contain the same `keyId="ST$eyJraWQiOi...` JWT token, confirming no token refresh occurred.

## Root Cause Analysis

### Scenario: Upload Failure + Retry

1. Initial upload runs for 29 minutes → Fails for unrelated reason
2. Script retries immediately, continuing with same token
3. Retry runs for another 29 minutes
4. **Total time: 58 minutes with same token**
5. Token expires at 60 minutes → 401 errors occur

The CLI does not:
- Monitor token expiration time
- Refresh the token from `security_token_file` during operation
- Implement automatic token refresh for long operations

## Proposed Solutions

### Option 1: Automatic Token Refresh (Preferred)
Implement automatic token refresh within OCI CLI:
- Monitor token expiration (`exp` claim in JWT)
- Automatically re-read `security_token_file` before expiration
- Refresh tokens proactively (e.g., every 10-45 minutes)

### Option 2: Configurable Token Lifetime
Allow users to configure session token lifetime via IAM policies:
- Extend default from 60 minutes to 90-120 minutes
- Provide flexibility based on security requirements

### Option 3: Better Error Handling
When a 401 error occurs:
- Check if `security_token_file` has been updated
- Retry the failed operation with the new token
- Provide clear guidance to users

## Security Impact

**Why API Key Authentication is NOT an acceptable workaround:**
- Requires storing long-lived credentials on disk
- Increases attack surface significantly
- Session tokens are specifically designed for temporary operations like scheduled backups

## Request

Please implement automatic token refresh in OCI CLI for long-running operations. This would:
- Improve security by allowing continued use of temporary credentials
- Support legitimate use cases (large backups, slow network connections)
- Eliminate workarounds that compromise security

## Related Issues

- oracle/oci-cli#68 - Not able to access buckets/objects
- oracle/oci-cli#514 - OCI Authentication Error

## Additional Context

This issue particularly affects:
- Automated backup systems using session tokens
- Uploads to Archive storage tier (slower than Standard)
- Networks with limited bandwidth
- Any operation exceeding 30-40 minutes

A 10-minute token refresh interval would completely resolve this issue while maintaining security.
