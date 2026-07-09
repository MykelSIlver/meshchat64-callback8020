/* ============================================================
 * polyfills-src.js — readable source of /c64/polyfills.js
 * Compatibility layer for the SailfishOS WebView (Gecko 91).
 * Load BEFORE script.js. Never touches upstream code.
 *
 * Build (bundles fflate, strips comments, ~15.8 kB output):
 *   npm install fflate esbuild
 *   npx esbuild polyfills-src.js --bundle --format=iife \
 *       --minify-whitespace --target=firefox91 --outfile=polyfills.js
 *
 * Covers:
 *  1. crypto.randomUUID            (native since Firefox 95)
 *  2. CompressionStream (gzip)     (native since Firefox 113)
 *  3. DecompressionStream (gzip)   (native since Firefox 113)
 *  4. MediaRecorder mimeType guard (audio/webm not supported everywhere)
 *
 * Note: Gecko 91 has ReadableStream but NO WritableStream/
 * TransformStream, so this polyfill implements the writable side
 * itself (duck-typed) and uses a real ReadableStream as the output,
 * so `new Response(stream.readable)` keeps working natively.
 * Compression via fflate → real gzip, byte-compatible with modern
 * browsers and with whatever the server/other clients expect.
 * (Compression matters: upstream runs it INSIDE the encryption
 * pipeline, so skipping it is not an option.)
 * ============================================================ */

import { gzipSync, gunzipSync, zlibSync, unzlibSync, deflateSync, inflateSync } from 'fflate';

(function () {
  'use strict';

  /* ---------- 1. crypto.randomUUID (Firefox 95+) ---------- */
  if (window.crypto && !('randomUUID' in window.crypto)) {
    window.crypto.randomUUID = function randomUUID() {
      // RFC 4122 v4 built on getRandomValues (available since FF 21)
      const b = crypto.getRandomValues(new Uint8Array(16));
      b[6] = (b[6] & 0x0f) | 0x40; // version 4
      b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
      const h = [];
      for (let i = 0; i < 256; i++) h.push((i + 0x100).toString(16).slice(1));
      return (
        h[b[0]] + h[b[1]] + h[b[2]] + h[b[3]] + '-' +
        h[b[4]] + h[b[5]] + '-' +
        h[b[6]] + h[b[7]] + '-' +
        h[b[8]] + h[b[9]] + '-' +
        h[b[10]] + h[b[11]] + h[b[12]] + h[b[13]] + h[b[14]] + h[b[15]]
      );
    };
  }

  /* ---------- 2 & 3. CompressionStream / DecompressionStream ---------- */
  // Non-streaming (collects chunks, processes on close) — plenty for chat
  // payloads and exactly the pattern upstream MeshChat uses:
  //   writer.write(...); writer.close(); new Response(stream.readable)
  function toU8(chunk) {
    if (chunk instanceof Uint8Array) return chunk;
    if (chunk instanceof ArrayBuffer) return new Uint8Array(chunk);
    if (ArrayBuffer.isView(chunk)) return new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength);
    throw new TypeError('Expected BufferSource chunk');
  }
  function concat(chunks) {
    let total = 0;
    for (const c of chunks) total += c.length;
    const out = new Uint8Array(total);
    let off = 0;
    for (const c of chunks) { out.set(c, off); off += c.length; }
    return out;
  }
  const CODECS = {
    compress:   { 'gzip': gzipSync,   'deflate': zlibSync,   'deflate-raw': deflateSync },
    decompress: { 'gzip': gunzipSync, 'deflate': unzlibSync, 'deflate-raw': inflateSync }
  };

  function makeStreamClass(direction) {
    return class {
      constructor(format) {
        const codec = CODECS[direction][format];
        if (!codec) throw new TypeError("Unsupported compression format: '" + format + "'");
        const chunks = [];
        let ctrl;
        this.readable = new ReadableStream({ start(c) { ctrl = c; } });
        this.writable = {
          getWriter() {
            let closed = false;
            return {
              ready: Promise.resolve(),
              closed: new Promise(() => {}),
              desiredSize: 1,
              write(chunk) {
                if (closed) return Promise.reject(new TypeError('Writer closed'));
                try { chunks.push(toU8(chunk)); return Promise.resolve(); }
                catch (e) { ctrl.error(e); return Promise.reject(e); }
              },
              close() {
                if (closed) return Promise.reject(new TypeError('Writer closed'));
                closed = true;
                try {
                  ctrl.enqueue(codec(concat(chunks)));
                  ctrl.close();
                  return Promise.resolve();
                } catch (e) { ctrl.error(e); return Promise.reject(e); }
              },
              abort(reason) { closed = true; ctrl.error(reason); return Promise.resolve(); },
              releaseLock() {}
            };
          }
        };
      }
    };
  }

  if (typeof window.CompressionStream === 'undefined') {
    window.CompressionStream = makeStreamClass('compress');
  }
  if (typeof window.DecompressionStream === 'undefined') {
    window.DecompressionStream = makeStreamClass('decompress');
  }

  /* ---------- 4. MediaRecorder mimeType guard ---------- */
  // Firefox/Gecko records audio as audio/ogg (Opus) by default and throws a
  // NotSupportedError on an unsupported mimeType option such as
  // "audio/webm". This wrapper silently drops an unsupported mimeType so the
  // recording simply proceeds in the native format.
  if (window.MediaRecorder && typeof MediaRecorder.isTypeSupported === 'function') {
    const Orig = window.MediaRecorder;
    const needsGuard = !Orig.isTypeSupported('audio/webm');
    if (needsGuard) {
      const Wrapped = function MediaRecorder(stream, options) {
        if (options && options.mimeType && !Orig.isTypeSupported(options.mimeType)) {
          options = Object.assign({}, options);
          delete options.mimeType;
        }
        return new Orig(stream, options);
      };
      Wrapped.prototype = Orig.prototype;
      Wrapped.isTypeSupported = Orig.isTypeSupported.bind(Orig);
      window.MediaRecorder = Wrapped;
    }
  }
})();
