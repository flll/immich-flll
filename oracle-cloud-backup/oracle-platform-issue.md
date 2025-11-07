# Oracle Cloud Infrastructure - Session Token Lifetime Issue

## Report To
Oracle Cloud Infrastructure Platform / IAM Team

---

## Issue Summary

**Session Token Lifetime Too Short for Long-Running Operations**

The current 60-minute session token lifetime is insufficient for long-running operations such as large multipart uploads to Object Storage, especially when using Archive tier storage. This forces users to either:
1. Use API keys (security risk - persistent credentials on disk)
2. Implement complex token refresh mechanisms
3. Accept operation failures

---

## Environment

- **OCI Service**: Object Storage
- **Authentication Method**: Session Token (`--auth security_token`)
- **Storage Tier**: Archive
- **Operation**: Multipart Upload
- **File Size**: ~180GB
- **Part Size**: 128MB (1463 parts total)
- **Parallel Upload Count**: 15

---

## Detailed Problem Description

### What Happened

1. **Initial Upload Attempt**: 29 minutes
2. **Retry After Failure**: 29 minutes
3. **Total Elapsed Time**: 58 minutes (no token refresh)
4. **Token Expiration**: 60 minutes
5. **Result**: Authentication failure at minute 40-58

### Timeline Analysis

```
04:23:06 UTC - Session token issued
             - iat: 1762488166
             - exp: 1762491766 (60 minutes)
             - jti: 23ab9347-9e5d-44a4-8dcc-89f7cd5a7c74

04:23:06 UTC - Upload begins (1st attempt)
04:52:00 UTC - 1st attempt completes (~29 min)

04:52:00 UTC - 2nd attempt begins (retry)
05:21:00 UTC - 2nd attempt completes (~29 min)

05:02:47 UTC - 401 Unauthorized errors begin
05:23:06 UTC - Token expires
```

### Root Cause

**The 60-minute token lifetime is fundamentally incompatible with:**
- Archive tier uploads (slower than Standard tier)
- Large files requiring 1000+ multipart uploads
- Network variations and retries
- Any operation requiring > 45 minutes (safe margin needed)

---

## Evidence from Logs

### Token Details (From JWT)
```json
{
  "iat": 1762488166,
  "exp": 1762491766,
  "jti": "23ab9347-9e5d-44a4-8dcc-89f7cd5a7c74",
  "sess_exp": "Fri, 07 Nov 2025 10:53:27 UTC"
}
```

**Observations:**
- Access token: 60 minutes (3600 seconds)
- Session: ~6.5 hours
- **Problem**: Access token too short for multipart upload operation

### Error Messages
```
oci.exceptions.ServiceError: {
  'status': 401, 
  'code': 'NotAuthenticated', 
  'message': 'The required information to complete authentication was not provided.',
  'operation_name': 'upload_part',
  'timestamp': '2025-11-07T05:02:47.289107+00:00'
}
```

---

## Impact Assessment

### Affected Use Cases

1. **Automated Backup Systems**
   - Daily/weekly backups typically > 100GB
   - Cannot complete within 60 minutes
   - Security policies mandate temporary credentials

2. **Archive Storage Users**
   - Archive tier uploads are inherently slower
   - Cost-optimized storage requires longer upload times

3. **Large Dataset Transfers**
   - Scientific data, media files, database backups
   - Files > 100GB are common

4. **Organizations with Security Policies**
   - Prohibited from using persistent API keys
   - Require time-limited credentials
   - Cannot complete necessary operations

### User Impact

- **Security Compromise**: Users forced to use API keys despite security risks
- **Operational Failure**: Legitimate operations fail unexpectedly
- **Poor User Experience**: No warning when token approaches expiration
- **Increased Costs**: Failed uploads consume bandwidth and time

---

## Current Workarounds (All Unsatisfactory)

### 1. Use API Keys
**Problems:**
- ❌ Persistent credentials stored on disk
- ❌ Long-lived credentials = larger attack surface
- ❌ Violates principle of least privilege
- ❌ Rotation complexity
- ❌ Security compliance issues

### 2. Manual Token Refresh
**Problems:**
- ❌ Cannot refresh during active multipart upload
- ❌ Requires complex scripting
- ❌ Not user-friendly
- ❌ Still fails if operation takes > 45 minutes continuously

### 3. Split Large Files
**Problems:**
- ❌ Defeats purpose of multipart upload
- ❌ Increased complexity
- ❌ Not always feasible

---

## Proposed Solutions

### Option 1: Increase Default Token Lifetime ⭐ **Recommended**

**Change default from 60 minutes to 120-180 minutes**

**Pros:**
- ✅ Solves most use cases immediately
- ✅ No code changes required
- ✅ Backward compatible
- ✅ Simple implementation

**Cons:**
- ⚠️ Slightly increased security window (still temporary)

**Recommendation**: 120 minutes as a reasonable balance

---

### Option 2: User-Configurable Token Lifetime ⭐ **Ideal**

**Allow users to configure session token lifetime via IAM policies**

Example policy:
```json
{
  "name": "long-running-operations-policy",
  "statements": [
    {
      "effect": "allow",
      "actions": ["objectstorage:*"],
      "resources": ["*"],
      "sessionTokenLifetime": "180m"
    }
  ]
}
```

**Pros:**
- ✅ Maximum flexibility
- ✅ Users can balance security vs. operational needs
- ✅ Different policies for different operations
- ✅ Enterprise-friendly

**Cons:**
- ⚠️ Requires IAM policy engine changes
- ⚠️ More complex implementation

---

### Option 3: Operation-Specific Token Extensions

**Automatically extend token lifetime for specific long-running operations**

- Object Storage multipart uploads: +60 minutes
- Database backups: +120 minutes
- Large file operations: dynamic based on file size

**Pros:**
- ✅ Intelligent, context-aware
- ✅ No user configuration needed
- ✅ Secure (only extends when needed)

**Cons:**
- ⚠️ Complex implementation
- ⚠️ Requires operation detection logic

---

## Security Considerations

### Why Session Tokens Should Be Preferred

**Session Tokens (Temporary):**
- ✅ Time-limited exposure (even with 120 min)
- ✅ MFA-protected at issuance
- ✅ Automatic expiration
- ✅ No persistent storage required
- ✅ Better audit trail

**API Keys (Persistent):**
- ❌ Indefinite exposure if compromised
- ❌ Stored permanently on disk
- ❌ No MFA enforcement
- ❌ Manual rotation required
- ❌ Forgotten keys remain active

### Proposed Security Balance

Even with 120-180 minute tokens:
- Still temporary (vs. indefinite API keys)
- Still time-limited
- Still better than persistent credentials
- Enables security-conscious users to avoid API keys

---

## Comparison with Other Cloud Providers

| Provider | Default Token Lifetime | Configurable | Max Lifetime |
|----------|----------------------|--------------|--------------|
| **OCI** | 60 minutes | ❌ No | 60 minutes |
| AWS | 60 minutes | ✅ Yes | 12 hours |
| Azure | 60-90 minutes | ✅ Yes | 24 hours |
| GCP | 60 minutes | ✅ Yes | 12 hours |

**OCI is behind industry standards in token lifetime flexibility.**

---

## Requested Changes

We respectfully request Oracle to implement **one or more** of the following:

1. **Immediate Fix** (High Priority):
   - Increase default session token lifetime to 120 minutes

2. **Short-term Enhancement** (High Priority):
   - Make token lifetime user-configurable via IAM policies
   - Range: 60-240 minutes

3. **Long-term Enhancement** (Medium Priority):
   - Implement automatic token lifetime extension for long-running operations
   - Add token expiration warnings in CLI

4. **Documentation** (Low Priority):
   - Document current limitations
   - Provide best practices for long-running operations
   - Clarify trade-offs between API keys and session tokens

---

## Business Impact

### Customer Satisfaction
- Reduced frustration with failed operations
- Better security posture
- Improved user experience

### Competitive Position
- Match or exceed other cloud providers
- Enable security-conscious customers
- Support modern backup/archival use cases

### Security Improvement
- Fewer users forced to use API keys
- Better alignment with security best practices
- Support for zero-trust architectures

---

## References

- [OCI Token-Based Authentication](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/clitoken.htm)
- [Token Expiration Table](https://docs.oracle.com/en-us/iaas/Content/Identity/api-getstarted/TokenExpiryTable.htm)
- [Related Issue: oracle/oci-cli#68](https://github.com/oracle/oci-cli/issues/68)
- [Related Issue: oracle/oci-cli#514](https://github.com/oracle/oci-cli/issues/514)

---

## Contact Information

This issue affects automated backup operations where:
- Security policies mandate temporary credentials
- Large files (100-200GB+) are common
- Archive storage tier is used for cost optimization
- Operations legitimately require 60-120 minutes

Additional logs and evidence are available upon request.

---

**Thank you for considering this enhancement. We believe addressing this issue will significantly improve OCI's security posture and user experience for long-running operations.**

