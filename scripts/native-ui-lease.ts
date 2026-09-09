import { dlopen, FFIType } from "bun:ffi";
import { closeSync, constants, fstatSync, ftruncateSync, openSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

/** The kernel releases this descriptor's flock on normal exit or process death.
 * Keep the file inode stable: unlinking a PID file permits competing owners. */
export function acquireGUILease(
  path = resolve(tmpdir(), "trigo-native-ui-acceptance.lock"),
): () => void {
  return acquireLocalLease(path, "native UI session");
}

export function acquireLocalLease(path: string, resource: string): () => void {
  if (process.platform !== "darwin") {
    throw new Error(`The ${resource} lease requires macOS`);
  }
  const library = dlopen("/usr/lib/libSystem.B.dylib", {
    flock: { args: [FFIType.int, FFIType.int], returns: FFIType.int },
  });
  let descriptor: number | undefined;
  const release = () => {
    if (descriptor !== undefined) {
      const value = descriptor;
      descriptor = undefined;
      try {
        closeSync(value);
      } finally {
        library.close();
      }
    }
  };
  try {
    descriptor = openSync(
      path,
      constants.O_CREAT | constants.O_WRONLY | constants.O_NOFOLLOW,
      0o600,
    );
    const stat = fstatSync(descriptor);
    if (!stat.isFile() || stat.nlink !== 1) {
      throw new Error(`The ${resource} lease must be one regular file`);
    }
    // Darwin sys/fcntl.h: LOCK_EX (0x02) | LOCK_NB (0x04).
    if (library.symbols.flock(descriptor, 0x02 | 0x04) !== 0) {
      throw new Error(`The ${resource} is already owned or its kernel lease is unavailable`);
    }
    ftruncateSync(descriptor, 0);
    writeFileSync(descriptor, String(process.pid));
    return release;
  } catch (error) {
    if (descriptor === undefined) {
      library.close();
    } else {
      release();
    }
    throw error;
  }
}
