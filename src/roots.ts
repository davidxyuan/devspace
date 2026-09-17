import { lstatSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

export class AccessDeniedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AccessDeniedError";
  }
}

export function expandHomePath(path: string): string {
  if (path === "~") return homedir();
  if (path.startsWith("~/") || path.startsWith("~\\")) {
    return resolve(homedir(), path.slice(2));
  }

  return path;
}

export function isPathInsideRoot(path: string, root: string): boolean {
  const resolvedPath = resolve(expandHomePath(path));
  const resolvedRoot = resolve(expandHomePath(root));
  const relationship = relative(resolvedRoot, resolvedPath);

  return (
    relationship === "" ||
    (!isAbsolute(relationship) &&
      !relationship.startsWith("..") &&
      relationship !== ".." &&
      !relationship.includes(`..${sep}`))
  );
}

export function assertAllowedPath(path: string, allowedRoots: string[]): string {
  const resolvedPath = resolve(expandHomePath(path));
  for (const root of allowedRoots) {
    if (!isPathInsideRoot(resolvedPath, root)) continue;
    try {
      if (isPathInsideRoot(canonicalPath(resolvedPath), canonicalPath(resolve(expandHomePath(root))))) {
        return resolvedPath;
      }
    } catch {
      // Unresolvable links and inaccessible ancestors cannot establish containment.
    }
  }

  // A canonical destination that is explicitly allowlisted is trusted even
  // when the lexical path reaches it through an alias/junction. Resolve each
  // root independently so one unavailable root cannot mask a later valid one.
  let canonicalResolved: string | undefined;
  try { canonicalResolved = canonicalPath(resolvedPath); } catch { canonicalResolved = undefined; }
  if (canonicalResolved) {
    for (const root of allowedRoots) {
      try {
        const canonicalRoot = canonicalPath(resolve(expandHomePath(root)));
        if (isPathInsideRoot(canonicalResolved, canonicalRoot)) return resolvedPath;
      } catch {}
    }
  }

  // Windows DFS / SMB referrals can move a path lexically under an approved
  // network root into another UNC share without a filesystem symlink. Permit
  // only that server-controlled case; local symlink/junction traversal stays denied.
  if (process.platform === "win32" && canonicalResolved) {
    for (const root of allowedRoots) {
      const resolvedRoot = resolve(expandHomePath(root));
      if (!isPathInsideRoot(resolvedPath, resolvedRoot)) continue;
      try {
        const canonicalRoot = canonicalPath(resolvedRoot);
        if (!isUncPath(canonicalRoot) || !isUncPath(canonicalResolved)) continue;
        if (containsSymbolicTraversal(resolvedPath, resolvedRoot)) continue;
        return resolvedPath;
      } catch {}
    }
  }

  throw new AccessDeniedError(`Path is outside allowed roots: ${path}`);
}


function isUncPath(path: string): boolean {
  return path.startsWith("\\\\");
}

function containsSymbolicTraversal(path: string, root: string): boolean {
  const resolvedPath = resolve(path);
  const resolvedRoot = resolve(root);
  if (!isPathInsideRoot(resolvedPath, resolvedRoot)) return true;
  let current = resolvedRoot;
  if (lstatSync(current).isSymbolicLink()) return true;
  const relationship = relative(resolvedRoot, resolvedPath);
  if (!relationship) return false;
  for (const segment of relationship.split(sep).filter(Boolean)) {
    current = join(current, segment);
    try {
      if (lstatSync(current).isSymbolicLink()) return true;
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code === "ENOENT" || code === "ENOTDIR") return false;
      throw error;
    }
  }
  return false;
}

function canonicalPath(path: string): string {
  let existing = path;
  const missing: string[] = [];
  while (true) {
    try {
      lstatSync(existing);
      break;
    } catch (error) {
      const parent = dirname(existing);
      if ((error as NodeJS.ErrnoException).code !== "ENOENT" || parent === existing) throw error;
      missing.unshift(basename(existing));
      existing = parent;
    }
  }
  // Resolve outside the ENOENT fallback: an existing dangling link must fail closed.
  return resolve(realpathSync.native(existing), ...missing);
}

export function resolveAllowedPath(inputPath: string, cwd: string, allowedRoots: string[]): string {
  const absolutePath = resolve(cwd, inputPath);
  return assertAllowedPath(absolutePath, allowedRoots);
}
