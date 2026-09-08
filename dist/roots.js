import { lstatSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, relative, resolve, sep } from "node:path";
export class AccessDeniedError extends Error {
    constructor(message) {
        super(message);
        this.name = "AccessDeniedError";
    }
}
export function expandHomePath(path) {
    if (path === "~")
        return homedir();
    if (path.startsWith("~/") || path.startsWith("~\\")) {
        return resolve(homedir(), path.slice(2));
    }
    return path;
}
export function isPathInsideRoot(path, root) {
    const resolvedPath = resolve(expandHomePath(path));
    const resolvedRoot = resolve(expandHomePath(root));
    const relationship = relative(resolvedRoot, resolvedPath);
    return (relationship === "" ||
        (!isAbsolute(relationship) &&
            !relationship.startsWith("..") &&
            relationship !== ".." &&
            !relationship.includes(`..${sep}`)));
}
export function assertAllowedPath(path, allowedRoots) {
    const resolvedPath = resolve(expandHomePath(path));
    for (const root of allowedRoots) {
        if (!isPathInsideRoot(resolvedPath, root))
            continue;
        try {
            if (isPathInsideRoot(canonicalPath(resolvedPath), canonicalPath(resolve(expandHomePath(root))))) {
                return resolvedPath;
            }
        }
        catch {
            // Unresolvable links and inaccessible ancestors cannot establish containment.
        }
    }
    throw new AccessDeniedError(`Path is outside allowed roots: ${path}`);
}
function canonicalPath(path) {
    let existing = path;
    const missing = [];
    while (true) {
        try {
            lstatSync(existing);
            break;
        }
        catch (error) {
            const parent = dirname(existing);
            if (error.code !== "ENOENT" || parent === existing)
                throw error;
            missing.unshift(basename(existing));
            existing = parent;
        }
    }
    // Resolve outside the ENOENT fallback: an existing dangling link must fail closed.
    return resolve(realpathSync.native(existing), ...missing);
}
export function resolveAllowedPath(inputPath, cwd, allowedRoots) {
    const absolutePath = resolve(cwd, inputPath);
    return assertAllowedPath(absolutePath, allowedRoots);
}
