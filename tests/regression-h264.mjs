/*
 * Regression test for the H.264 feature (server + noVNC contract).
 *
 * Run with:  node tests/regression-h264.mjs
 *
 * It verifies, without an iOS device or a browser:
 *  1. The noVNC H.264 parser (H264Parser) recognises an IDR keyframe and
 *     extracts SPS/PPS — this is exactly the "noVNC can't decode keyframes"
 *     failure that happens when the server only emits P-frames.
 *  2. A P-slice-only stream is NOT treated as a keyframe (guard for the
 *     "VideoToolbox outputs only non-keyframes" regression).
 *  3. The Open H.264 encoding number is 50 on BOTH sides (server + noVNC),
 *     not the TurboVNC/QEMU "VA H.264" number 0x48323634.
 *  4. The server forces IDR keyframes (VideoToolbox ForceKeyFrame + GOP).
 *
 * This is a pure Node.js script; it imports the actual bundled noVNC source,
 * not a copy. It stubs the two browser globals that noVNC's logging module
 * touches at import time.
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';

// ---------------------------------------------------------------------------
// Resolve repo-relative paths from this file, so the test can run from any cwd.
// ---------------------------------------------------------------------------
const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..');
const rel = (p) => path.join(repoRoot, p);

// noVNC's logging module references `window` at import time; stub it.
globalThis.window = {
    console,
    Error,
};

const { H264Parser } = await import(
    pathToFileURL(rel('layout/usr/share/trollvnc/webclients/novnc/core/decoders/h264.js'))
);
const { encodings } = await import(
    pathToFileURL(rel('layout/usr/share/trollvnc/webclients/novnc/core/encodings.js'))
);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
const START_CODE_4 = Uint8Array.from([0x00, 0x00, 0x00, 0x01]);
const START_CODE_3 = Uint8Array.from([0x00, 0x00, 0x01]);

function concat(parts) {
    const len = parts.reduce((n, p) => n + p.length, 0);
    const out = new Uint8Array(len);
    let off = 0;
    for (const p of parts) {
        out.set(p, off);
        off += p.length;
    }
    return out;
}

// A minimal Baseline SPS: NAL header 0x67 (type 7), then profile/constraint/level.
const SPS = Uint8Array.from([0x67, 0x42, 0x00, 0x1e, 0x8c, 0x8a]);
// A minimal PPS: NAL header 0x68 (type 8).
const PPS = Uint8Array.from([0x68, 0xce, 0x06, 0xe2]);
// An IDR slice: NAL header 0x65 (type 5).
const IDR = Uint8Array.from([0x65, 0x88, 0x84, 0x00]);
// A non-IDR (P) slice: NAL header 0x41 (type 1).
const P_SLICE = Uint8Array.from([0x41, 0x9a, 0x00]);

function parseAnnexB(stream) {
    const parser = new H264Parser(stream);
    const frame = parser.parse();
    return { frame, parser };
}

// ---------------------------------------------------------------------------
// Assertions
// ---------------------------------------------------------------------------
let passed = 0;
function ok(cond, label) {
    assert.ok(cond, label);
    passed += 1;
    console.log(`  ok - ${label}`);
}

console.log('H.264 regression tests');

// 1) SPS + PPS + IDR (4-byte start codes, exactly what the server emits) is a keyframe.
{
    const stream = concat([START_CODE_4, SPS, START_CODE_4, PPS, START_CODE_4, IDR]);
    const { frame, parser } = parseAnnexB(stream);
    ok(frame !== null, 'SPS+PPS+IDR stream yields a frame');
    ok(frame.key === true, 'SPS+PPS+IDR stream is recognised as a keyframe');
    ok(parser.profileIdc === 0x42, 'SPS profile_idc is parsed (Baseline 0x42)');
    ok(parser.levelIdc === 0x1e, 'SPS level_idc is parsed');
}

// 2) 3-byte start codes are also accepted (Annex-B compatibility).
{
    const stream = concat([START_CODE_3, SPS, START_CODE_3, PPS, START_CODE_3, IDR]);
    const { frame } = parseAnnexB(stream);
    ok(frame !== null && frame.key === true, '3-byte start-code keyframe is recognised');
}

// 3) A P-slice-only stream is NOT a keyframe (the classic "only P-frames" bug).
{
    const stream = concat([START_CODE_4, P_SLICE]);
    const { frame, parser } = parseAnnexB(stream);
    ok(frame !== null, 'P-slice stream yields a frame');
    ok(frame.key === false, 'P-slice stream is NOT a keyframe');
    ok(parser.profileIdc === null, 'P-slice stream has no SPS (cannot configure decoder)');
}

// 4) Both sides agree on the Open H.264 encoding number (50), not 0x48323634.
{
    ok(encodings.encodingH264 === 50, `noVNC encodings.encodingH264 === 50 (got ${encodings.encodingH264})`);
}

// 5) Source-contract guards: server must use 50 and must force IDR keyframes.
{
    const serverSrc = readFileSync(rel('src/trollvncserver.mm'), 'utf8');
    ok(
        serverSrc.includes('static const int kTvEncodingOpenH264 = 50;'),
        'server defines the Open H.264 encoding as 50'
    );

    const encoderSrc = readFileSync(rel('src/H264Encoder.mm'), 'utf8');
    ok(
        encoderSrc.includes('kVTEncodeFrameOptionKey_ForceKeyFrame'),
        'server forces IDR keyframes (kVTEncodeFrameOptionKey_ForceKeyFrame)'
    );
    ok(
        encoderSrc.includes('kVTCompressionPropertyKey_MaxKeyFrameInterval'),
        'server emits periodic keyframes (kVTCompressionPropertyKey_MaxKeyFrameInterval)'
    );
    ok(
        encoderSrc.includes('kVTCompressionPropertyKey_AllowFrameReordering'),
        'server disables B-frame reordering (kVTCompressionPropertyKey_AllowFrameReordering)'
    );
}

console.log(`\n${passed} checks passed.`);
