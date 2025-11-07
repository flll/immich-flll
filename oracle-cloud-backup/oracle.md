**Security Token Authentication Times Out During Long Multipart Uploads**

---

## Issue Description

When uploading large files to OCI Object Storage using `oci os object put` with `--auth security_token`, the authentication fails with a `401 NotAuthenticated` error during long-running multipart uploads.

## Environment

- **OCI CLI Version**: 3.69.0
- **Python SDK Version**: 2.162.0
- **Authentication Method**: `--auth security_token`
- **Storage Tier**: Archive
- **File Size**: ~180GB (resulting in 1400+ parts with 128MB part size)
- **Upload Duration**: 40+ minutes before failure

## Steps to Reproduce

1. Authenticate using security token (session token from web console)
2. Start a large multipart upload to Archive storage tier:

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
    --part-size 128 \
    --parallel-upload-count 15 \
    --auth security_token \
    --region "${OCI_REGION}" \
    --debug
```

3. Upload begins successfully but fails after ~30-40 minutes with 401 errors on individual upload_part operations

## Error Message

```
oci.exceptions.ServiceError: {
  'target_service': 'object_storage', 
  'status': 401, 
  'code': 'NotAuthenticated', 
  'opc-request-id': 'iad-1:fPhKAyW3D3LZ8bF7Rnd5ip6nP6hMbATmDX6J2SZAXaSAj4AuC2wBcfFS0QZBUlAX', 
  'message': 'The required information to complete authentication was not provided.',
  'operation_name': 'upload_part', 
  'timestamp': '2025-11-07T05:02:47.289107+00:00'
}
```

## Current Behavior

- Security token expires or becomes invalid during the upload (typically after 30-40 minutes)
- Individual `upload_part` operations fail with HTTP 401 even though the session token's `sess_exp` time has not been reached
- The multipart upload cannot complete for large files
- This affects Archive tier uploads particularly, as they tend to be slower than Standard tier

## Expected Behavior

One of the following solutions would address this issue:

### 1. **Token Lifetime Extension** (Preferred)
Allow session tokens to remain valid for longer periods (e.g., 60-90 minutes minimum) to accommodate long-running operations like large multipart uploads.

### 2. **Configurable Token Policy** (Ideal)
Allow users to configure session token lifetime through IAM policies based on their security requirements and use cases. For example:

```json
{
  "sessionTokenLifetime": "120m",
  "allowedOperations": ["objectstorage:*"]
}
```

### 3. **Automatic Token Refresh**
Implement an automatic token refresh mechanism in the OCI CLI for long-running operations, similar to how other cloud providers handle this.

### 4. **Better Documentation**
Document the recommended authentication method and limitations for long-running uploads, including guidance on when to use API keys vs. session tokens.

## Security Concerns

**Why API Key Authentication is Not an Acceptable Workaround:**

While API key authentication is often suggested as a workaround, it poses significant security risks:

1. **Persistent Credentials**: API keys are long-lived credentials that, if compromised, provide persistent access to the tenancy
2. **Storage Risk**: Storing private keys on disk (especially in automated backup systems) increases the attack surface
3. **Rotation Complexity**: API key rotation requires updating multiple systems and configurations
4. **Audit Trail**: Session tokens provide better audit trails for temporary operations

**Why Session Tokens are Superior for This Use Case:**

1. **Time-Limited**: Session tokens automatically expire, limiting the window of vulnerability
2. **Temporary Access**: Perfect for scheduled backup operations that run and complete
3. **No Persistent Storage**: No need to store long-lived credentials on the system
4. **Principle of Least Privilege**: Can be issued with specific, limited permissions

## Impact

This issue affects:
- Automated backup systems using session tokens
- Large file uploads (>100GB) to Archive storage
- Users following security best practices by avoiding persistent API keys
- Organizations with strict security policies requiring temporary credentials

## Workaround (Current)

The only current workaround is to use API key authentication, which requires:
```bash
--auth api_key
```

However, this compromises security by requiring persistent storage of private keys.

## Proposed Solution

**We respectfully request that Oracle implement one or more of the following:**

1. **Increase the default session token lifetime** from 30-40 minutes to at least 60-90 minutes for operations involving Object Storage multipart uploads
2. **Make session token lifetime configurable** through IAM policies, allowing administrators to balance security and operational needs
3. **Implement automatic token refresh** within the CLI for long-running operations
4. **Add a specific authentication mode** for long-running operations that uses refresh tokens

## Related Issues

- oracle/oci-cli#68 - Not able to access buckets/objects from OCI CLI
- oracle/oci-cli#514 - OCI Authentication Error

## Additional Context

This issue was discovered during automated backup operations where:
- Backups run on a schedule (daily/weekly)
- Files are typically 100-200GB in size
- Archive storage tier is used for cost optimization
- Security policies mandate the use of temporary credentials over persistent API keys

We believe this is a common use case that affects many OCI users who prioritize security.

---

## Contact Information

This issue was reported by a user implementing automated backup solutions with security best practices in mind. If additional information or logs are needed, please let us know.

Thank you for considering this enhancement request. We believe addressing this issue will significantly improve the security posture of automated backup and large file upload operations on OCI.

