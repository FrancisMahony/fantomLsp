import * as path from "path";
import * as fs from "fs";
import * as os from "os";
import {
  workspace,
  ExtensionContext,
  window,
  commands,
  StatusBarAlignment,
  StatusBarItem,
} from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
  Position as ProtocolPosition,
  Location as ProtocolLocation,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;
let statusBarItem: StatusBarItem | undefined;

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

// The folder itself plus exactly three ancestors, independently for each root.
// Do not descend into source trees or assume every workspace is an env root.
function workspaceEnvRoots(): string[] {
  const roots: string[] = [];
  for (const folder of workspace.workspaceFolders ?? []) {
    if (folder.uri.scheme !== "file") continue;
    let dir = folder.uri.fsPath;
    for (let level = 0; level <= 3; level++) {
      try {
        const lib = path.join(dir, "lib", "fan");
        const hasPods = fs.existsSync(lib) && fs.statSync(lib).isDirectory() &&
          fs.readdirSync(lib, { withFileTypes: true }).some(f => f.isFile() && f.name.endsWith(".pod"));
        const props = path.join(dir, "fan.props");
        if ((fs.existsSync(props) && fs.statSync(props).isFile()) || hasPods) roots.push(dir);
      } catch {
        // Inaccessible ancestor is not evidence of an environment root.
      }
      const parent = path.dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  }
  return roots;
}

function configuredEnvPath(): string[] {
  const configured = workspace.getConfiguration("fantom").get<string[]>("envPath") ?? [];
  const paths = configured;
  const seen = new Set<string>();
  return paths.filter(p => p.trim().length > 0 && path.isAbsolute(p)).map(p => path.resolve(p)).filter(p => {
    const key = os.platform() === "win32" ? p.toLowerCase() : p;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
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
  const envPath = configuredEnvPath();
  const runtimePath = path.join(context.extensionPath, "server");
  // Overwrite, never append inherited FAN_ENV_PATH. Strip case variants too:
  // Windows environment keys are case insensitive. Installed home is PathEnv's
  // automatic fallback; workspace pods must never enter the JVM search path.
  const launchEnv = { ...process.env };
  for (const key of Object.keys(launchEnv)) {
    if (["FAN_ENV", "FAN_ENV_PATH"].includes(key.toUpperCase())) delete launchEnv[key];
  }

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
        env: {
          ...launchEnv,
          FAN_HOME: fanHome,
          FAN_ENV: 'util::PathEnv',
          FAN_ENV_PATH: runtimePath,
        },
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
        env: {
          ...launchEnv,
          FAN_HOME: fanHome,
          JAVA_TOOL_OPTIONS: javaOpts,
          FAN_ENV: 'util::PathEnv',
          FAN_ENV_PATH: runtimePath,
        },
        shell: isWindows,
      },
      transport: TransportKind.stdio,
    };
  }

  const launchChannel = window.createOutputChannel("Fantom LSP Launch");
  launchChannel.appendLine(`[launch] fanHome:  ${fanHome}`);
  launchChannel.appendLine(`[launch] sysJar:   ${sysJar ?? "(not found, using fan.bat)"}`);
  launchChannel.appendLine(`[launch] javaExe:  ${javaExe}`);
  launchChannel.appendLine(`[launch] runtimePath: ${runtimePath} (installed fallback: ${fanHome})`);
  launchChannel.appendLine(`[launch] inherited FAN_ENV_PATH ignored: ${process.env["FAN_ENV_PATH"] ?? "(unset)"}`);
  launchChannel.appendLine(`[launch] configured lookup roots: ${envPath.join(path.delimiter)}`);
  launchChannel.appendLine(`[launch] detected lookup roots: ${workspaceEnvRoots().join(path.delimiter)}`);
  if (sysJar) {
    const opts = serverOptions as { command: string; args: string[] };
    launchChannel.appendLine(`[launch] command:  ${opts.command} ${opts.args.join(" ")}`);
  } else {
    const opts = serverOptions as { command: string; args: string[] };
    launchChannel.appendLine(`[launch] command:  ${opts.command} ${opts.args.join(" ")}`);
  }
  launchChannel.appendLine("[launch] server starting");

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "fantom" }],
    synchronize: {
      fileEvents: [
        workspace.createFileSystemWatcher("**/*.fan"),
        workspace.createFileSystemWatcher("**/*.fwt"),
      ],
      configurationSection: "fantom"
    },
    initializationOptions: {
      envPath,
      codeLens: { enabled: config.get<boolean>("codeLens.enabled") ?? true },
      semanticIndex: { backgroundCompile: config.get<boolean>("semanticIndex.backgroundCompile") ?? true },
      // Detection is recomputed server-side from current workspaceFolders so
      // removed folders cannot persist in the configured envPath list.
      maxFiles: config.get<number>("maxFiles") ?? 0,
      excludeDirs: config.get<string[]>("excludeDirs") ?? [
        ".git",
        "node_modules",
        ".hg",
        "build",
        "out",
        "dist",
        ".svn",
        "__pycache__",
        "lib",
        "temp",
        "tmp",
      ],
    },
    outputChannelName: "Fantom Language Server",
    middleware: {
      provideDocumentFormattingEdits: async (document, options, token, next) => {
        const config = workspace.getConfiguration("fantom.formatting");
        const bracketStyle = config.get<string>("bracketStyle") || "allman";
        const customOptions = {
          ...options,
          bracketStyle: bracketStyle
        };
        return next(document, customOptions, token);
      }
    }
  };

  client = new LanguageClient(
    "fantomLanguageServer",
    "Fantom Language Server",
    serverOptions,
    clientOptions
  );

  statusBarItem = window.createStatusBarItem(StatusBarAlignment.Left, 100);
  statusBarItem.text = "Fantom LS";
  statusBarItem.tooltip = "Fantom Language Server";
  statusBarItem.command = "fantom.restartServer";
  context.subscriptions.push(statusBarItem);

  context.subscriptions.push(
    commands.registerCommand("fantom.showReferences", async (uri: string, pos: ProtocolPosition, locs: ProtocolLocation[]) => {
      if (!client) return;
      const converter = client.protocol2CodeConverter;
      await commands.executeCommand(
        "editor.action.showReferences",
        converter.asUri(uri),
        converter.asPosition(pos),
        locs.map(loc => converter.asLocation(loc))
      );
    }),
    commands.registerCommand("fantom.restartServer", async () => {
      if (client) {
        await client.restart();
        window.showInformationMessage("Fantom Language Server restarted.");
      }
    })
  );

  try {
    await client.start();
    statusBarItem.show();
  } catch (err) {
    const choice = await window.showErrorMessage(
      `Fantom Language Server failed to start: ${err instanceof Error ? err.message : String(err)}`,
      "Open Launch Log"
    );
    if (choice === "Open Launch Log") {
      launchChannel.show(true);
    }
  }

  workspace.onDidChangeConfiguration((e) => {
    if (e.affectsConfiguration("fantom.home") || e.affectsConfiguration("fantom.javaOpts")) {
      window.showInformationMessage("Fantom Language Server settings changed.", "Restart").then((choice) => {
        if (choice === "Restart") commands.executeCommand("fantom.restartServer");
      });
    }
    if (e.affectsConfiguration("fantom.formatting.bracketStyle")) {
      client?.sendNotification("workspace/didChangeConfiguration", {
        settings: {
          fantom: {
            formatting: {
              bracketStyle: workspace.getConfiguration("fantom.formatting").get<string>("bracketStyle")
            }
          }
        }
      });
    }
  });
}

export async function deactivate(): Promise<void> {
  statusBarItem?.hide();
  statusBarItem = undefined;
  if (client) {
    await client.stop();
    client = undefined;
  }
}
