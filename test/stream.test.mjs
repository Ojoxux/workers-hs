import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { BASE, fakeCtx, loadWorker } from "./harness.mjs";

const worker = await loadWorker("test-worker", { exposeErrors: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function send(path, init) {
  return worker.fetch(new Request(`${BASE}${path}`, init), {}, fakeCtx().ctx);
}

async function readChunks(res) {
  const reader = res.body.getReader();
  const out = [];
  for (;;) {
    const { done, value } = await reader.read();
    if (done) return out;
    out.push({ at: Date.now(), text: new TextDecoder().decode(value), length: value.length });
  }
}

test("bodyStream sends each flushed chunk before the writer finishes", async () => {
  const start = Date.now();
  const chunks = await readChunks(await send("/stream/slow"));
  assert.deepEqual(chunks.map((c) => c.text), ["one\n", "two\n", "three\n"]);
  assert.ok(chunks[0].at - start < 250, `first chunk after ${chunks[0].at - start}ms`);
  assert.ok(chunks[2].at - chunks[0].at >= 500, "chunks were not spread out");
});

test("bodyStream buffers small writes up to 16 KB", async () => {
  const chunks = await readChunks(await send("/stream/big"));
  assert.deepEqual(chunks.map((c) => c.length), [16390, 3610]);
});

test("an exception in the writer errors the stream and is logged", async () => {
  const logged = mock.method(console, "error", () => {});
  try {
    const res = await send("/stream/fail");
    assert.equal(res.status, 200);
    await assert.rejects(res.text());
    assert.ok(logged.mock.calls.some((c) => /stream boom/.test(String(c.arguments[0]))));
  } finally {
    logged.mock.restore();
  }
});

test("a cancelled reader stops the writer quietly", async () => {
  const logged = mock.method(console, "error", () => {});
  try {
    const reader = (await send("/stream/endless")).body.getReader();
    await reader.read();
    await reader.cancel();
    await sleep(100);
    const stoppedAt = await (await send("/stream/endless-writes")).text();
    await sleep(200);
    assert.equal(await (await send("/stream/endless-writes")).text(), stoppedAt);
    assert.ok(Number(stoppedAt) < 10, `wrote ${stoppedAt} chunks`);
    assert.equal(logged.mock.callCount(), 0);
  } finally {
    logged.mock.restore();
  }
});

test("bytes reads a bodyStream", async () => {
  assert.equal(await (await send("/stream/bytes")).text(), "hello stream");
});
