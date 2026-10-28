// Screendrop upload endpoint hosted on the Multinational Academy domain.
// Route: example.com/screendrop*
// App worker URL: https://example.com/screendrop
//
// Retention: at most 20 objects AND at most 100 MB in total, whichever comes
// first. The oldest uploads beyond either limit are deleted automatically.
// Only keys prefixed "screendrop-" are counted or deleted, so other objects in
// the shared bucket are untouched.

const PREFIX = "screendrop-";
const MAX_OBJECTS = 20;
const MAX_BYTES = 100 * 1024 * 1024;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;
    const auth = request.headers.get("Authorization") || "";
    const match = auth.match(/^Bearer\s+(.+)$/i);
    const token = match ? match[1].trim() : "";

    if (path.endsWith("/api/ping") && request.method === "GET") {
      if (!authorized(token, env)) return json({ error: "unauthorized" }, 401);
      return json({ version: "academy-upload-2" });
    }
    if (path.endsWith("/api/setup") && request.method === "POST") {
      return json({ ok: true });
    }
    if (path.endsWith("/api/status") && request.method === "GET") {
      if (!authorized(token, env)) return json({ error: "unauthorized" }, 401);
      const usage = await usageOf(env);
      return json({
        count: usage.count,
        bytes: usage.bytes,
        maxObjects: MAX_OBJECTS,
        maxBytes: MAX_BYTES
      });
    }
    if (path.endsWith("/api/upload") && request.method === "PUT") {
      return upload(request, env, url, token);
    }
    if (path.indexOf("/api/upload/") !== -1 && request.method === "DELETE") {
      return remove(request, env, url, token);
    }
    if (path.indexOf("/api/uploads/") !== -1 && request.method === "GET") {
      return serve(env, url);
    }
    return new Response("Not found", { status: 404 });
  }
};

function json(value, status) {
  return new Response(JSON.stringify(value), {
    status: status || 200,
    headers: { "content-type": "application/json; charset=utf-8" }
  });
}

function authorized(token, env) {
  return Boolean(token) && Boolean(env.UPLOAD_TOKEN) && token === env.UPLOAD_TOKEN;
}

async function upload(request, env, url, token) {
  if (!authorized(token, env)) return json({ error: "unauthorized" }, 401);

  const declared = Number(request.headers.get("content-length") || "0");
  if (declared > MAX_BYTES) {
    return json({ error: "file exceeds the 100 MB Screendrop limit" }, 413);
  }

  const rawName = request.headers.get("X-Filename") || "screenshot.png";
  const filename = rawName.replace(/[^A-Za-z0-9._-]+/g, "_");
  const type = request.headers.get("Content-Type") || "application/octet-stream";
  let ext = "bin";
  if (filename.indexOf(".") !== -1) ext = filename.split(".").pop().toLowerCase();
  else if (type.indexOf("png") !== -1) ext = "png";

  const id = PREFIX + crypto.randomUUID() + "." + ext;
  const object = await env.BUCKET.put(id, request.body, {
    httpMetadata: { contentType: type }
  });
  const size = object ? object.size : declared;

  if (size > MAX_BYTES) {
    await env.BUCKET.delete(id);
    return json({ error: "file exceeds the 100 MB Screendrop limit" }, 413);
  }

  await trim(env);
  const share = url.origin + "/screendrop/api/uploads/" + encodeURIComponent(id);
  return json({ id: id, url: share, filename: filename, size: size }, 201);
}

async function remove(request, env, url, token) {
  if (!authorized(token, env)) return json({ error: "unauthorized" }, 401);
  const id = decodeURIComponent(url.pathname.split("/").pop() || "");
  if (id.indexOf(PREFIX) !== 0) return json({ error: "not found" }, 404);
  await env.BUCKET.delete(id);
  return json({ ok: true });
}

async function serve(env, url) {
  const id = decodeURIComponent(url.pathname.split("/").pop() || "");
  const object = await env.BUCKET.get(id);
  if (!object) return new Response("Not found", { status: 404 });
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("cache-control", "public, max-age=31536000, immutable");
  return new Response(object.body, { headers: headers });
}

async function usageOf(env) {
  const list = await env.BUCKET.list({ prefix: PREFIX, limit: 1000 });
  let bytes = 0;
  for (const object of list.objects) bytes += object.size;
  return { count: list.objects.length, bytes: bytes };
}

async function trim(env) {
  const list = await env.BUCKET.list({ prefix: PREFIX, limit: 1000 });
  const objects = list.objects.slice().sort(function (a, b) {
    return b.uploaded.getTime() - a.uploaded.getTime();
  });

  let kept = 0;
  let total = 0;
  for (const object of objects) {
    if (kept >= MAX_OBJECTS || total + object.size > MAX_BYTES) {
      await env.BUCKET.delete(object.key);
    } else {
      kept += 1;
      total += object.size;
    }
  }
}
