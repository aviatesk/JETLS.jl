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

export class StartupStatusBar {
  private readonly item: vscode.StatusBarItem;
  private hideTimer: NodeJS.Timeout | undefined;
  private suppressed = false;

  constructor() {
    this.item = vscode.window.createStatusBarItem(
      vscode.StatusBarAlignment.Left,
      100,
    );
    this.item.name = "JETLS server startup status";
    this.item.command = {
      command: "jetls-client.showOutput",
      title: "Show JETLS output",
    };
  }

  show(status: ServerStartupStatus): void {
    if (this.suppressed) {
      return;
    }
    this.clearHideTimer();

    this.item.backgroundColor = undefined;
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
