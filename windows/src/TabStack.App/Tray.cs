using WinForms = System.Windows.Forms;

namespace TabStack.App;

/// <summary>Notification-area icon: the way out when the sidebar is in trouble.</summary>
sealed class Tray : IDisposable
{
    readonly WinForms.NotifyIcon icon;

    public Tray(AppShell shell)
    {
        var menu = new WinForms.ContextMenuStrip();
        menu.Items.Add("显示所有隐藏的窗口", null, (_, _) => shell.ShowAllHidden());
        menu.Items.Add("设置…", null, (_, _) => shell.OpenSettings());
        menu.Items.Add("打开数据文件夹", null, (_, _) =>
            System.Diagnostics.Process.Start("explorer.exe", Core.Store.DefaultDirectory));
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("退出 TabStack", null, (_, _) => shell.Quit());

        var stream = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/Assets/TabStack.ico"))!.Stream;
        icon = new WinForms.NotifyIcon
        {
            Icon = new System.Drawing.Icon(stream, WinForms.SystemInformation.SmallIconSize),
            Text = "TabStack",
            ContextMenuStrip = menu,
            Visible = true,
        };
    }

    public void Notify(string text) => icon.ShowBalloonTip(5000, "TabStack", text, WinForms.ToolTipIcon.Info);

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
    }
}
