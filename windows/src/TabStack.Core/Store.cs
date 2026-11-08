using System.Text.Json;
using System.Text.Json.Serialization;

namespace TabStack.Core;

/// <summary>JSON persistence. Writes go to a temp file first so a crash mid-write never
/// leaves a truncated state file.</summary>
public sealed class Store
{
    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public string Path { get; }

    public Store(string path) => Path = path;

    /// <summary>%LOCALAPPDATA%\TabStack</summary>
    public static string DefaultDirectory =>
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TabStack");

    public AppState Load()
    {
        try
        {
            if (File.Exists(Path))
                return JsonSerializer.Deserialize<AppState>(File.ReadAllText(Path), Json) ?? new AppState();
        }
        catch (JsonException)
        {
            // Keep the broken file for inspection instead of overwriting it with an empty state.
            File.Copy(Path, Path + ".broken", overwrite: true);
        }
        return new AppState();
    }

    public void Save(AppState state) => AtomicWrite(Path, JsonSerializer.Serialize(state, Json));

    internal static void AtomicWrite(string path, string text)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, text);
        File.Move(tmp, path, overwrite: true);
    }
}
