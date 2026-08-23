export class CoalescingTaskRunner {
  private activeRun: Promise<void> | undefined;
  private runRequested = false;

  constructor(private readonly runOnce: () => Promise<void>) {}

  get active(): Promise<void> | undefined {
    return this.activeRun;
  }

  get pending(): boolean {
    return this.runRequested;
  }

  run(): Promise<void> {
    this.runRequested = true;
    if (this.activeRun === undefined) {
      this.activeRun = Promise.resolve().then(() => this.runRequestedTasks());
    }
    return this.activeRun;
  }

  private async runRequestedTasks(): Promise<void> {
    let lastFailure: { error: unknown } | undefined;
    try {
      while (this.runRequested) {
        this.runRequested = false;
        try {
          await this.runOnce();
          lastFailure = undefined;
        } catch (error) {
          lastFailure = { error };
        }
      }
      if (lastFailure !== undefined) {
        throw lastFailure.error;
      }
    } finally {
      this.activeRun = undefined;
    }
  }
}
