// Pure helpers for tool/generate_illustrations.mjs (SS-098), kept apart so
// tests can import them without launching a browser or a server.
import { existsSync, realpathSync, statSync } from 'node:fs';
import { isAbsolute, join, relative, resolve } from 'node:path';

/// Whether [child] is [parent] or inside it, by path components (not a
/// string prefix, so `/a/build2` is not inside `/a/build`).
export function within(parent, child) {
  const rel = relative(parent, child);
  return rel === '' || (!rel.startsWith('..') && !isAbsolute(rel));
}

/// The file to serve for [urlPath] from the canonical [build] directory, or
/// null to refuse. The final file (the request, or index.html for a missing
/// path or a directory) is chosen first, then canonicalized and checked, so
/// a symlinked index.html cannot escape the build either.
export function fileToServe(build, urlPath) {
  let decoded;
  try {
    decoded = decodeURIComponent(urlPath.split('?')[0]);
  } catch {
    return null;
  }
  let candidate = resolve(build, `.${decoded}`);
  if (!existsSync(candidate) || statSync(candidate).isDirectory()) {
    candidate = join(build, 'index.html');
  }
  if (!existsSync(candidate)) return null;
  const real = realpathSync(candidate);
  if (!within(build, real) || !statSync(real).isFile()) return null;
  return real;
}

/// Whether the page's announced mode lets this driver run arm model
/// traffic: the same mode, and for pre-made runs a compiled limit no larger
/// than the driver's own cap.
export function modeAllowed(driverMode, driverCap, announced) {
  if (!announced || announced.mode !== driverMode) return false;
  if (driverMode === 'premade') {
    return Number.isSafeInteger(announced.max) && announced.max >= 0 && announced.max <= driverCap;
  }
  return true;
}

/// The on-demand gate's evidence: the labelled image is on screen, exactly
/// one settled, successful `step_illustration` text leg for the expected
/// model was written, and the driver observed exactly one successful
/// request to that model.
export function gateEvidenceOk({ shown, legs, requests, model }) {
  if (shown !== true || typeof model !== 'string' || model === '') return false;
  if (!Array.isArray(legs) || legs.length !== 1) return false;
  const [leg] = legs;
  const legOk =
    leg.feature === 'step_illustration' &&
    Array.isArray(leg.kinds) && leg.kinds.length === 1 && leg.kinds[0] === 'text' &&
    leg.transferPermitted === true &&
    leg.provenance === 'cloudAdapter' &&
    leg.error === null &&
    leg.pending === false &&
    leg.modelLabel === `${model} (text→image)`;
  if (!legOk || !Array.isArray(requests)) return false;
  const modelRequests = requests.filter((r) => /generateContent/.test(r.path ?? ''));
  return (
    modelRequests.length === 1 &&
    modelRequests[0].status === 200 &&
    modelRequests[0].path.includes(`/models/${model}:generateContent`)
  );
}
