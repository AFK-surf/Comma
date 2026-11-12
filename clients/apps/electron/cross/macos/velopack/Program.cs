using System.Diagnostics;
using Microsoft.Extensions.Logging;
using Velopack.Core;
using Velopack.Core.Abstractions;
using Velopack.Packaging;
using Velopack.Packaging.Unix.Commands;

if (args.FirstOrDefault() != "pack") {
    Console.Error.WriteLine(
        "usage: vpk pack --packId ID --packVersion VERSION --packDir APP --outputDir DIR " +
        "[--packTitle TITLE] [--channel CHANNEL] [--mainExe NAME]");
    return 1;
}

var options = args.Skip(1).Chunk(2).ToDictionary(pair => pair[0].TrimStart('-'), pair => pair.ElementAtOrDefault(1));
HelperFile.AddSearchPath(Environment.GetEnvironmentVariable("VELOPACK_VENDOR_DIR"));

using var loggerFactory = LoggerFactory.Create(builder =>
    builder.AddSimpleConsole(console => console.SingleLine = true).SetMinimumLevel(LogLevel.Information));
var log = loggerFactory.CreateLogger("vpk");

await new LinuxOsxPackCommandRunner(log, new LoggerConsole(log)).Run(new OsxPackOptions {
    PackId = options["packId"],
    PackTitle = options.GetValueOrDefault("packTitle"),
    PackVersion = options["packVersion"],
    Channel = options.GetValueOrDefault("channel"),
    PackDirectory = options["packDir"],
    ReleaseDir = Directory.CreateDirectory(options["outputDir"]),
    EntryExecutableName = options.GetValueOrDefault("mainExe"),
    NoInst = true,
});
return 0;

class LinuxOsxPackCommandRunner(ILogger log, IFancyConsole console) : OsxPackCommandRunner(log, console)
{
    protected override Task CodeSign(Action<int> progress, string packDir)
    {
        Run("/opt/macos-cross/sign.sh", [packDir]);
        progress(100);
        return Task.CompletedTask;
    }

    protected override Task CreatePortablePackage(Action<int> progress, string packDir, string outputPath)
    {
        Run("zip", ["-qry", outputPath, Path.GetFileName(packDir)], Path.GetDirectoryName(packDir));
        progress(100);
        return Task.CompletedTask;
    }

    static void Run(string file, string[] arguments, string workingDirectory = "")
    {
        using var process = Process.Start(new ProcessStartInfo(file, arguments) { WorkingDirectory = workingDirectory })!;
        process.WaitForExit();
        if (process.ExitCode != 0) throw new Exception($"{file} exited with {process.ExitCode}");
    }
}
