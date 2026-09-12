const remote = @import("../system/remote.zig");
pub fn status(r: remote.Remote) ![]const u8 {
    const result = try r.run(.status, "systemctl show dragontools-victoriametrics.service --property=LoadState,ActiveState,SubState,UnitFileState --no-pager");
    if (result.code != 0) return error.StatusFailed;
    // Do not echo arbitrary remote output or terminal control sequences.
    if (@import("std").mem.indexOf(u8, result.output, "LoadState=not-found") != null) return "VictoriaMetrics: not installed\n";
    if (@import("std").mem.indexOf(u8, result.output, "ActiveState=active\n") != null) return "VictoriaMetrics: active (run monitoring verify for health)\n";
    return "VictoriaMetrics: inactive or unhealthy (run monitoring verify)\n";
}
