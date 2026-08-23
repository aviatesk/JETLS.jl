import type * as cp from "node:child_process";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";

export class FakeChildProcess extends EventEmitter {
  readonly stdout = new PassThrough();
  readonly stderr = new PassThrough();
  readonly killCalls: (NodeJS.Signals | number | undefined)[] = [];
  pid: number | undefined = 1234;
  onKill: ((signal?: NodeJS.Signals | number) => void) | undefined;

  kill(signal?: NodeJS.Signals | number): boolean {
    this.killCalls.push(signal);
    this.onKill?.(signal);
    return true;
  }

  close(code: number | null, signal: NodeJS.Signals | null): void {
    this.stdout.end();
    this.stderr.end();
    this.emit("exit", code, signal);
    this.emit("close", code, signal);
  }

  asChildProcess(): cp.ChildProcess {
    return this as unknown as cp.ChildProcess;
  }
}

export interface SpawnCall {
  command: string;
  args: readonly string[];
  options: cp.SpawnOptions;
}
