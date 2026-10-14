// 订阅服务（Cloudflare Worker + KV + R2）。服务器 server/sub.py 生成每个用户的配置，用令牌派生的密钥加密后推上来；
// 这里只存密文，键是 sha256(令牌)。有人拿着令牌来取时才解密。
//
//   GET  /s/<token>                 浏览器打开 = 安装页（按设备只显示该看的步骤）；App 来取 = 按 User-Agent 给对应格式
//   GET  /s/<token>/<format>        指定格式：shadowrocket | singbox | clash
//   GET  /t/<电视码>                电视用的短地址（8 位），内容同上，默认 Clash 格式（电视上的 Clash Meta）
//   GET  /rules/<(geosite|geoip)-cn>.<srs|mrs>   分流规则（服务器从 GitHub 取来推上来；国内直连就能下，不依赖隧道）
//   GET  /dl/<name>                 App 安装包（服务器从 GitHub 取来推到 R2；国内下 GitHub 太慢）
//   管理（Bearer ADMIN_TOKEN，只有服务器用）：PUT|DELETE /admin/u/<id>、PUT /admin/r/<file>、PUT /admin/dl/<name>、
//   GET /admin/dl（已有安装包的版本）、GET /admin/list
//
// 加密和 server/sub.py 的 keys()/seal() 一一对应：HKDF-SHA256 → AES-256-CBC + HMAC-SHA256（先加密后 MAC）。
// 站点的名字（BRAND / APP_ID / EXIT_NAME / EXIT_COUNTRY / NODE_PREFIX / SERVER_V4）跟着每条订阅记录的 meta 来（server/sub.py 写进去）；
// 老记录没有时用 Worker 的环境变量（wrangler.toml [vars]），再没有就用下面的默认值。
import WIN_INSTALL from "../client/windows/user/install.ps1";
import WIN_TRAY from "../client/windows/user/tray.ps1";
import WIN_UPDATE from "../client/windows/user/update.ps1";
import WIN_AUTOSTART from "../client/windows/user/autostart.ps1";
import WIN_UNINSTALL from "../client/windows/user/uninstall.ps1";
import MAC_INSTALL from "../client/macos/user/install.sh";
import MAC_UPDATE from "../client/macos/user/update.sh";
import MAC_UNINSTALL from "../client/macos/user/uninstall.sh";

const te = new TextEncoder();
const WIN_FILES = { "tray.ps1": WIN_TRAY, "update.ps1": WIN_UPDATE, "autostart.ps1": WIN_AUTOSTART, "uninstall.ps1": WIN_UNINSTALL };
const FORMATS = {
  shadowrocket: "text/plain; charset=utf-8",
  singbox: "application/json; charset=utf-8",
  "singbox-windows": "application/json; charset=utf-8",
  "singbox-macos": "application/json; charset=utf-8",
  clash: "text/yaml; charset=utf-8",
  "clash-proxies": "text/yaml; charset=utf-8",
};
const TOKEN = { s: /^[A-Za-z0-9_-]{20,64}$/, t: /^[2-9a-hjkmnp-z]{8}$/ };
// app packages kept in R2 under these stable names (server/sub.py apps keeps them current)
const APPS = {
  "flclash-android.apk": "application/vnd.android.package-archive",
  "clashmeta-tv.apk": "application/vnd.android.package-archive",
  "clashmeta-tv-arm64.apk": "application/vnd.android.package-archive",
  "sing-box-windows-amd64.zip": "application/zip",
  "sing-box-darwin-arm64.tar.gz": "application/gzip",
  "sing-box-darwin-amd64.tar.gz": "application/gzip",
};
// the Mac user-edition app: <lowercase APP_ID>-mac.zip (client/macos/build-user-app.sh uploads it)
const MAC_APP = /^[a-z0-9][a-z0-9-]{0,40}-mac\.zip$/;
const appType = (n) => APPS[n] || (MAC_APP.test(n) ? "application/zip" : null);

const DEFAULTS = { brand: "家里线路", app_id: "HomeVPN", exit_name: "家里", exit_country: "", node_prefix: "Home", server_v4: "" };
function siteOf(meta, env) {
  const v = (k) => meta?.[k] ?? env?.[k.toUpperCase()] ?? DEFAULTS[k];
  return { brand: v("brand"), app_id: v("app_id"), exit_name: v("exit_name"), exit_country: v("exit_country"),
           node_prefix: v("node_prefix"), server_v4: v("server_v4") };
}
// fill the site names into a client script (Windows / Mac user edition)
const fillSite = (script, st) => script.replaceAll("__BRAND__", st.brand).replaceAll("__APP_ID_LC__", st.app_id.toLowerCase())
  .replaceAll("__APP_ID__", st.app_id).replaceAll("__EXIT_NAME__", st.exit_name).replaceAll("__EXIT_COUNTRY__", st.exit_country)
  .replaceAll("__SERVER_V4__", st.server_v4);
const macCommand = (link) => `curl -fsSL ${link}/mac | bash`;
const b64utf8 = (s) => btoa(String.fromCharCode(...te.encode(s)));
// what the Windows page tells people to paste into Win+R (TLS 1.2 forced: old Windows 10 PowerShell defaults to TLS 1.0)
const winCommand = (link) =>
  `powershell -ExecutionPolicy Bypass -c "[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm ${link}/windows | iex"`;

// which format an app wants, from its User-Agent; null = a browser (show the install page)
function formatFor(ua) {
  const u = ua.toLowerCase();
  if (/shadowrocket/.test(u)) return "shadowrocket";
  if (/sing-box|sfa\/|sfi\/|sfm\/|sft\/|hiddify|karing/.test(u)) return "singbox";
  if (/clash|mihomo|stash/.test(u)) return "clash";
  if (/mozilla|safari|chrome|firefox|edg\//.test(u)) return null;
  return "clash";   // unknown apps: Clash format is the most widely understood
}

function deviceOf(ua) {
  if (/iphone|ipad|ipod/i.test(ua)) return "ios";
  if (/android/i.test(ua) && /\btv\b|aft|mitv|mibox|bravia|smart-?tv|googletv|hismart/i.test(ua)) return "tv";
  if (/android/i.test(ua)) return "android";
  if (/windows/i.test(ua)) return "windows";
  if (/macintosh|mac os x/i.test(ua)) return "mac";
  return "other";
}

async function hmac(key, data) {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, data));
}
const cat = (...xs) => {
  const out = new Uint8Array(xs.reduce((n, x) => n + x.length, 0));
  let i = 0;
  for (const x of xs) { out.set(x, i); i += x.length; }
  return out;
};
const hex = (b) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");

// "jp-exit-sub" is the project's old name: a protocol constant, the same in server/sub.py. Changing it orphans every
// subscription link already handed out.
async function keys(token) {
  const prk = await hmac(te.encode("jp-exit-sub"), te.encode(token));
  const info = te.encode("v1 enc+mac");
  const t1 = await hmac(prk, cat(info, [1]));
  const t2 = await hmac(prk, cat(t1, info, [2]));
  const id = hex(await crypto.subtle.digest("SHA-256", te.encode("jp-exit-sub:id:" + token)));
  return { ek: t1, mk: t2, id };
}

async function unseal(k, blob) {
  const raw = Uint8Array.from(atob(blob), (c) => c.charCodeAt(0));
  const iv = raw.slice(0, 16), ct = raw.slice(16, -32), tag = raw.slice(-32);
  const mk = await crypto.subtle.importKey("raw", k.mk, { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  if (!(await crypto.subtle.verify("HMAC", mk, tag, cat(iv, ct)))) throw new Error("bad tag");
  const ek = await crypto.subtle.importKey("raw", k.ek, { name: "AES-CBC" }, false, ["decrypt"]);
  return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-CBC", iv }, ek, ct));
}

function sameSecret(a, b) {
  const x = te.encode(a), y = te.encode(b);
  if (x.length !== y.length) return false;
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i];
  return d === 0;
}

const todayCN = () => new Date(Date.now() + 8 * 3600e3).toISOString().slice(0, 10);   // Asia/Shanghai, like the server
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const text = (body, status = 200, type = "text/plain; charset=utf-8", extra = {}) =>
  new Response(body, { status, headers: { "content-type": type, "cache-control": "no-store", ...extra } });

async function admin(request, env, path) {
  const auth = request.headers.get("authorization") || "";
  if (!env.ADMIN_TOKEN || !sameSecret(auth, `Bearer ${env.ADMIN_TOKEN}`)) return text("unauthorized\n", 401);
  if (path === "list" && request.method === "GET") {
    const l = await env.SUBS.list({ prefix: "u:" });
    return text(JSON.stringify(l.keys.map((k) => k.name.slice(2))), 200, "application/json");
  }
  if (path === "dl" && request.method === "GET") {
    return text(JSON.stringify((await env.SUBS.get("dlmeta", "json")) || {}), 200, "application/json");
  }
  const d = path.match(/^dl\/([a-z0-9.-]+)$/);
  if (d && request.method === "PUT") {
    if (!appType(d[1])) return text("unknown app\n", 400);
    const version = request.headers.get("x-version") || "";
    const obj = await env.DL.put(d[1], request.body, {
      httpMetadata: { contentType: appType(d[1]) }, customMetadata: { version },
    });
    const meta = (await env.SUBS.get("dlmeta", "json")) || {};
    meta[d[1]] = { version, size: obj.size, at: new Date().toISOString() };
    await env.SUBS.put("dlmeta", JSON.stringify(meta));
    return text(`stored ${d[1]} ${obj.size}\n`, 201);
  }
  const r = path.match(/^r\/((?:geosite|geoip)-cn\.(?:srs|mrs))$/);
  if (r && request.method === "PUT") {
    const data = await request.arrayBuffer();
    if (!data.byteLength) return text("empty\n", 400);
    await env.SUBS.put("r:" + r[1], data);
    return text(`stored ${data.byteLength}\n`, 201);
  }
  const m = path.match(/^u\/([0-9a-f]{64})$/);
  if (!m) return text("not found\n", 404);
  if (request.method === "PUT") {
    const body = await request.json();
    if (!body.files || typeof body.files !== "object") return text("bad body\n", 400);
    await env.SUBS.put("u:" + m[1], JSON.stringify({ files: body.files, at: Date.now() }));
    return text("stored\n", 201);
  }
  if (request.method === "DELETE") {
    await env.SUBS.delete("u:" + m[1]);
    return text("deleted\n");
  }
  return text("method not allowed\n", 405);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    if (parts[0] === "admin") return admin(request, env, parts.slice(1).join("/"));
    const rule = url.pathname.match(/^\/rules\/((?:geosite|geoip)-cn\.(?:srs|mrs))$/);
    if (rule) {
      const data = await env.SUBS.get("r:" + rule[1], "arrayBuffer");
      return data ? new Response(data, { headers: { "content-type": "application/octet-stream", "cache-control": "public, max-age=3600" } })
                  : text("not found\n", 404);
    }
    if (parts[0] === "dl" && parts.length === 2 && appType(parts[1])) {
      const obj = await env.DL.get(parts[1]);
      if (!obj) return text("还没准备好，过几分钟再试\n", 404);
      const v = obj.customMetadata?.version || "";
      const fname = parts[1].replace(/\.(apk|zip|tar\.gz)$/, v ? `-${v}.$1` : ".$1");
      return new Response(obj.body, { headers: {
        "content-type": appType(parts[1]), "content-length": String(obj.size),
        "content-disposition": `attachment; filename="${fname}"`, "cache-control": "public, max-age=3600" } });
    }
    const kind = parts[0];
    if (!TOKEN[kind] || !parts[1] || parts.length > 3 || !TOKEN[kind].test(parts[1])) return text("not found\n", 404);
    const token = parts[1];
    const ua = request.headers.get("user-agent") || "";
    const fmt = parts[2] || formatFor(ua) || null;
    const k = await keys(token);
    const rec = await env.SUBS.get("u:" + k.id, "json");
    if (!rec) return fmt ? text("not found\n", 404) : page404();
    const files = rec.files;
    const meta = JSON.parse(new TextDecoder().decode(await unseal(k, files.meta)));
    const expired = meta.expires && meta.expires < todayCN();
    const st = siteOf(meta, env);
    if (!fmt) return expired ? pageExpired(meta, st) : page(url, meta, deviceOf(ua), kind, st);
    if (expired) {
      const msg = { windows: "Write-Host '账号已到期：找给你链接的人续期。' -ForegroundColor Red\n", mac: "echo '账号已到期：找给你链接的人续期。'\n" };
      return text(msg[fmt] || "expired\n", 410);
    }
    if (fmt === "mac" && kind === "s") {
      const dl = (await env.SUBS.get("dlmeta", "json")) || {};
      const ver = (dl["sing-box-darwin-arm64.tar.gz"]?.version || "").replace(/^v/, "");
      const script = fillSite(MAC_INSTALL.replaceAll("__SUB_URL__", `${url.origin}/s/${token}`).replaceAll("__SINGBOX_VERSION__", ver)
        .replace("__UPDATE_SH__", () => MAC_UPDATE.trimEnd()).replace("__UNINSTALL_SH__", () => MAC_UNINSTALL.trimEnd()), st);
      return text(script, 200, "text/plain; charset=utf-8");
    }
    if (fmt === "windows" && kind === "s") {
      const dl = (await env.SUBS.get("dlmeta", "json")) || {};
      const ver = (dl["sing-box-windows-amd64.zip"]?.version || "").replace(/^v/, "");
      const files = Object.entries(WIN_FILES).map(([n, c]) => `'${n}' = '${b64utf8(fillSite(c, st))}'`).join("; ");
      const script = fillSite(WIN_INSTALL.replaceAll("__SUB_URL__", `${url.origin}/s/${token}`)
        .replaceAll("__SINGBOX_VERSION__", ver), st).replaceAll("__FILES__", files);
      return text(script, 200, "text/plain; charset=utf-8");
    }
    const f = FORMATS[fmt] && files[fmt] ? fmt : (kind === "t" && files.clash ? "clash" : null);
    if (!f) return text("not found\n", 404);
    const extra = { "profile-update-interval": "12",
                    "content-disposition": `inline; filename*=UTF-8''${encodeURIComponent(st.brand)}` };
    if (meta.expires) {
      // shown by Shadowrocket / Clash apps as the expiry date (end of that day, China time)
      extra["subscription-userinfo"] = `upload=0; download=0; total=0; expire=${Math.floor(Date.parse(meta.expires + "T23:59:59+08:00") / 1000)}`;
    }
    return text(await unseal(k, files[f]), 200, FORMATS[f], extra);
  },
};

// ---------------------------------------------------------------- pages
function page404() {
  return html(`<h1>链接无效</h1><p>这个链接不存在或已经换掉了。找给你链接的人要一个新的。</p>`, 404, "链接无效");
}
function pageExpired(meta, st) {
  return html(`<h1>已到期</h1><p>账号 ${esc(meta.name)} 在 ${esc(meta.expires)} 到期，已经停用。要继续用，找给你链接的人续期。</p>`, 410, st.brand);
}

function page(url, meta, device, kind, st) {
  const link = `${url.origin}${url.pathname.replace(/\/+$/, "")}`;
  const tv = meta.tv ? `${url.origin}/t/${meta.tv}` : null;
  const name = st.brand;
  const srImport = `shadowrocket://add/sub://${btoa(link + "/shadowrocket").replace(/=+$/, "")}?remark=${encodeURIComponent(name)}`;
  const flImport = `flclash://install-config?url=${encodeURIComponent(link + "/clash")}&name=${encodeURIComponent(name)}`;
  const exp = meta.expires ? `可以用到 ${esc(meta.expires)}` : "长期有效";
  const copy = (value, label = "复制") =>
    `<div class="copyrow"><code>${esc(value)}</code><button type="button" data-copy="${esc(value)}">${label}</button></div>`;

  const sections = {
    ios: ["iPhone / iPad", `
      <ol class="steps">
        <li><b>准备一个外区 Apple ID</b>（美国、香港等地区）。国内 App Store 里没有这类 App。
          只在 <b>App Store</b> 里切换登录，<b>不要</b>在「设置」最上面的 Apple ID / iCloud 里登录，免得照片、通讯录被同步走。
          <span class="muted">不会弄就找给你链接的人帮忙。</span></li>
        <li>在 App Store 搜索 <b>Shadowrocket</b>（小火箭，付费约 $2.99）并安装。</li>
        <li><a class="btn" href="${esc(srImport)}">一键导入到 Shadowrocket</a><br><span class="muted">弹出「要打开 Shadowrocket 吗」点「打开」，再点「添加」。</span></li>
        <li>回到 Shadowrocket 首页，打开最上面的开关，第一次会问「添加 VPN 配置」，点「允许」并输入锁屏密码。</li>
        <li>完成。顶部出现 <b>VPN</b> 字样就是连上了；不用了就在 App 里关掉开关。</li>
      </ol>
      <details><summary>按钮点了没反应？</summary>
        <p>打开 Shadowrocket → 右上角 ＋ → 类型选 <b>Subscribe</b> → URL 粘贴下面这行 → 保存。</p>${copy(link)}</details>
      <details><summary>不想花钱？用免费的 Clash Mi</summary>
        <p>App Store（外区）搜 <b>Clash Mi</b> 安装 → 打开后添加订阅，粘贴下面这行 → 选中它 → 点连接。</p>${copy(link)}</details>`],
    android: ["安卓手机", `
      <ol class="steps">
        <li><a class="btn" href="/dl/flclash-android.apk">下载 FlClash</a><br>
          <span class="muted">下载完点通知栏里的文件安装。手机提示「风险应用」「未经检测」时，选「继续安装」或「仍然安装」；
          小米、华为等要是找不到继续的按钮，先在「设置」里关掉「纯净模式 / 安全守护 / 外部来源应用检查」，装完可以再打开。</span></li>
        <li>装好后回到这个页面，点：<br><a class="btn" href="${esc(flImport)}">一键导入到 FlClash</a><br>
          <span class="muted">第一次打开 FlClash 会先弹「免责声明」和「数据收集说明」，分别点「同意」「确认」；
          接着问「从这个链接新建配置？」点「确认」。</span></li>
        <li>点 FlClash 下面的「仪表盘」回到首页，点右下角的 <b>▶ 启动</b>。第一次会先问「允许发送通知」点「允许」，
          再问「建立 VPN 连接」点「确定」。</li>
        <li>完成。状态栏出现 🔑 钥匙图标就是连上了。</li>
      </ol>
      <details><summary>按钮点了没反应？</summary>
        <p>打开 FlClash → 「配置」→ 右下角 ＋ → 「URL」→ 粘贴下面这行 → 提交，然后回首页点启动。</p>${copy(link)}</details>`],
    tv: ["电视 / 电视盒子（小米电视等）", tv ? `
      <p class="muted">电视上操作不方便，建议<b>在手机或电脑上打开这个页面</b>，照着做。</p>
      <ol class="steps">
        <li>在电脑上 <a href="/dl/clashmeta-tv.apk">下载电视版 Clash Meta</a>，拷到 U 盘（U 盘要是 FAT32 格式，一般的都是）。<br>
          <span class="muted">后面安装时提示「解析包出错」或「与设备不兼容」，换这个版本再试：<a href="/dl/clashmeta-tv-arm64.apk">64 位版</a>。</span></li>
        <li>电视：「设置 → 账号与安全」打开 <b>允许安装未知来源的应用</b>（每个品牌叫法略有不同）。</li>
        <li>U 盘插到电视上，用「文件管理 / 高清播放器」找到这个 APK 安装。<br>
          <span class="muted">小米电视提示「应用存在违规功能，禁止安装」时：先把电视的网络断开（设置 → 网络，关掉 Wi-Fi 或拔网线），再安装，装完连回网络。</span></li>
        <li>打开 Clash Meta，用遥控器选「<b>配置</b>」→ 右上角 <b>＋</b> →「<b>URL</b>」。</li>
        <li>「名称」随便填（比如 ${esc(st.node_prefix)}）。选「<b>URL</b>」那一行，用遥控器输入下面这个<b>电视专用地址</b>：
          <div class="tvcode">${esc(tv)}</div>
          <span class="muted">输完按遥控器的<b>返回键</b>收起键盘，再选「确定」。只有最后 8 位是你专属的，输错一位会下载失败，核对一下就行。
          「自动更新」不用管。</span></li>
        <li>选右上角的<b>保存</b>图标。回到配置列表后，在「${esc(st.node_prefix)}」这一行上按<b>确认键</b>，前面的圆圈变蓝就是选中了。
          <span class="muted">要是弹出「更新 / 编辑 / 删除」菜单，按返回，先按一下<b>左键</b>再按确认。</span></li>
        <li>按返回回到首页，选最上面的「<b>已停止</b>」按确认，变成「<b>运行中</b>」。第一次会问是否允许建立 VPN 连接，
          用左右键选「<b>确定</b>」再按确认。</li>
      </ol>` : `<p class="muted">找给你链接的人开通电视地址。</p>`],
    mac: ["Mac 电脑", kind === "s" ? `
      <ol class="steps">
        <li>点这个按钮复制安装命令：<br><button type="button" class="btn" data-copy="${esc(macCommand(link))}">复制安装命令</button></li>
        <li>打开「<b>终端</b>」：按 <b>Command + 空格</b>，输入「终端」两个字，按回车。</li>
        <li>在终端窗口里按 <b>Command + V</b> 粘贴，再按 <b>回车</b>。</li>
        <li>提示「密码」时，输入这台 Mac 的<b>开机密码</b>，按回车。<span class="muted">输入时屏幕上什么都不显示，是正常的，照常输完按回车就行。</span></li>
        <li>等一分钟左右，出现 <b>「装好了，已经连上」</b> 就完成了，终端窗口可以关掉。</li>
      </ol>
      <p class="muted">以后看屏幕<b>右上角</b>的盾牌图标：带勾 = 已连接，带斜杠 = 未连接，点它就能连接 / 断开。开机会自动连上。</p>
      <details><summary>装的时候报错？</summary>
        <p>把终端窗口截图发给给你链接的人。也可以再运行一次安装命令，重复安装不会出问题。</p></details>`
      : `<p class="muted">电脑请用完整的订阅链接打开这个页面。</p>`],
    windows: ["Windows 电脑", kind === "s" ? `
      <ol class="steps">
        <li>点这个按钮复制安装命令：<br><button type="button" class="btn" data-copy="${esc(winCommand(link))}">复制安装命令</button></li>
        <li>按键盘上的 <b>Windows 徽标键 + R</b>（左下角有窗户图案的键，按住它再按 R），会弹出「运行」小窗口。</li>
        <li>在小窗口里按 <b>Ctrl + V</b> 粘贴，再按 <b>回车</b>。</li>
        <li>弹出「你要允许此应用对你的设备进行更改吗？」点 <b>是</b>。</li>
        <li>等一分钟左右，蓝色窗口里出现 <b>「装好了，已经连上」</b> 就完成了，按回车关掉窗口。</li>
      </ol>
      <p class="muted">以后看屏幕右下角的圆点：<b>绿色 = 已连接</b>，灰色 = 未连接，点它就能连接 / 断开。开机会自动连上。
      圆点被收起来了的话，点任务栏右下角的「^」就能看到。</p>
      <details><summary>装的时候报错或者没反应？</summary>
        <p>把窗口截图发给给你链接的人。也可以再运行一次安装命令，重复安装不会出问题。</p></details>`
      : `<p class="muted">电脑请用完整的订阅链接打开这个页面。</p>`],
  };
  const order = ["ios", "android", "tv", "mac", "windows"];
  const first = sections[device] ? device : null;
  const blocks = order.map((d) => `
<section id="${d}" class="${d === first ? "open" : ""}">
  <h2><button type="button" class="toggle" aria-expanded="${d === first}">${sections[d][0]}${d === first ? '<span class="here">这台设备</span>' : ""}</button></h2>
  <div class="body">${sections[d][1]}</div>
</section>`);
  if (first) blocks.unshift(blocks.splice(order.indexOf(first), 1)[0]);

  return html(`
<header><h1>${esc(name)}</h1><p class="sub">${esc(meta.name)} · ${exp}</p></header>
<p class="warn">这个页面的地址就是你的专属钥匙，<b>只给自己的设备用</b>，别转发给别人、别发到群里。</p>
${first ? "" : `<p>选一下你要装的设备：</p>`}
${blocks.join("\n")}
<footer>遇到问题截个图发给给你链接的人。<br>更新于 ${esc(meta.updated || "")}</footer>
<script>
document.querySelectorAll("button[data-copy]").forEach(b => b.addEventListener("click", async () => {
  const v = b.dataset.copy;
  try { await navigator.clipboard.writeText(v); }
  catch (e) { const t = document.createElement("textarea"); t.value = v; document.body.appendChild(t); t.select(); document.execCommand("copy"); t.remove(); }
  const old = b.textContent; b.textContent = "已复制"; setTimeout(() => b.textContent = old, 1500);
}));
document.querySelectorAll("button.toggle").forEach(b => b.addEventListener("click", () => {
  const s = b.closest("section"); s.classList.toggle("open"); b.setAttribute("aria-expanded", s.classList.contains("open"));
}));
// iPadOS reports itself as a Mac: a touch "Mac" is an iPad
if (${JSON.stringify(device)} === "mac" && navigator.maxTouchPoints > 1) {
  const ios = document.getElementById("ios");
  document.querySelectorAll("section.open").forEach(s => s.classList.remove("open"));
  ios.classList.add("open"); ios.parentNode.insertBefore(ios, document.querySelector("section"));
}
</script>`, 200, name);
}

function html(body, status = 200, title = "VPN") {
  return new Response(`<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex">
<title>${esc(title)}</title><style>
:root{--bg:#f5f6f8;--card:#fff;--fg:#1d1f23;--muted:#6b7280;--accent:#2563eb;--accentfg:#fff;--warnbg:#fff4df;--warnfg:#7a4d00;--line:#e5e7eb;--code:#f1f3f5}
@media (prefers-color-scheme: dark){:root{--bg:#111316;--card:#1b1e23;--fg:#e8eaed;--muted:#9aa0a6;--accent:#5b8dff;--accentfg:#fff;--warnbg:#2d2410;--warnfg:#f0c36d;--line:#2c3036;--code:#23272d}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);font:17px/1.65 -apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif}
main{max-width:640px;margin:0 auto;padding:24px 16px 56px}h1{font-size:26px;margin:0}.sub{color:var(--muted);margin:2px 0 0}
section{background:var(--card);border:1px solid var(--line);border-radius:14px;margin:14px 0;overflow:hidden}
h2{margin:0;font-size:18px}.toggle{all:unset;box-sizing:border-box;display:flex;align-items:center;gap:8px;width:100%;padding:16px;cursor:pointer;font-weight:600}
.toggle::after{content:"›";margin-left:auto;color:var(--muted);font-size:22px;transition:transform .15s}section.open .toggle::after{transform:rotate(90deg)}
.here{font-size:12px;font-weight:600;background:var(--accent);color:var(--accentfg);border-radius:10px;padding:1px 8px}
.body{display:none;padding:0 16px 16px}section.open .body{display:block}
.steps{padding-left:22px;margin:0}.steps li{margin:12px 0}.steps li::marker{font-weight:700;color:var(--accent)}
.btn{display:inline-block;margin:6px 0 2px;background:var(--accent);color:var(--accentfg);padding:12px 20px;border-radius:10px;text-decoration:none;font-weight:700;font-size:17px}
.warn{background:var(--warnbg);color:var(--warnfg);padding:10px 12px;border-radius:10px;font-size:15px}.muted{color:var(--muted);font-size:15px}
details{margin-top:12px;font-size:15px}summary{cursor:pointer;color:var(--accent)}
.copyrow{display:flex;gap:8px;align-items:stretch;margin:6px 0}.copyrow code{flex:1;min-width:0;word-break:break-all;background:var(--code);border-radius:8px;padding:8px;font-size:13px}
.copyrow button{border:0;background:var(--accent);color:var(--accentfg);border-radius:8px;padding:0 14px;font-size:15px;font-weight:600;cursor:pointer}
.tvcode{margin:8px 0;padding:12px;background:var(--code);border-radius:10px;font:600 20px/1.4 ui-monospace,Menlo,Consolas,monospace;word-break:break-all;letter-spacing:.5px}
a{color:var(--accent)}footer{color:var(--muted);font-size:14px;margin-top:24px}
</style></head><body><main>${body}</main></body></html>`, { status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}
