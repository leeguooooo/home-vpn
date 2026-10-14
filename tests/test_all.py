"""python3 -m unittest discover -s tests  (fake secrets and a throwaway certificate only)

Set SINGBOX=/path/to/sing-box to also run `sing-box check` on every generated config (CI does)."""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
FIXTURE_SITE = os.path.join(HERE, "fixtures", "site")
os.environ["JPX_SITE"] = FIXTURE_SITE      # never the real deployment's site/
sys.path.insert(0, os.path.join(REPO, "lib"))
sys.path.insert(0, os.path.join(REPO, "server"))
sys.path.insert(0, os.path.join(REPO, "client"))
import jpx  # noqa: E402
import render  # noqa: E402

import importlib.util  # noqa: E402  (make-config.py has a dash in its name)
_spec = importlib.util.spec_from_file_location("make_config", os.path.join(REPO, "client", "make-config.py"))
make_config = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(make_config)

FAKE_SECRETS = """# test only
HY2_PASSWORD=test-hy2-owner
HY2_OBFS_PASSWORD=unused
STLS_PASSWORD=test-stls-owner
SS_PASSWORD=dGVzdC1zcy0xMjM0NTY3OA== # gitleaks:allow (fake, test only)
# alice（2026-01-01 加）
ALICE_HY2_PASSWORD=test-hy2-alice
ALICE_STLS_PASSWORD=test-stls-alice
# cn（回国）
CN_HY2_PASSWORD=test-hy2-cn
CN_STLS_PASSWORD=test-stls-cn
BROKEN_HY2_PASSWORD=has-no-stls-pair
"""


class StateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.tmp, "certs"))
        with open(os.path.join(self.tmp, "secrets.env"), "w") as fh:
            fh.write(FAKE_SECRETS)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                        "-nodes", "-days", "1", "-keyout", os.path.join(self.tmp, "certs", "server.key"),
                        "-out", os.path.join(self.tmp, "certs", "server.crt"), "-subj", "/CN=test.example"],
                       check=True, capture_output=True)
        os.environ["JPX_STATE"] = self.tmp

    def tearDown(self):
        shutil.rmtree(self.tmp)
        os.environ.pop("JPX_STATE", None)

    def singbox_check(self, cfg):
        sb = os.environ.get("SINGBOX")
        if not sb:
            return
        cfg = json.loads(json.dumps(cfg))
        # check opens local rule sets and the log file: point them at things that exist here
        cfg.get("log", {}).pop("output", None)
        rs = cfg.get("route", {}).get("rule_set", [])
        if rs:
            src, srs = os.path.join(self.tmp, "rs.json"), os.path.join(self.tmp, "rs.srs")
            with open(src, "w") as fh:
                json.dump({"version": 3, "rules": [{"domain_suffix": ["cn"]}]}, fh)
            subprocess.run([sb, "rule-set", "compile", "-o", srs, src], check=True, capture_output=True)
            for i, r in enumerate(rs):      # remote ones too: check must not download anything
                rs[i] = {"type": "local", "tag": r["tag"], "format": "binary", "path": srs}
        p = os.path.join(self.tmp, "check.json")
        with open(p, "w") as fh:
            json.dump(cfg, fh)
        r = subprocess.run([sb, "check", "-c", p], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def export(self, user="owner"):
        out = subprocess.run(["zsh", os.path.join(REPO, "server", "export-client.sh"), user],
                             check=True, capture_output=True, text=True).stdout
        return json.loads(out)


class SiteTest(StateTest):
    """site.example/ is what a new deployment starts from: it must load, fill the defaults and produce valid configs."""
    def setUp(self):
        super().setUp()
        os.environ["JPX_SITE"] = os.path.join(REPO, "site.example")
        with open(os.path.join(self.tmp, "secrets.env"), "w") as fh:
            fh.write(FAKE_SECRETS.replace("-owner", "-me"))

    def tearDown(self):
        os.environ["JPX_SITE"] = FIXTURE_SITE
        super().tearDown()

    def test_example_site(self):
        s = jpx.site()
        self.assertEqual((s["SHARED_USER"], s["OWNER_USERS"], s["HY2_V4_PORT"]), ("me", "me", 443))
        cfg = render.render("2001:db8::1")
        self.assertEqual([u["name"] for u in cfg["inbounds"][0]["users"]], ["me", "alice", "cn"])
        self.assertFalse(any(o["tag"] == "cn-exit" for o in cfg["outbounds"]))          # CN_EXIT_USER empty
        self.singbox_check(cfg)
        ex = self.export("me")
        self.assertEqual(ex["server_v4_host"], s["SERVER_V4"])                           # no DDNS name: the IP
        mac = make_config.build(ex, "macos")
        self.assertTrue(mac["route"]["rule_set"][0]["path"].startswith(os.path.expanduser("~/home-vpn-client/")))
        self.singbox_check(mac)
        mob = make_config.build(ex, "mobile", rule_sets="remote", defaults=False)
        self.assertIn("raw.githubusercontent.com", mob["route"]["rule_set"][0]["url"])   # no SUB_BASE: upstream rule sets
        clash = make_config.to_yaml(make_config.build_clash(ex))
        self.assertIn("Home-HY2-v4", clash)

    def test_shell_loader(self):
        """lib/site.sh and jpx.site() agree (defaults first, then site.env)."""
        out = subprocess.run(["zsh", "-c", f'REPO={REPO}; source $REPO/lib/site.sh; print -r -- "$SHARED_USER|$OWNER_USERS|$STATE|$BRAND|$SINGBOX_VERSION"'],
                             capture_output=True, text=True, check=True).stdout.strip()
        s = jpx.site()
        self.assertEqual(out, "|".join([s["SHARED_USER"], s["OWNER_USERS"], self.tmp, s["BRAND"], s["SINGBOX_VERSION"]]))
        no_state = dict(os.environ); no_state.pop("JPX_STATE")
        out = subprocess.run(["zsh", "-c", f'REPO={REPO}; source $REPO/lib/site.sh; print -r -- $STATE'],
                             capture_output=True, text=True, check=True, env=no_state).stdout.strip()
        self.assertEqual(out, os.path.expanduser("~/.home-vpn"))

    def test_missing_site(self):
        env = dict(os.environ, JPX_SITE=os.path.join(self.tmp, "nope"))
        r = subprocess.run(["zsh", "-c", f'REPO={REPO}; source $REPO/lib/site.sh'], capture_output=True, text=True, env=env)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("site.example", r.stderr)


class ServerRenderTest(StateTest):
    def test_users_ports_rules(self):
        cfg = render.render("2001:db8::1")
        ins = {i["tag"]: i for i in cfg["inbounds"]}
        self.assertEqual([u["name"] for u in ins["hy2-in-v4"]["users"]], ["owner", "alice", "cn"])   # BROKEN skipped
        self.assertEqual(ins["hy2-in-v6"]["listen"], "2001:db8::1")
        self.assertEqual(ins["stls-in"]["users"][1]["password"], "test-stls-alice")
        self.assertIsInstance(ins["hy2-in-v4"]["listen_port"], int)
        self.assertTrue(ins["hy2-in-v4"]["tls"]["key_path"].startswith(self.tmp))
        rules = cfg["route"]["rules"]
        self.assertEqual(rules[0], {"action": "sniff"})
        i_bt = next(i for i, r in enumerate(rules) if r.get("protocol") == ["bittorrent"])
        # 回国: the cn account leaves through the reverse tunnel; its UDP is refused
        self.assertEqual(rules[i_bt + 1], {"auth_user": ["cn"], "network": ["udp"], "action": "reject"})
        self.assertEqual(rules[i_bt + 2], {"auth_user": ["cn"], "outbound": "cn-exit"})
        # only the owner reaches the home LAN; everyone else (and unknown users) is resolved, then refused
        self.assertEqual(rules[i_bt + 3], {"auth_user": ["owner"], "outbound": "direct"})
        self.assertEqual(rules[i_bt + 4], {"action": "resolve"})
        self.assertEqual(rules[i_bt + 5], {"ip_is_private": True, "action": "reject"})
        self.assertIn("2001:db8::1/128", rules[i_bt + 6]["ip_cidr"])     # the home's own addresses too
        self.assertIn(jpx.site()["SERVER_V4"] + "/32", rules[i_bt + 6]["ip_cidr"])
        self.assertEqual(rules[i_bt + 7]["action"], "reject")
        cn_out = next(o for o in cfg["outbounds"] if o["tag"] == "cn-exit")
        self.assertEqual((cn_out["server"], cn_out["server_port"]), ("127.0.0.1", 18090))
        site_rules = jpx.strip_comments(jpx.load_json(os.path.join(FIXTURE_SITE, "server-rules.json")))
        self.assertEqual(rules[1:1 + len(site_rules)], site_rules)
        text = json.dumps(cfg)
        self.assertNotIn("@", text.replace("@openssh", ""))
        self.assertNotIn("_comment", text)
        self.singbox_check(cfg)

    def test_compare_guard(self):
        cfg = render.render("2001:db8::1")
        p = os.path.join(self.tmp, "running.json")
        with open(p, "w") as fh:
            json.dump(cfg, fh)
        ok = subprocess.run([sys.executable, os.path.join(REPO, "server", "render.py"), "--v6", "2001:db8::1", "--compare", p],
                            capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0, ok.stdout)
        bad = subprocess.run([sys.executable, os.path.join(REPO, "server", "render.py"), "--v6", "2001:db8::2", "--compare", p],
                             capture_output=True, text=True)
        self.assertEqual(bad.returncode, 1)
        self.assertNotIn("test-hy2-owner", bad.stdout)


class ExportAndClientTest(StateTest):
    def test_export_fingerprint(self):
        ex = self.export("alice")
        self.assertEqual(ex["hy2_password"], "test-hy2-alice")
        fp = subprocess.run(["openssl", "x509", "-noout", "-fingerprint", "-sha256", "-in",
                             os.path.join(self.tmp, "certs", "server.crt")], capture_output=True, text=True).stdout
        self.assertEqual(ex["cert_sha256"], fp.strip().split("=")[1])
        with self.assertRaises(subprocess.CalledProcessError):
            self.export("nobody")

    def test_macos_policy(self):
        cfg = make_config.build(self.export(), "macos", data_dir="/tmp/x")
        ob = {o["tag"]: o for o in cfg["outbounds"]}
        auto = ob[make_config.AUTO]
        self.assertEqual(auto["outbounds"], ["Home-HY2-v4", "Home-HY2-v6"])        # v4 first, HY2 only
        for g in (make_config.HOME, make_config.CLAUDE):
            self.assertEqual(ob[g]["default"], make_config.AUTO)
            self.assertIn("Home-STLS-v4", ob[g]["outbounds"])                        # STLS: manual only
        claude = [r for r in cfg["route"]["rules"] if "anthropic.com" in r.get("domain_suffix", [])]
        self.assertEqual(claude[0]["outbound"], make_config.CLAUDE)
        self.assertEqual(cfg["inbounds"][0]["mtu"], 1500)
        self.assertNotIn("up_mbps", ob["Home-HY2-v4"])                              # laptop: BBR on upload
        rules = cfg["route"]["rules"]
        i_rd = next(i for i, r in enumerate(rules) if r.get("ip_cidr") == ["192.168.1.20/32"])
        i_pv = next(i for i, r in enumerate(rules) if r.get("ip_is_private"))
        self.assertLess(i_rd, i_pv)                                                  # the server-side LAN via the tunnel, everywhere
        self.assertEqual(ob["Home-HY2-v4"]["down_mbps"], 100)
        self.assertEqual(cfg["route"]["rule_set"][0]["path"], "/tmp/x/geosite-cn.srs")
        self.assertEqual(ob["Home-HY2-v4"]["server"], jpx.site()["SERVER_V4_HOST"])        # v4 node by DDNS name
        self.assertEqual(ob["stls-v4"]["server"], jpx.site()["SERVER_V4_HOST"])
        self.assertNotIn("output", cfg["log"])
        self.singbox_check(cfg)

    def test_no_cn_user_no_cn_exit(self):
        with open(os.path.join(self.tmp, "secrets.env"), "w") as fh:
            fh.write(FAKE_SECRETS.split("# cn")[0])
        cfg = render.render("2001:db8::1")
        self.assertFalse(any(o["tag"] == "cn-exit" for o in cfg["outbounds"]))

    def test_macos_cn_mode(self):
        cfg = make_config.build(self.export(), "macos", data_dir="/tmp/x", cn_ex=self.export("cn"))
        ob = {o["tag"]: o for o in cfg["outbounds"]}
        self.assertEqual(ob["回国-HY2-v4"]["password"], "test-hy2-cn")
        self.assertEqual(ob[make_config.CN_SITES]["outbounds"], ["direct", make_config.CN_AUTO])
        self.assertEqual(ob[make_config.CN_SITES]["default"], "direct")                 # at home in China
        self.assertIn("direct", ob[make_config.HOME]["outbounds"])                      # abroad: rest direct
        cn_rule = next(r for r in cfg["route"]["rules"] if r.get("rule_set"))
        self.assertEqual(cn_rule["outbound"], make_config.CN_SITES)
        self.assertEqual({r["server"] for r in cfg["dns"]["rules"]}, {"cn"})
        self.assertEqual(ob[make_config.CLAUDE]["default"], make_config.AUTO)              # Claude always via the exit
        self.singbox_check(cfg)

    def test_windows_profile_and_secret(self):
        prof = jpx.load_json(os.path.join(FIXTURE_SITE, "clients", "desktop.json"))
        cfg = make_config.build(self.export(), "windows", prof, clash_secret="keepme")
        rules = cfg["route"]["rules"]
        i_cidr = next(i for i, r in enumerate(rules) if "ip_cidr" in r)
        self.assertEqual(sum(1 for r in rules if r.get("ip_cidr") == ["192.168.1.20/32"]), 1)   # no duplicate after the merge
        i_priv = next(i for i, r in enumerate(rules) if r.get("ip_is_private"))
        i_proc = next(i for i, r in enumerate(rules) if "process_name" in r)
        self.assertLess(i_cidr, i_priv)
        self.assertLess(i_priv, i_proc)
        self.assertEqual(cfg["inbounds"][0]["mtu"], 9000)
        hy = [o for o in cfg["outbounds"] if o["type"] == "hysteria2"]
        self.assertTrue(all(o["up_mbps"] == 60 and o["down_mbps"] == 100 for o in hy))   # desktop pins its measured rate
        auto = next(o for o in cfg["outbounds"] if o["tag"] == make_config.AUTO)
        self.assertEqual(auto["outbounds"], ["Home-HY2-v4"])                           # desktop: v6 upload capped
        home = next(o for o in cfg["outbounds"] if o["tag"] == make_config.HOME)
        self.assertIn("Home-HY2-v6", home["outbounds"])                                  # still selectable by hand
        self.assertEqual(rules[0], {"inbound": ["cn-exit-in"], "outbound": "direct"})     # desktop is the 回国 exit
        socks = next(i for i in cfg["inbounds"] if i["tag"] == "cn-exit-in")
        self.assertEqual((socks["listen"], socks["listen_port"]), ("127.0.0.1", 18090))
        self.assertEqual(next(r for r in cfg["route"]["rules"] if r.get("rule_set"))["outbound"], "direct")
        self.assertTrue(cfg["log"]["output"].startswith("C:/ProgramData/sing-box"))
        self.assertEqual(cfg["experimental"]["clash_api"]["secret"], "keepme")
        self.assertNotIn("desktop_user", json.dumps(cfg))
        self.assertNotIn("someone", json.dumps(cfg))
        self.singbox_check(cfg)

    def test_mobile_subscription_config(self):
        cfg = make_config.build(self.export(), "mobile", rule_sets="remote", defaults=False)
        self.assertNotIn("clash_api", cfg["experimental"])                                # the app has its own
        self.assertNotIn("output", cfg["log"])
        self.assertFalse(any(r.get("ip_cidr") for r in cfg["route"]["rules"]))   # the owner's LAN rules stay out
        self.assertEqual(cfg["inbounds"][0]["address"], make_config.USER_EDITION["tun"])   # never collides with the owner's client
        rs = cfg["route"]["rule_set"]
        self.assertTrue(all(r["type"] == "remote" and r["download_detour"] == "direct" for r in rs))   # before the tunnel is up
        self.assertEqual(rs[0]["url"], jpx.site()["SUB_BASE"] + "/rules/geosite-cn.srs")
        self.singbox_check(cfg)


def esbuild():
    """wrangler bundles the Worker with esbuild; the tests do the same (the .ps1 files are imported as text)."""
    found = shutil.which("esbuild")
    if found:
        return found
    try:
        root = subprocess.run(["npm", "root", "-g"], capture_output=True, text=True).stdout.strip()
    except OSError:
        return None
    p = os.path.join(root, "wrangler", "node_modules", ".bin", "esbuild")
    return p if os.path.exists(p) else None


@unittest.skipUnless(shutil.which("node") and shutil.which("openssl") and esbuild(), "needs node + openssl + esbuild")
class SubscriptionTest(unittest.TestCase):
    """server/sub.py seals, sub/worker.js opens: same keys, same format; expired and wrong tokens get nothing."""
    def run_worker(self, expires):
        import importlib.util
        spec = importlib.util.spec_from_file_location("sub", os.path.join(REPO, "server", "sub.py"))
        sub = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sub)
        tok, tv = "AbCdEfGhIjKlMnOpQrStUvWxYz012345", "k7m3x9pq"
        files = {"meta": json.dumps({"name": "alice", "expires": expires, "updated": "now", "tv": tv}),
                 "shadowrocket": "c2hhZG93cm9ja2V0", "singbox": json.dumps({"ok": 1}), "clash": "mode: rule\n"}
        sealed = {t: {k: sub.seal(t, v.encode()) for k, v in files.items()} for t in (tok, tv)}
        self.assertEqual(sub.unseal(tok, sealed[tok]["singbox"]), files["singbox"].encode())
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"token": tok, "tv": tv, "files": sealed,
                       "records": [[tok, sub.keys(tok)[2]], [tv, sub.keys(tv)[2]]]}, fh)
        bundle = fh.name + ".mjs"
        try:
            subprocess.run([esbuild(), os.path.join(REPO, "sub", "worker.js"), "--bundle", "--format=esm", "--loader:.ps1=text", "--loader:.sh=text",
                            "--log-level=error", "--outfile=" + bundle], check=True)
            out = subprocess.run(["node", os.path.join(HERE, "sub_worker_check.mjs"), fh.name, bundle],
                                 capture_output=True, text=True, check=True).stdout
        finally:
            os.unlink(fh.name)
            if os.path.exists(bundle):
                os.unlink(bundle)
        return json.loads(out)

    def test_roundtrip(self):
        r = self.run_worker("2099-01-01")
        self.assertEqual(r["shadowrocket"], {"s": 200, "b": "c2hhZG93cm9ja2V0"})
        self.assertEqual(json.loads(r["singbox"]["b"]), {"ok": 1})
        self.assertEqual(r["clash"]["b"], "mode: rule\n")
        self.assertEqual(r["page"], {"s": 200, "iosFirst": True, "hasImport": True, "hasTv": True})
        self.assertTrue(r["pageAndroid"])                                   # an Android phone sees Android first
        self.assertEqual(r["auto"], {"shadowrocket": "c2hhZG93cm9ja2V0", "singbox": '{"ok": 1}',
                                     "clash": "mode: rule\n", "clash2": "mode: rule\n", "unknown": "mode: rule\n"})
        self.assertEqual(r["tv"], "mode: rule\n")                          # the TV code opens its own copy
        self.assertEqual(r["tvBad"], 404)
        self.assertEqual((r["wrong"], r["adminNoAuth"], r["del"], r["afterDel"]), (404, 401, 200, 404))
        self.assertEqual(r["win"], {"hasUrl": True, "hasVersion": True, "placeholders": [], "files": 4, "trayRoundTrip": True})
        self.assertTrue(r["winPage"])                                      # a Windows browser gets the copy-command button
        mac = r["mac"]
        self.assertEqual(re.findall(r"__[A-Z_]+__", mac), [])
        self.assertIn("SUB='https://sub.example/s/", mac)
        self.assertIn("singbox-macos", mac)                                # the updater is embedded
        self.assertIn("launchctl bootout", mac)                            # so is the uninstaller
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as fh:
            fh.write(mac)
        try:
            subprocess.run(["bash", "-n", fh.name], check=True)             # the delivered script parses
        finally:
            os.unlink(fh.name)
        self.assertTrue(r["macPage"])

    def test_expired(self):
        r = self.run_worker("2000-01-01")
        self.assertEqual(r["singbox"]["s"], 410)
        self.assertEqual(r["page"]["s"], 410)


if __name__ == "__main__":
    unittest.main()
