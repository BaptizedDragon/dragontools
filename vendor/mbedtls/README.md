# Embedded crypto provenance

Pinned upstream release: **Mbed TLS 4.2.0**, including **TF-PSA-Crypto 1.2.0**.
Released 2026-07-07. Verified against the official release metadata, asset digest,
and locally hashed official archive on 2026-09-18.

* [Official release](https://github.com/Mbed-TLS/mbedtls/releases/tag/mbedtls-4.2.0)
* [Complete source archive](https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-4.2.0/mbedtls-4.2.0.tar.bz2)
* [Official checksum file](https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-4.2.0/mbedtls-4.2.0-sha256sum.txt)
* SHA-256: `2bed9d713b4668f76553b097e72b8aa30bc8f112a940d7ae228d524bbde6ffea`

This directory contains an unmodified source/header subset and both upstream
license files. `SHA256FILES.json` records every copied file. It excludes this
DragonTools provenance document and the manifest itself. No build downloads,
system crypto libraries, CMake, Perl, or Python generators are needed. The
official archive supplies generated and submodule content missing from GitHub's
automatic source snapshots.

`src/pki/build.zig` lists compiled translation units. Extra upstream headers and
source are retained for review but are not implicitly compiled. DragonTools'
checked-in `src/pki/crypto_config.h` and `tls_config.h` replace default configs:

| Feature | Reason |
| --- | --- |
| OS entropy, PSA RNG, CTR-DRBG | Local key and unpredictable serial generation |
| P-256, ECDSA, SHA-256 | The sole certificate/key/signature profile |
| PK, PEM, ASN.1, X.509 parse/write | Local keys, strict bounded CSRs and certificates |
| X.509 verification and time | Chain, self-signature, purpose and validity checks |
| ECDH, TLS 1.2, AES-128-GCM, TLS PRF | Narrow mTLS client; no inbound agent listener |
| TLS server support | Shared profile testing; no deployed Zig gateway |
| Version reporting | Compiled version guard and operator metadata |

RSA, other curves, weak hashes, TLS 1.3, CRLs, PKCS7, PSA persistent storage,
debug logging and external providers are disabled. A PSA RSA translation unit
supplies required unsupported-operation stubs; RSA algorithms remain disabled.
The 4.2.0 X.509 profile API checks legacy key-type IDs as well as signature IDs;
the single C binding imports the pinned private declaration for `ECKEY` solely
to constrain that profile correctly. DER policy independently requires P-256
and ECDSA/SHA-256.

Verify the checked-in copy:

```sh
python3 tools/verify_crypto_vendor.py
# Additionally compare each copied byte with a locally downloaded official archive:
python3 tools/verify_crypto_vendor.py --archive /path/to/mbedtls-4.2.0.tar.bz2
zig build test-pki
```

The code-reviewed minimum approved release is 4.2.0. A newer upstream release is
maintenance information, never permission for install/apply/verify to download or
upgrade crypto. Review upstream security notes, change pins/config/source
intentionally, rerun native PKI/TLS and lifecycle tests on Linux and macOS, then
release a matching controller and helper. A dated review is not a permanent
claim that any release is the latest or free of vulnerabilities.
