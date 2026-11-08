using Windows.Win32;
using Windows.Win32.Devices.Display;
using Windows.Win32.Foundation;

namespace TabStack.Platform.Windows;

/// <summary>
/// Maps GDI display names (<c>\.\DISPLAY1</c>, which can be renumbered when monitors are
/// plugged in again) to the monitor's device path from DISPLAYCONFIG, which stays the same
/// for the same monitor on the same port, plus its friendly name ("DELL U3423WE").
/// </summary>
static class DisplayIds
{
    static Dictionary<string, (string Id, string? Name)> map = new();
    static long refreshed;

    public static (string Id, string? Name) For(string gdiName)
    {
        // Re-query on a miss and at most every few seconds otherwise (displays changed).
        if (!map.ContainsKey(gdiName) || Environment.TickCount64 - refreshed > 5000)
        {
            try { map = Query(); }
            catch { /* keep the GDI name */ }
            refreshed = Environment.TickCount64;
        }
        return map.TryGetValue(gdiName, out var v) ? v : (gdiName, null);
    }

    static unsafe Dictionary<string, (string, string?)> Query()
    {
        var result = new Dictionary<string, (string, string?)>(StringComparer.OrdinalIgnoreCase);
        const QUERY_DISPLAY_CONFIG_FLAGS flags = QUERY_DISPLAY_CONFIG_FLAGS.QDC_ONLY_ACTIVE_PATHS;
        if (PInvoke.GetDisplayConfigBufferSizes(flags, out var pathCount, out var modeCount) != WIN32_ERROR.ERROR_SUCCESS) return result;
        var paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
        var modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
        fixed (DISPLAYCONFIG_PATH_INFO* pp = paths)
        fixed (DISPLAYCONFIG_MODE_INFO* pm = modes)
        {
            if (PInvoke.QueryDisplayConfig(flags, ref pathCount, pp, ref modeCount, pm, null) != WIN32_ERROR.ERROR_SUCCESS) return result;
        }
        for (var i = 0; i < pathCount; i++)
        {
            var path = paths[i];
            var source = new DISPLAYCONFIG_SOURCE_DEVICE_NAME();
            source.header.type = DISPLAYCONFIG_DEVICE_INFO_TYPE.DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
            source.header.size = (uint)sizeof(DISPLAYCONFIG_SOURCE_DEVICE_NAME);
            source.header.adapterId = path.sourceInfo.adapterId;
            source.header.id = path.sourceInfo.id;
            if (PInvoke.DisplayConfigGetDeviceInfo(&source.header) != 0) continue;

            var target = new DISPLAYCONFIG_TARGET_DEVICE_NAME();
            target.header.type = DISPLAYCONFIG_DEVICE_INFO_TYPE.DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
            target.header.size = (uint)sizeof(DISPLAYCONFIG_TARGET_DEVICE_NAME);
            target.header.adapterId = path.targetInfo.adapterId;
            target.header.id = path.targetInfo.id;
            if (PInvoke.DisplayConfigGetDeviceInfo(&target.header) != 0) continue;

            var gdi = source.viewGdiDeviceName.ToString();
            var id = target.monitorDevicePath.ToString();
            var name = target.monitorFriendlyDeviceName.ToString();
            // Mirrored displays share a source: the first monitor wins.
            if (id.Length > 0 && !result.ContainsKey(gdi)) result[gdi] = (id, name.Length > 0 ? name : null);
        }
        return result;
    }
}
