'use strict';

import * as vscode from 'vscode';

import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions
} from 'vscode-languageclient/node';

let languageClient: LanguageClient;
let outputChannel: vscode.OutputChannel;
let traceOutputChannel: vscode.OutputChannel;

function startLanguageServer(context: vscode.ExtensionContext) {
  const config = vscode.workspace.getConfiguration('JETLSClient');
  const juliaExecutable = config.get<string>('executablePath', 'julia');

  const serverScript = context.asAbsolutePath('runserver.jl');
  const serverArgsToRun = ['--startup-file=no', '--project=.', serverScript];
  const serverArgsToDebug = ['--startup-file=no', '--project=.', serverScript, '--debug=yes'];
  const serverOptions: ServerOptions = {
    run: { command: juliaExecutable, args: serverArgsToRun },
    debug: { command: juliaExecutable, args: serverArgsToDebug }
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: 'julia' }],
    // synchronize: {
    //   // Notify the server about file changes to '.clientrc files contained in the workspace
    //   fileEvents: vscode.workspace.createFileSystemWatcher('**/.clientrc'),
    // },
    outputChannel,
    traceOutputChannel,
  };

  languageClient = new LanguageClient(
    'JETLSClient',
    'JETLS Language Server',
    serverOptions,
    clientOptions,
  );

  languageClient.start();
}

// TODO: "Refresh" the language server when the configuration changes

function restartLanguageServer(context: vscode.ExtensionContext) {
  if (languageClient) {
    languageClient.stop().then(() => {
      languageClient.start();
    });
  } else {
    startLanguageServer(context);
  }
}

export function activate(context: vscode.ExtensionContext) {
  context.subscriptions.push(vscode.workspace.onDidChangeConfiguration(event => {
    if (event.affectsConfiguration('JETLSClient.juliaExecutablePath')) {
      restartLanguageServer(context);
    };
  }));
  context.subscriptions.push(
    vscode.commands.registerCommand('JETLSClient.restartLanguageServer', () => {
      restartLanguageServer(context);
    })
  );

  outputChannel = vscode.window.createOutputChannel('JETLS Language Server');
  traceOutputChannel = vscode.window.createOutputChannel('JETLS Language Server (Trace)');

  startLanguageServer(context);
}

export function deactivate() {
  const promises: Thenable<void>[] = [];
  if (languageClient) {
    promises.push(languageClient.stop());
  }
  if (outputChannel) {
    outputChannel.dispose();
  }
  if (traceOutputChannel) {
    traceOutputChannel.dispose();
  }
  return Promise.all(promises);
}
