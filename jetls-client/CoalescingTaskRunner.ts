export class CoalescingTaskRunner {
  private activeRun: Promise<void> | undefined;
  private runRequested = false;

  constructor(private readonly runOnce: () => Promise<void>) {}

  run(): Promise<void> {
    this.runRequested = true;
    if (this.activeRun === undefined) {
      this.activeRun = Promise.resolve().then(() => this.runRequestedTasks());
    }
    return this.activeRun;
  }

  private async runRequestedTasks(): Promise<void> {
    try {
      while (this.runRequested) {
        this.runRequested = false;
        await this.runOnce();
      }
    } finally {
      this.activeRun = undefined;
    }
  }
}
