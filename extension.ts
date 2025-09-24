"use strict";

import * as vscode from "vscode";
import { ExtensionContext, OutputChannel } from "vscode";

import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from "vscode-languageclient/node";

let languageClient: LanguageClient;
let outputChannel: OutputChannel;

function startLanguageServer(context: ExtensionContext) {
  const config = vscode.workspace.getConfiguration("jetls-client");
  const juliaExecutable = config.get<string>("juliaExecutablePath", "julia");

  const serverScript = context.asAbsolutePath("runserver.jl");
  const serverArgsToRun = [
    "--startup-file=no",
    "--history-file=no",
    "--project=.",
    "--threads=auto",
    serverScript,
  ];
  const serverArgsToDebug = [
    "--startup-file=no",
    "--history-file=no",
    "--project=.",
    "--threads=auto",
    serverScript,
    "--debug=yes",
  ];
  const serverOptions: ServerOptions = {
    run: { command: juliaExecutable, args: serverArgsToRun },
    debug: { command: juliaExecutable, args: serverArgsToDebug },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      {
        scheme: "file",
        language: "julia",
      },
      {
        scheme: "untitled",
        language: "julia",
      },
    ],
    outputChannel,
  };

  languageClient = new LanguageClient(
    "jetls-client",
    "JETLS Language Server",
    serverOptions,
    clientOptions,
  );

  languageClient.start();
}

function restartLanguageServer(context: ExtensionContext) {
  if (languageClient) {
    languageClient.stop().then(() => {
      languageClient.start();
    });
  } else {
    startLanguageServer(context);
  }
}

export function activate(context: ExtensionContext) {
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("jetls-client.juliaExecutablePath")) {
        restartLanguageServer(context);
      }
    }),
  );
  context.subscriptions.push(
    vscode.commands.registerCommand(
      "jetls-client.restartLanguageServer",
      () => {
        restartLanguageServer(context);
      },
    ),
  );

  outputChannel = vscode.window.createOutputChannel("JETLS Language Server");

  startLanguageServer(context);
}

export async function deactivate() {
  if (languageClient) {
    await languageClient.stop();
  }
  if (outputChannel) {
    outputChannel.dispose();
  }
}
