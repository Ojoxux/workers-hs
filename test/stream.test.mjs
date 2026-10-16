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

function chunkedBody(parts) {
  return new ReadableStream({
    start(c) {
      for (const p of parts) c.enqueue(new TextEncoder().encode(p));
      c.close();
    },
  });
}

test("bodyReader reads a request body chunk by chunk", async () => {
  const res = await send("/stream/chunks", { method: "POST", body: chunkedBody(["ab", "cde", "f"]), duplex: "half" });
  assert.equal(await res.text(), "chunks=3 bytes=6");
});

test("bodyReader of a bodyless request ends at once", async () => {
  assert.equal(await (await send("/stream/chunks")).text(), "chunks=0 bytes=0");
});

test("bodyReader after a read throws BodyAlreadyUsed", async () => {
  const res = await send("/stream/reader-after-read", { method: "POST", body: "x" });
  assert.equal(res.status, 500);
  assert.match(await res.text(), /body already used/);
});

const yesod = await loadWorker("test-yesod", { exposeErrors: true });

test("Yesod respondSource with sendFlush streams", async () => {
  const start = Date.now();
  const env = { SESSION_KEY: "test-session-key-current-0123456789abcdef" };
  const res = await yesod.fetch(new Request(`${BASE}/stream`), env, fakeCtx().ctx);
  const chunks = await readChunks(res);
  assert.equal(chunks.map((c) => c.text).join(""), "one\ntwo\nthree\n");
  assert.ok(chunks[0].at - start < 250, `first chunk after ${chunks[0].at - start}ms`);
  assert.ok(chunks.length >= 3, `${chunks.length} chunks`);
});

test("a Yesod source that holds a resource streams to the end", async () => {
  const logged = mock.method(console, "error", () => {});
  try {
    const env = { SESSION_KEY: "test-session-key-current-0123456789abcdef" };
    const res = await yesod.fetch(new Request(`${BASE}/stream/resource`), env, fakeCtx().ctx);
    assert.equal(await res.text(), "inside\n");
    assert.equal(logged.mock.callCount(), 0, String(logged.mock.calls[0]?.arguments[0]));
  } finally {
    logged.mock.restore();
  }
});

test("the request stays alive until a WAI Application has finished", async () => {
  const env = { SESSION_KEY: "test-session-key-current-0123456789abcdef" };
  const { ctx, pending } = fakeCtx();
  const res = await yesod.fetch(new Request(`${BASE}/stream/resource`), env, ctx);
  assert.equal(pending.length, 1);
  let finished = false;
  pending[0].then(() => (finished = true));
  assert.equal(await res.text(), "inside\n");
  await pending[0];
  assert.ok(finished);
});
