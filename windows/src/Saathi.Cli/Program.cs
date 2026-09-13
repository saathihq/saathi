//
//  Program.cs
//  saathi (Windows)
//
//  The basic Windows client, command for command the same as the macOS one:
//
//    saathi provider           which mode this is in, and whether anything leaves the machine
//    saathi actions            what this build can be asked to do
//    saathi health             is the backend up
//    saathi say "..."          say one line
//    saathi demo               a three-step lesson, narrated
//
//  It prints rather than speaks, because speaking on Windows means System.Speech or WinRT, both of
//  which are Windows-only assemblies — and keeping this project net8.0 is what lets CI verify on
//  Linux that the contract still compiles for the Windows client. The speaking implementation
//  arrives with the WPF shell, behind the same ISpeaker.
//

using Saathi.Contract;
using Saathi.Core;

var arguments = args;
var positional = arguments.Where(a => !a.StartsWith("--", StringComparison.Ordinal)).ToArray();
var command = positional.FirstOrDefault() ?? "help";

var speaker = new PrintingSpeaker();
var performer = new ActionPerformer(speaker, new SystemUrlOpener());

Tone ToneOption()
{
    const string flag = "--tone=";
    var raw = arguments.FirstOrDefault(a => a.StartsWith(flag, StringComparison.Ordinal))?[flag.Length..];
    return Enum.TryParse<Tone>(raw, ignoreCase: true, out var tone) ? tone : Tone.Neutral;
}

int Fail(string message)
{
    Console.Error.WriteLine($"saathi: {message}");
    return 1;
}

switch (command)
{
    case "provider":
    {
        var configuration = ConfigurationStore.Load(ConfigurationStore.DefaultPath());
        Console.WriteLine(ProviderReport.Describe(configuration));
        if (arguments.Contains("--probe"))
        {
            Console.WriteLine($"  status     {await ProviderReport.ReachabilityAsync(configuration)}");
        }
        return 0;
    }

    case "actions":
        Console.WriteLine($"contract {SaathiBackend.ContractVersion} — {SaathiActions.AllWireNames.Length} actions");
        foreach (var wireName in SaathiActions.AllWireNames) Console.WriteLine($"  {wireName}");
        Console.WriteLine();
        Console.WriteLine($"tones: {string.Join(", ", Enum.GetNames<Tone>().Select(n => n.ToLowerInvariant()))}");
        Console.WriteLine($"paces: {string.Join(", ", Enum.GetNames<Pace>().Select(n => n.ToLowerInvariant()))}");
        return 0;

    case "health":
    {
        var configuration = ConfigurationStore.Load(ConfigurationStore.DefaultPath());
        Console.WriteLine($"backend: {configuration.ResolvedBaseUrl}");
        try
        {
            using var client = new BackendClient(configuration);
            var health = await client.HealthAsync();
            // `bool.ToString()` yields "True"; the macOS client prints "true". Two clients that disagree
            // about how to spell a boolean are two clients whose output cannot be diffed, and diffing
            // them is how this project checks that they still behave the same.
            var ok = health.Ok ? "true" : "false";
            Console.WriteLine($"health: ok={ok} version={health.Version ?? "unknown"}");
            return 0;
        }
        catch (BackendException e)
        {
            return Fail(e.Message);
        }
    }

    case "say":
    {
        if (positional.Length < 2) return Fail("say what? — saathi say \"hello\"");
        var text = string.Join(' ', positional.Skip(1));
        await performer.PerformAsync(new SayAction(text, ToneOption()));
        return 0;
    }

    case "demo":
    {
        // Deliberately hard-coded: this is the smoke test that the contract, the action performer
        // and the speaker all line up, not a feature. What a real lesson looks like is one of the
        // open product questions in the root README.
        ShowStepAction[] steps =
        [
            new("Pick something you want to learn", 1, 3,
                "Anything at all. Saathi is here to keep you company while you do."),
            new("Try the first small piece of it", 2, 3,
                "Small enough that getting it wrong costs nothing."),
            new("Tell Saathi how that went", 3, 3),
        ];

        foreach (var step in steps) await performer.PerformAsync(step);
        await performer.PerformAsync(new SayAction("That is the whole loop.", Tone.Calm));
        return 0;
    }

    case "help":
    case "--help":
    case "-h":
        Console.WriteLine("""
            saathi — a companion for learning and playing with new things

              saathi provider             which mode this is in  (--probe to check it is reachable)
              saathi actions              list what this build can be asked to do
              saathi health               check the backend
              saathi say "..."            say one line  (--tone=calm|encouraging|neutral)
              saathi demo                 a three-step lesson, narrated
            """);
        return 0;

    default:
        return Fail($"unknown command \"{command}\" — try `saathi help`");
}
