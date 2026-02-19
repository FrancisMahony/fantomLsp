"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.activate = activate;
exports.deactivate = deactivate;
const path = __importStar(require("path"));
const fs = __importStar(require("fs"));
const os = __importStar(require("os"));
const vscode_1 = require("vscode");
const node_1 = require("vscode-languageclient/node");
let client;
function findFantomHome() {
    const config = vscode_1.workspace.getConfiguration("fantom");
    const configHome = config.get("home");
    if (configHome && fs.existsSync(configHome)) {
        return configHome;
    }
    const envHome = process.env["FAN_HOME"];
    if (envHome && fs.existsSync(envHome)) {
        return envHome;
    }
    return undefined;
}
function findJavaExecutable(fanHome) {
    const javaHome = process.env["JAVA_HOME"];
    if (javaHome) {
        const isWindows = os.platform() === "win32";
        const javaExe = path.join(javaHome, "bin", isWindows ? "java.exe" : "java");
        if (fs.existsSync(javaExe)) {
            return javaExe;
        }
    }
    console.log();
    const fanJava = path.join(fanHome, "bin", os.platform() === "win32" ? "java.exe" : "java");
    if (fs.existsSync(fanJava)) {
        return fanJava;
    }
    return "java";
}
function findSysJar(fanHome) {
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
async function activate(context) {
    const fanHome = findFantomHome();
    if (!fanHome) {
        const msg = "Fantom installation not found. Set the FAN_HOME environment variable or configure fantom.home in settings.";
        vscode_1.window.showErrorMessage(msg);
        return;
    }
    const config = vscode_1.workspace.getConfiguration("fantom");
    const javaOpts = config.get("javaOpts") || "-Xmx1024m";
    const sysJar = findSysJar(fanHome);
    const javaExe = findJavaExecutable(fanHome);
    let serverOptions;
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
            transport: node_1.TransportKind.stdio,
        };
    }
    else {
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
            transport: node_1.TransportKind.stdio,
        };
    }
    const launchChannel = vscode_1.window.createOutputChannel("Fantom LSP Launch");
    launchChannel.appendLine(`[launch] fanHome:  ${fanHome}`);
    launchChannel.appendLine(`[launch] sysJar:   ${sysJar ?? "(not found, using fan.bat)"}`);
    launchChannel.appendLine(`[launch] javaExe:  ${javaExe}`);
    if (sysJar) {
        const opts = serverOptions;
        launchChannel.appendLine(`[launch] command:  ${opts.command} ${opts.args.join(" ")}`);
    }
    else {
        const opts = serverOptions;
        launchChannel.appendLine(`[launch] command:  ${opts.command} ${opts.args.join(" ")}`);
    }
    launchChannel.show(true);
    const clientOptions = {
        documentSelector: [{ scheme: "file", language: "fantom" }],
        synchronize: {
            fileEvents: vscode_1.workspace.createFileSystemWatcher("**/*.fan"),
            configurationSection: "fantom"
        },
        outputChannelName: "Fantom Language Server",
        middleware: {
            provideDocumentFormattingEdits: async (document, options, token, next) => {
                const config = vscode_1.workspace.getConfiguration("fantom.formatting");
                const bracketStyle = config.get("bracketStyle") || "preserve";
                const customOptions = {
                    ...options,
                    bracketStyle: bracketStyle
                };
                return next(document, customOptions, token);
            }
        }
    };
    client = new node_1.LanguageClient("fantomLanguageServer", "Fantom Language Server", serverOptions, clientOptions);
    context.subscriptions.push(vscode_1.commands.registerCommand("fantom.restartServer", async () => {
        if (client) {
            await client.restart();
            vscode_1.window.showInformationMessage("Fantom Language Server restarted.");
        }
    }));
    await client.start();
    vscode_1.workspace.onDidChangeConfiguration((e) => {
        if (e.affectsConfiguration("fantom.formatting.bracketStyle")) {
            client?.sendNotification("workspace/didChangeConfiguration", {
                settings: {
                    fantom: {
                        formatting: {
                            bracketStyle: vscode_1.workspace.getConfiguration("fantom.formatting").get("bracketStyle")
                        }
                    }
                }
            });
        }
    });
}
async function deactivate() {
    if (client) {
        await client.stop();
        client = undefined;
    }
}
//# sourceMappingURL=extension.js.map