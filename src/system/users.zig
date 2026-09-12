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
