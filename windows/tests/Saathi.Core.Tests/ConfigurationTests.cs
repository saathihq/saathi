//
//  ConfigurationTests.cs
//
//  Mirrors the ConfigurationTests in the macOS package.
//

using Saathi.Contract;
using Saathi.Core;
using Xunit;

namespace Saathi.Core.Tests;

public class ConfigurationTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"saathi-tests-{Guid.NewGuid():N}");

    private string TemporaryConfigPath() => Path.Combine(_directory, "shell.json");

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
        GC.SuppressFinalize(this);
    }

    [Fact]
    public void MissingConfigIsNotAnErrorAndYieldsTheHostedDefault()
    {
        var configuration = ConfigurationStore.Load(TemporaryConfigPath());
        Assert.Null(configuration.Token);
        Assert.Equal(SaathiBackend.DefaultBaseUrl, configuration.ResolvedBaseUrl);
    }

    [Fact]
    public void AConfiguredBackendUrlOverridesTheDefault()
    {
        var configuration = new SaathiConfiguration { BackendUrl = "http://localhost:8080", Token = "t" };
        Assert.Equal("http://localhost:8080", configuration.ResolvedBaseUrl);
    }

    [Fact]
    public void ABlankBackendUrlFallsBackToTheDefault()
    {
        var configuration = new SaathiConfiguration { BackendUrl = "   " };
        Assert.Equal(SaathiBackend.DefaultBaseUrl, configuration.ResolvedBaseUrl);
    }

    [Fact]
    public void ASavedConfigLoadsBackIdentically()
    {
        var path = TemporaryConfigPath();
        var original = new SaathiConfiguration { BackendUrl = "https://example.test", Token = "abc" };

        ConfigurationStore.Save(original, path);
        var loaded = ConfigurationStore.Load(path);

        Assert.Equal(original.BackendUrl, loaded.BackendUrl);
        Assert.Equal(original.Token, loaded.Token);
    }

    /// <summary>
    /// The file holds a bearer token. On Unix that is a mode check; on Windows the equivalent is an
    /// ACL and belongs to the shell that first writes a token, so there is nothing to assert yet.
    /// </summary>
    [Fact]
    public void TheConfigIsWrittenOwnerReadableOnlyOnUnix()
    {
        if (OperatingSystem.IsWindows()) return;

        var path = TemporaryConfigPath();
        ConfigurationStore.Save(new SaathiConfiguration { Token = "secret" }, path);

        var mode = File.GetUnixFileMode(path);
        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, mode);
    }

    [Fact]
    public void MalformedConfigSaysSoRatherThanPretendingItIsEmpty()
    {
        var path = TemporaryConfigPath();
        Directory.CreateDirectory(_directory);
        File.WriteAllText(path, "{ not json");

        Assert.Throws<ConfigurationException>(() => ConfigurationStore.Load(path));
    }

    [Fact]
    public void TheConfigPathCanBeOverriddenForTestsAndCI()
    {
        var path = ConfigurationStore.DefaultPath(
            new Dictionary<string, string> { ["SAATHI_CONFIG"] = "/tmp/elsewhere.json" },
            homeDirectory: "/Users/nobody");

        Assert.Equal("/tmp/elsewhere.json", path);
    }

    [Fact]
    public void TheDefaultPathIsUnderTheHomeDirectory()
    {
        var path = ConfigurationStore.DefaultPath(new Dictionary<string, string>(), homeDirectory: "/Users/nobody");
        Assert.Equal(Path.Combine("/Users/nobody", ".saathi", "shell.json"), path);
    }
}
