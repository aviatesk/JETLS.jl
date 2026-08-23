import * as vscode from "vscode";

import { ExecutableConfig } from "./preflight";

export interface ServerConfig {
  executable: ExecutableConfig;
  communicationChannel: string;
  socketPort: number;
  initializationOptions: object;
}

export function getServerConfig(): ServerConfig {
  const config = vscode.workspace.getConfiguration("jetls-client");
  const defaultExecutable = "jetls";
  const executable = config.get<ExecutableConfig>("executable", {
    path: defaultExecutable,
    threads: "auto",
  });
  return {
    executable,
    communicationChannel: config.get<string>("communicationChannel", "auto"),
    socketPort: config.get<number>("socketPort", 8080),
    initializationOptions: config.get<object>("initializationOptions", {}),
  };
}

export function hasServerConfigChanged(
  oldConfig: ServerConfig | null,
  newConfig: ServerConfig,
): boolean {
  if (!oldConfig) {
    return true;
  }
  return (
    JSON.stringify(oldConfig.executable) !==
      JSON.stringify(newConfig.executable) ||
    oldConfig.communicationChannel !== newConfig.communicationChannel ||
    oldConfig.socketPort !== newConfig.socketPort ||
    // The server only reads `initializationOptions` on initialize, so a
    // change can take effect solely through a restart.
    JSON.stringify(oldConfig.initializationOptions) !==
      JSON.stringify(newConfig.initializationOptions)
  );
}

export function affectsServerConfig(
  event: vscode.ConfigurationChangeEvent,
): boolean {
  return (
    event.affectsConfiguration("jetls-client.executable") ||
    event.affectsConfiguration("jetls-client.communicationChannel") ||
    event.affectsConfiguration("jetls-client.socketPort") ||
    event.affectsConfiguration("jetls-client.initializationOptions")
  );
}
