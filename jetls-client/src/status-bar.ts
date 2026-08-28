import * as vscode from "vscode";

export type ServerStartupStatus =
  | "checking"
  | "starting"
  | "restarting"
  | "precompiling"
  | "ready"
  | "failed"
  | "restart-failed"
  | "crashed";

const SHOW_OUTPUT_COMMAND: vscode.Command = {
  command: "jetls-client.showOutput",
  title: "Show JETLS output",
};

export class StartupStatusBar {
  private readonly item: vscode.StatusBarItem;
  private hideTimer: NodeJS.Timeout | undefined;
  private suppressed = false;
  private managedProgress = false;

  constructor() {
    this.item = vscode.window.createStatusBarItem(
      vscode.StatusBarAlignment.Left,
      100,
    );
    this.item.name = "JETLS server startup status";
    this.item.command = SHOW_OUTPUT_COMMAND;
  }

  show(status: ServerStartupStatus): void {
    if (this.suppressed) {
      return;
    }
    this.clearHideTimer();
    this.managedProgress = false;

    this.item.backgroundColor = undefined;
    this.item.command = SHOW_OUTPUT_COMMAND;
    switch (status) {
      case "checking":
        this.item.text = "$(sync~spin) Checking JETLS...";
        this.item.tooltip = "Checking the JETLS executable and version.";
        break;
      case "starting":
        this.item.text = "$(sync~spin) Starting JETLS...";
        this.item.tooltip = "Starting the JETLS language server.";
        break;
      case "restarting":
        this.item.text = "$(sync~spin) Restarting JETLS...";
        this.item.tooltip = "Restarting the JETLS language server.";
        break;
      case "precompiling":
        this.item.text = "$(sync~spin) Precompiling JETLS...";
        this.item.tooltip =
          "Precompiling JETLS. The first startup may take longer.";
        break;
      case "ready":
        this.item.text = "$(check) JETLS ready";
        this.item.tooltip = "JETLS started successfully.";
        this.hideTimer = setTimeout(() => {
          this.item.hide();
          this.hideTimer = undefined;
        }, 3000);
        break;
      case "failed":
        this.item.text = "$(error) JETLS failed to start";
        this.item.tooltip =
          "JETLS failed to start. Click to open the JETLS output.";
        this.item.backgroundColor = new vscode.ThemeColor(
          "statusBarItem.errorBackground",
        );
        break;
      case "restart-failed":
        this.item.text = "$(error) JETLS restart failed";
        this.item.tooltip =
          "JETLS could not be stopped for restart. Click to open the JETLS output.";
        this.item.backgroundColor = new vscode.ThemeColor(
          "statusBarItem.errorBackground",
        );
        break;
      case "crashed":
        this.item.text = "$(error) JETLS stopped";
        this.item.tooltip =
          "JETLS stopped unexpectedly. Click to open the JETLS output.";
        this.item.backgroundColor = new vscode.ThemeColor(
          "statusBarItem.errorBackground",
        );
        break;
    }
    this.item.show();
  }

  /** Shows a spinner with a managed-installation progress message. */
  showManagedProgress(message: string): void {
    if (this.suppressed) {
      return;
    }
    this.clearHideTimer();
    this.managedProgress = true;
    this.item.backgroundColor = undefined;
    this.item.command = SHOW_OUTPUT_COMMAND;
    this.item.text = `$(sync~spin) ${message}`;
    this.item.tooltip = "Setting up the managed JETLS installation.";
    this.item.show();
  }

  /**
   * Updates only the tooltip with the latest installation output line;
   * a no-op unless the managed-progress spinner is showing.
   */
  showManagedProgressDetail(line: string): void {
    if (this.suppressed || !this.managedProgress) {
      return;
    }
    this.item.tooltip = `${line}\nClick to open the JETLS output.`;
  }

  /**
   * Shows a persistent managed-installation failure with a one-line
   * summary; clicking the item opens the output channel, which holds the
   * full failure details.
   */
  showManagedFailure(summary: string): void {
    if (this.suppressed) {
      return;
    }
    this.clearHideTimer();
    this.managedProgress = false;
    this.item.text = "$(error) Managed JETLS failed";
    this.item.tooltip = `${summary}\nClick to open the JETLS output.`;
    this.item.backgroundColor = new vscode.ThemeColor(
      "statusBarItem.errorBackground",
    );
    this.item.command = SHOW_OUTPUT_COMMAND;
    this.item.show();
  }

  /** Ignore further status updates; used once deactivation has started. */
  suppress(): void {
    this.suppressed = true;
    this.clearHideTimer();
  }

  dispose(): void {
    this.clearHideTimer();
    this.item.dispose();
  }

  private clearHideTimer(): void {
    if (this.hideTimer !== undefined) {
      clearTimeout(this.hideTimer);
      this.hideTimer = undefined;
    }
  }
}
