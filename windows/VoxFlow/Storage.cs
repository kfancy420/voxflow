using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace VoxFlow;

/// <summary>App settings persisted to %APPDATA%\VoxFlow\settings.json.</summary>
public sealed class Settings
{
    public bool CleanupEnabled { get; set; } = true;
    public bool TrailingSpace { get; set; } = true;
    /// <summary>
    /// medium.en: on a GPU-accelerated machine the extra ~100 ms is
    /// imperceptible and it is measurably better on technical vocabulary.
    /// </summary>
    public string Model { get; set; } = "medium.en";
    /// <summary>True once we've auto-enabled start-with-Windows on first run.</summary>
    public bool AutoStartConfigured { get; set; } = false;

    private static string FilePath =>
        Path.Combine(AppDataDirectory(), "settings.json");

    public static string AppDataDirectory()
    {
        string dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "VoxFlow");
        Directory.CreateDirectory(dir);
        return dir;
    }

    public static Settings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings();
        }
        catch { }
        return new Settings();
    }

    public void Save()
    {
        try
        {
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this,
                new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }
}

/// <summary>
/// Personal dictionary: whole-word, case-insensitive replacements loaded from
/// %APPDATA%\VoxFlow\dictionary.json (editable via the tray menu).
/// </summary>
public static class PersonalDictionary
{
    private static string FilePath =>
        Path.Combine(Settings.AppDataDirectory(), "dictionary.json");

    public static void EnsureExists()
    {
        if (File.Exists(FilePath)) return;
        // Whisper has no idea "VoxFlow" is a word, so it guesses at the sounds
        // and lands on things like "box flow" or "Vox Flow". Seed the common
        // mishearings — this is exactly what the dictionary is for.
        var sample = new Dictionary<string, string>
        {
            ["voxflow"] = "VoxFlow",
            ["vox flow"] = "VoxFlow",
            ["box flow"] = "VoxFlow",
            ["fox flow"] = "VoxFlow",
        };
        try
        {
            File.WriteAllText(FilePath, JsonSerializer.Serialize(sample,
                new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    public static string PathForEditing()
    {
        EnsureExists();
        return FilePath;
    }

    public static string Apply(string text)
    {
        Dictionary<string, string>? entries = null;
        try
        {
            if (File.Exists(FilePath))
                entries = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(FilePath));
        }
        catch { }
        if (entries == null || entries.Count == 0) return text;

        foreach (var pair in entries.OrderByDescending(p => p.Key.Length))
        {
            if (string.IsNullOrWhiteSpace(pair.Key)) continue;
            string escaped = Regex.Escape(pair.Key);
            string pattern = (char.IsLetterOrDigit(pair.Key[0]) ? @"\b" : "")
                + escaped
                + (char.IsLetterOrDigit(pair.Key[^1]) ? @"\b" : "");
            text = Regex.Replace(text, pattern, pair.Value.Replace("$", "$$"), RegexOptions.IgnoreCase);
        }
        return text;
    }
}

/// <summary>History of dictations, newest first, capped at 200.</summary>
public static class HistoryStore
{
    private sealed record Entry(DateTime Date, string Raw, string Cleaned, string? App);

    private static string FilePath =>
        Path.Combine(Settings.AppDataDirectory(), "history.json");

    public static string PathForViewing() => FilePath;

    public static void Add(string raw, string cleaned, string? app)
    {
        if (string.IsNullOrWhiteSpace(cleaned)) return;
        try
        {
            List<Entry> entries = new();
            if (File.Exists(FilePath))
                entries = JsonSerializer.Deserialize<List<Entry>>(File.ReadAllText(FilePath)) ?? new();
            entries.Insert(0, new Entry(DateTime.Now, raw, cleaned, app));
            if (entries.Count > 200) entries.RemoveRange(200, entries.Count - 200);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(entries,
                new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }
}
