import * as path from "path";
import * as fs from "fs";
import * as os from "os";
import {
  workspace,
  ExtensionContext,
  window,
  commands,
} from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

function findFantomHome(): string | undefined {
  const config = workspace.getConfiguration("fantom");
  const configHome = config.get<string>("home");
  if (configHome && fs.existsSync(configHome)) {
    return configHome;
  }

  const envHome = process.env["FAN_HOME"];
  if (envHome && fs.existsSync(envHome)) {
    return envHome;
  }

  return undefined;
}

function findJavaExecutable(fanHome: string): string {
  const javaHome = process.env["JAVA_HOME"];
  if (javaHome) {
    const isWindows = os.platform() === "win32";
    const javaExe = path.join(javaHome, "bin", isWindows ? "java.exe" : "java");
    if (fs.existsSync(javaExe)) {
      return javaExe;
    }
  }
  console.log()
  const fanJava = path.join(
    fanHome,
    "bin",
    os.platform() === "win32" ? "java.exe" : "java"
  );
  if (fs.existsSync(fanJava)) {
    return fanJava;
  }

  return "java";
}

function findSysJar(fanHome: string): string | undefined {
  const candidates = [
    path.join(fanHome, "lib", "java", "sys.jar"),
    path.join(fanHome, "lib", "fan", "sys.jar"),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) {
      return c;
    }
  }
  return undefined;
}

export async function activate(context: ExtensionContext): Promise<void> {
  const fanHome = findFantomHome();
  if (!fanHome) {
    const msg =
      "Fantom installation not found. Set the FAN_HOME environment variable or configure fantom.home in settings.";
    window.showErrorMessage(msg);
    return;
  }

  const config = workspace.getConfiguration("fantom");
  const javaOpts = config.get<string>("javaOpts") || "-Xmx1024m";

  const sysJar = findSysJar(fanHome);
  const javaExe = findJavaExecutable(fanHome);

  let serverOptions: ServerOptions;

  if (sysJar) {
    const javaArgs = [
      ...javaOpts.split(/\s+/),
      `-Dfan.home=${fanHome}`,
      "-cp",
      sysJar,
      "fanx.tools.Fan",
      "fantomLsp::Main",
    ];

    serverOptions = {
      command: javaExe,
      args: javaArgs,
      options: {
        env: { ...process.env, FAN_HOME: fanHome },
      },
      transport: TransportKind.stdio,
    };
  } else {
    const isWindows = os.platform() === "win32";
    const binName = isWindows ? "fan.bat" : "fan";
    const fanBin = path.join(fanHome, "bin", binName);
    const fanExe = fs.existsSync(fanBin) ? fanBin : binName;

    serverOptions = {
      command: fanExe,
      args: ["fantomLsp::Main"],
      options: {
        env: { ...process.env, FAN_HOME: fanHome, JAVA_TOOL_OPTIONS: javaOpts },
        shell: isWindows,
      },
      transport: TransportKind.stdio,
    };
  }

  const launchChannel = window.createOutputChannel("Fantom LSP Launch");
  launchChannel.appendLine(`[launch] fanHome:  ${fanHome}`);
  launchChannel.appendLine(`[launch] sysJar:   ${sysJar ?? "(not found, using fan.bat)"}`);
  launchChannel.appendLine(`[launch] javaExe:  ${javaExe}`);
  if (sysJar) {
    const opts = serverOptions as { command: string; args: string[] };
    launchChannel.appendLine(`[launch] command:  ${opts.command} ${opts.args.join(" ")}`);
  } else {
    const opts = serverOptions as { command: string; args: string[] };
    launchChannel.appendLine(`[launch] command:  ${opts.command} ${opts.args.join(" ")}`);
  }
  launchChannel.show(true);

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "fantom" }],
    synchronize: {
      fileEvents: workspace.createFileSystemWatcher("**/*.fan"),
    },
    outputChannelName: "Fantom Language Server",
  };

  client = new LanguageClient(
    "fantomLanguageServer",
    "Fantom Language Server",
    serverOptions,
    clientOptions
  );

  context.subscriptions.push(
    commands.registerCommand("fantom.restartServer", async () => {
      if (client) {
        await client.restart();
        window.showInformationMessage("Fantom Language Server restarted.");
      }
    })
  );

  await client.start();
}

export async function deactivate(): Promise<void> {
  if (client) {
    await client.stop();
    client = undefined;
  }
}
