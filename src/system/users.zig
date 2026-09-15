pub const ensure_victoriametrics =
    \\set -eu
    \\if getent passwd dt-victoriametrics >/dev/null; then
    \\  test "$(getent passwd dt-victoriametrics | cut -d: -f7)" = /usr/sbin/nologin
    \\  test "$(getent passwd dt-victoriametrics | cut -d: -f6)" = /var/lib/dragontools/victoriametrics
    \\  test "$(id -u dt-victoriametrics)" -ne 0
    \\  test "$(id -gn dt-victoriametrics)" = dt-victoriametrics
    \\  printf unchanged
    \\else
    \\  getent group dt-victoriametrics >/dev/null && exit 41
    \\  useradd --system --user-group --home-dir /var/lib/dragontools/victoriametrics --no-create-home --shell /usr/sbin/nologin dt-victoriametrics
    \\  printf changed
    \\fi
;
pub const ensure_victorialogs =
    \\set -eu
    \\if getent passwd dt-victorialogs >/dev/null; then
    \\  test "$(getent passwd dt-victorialogs | cut -d: -f7)" = /usr/sbin/nologin || exit 41
    \\  test "$(getent passwd dt-victorialogs | cut -d: -f6)" = /var/lib/dragontools/victorialogs || exit 41
    \\  test "$(id -u dt-victorialogs)" -ne 0 || exit 41
    \\  test "$(id -gn dt-victorialogs)" = dt-victorialogs || exit 41
    \\  printf unchanged
    \\else
    \\  getent group dt-victorialogs >/dev/null && exit 41
    \\  useradd --system --user-group --home-dir /var/lib/dragontools/victorialogs --no-create-home --shell /usr/sbin/nologin dt-victorialogs
    \\  printf changed
    \\fi
;
