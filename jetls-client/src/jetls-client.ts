"use strict";

import * as vscode from "vscode";
import { ExtensionContext, LogOutputChannel } from "vscode";

import { affectsServerConfig } from "./server-config";
import {
  activateServerLifecycle,
  requestLanguageServerRestart,
  reinstallServer,
  restartOnServerConfigChange,
  shutdownServerLifecycle,
} from "./server-lifecycle";
import { StartupStatusBar } from "./status-bar";

let outputChannel: LogOutputChannel;
let statusBar: StartupStatusBar;

export function activate(context: ExtensionContext) {
  statusBar = new StartupStatusBar();
  context.subscriptions.push(statusBar);

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (affectsServerConfig(event)) {
        restartOnServerConfigChange();
      }
    }),
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("jetls-client.restartLanguageServer", () =>
      requestLanguageServerRestart(),
    ),
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("jetls-client.reinstallServer", () => {
      void reinstallServer().catch((err) => {
        const message = err instanceof Error ? err.message : String(err);
        outputChannel.appendLine(
          `[jetls-client] Failed to reinstall the managed JETLS: ${message}.`,
        );
      });
    }),
  );

  outputChannel = vscode.window.createOutputChannel("JETLS", { log: true });
  context.subscriptions.push(
    vscode.commands.registerCommand("jetls-client.showOutput", () =>
      outputChannel.show(),
    ),
  );

  activateServerLifecycle(outputChannel, statusBar, context);

  requestLanguageServerRestart();
}

export async function deactivate() {
  statusBar?.suppress();
  await shutdownServerLifecycle();
  if (outputChannel) {
    outputChannel.dispose();
  }
  if (statusBar) {
    statusBar.dispose();
  }
}
