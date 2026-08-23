import * as vscode from "vscode";
import { ExtensionContext } from "vscode";

import {
  JETLS_CHANGELOG_URL,
  JETLS_INSTALL_COMMAND,
  JETLS_INSTALL_GUIDE_URL,
  JETLS_MIGRATION_GUIDE_URL,
} from "./constants";

export async function checkForUpdates(
  context: ExtensionContext,
): Promise<void> {
  const currentVersion = vscode.extensions.getExtension("aviatesk.jetls-client")
    ?.packageJSON.version;
  const previousVersion = context.globalState.get<string>("version");

  if (currentVersion && !previousVersion) {
    // First-time installation
    const message =
      "Welcome to JETLS Client! To use this extension, you need to install the JETLS executable. " +
      "Click 'Install JETLS' to get started.";
    const installButton = "Install JETLS";
    const docsButton = "View installation guide";

    const selection = await vscode.window.showInformationMessage(
      message,
      installButton,
      docsButton,
    );

    if (selection === installButton) {
      const terminal = vscode.window.createTerminal("Install JETLS");
      terminal.show();
      terminal.sendText(JETLS_INSTALL_COMMAND, true);
    } else if (selection === docsButton) {
      vscode.env.openExternal(vscode.Uri.parse(JETLS_INSTALL_GUIDE_URL));
    }
  } else if (
    currentVersion &&
    previousVersion &&
    currentVersion !== previousVersion
  ) {
    // Update detected
    if (
      previousVersion.startsWith("0.1.") &&
      currentVersion.startsWith("0.2.")
    ) {
      // Special handling for v0.1.x -> v0.2.0 breaking update
      const message =
        "JETLS Client v0.2.0 requires reinstalling JETLS with the new installation method. " +
        "Click 'Reinstall JETLS' to run the installation command.";
      const reinstallButton = "Reinstall JETLS";
      const migrationGuideButton = "View migration guide";

      const selection = await vscode.window.showWarningMessage(
        message,
        reinstallButton,
        migrationGuideButton,
      );

      if (selection === reinstallButton) {
        const terminal = vscode.window.createTerminal("Reinstall JETLS");
        terminal.show();
        terminal.sendText(JETLS_INSTALL_COMMAND, true);
      } else if (selection === migrationGuideButton) {
        vscode.env.openExternal(vscode.Uri.parse(JETLS_MIGRATION_GUIDE_URL));
      }
    } else {
      // Normal update
      const message =
        "JETLS Client has been updated! Please make sure to update the JETLS server as well.";
      const updateButton = "Update JETLS";
      const changelogButton = "View CHANGELOG.md";

      const selection = await vscode.window.showInformationMessage(
        message,
        updateButton,
        changelogButton,
      );

      if (selection === updateButton) {
        const terminal = vscode.window.createTerminal("Update JETLS");
        terminal.show();
        terminal.sendText(JETLS_INSTALL_COMMAND, true);
      } else if (selection === changelogButton) {
        vscode.env.openExternal(vscode.Uri.parse(JETLS_CHANGELOG_URL));
      }
    }
  }

  if (currentVersion) {
    await context.globalState.update("version", currentVersion);
  }
}
