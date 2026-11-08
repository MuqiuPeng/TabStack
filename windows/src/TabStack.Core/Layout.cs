namespace TabStack.Core;

/// <summary>A display as the platform reports it (physical pixels).</summary>
public sealed record MonitorInfo(string Device, Rect Bounds, Rect WorkArea, int Dpi, bool Primary);

/// <summary>Geometry for restoring a saved placement on the displays that exist now.</summary>
public static class LayoutMath
{
    public static int Right(this Rect r) => r.X + r.W;
    public static int Bottom(this Rect r) => r.Y + r.H;

    public static long Overlap(Rect a, Rect b)
    {
        long w = Math.Min(a.Right(), b.Right()) - Math.Max(a.X, b.X);
        long h = Math.Min(a.Bottom(), b.Bottom()) - Math.Max(a.Y, b.Y);
        return w > 0 && h > 0 ? w * h : 0;
    }

    /// <summary>The monitor a rectangle mostly lies on; the nearest one when it lies on none
    /// (MonitorFromRect with MONITOR_DEFAULTTONEAREST).</summary>
    public static MonitorInfo Nearest(Rect r, IReadOnlyList<MonitorInfo> monitors)
    {
        var best = monitors.MaxBy(m => Overlap(r, m.Bounds))!;
        if (Overlap(r, best.Bounds) > 0) return best;
        double cx = r.X + r.W / 2.0, cy = r.Y + r.H / 2.0;
        return monitors.MinBy(m =>
        {
            var dx = Math.Max(Math.Max(m.Bounds.X - cx, 0), cx - m.Bounds.Right());
            var dy = Math.Max(Math.Max(m.Bounds.Y - cy, 0), cy - m.Bounds.Bottom());
            return dx * dx + dy * dy;
        })!;
    }

    /// <summary>
    /// Adjusts a saved placement to the current displays. If its monitor is gone, its DPI
    /// changed, or the window would be mostly off-screen, the size is scaled by the DPI ratio
    /// and the window moved into the work area of the nearest monitor (keeping its offset
    /// within that monitor when it can). Otherwise it is returned unchanged.
    /// </summary>
    public static Placement Fit(Placement p, IReadOnlyList<MonitorInfo> monitors)
    {
        if (monitors.Count == 0) return p;
        var reference = p.State == PlacementState.Snapped ? p.ActualRect : p.NormalRect;
        var saved = monitors.FirstOrDefault(m => m.Device == p.Monitor);
        var target = saved ?? Nearest(reference, monitors);
        var dpiChanged = p.Dpi > 0 && target.Dpi != p.Dpi;
        var visibleEnough = Overlap(reference, target.WorkArea) * 2 >= (long)reference.W * reference.H;
        if (saved is not null && !dpiChanged && visibleEnough) return p;

        var scale = p.Dpi > 0 ? (double)target.Dpi / p.Dpi : 1;
        // Keep the window's offset within its monitor when we know where that was; a window
        // from a monitor that is gone is centred instead.
        var keepOffset = saved is not null || Overlap(reference, target.Bounds) > 0;
        var origin = saved?.WorkArea ?? target.WorkArea;
        Rect Move(Rect r)
        {
            var w = Math.Min((int)Math.Round(r.W * scale), target.WorkArea.W);
            var h = Math.Min((int)Math.Round(r.H * scale), target.WorkArea.H);
            var x = keepOffset ? target.WorkArea.X + (int)Math.Round((r.X - origin.X) * scale) : target.WorkArea.X + (target.WorkArea.W - w) / 2;
            var y = keepOffset ? target.WorkArea.Y + (int)Math.Round((r.Y - origin.Y) * scale) : target.WorkArea.Y + (target.WorkArea.H - h) / 2;
            x = Math.Clamp(x, target.WorkArea.X, target.WorkArea.Right() - w);
            y = Math.Clamp(y, target.WorkArea.Y, target.WorkArea.Bottom() - h);
            return new Rect(x, y, w, h);
        }
        return new Placement
        {
            State = p.State,
            NormalRect = Move(p.NormalRect),
            ActualRect = Move(p.ActualRect),
            Monitor = target.Device,
            Dpi = target.Dpi,
            Visible = p.Visible,
        };
    }

    /// <summary>Tiling: the whole work area, or its left/right half for a pair.</summary>
    public static Rect Tile(Rect work, int side) => side switch
    {
        < 0 => new Rect(work.X, work.Y, work.W / 2, work.H),
        > 0 => new Rect(work.X + work.W / 2, work.Y, work.W - work.W / 2, work.H),
        _ => work,
    };
}
