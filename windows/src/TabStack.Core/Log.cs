namespace TabStack.Core;

/// <summary>Appends to %LOCALAPPDATA%\TabStack\TabStack.log.</summary>
public static class Log
{
    static readonly object gate = new();
    public static string Path { get; set; } = System.IO.Path.Combine(Store.DefaultDirectory, "TabStack.log");

    public static void Write(string message)
    {
        try
        {
            lock (gate)
            {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
                var info = new FileInfo(Path);
                if (info.Exists && info.Length > 2_000_000) File.Move(Path, Path + ".old", overwrite: true);
                File.AppendAllText(Path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{Environment.ProcessId}] {message}{Environment.NewLine}");
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
