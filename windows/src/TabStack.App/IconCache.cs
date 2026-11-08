using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace TabStack.App;

/// <summary>App icons by exe path, extracted once.</summary>
static class IconCache
{
    static readonly Dictionary<string, ImageSource?> cache = new(StringComparer.OrdinalIgnoreCase);

    public static ImageSource? For(string? exe)
    {
        if (string.IsNullOrEmpty(exe)) return null;
        if (cache.TryGetValue(exe, out var img)) return img;
        img = null;
        try
        {
            using var icon = System.Drawing.Icon.ExtractAssociatedIcon(exe);
            if (icon is not null)
            {
                img = Imaging.CreateBitmapSourceFromHIcon(icon.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                img.Freeze();
            }
        }
        catch (Exception e) when (e is ArgumentException or IOException or System.ComponentModel.Win32Exception) { }
        cache[exe] = img;
        return img;
    }
}
