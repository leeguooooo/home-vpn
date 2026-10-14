// node tests/sub_worker_check.mjs <fixture.json> <bundled worker.mjs>: runs sub/worker.js (bundled by esbuild, like
// wrangler does, so the .ps1 text imports resolve) against a fake KV holding what server/sub.py sealed
import fs from "node:fs";
import { pathToFileURL } from "node:url";
const worker = (await import(pathToFileURL(process.argv[3]).href)).default;
const fx = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const kv = new Map();
for (const [tok, id] of fx.records) kv.set("u:" + id, JSON.stringify({ files: fx.files[tok] }));
const env = { ADMIN_TOKEN: "admintok", SUBS: {
  get: async (k, t) => (kv.has(k) ? (t === "json" ? JSON.parse(kv.get(k)) : kv.get(k)) : null),
  put: async (k, v) => kv.set(k, v), delete: async (k) => kv.delete(k),
  list: async ({ prefix }) => ({ keys: [...kv.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })) }) } };
const BROWSER = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1";
const get = async (p, init = {}) => {
  const r = await worker.fetch(new Request("https://sub.example" + p, init), env);
  return [r.status, await r.text(), r.headers];
};
const ua = (s) => ({ headers: { "user-agent": s } });
const out = {};
for (const f of ["shadowrocket", "singbox", "clash"]) { const [s, b] = await get(`/s/${fx.token}/${f}`, ua(BROWSER)); out[f] = { s, b }; }
const [ps, pb] = await get(`/s/${fx.token}`, ua(BROWSER));
out.page = { s: ps, iosFirst: pb.indexOf('id="ios"') < pb.indexOf('id="android"'),
             hasImport: pb.includes("shadowrocket://add/sub://") && pb.includes("flclash://install-config"),
             hasTv: pb.includes("/t/" + fx.tv) };
out.pageAndroid = (await get(`/s/${fx.token}`, ua("Mozilla/5.0 (Linux; Android 15; 2312DRA50C) Chrome/140 Mobile Safari/537.36")))[1].indexOf('id="android"') <
                  (await get(`/s/${fx.token}`, ua("Mozilla/5.0 (Linux; Android 15; 2312DRA50C) Chrome/140 Mobile Safari/537.36")))[1].indexOf('id="ios"');
out.auto = {};
for (const [name, s] of [["shadowrocket", "Shadowrocket/2508 CFNetwork/3826 Darwin/24.4.0"], ["singbox", "SFA/1.14.2 (Android 15)"],
                         ["clash", "ClashMetaForAndroid/2.11.34"], ["clash2", "FlClash/v0.8.98 clash-verge"], ["unknown", "okhttp/4.12"]]) {
  out.auto[name] = (await get(`/s/${fx.token}`, ua(s)))[1];
}
out.tv = (await get(`/t/${fx.tv}`, ua("ClashMetaForAndroid/2.11.34")))[1];
out.tvBad = (await get(`/t/${fx.tv.slice(0, -1)}0`, ua("ClashMetaForAndroid/2.11.34")))[0];
out.wrong = (await get(`/s/${fx.token.slice(0, -1)}x/singbox`))[0];
out.adminNoAuth = (await get(`/admin/list`))[0];
out.adminList = (await get(`/admin/list`, { headers: { authorization: "Bearer admintok" } }))[1];
out.del = (await get(`/admin/u/${fx.records[0][1]}`, { method: "DELETE", headers: { authorization: "Bearer admintok" } }))[0];
out.afterDel = (await get(`/s/${fx.token}/singbox`))[0];
kv.set("u:" + fx.records[0][1], JSON.stringify({ files: fx.files[fx.token] }));
kv.set("dlmeta", JSON.stringify({ "sing-box-windows-amd64.zip": { version: "v1.14.1" } }));
const win = (await get(`/s/${fx.token}/windows`, ua("Mozilla/5.0 (Windows NT 10.0; Win64; x64) WindowsPowerShell/5.1")))[1];
out.win = { hasUrl: win.includes(`'https://sub.example/s/${fx.token}'`), hasVersion: win.includes("$want = '1.14.1'"),
            placeholders: (win.match(/__[A-Z_]+__/g) || []), files: (win.match(/'(\w+\.ps1)' = '/g) || []).length,
            // the embedded tray script comes back intact, with the site names filled in (fx.brand: the record's brand)
            trayRoundTrip: ((t) => t.includes(fx.brand || "家里线路") && !/__[A-Z_]+__/.test(t))(
              Buffer.from((win.match(/'tray\.ps1' = '([^']+)'/) || [0, ""])[1], "base64").toString("utf8")) };
kv.set("dlmeta", JSON.stringify({ "sing-box-windows-amd64.zip": { version: "v1.14.1" }, "sing-box-darwin-arm64.tar.gz": { version: "v1.14.1" } }));
out.mac = (await get(`/s/${fx.token}/mac`, ua("curl/8.7.1")))[1];
out.macPage = (await get(`/s/${fx.token}`, ua("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605.1.15")))[1].includes("/mac | bash");
out.winPage = (await get(`/s/${fx.token}`, ua("Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/140")))[1].includes("irm https://sub.example/s/");
console.log(JSON.stringify(out));
