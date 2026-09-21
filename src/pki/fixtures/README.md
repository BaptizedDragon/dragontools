# Public test fixtures — never production credentials

These disposable keys and certificates are intentionally public test data.
They were generated locally with OpenSSL 3.6.3 on 2026-09-18, with
`OPENSSL_CONF=/dev/null`, using the prior DragonTools P-256/SHA-256 profile.
The root is self-signed with critical CA:TRUE,pathlen:0 and keyCertSign,cRLSign.
Leaves have critical CA:FALSE, digitalSignature, the appropriate EKU, and fixed
DNS/IP or `dragontools://hosts/dt-0123456789abcdef0123456789abcdef` SANs.
They exercise PKCS#8 private keys and OpenSSL's SKI/AKI extensions without any
OpenSSL executable dependency in native tests. Tests use the fixture's validity
start plus one second, so they do not depend on wall-clock expiry.

The RSA and P-384 CSRs are signed, syntactically valid negative fixtures. Their
private keys were discarded. They must be rejected by the native P-256 policy.
The server CSR requests DNS/IP and is also a negative client-CSR fixture.
