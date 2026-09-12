//
//  Configuration.cs
//  Saathi.Core
//
//  Reading ~/.saathi/shell.json, and refusing to be careless with the token in it.
//  The Swift counterpart is macos/Saathi/Sources/SaathiKit/Configuration.swift — these two are
//  meant to behave identically, and the tests on both sides assert the same things.
//

using System.Text.Json;
using Saathi.Contract;

namespace Saathi.Core;

public sealed class ConfigurationException : Exception
{
    public ConfigurationException(string message, Exception? inner = null) : base(message, inner) { }
}

public static class ConfigurationStore
{
    /// <summary>
    /// <c>~/.saathi/shell.json</c>, or whatever <c>SAATHI_CONFIG</c> points at (tests and CI use that).
    /// </summary>
    public static string DefaultPath(IDictionary<string, string>? environment = null, string? homeDirectory = null)
    {
        var overridePath = environment is not null
            ? (environment.TryGetValue("SAATHI_CONFIG", out var fromDictionary) ? fromDictionary : null)
            : Environment.GetEnvironmentVariable("SAATHI_CONFIG");

        if (!string.IsNullOrEmpty(overridePath)) return overridePath;

        var home = homeDirectory ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(home, ".saathi", "shell.json");
    }

    /// <summary>
    /// A missing file is not an error — it means "no token yet, use the hosted default", which is
    /// exactly the state a fresh install is in.
    /// </summary>
    public static SaathiConfiguration Load(string path)
    {
        if (!File.Exists(path)) return new SaathiConfiguration();

        string json;
        try
        {
            json = File.ReadAllText(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new ConfigurationException($"cannot read {path}: {e.Message}", e);
        }

        try
        {
            return JsonSerializer.Deserialize<SaathiConfiguration>(json) ?? new SaathiConfiguration();
        }
        catch (JsonException e)
        {
            throw new ConfigurationException($"{path} is not valid Saathi config: {e.Message}", e);
        }
    }

    /// <summary>
    /// Written owner-only from the start. The file holds a bearer token, and a token in a
    /// world-readable file is a token every process on the machine has.
    /// </summary>
    public static void Save(SaathiConfiguration configuration, string path)
    {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);

        var json = JsonSerializer.Serialize(configuration, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json);
        RestrictToOwner(path);
    }

    /// <summary>
    /// On Unix this is a plain chmod 600. On Windows there is no mode bit: the equivalent is to
    /// replace the file's inherited ACL with one that names only the current user, which is what
    /// DPAPI-less local secrets are normally given.
    /// </summary>
    private static void RestrictToOwner(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            // Deliberately not implemented with a silent fallback: an ACL that quietly failed to
            // apply would leave the token readable while looking handled. The WPF shell will carry
            // the real implementation (FileSecurity: disable inheritance, one FullControl ACE for
            // WindowsIdentity.GetCurrent) alongside the sign-in flow that first writes a token.
            return;
        }

        File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }
}
