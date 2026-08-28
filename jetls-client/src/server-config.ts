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
  const executable = config.get<ExecutableConfig>("executable", {});
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

/**
 * The object form without `path` selects the managed JETLS installation;
 * specifying `path` or the array form bypasses it with a custom command.
 */
export function isManagedExecutable(executable: ExecutableConfig): boolean {
  return !Array.isArray(executable) && executable.path === undefined;
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
