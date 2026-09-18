const std = @import("std");

/// Explicit reviewed source list: no RSA, alternative curves/drivers, PSA
/// persistence, PKCS7, TLS 1.3, debug, test or generated-at-build dependencies.
pub fn link(b: *std.Build, module: *std.Build.Module) void {
    module.link_libc = true;
    module.addCMacro("MBEDTLS_CONFIG_FILE", "\"tls_config.h\"");
    module.addCMacro("TF_PSA_CRYPTO_CONFIG_FILE", "\"crypto_config.h\"");
    module.addIncludePath(b.path("src/pki"));
    for ([_][]const u8{
        "include",                               "library",                           "tf-psa-crypto/include", "tf-psa-crypto/core",
        "tf-psa-crypto/platform",                "tf-psa-crypto/utilities",           "tf-psa-crypto/extras",  "tf-psa-crypto/dispatch",
        "tf-psa-crypto/drivers/builtin/include", "tf-psa-crypto/drivers/builtin/src",
    }) |path| module.addIncludePath(b.path(b.fmt("vendor/mbedtls/{s}", .{path})));
    module.addCSourceFiles(.{
        .root = b.path("vendor/mbedtls"),
        .flags = &.{ "-std=c99", "-D_POSIX_C_SOURCE=200809L", "-fno-strict-aliasing", "-fstack-protector-strong" },
        .files = &.{
            "library/mbedtls_config.c",                                  "library/x509.c",                                        "library/x509_create.c",
            "library/x509_crt.c",                                        "library/x509_csr.c",                                    "library/x509_oid.c",
            "library/x509write.c",                                       "library/x509write_crt.c",                               "library/x509write_csr.c",
            "library/net_sockets.c",                                     "library/ssl_ciphersuites.c",                            "library/ssl_client.c",
            "library/ssl_msg.c",                                         "library/ssl_tls.c",                                     "library/ssl_tls12_client.c",
            "library/ssl_tls12_server.c",                                "library/version.c",                                     "tf-psa-crypto/core/tf_psa_crypto_config.c",
            "tf-psa-crypto/core/tf_psa_crypto_version.c",                "tf-psa-crypto/core/psa_crypto.c",                       "tf-psa-crypto/core/psa_crypto_client.c",
            "tf-psa-crypto/core/psa_crypto_driver_wrappers_no_static.c", "tf-psa-crypto/core/psa_crypto_slot_management.c",       "tf-psa-crypto/core/psa_crypto_random.c",
            "tf-psa-crypto/core/psa_util.c",                             "tf-psa-crypto/platform/platform.c",                     "tf-psa-crypto/platform/platform_util.c",
            "tf-psa-crypto/extras/pk.c",                                 "tf-psa-crypto/extras/pk_ecc.c",                         "tf-psa-crypto/extras/pk_wrap.c",
            "tf-psa-crypto/extras/pkparse.c",                            "tf-psa-crypto/extras/pkwrite.c",                        "tf-psa-crypto/extras/md.c",
            "tf-psa-crypto/utilities/asn1parse.c",                       "tf-psa-crypto/utilities/asn1write.c",                   "tf-psa-crypto/utilities/base64.c",
            "tf-psa-crypto/utilities/constant_time.c",                   "tf-psa-crypto/utilities/oid.c",                         "tf-psa-crypto/utilities/pem.c",
            "tf-psa-crypto/drivers/builtin/src/aes.c",                   "tf-psa-crypto/drivers/builtin/src/block_cipher.c",      "tf-psa-crypto/drivers/builtin/src/bignum.c",
            "tf-psa-crypto/drivers/builtin/src/bignum_core.c",           "tf-psa-crypto/drivers/builtin/src/bignum_mod.c",        "tf-psa-crypto/drivers/builtin/src/bignum_mod_raw.c",
            "tf-psa-crypto/drivers/builtin/src/ctr_drbg.c",              "tf-psa-crypto/drivers/builtin/src/entropy.c",           "tf-psa-crypto/drivers/builtin/src/entropy_poll.c",
            "tf-psa-crypto/drivers/builtin/src/ecdsa.c",                 "tf-psa-crypto/drivers/builtin/src/ecp.c",               "tf-psa-crypto/drivers/builtin/src/ecp_curves.c",
            "tf-psa-crypto/drivers/builtin/src/gcm.c",                   "tf-psa-crypto/drivers/builtin/src/sha256.c",            "tf-psa-crypto/drivers/builtin/src/psa_crypto_aead.c",
            "tf-psa-crypto/drivers/builtin/src/psa_crypto_cipher.c",     "tf-psa-crypto/drivers/builtin/src/psa_crypto_ecp.c",    "tf-psa-crypto/drivers/builtin/src/psa_crypto_hash.c",
            "tf-psa-crypto/drivers/builtin/src/psa_crypto_mac.c",        "tf-psa-crypto/drivers/builtin/src/psa_util_internal.c",
            // PSA's unconditional asymmetric entry points require these
            // not-supported stubs; RSA algorithms themselves stay disabled.
            "tf-psa-crypto/drivers/builtin/src/psa_crypto_rsa.c",
        },
    });
}
