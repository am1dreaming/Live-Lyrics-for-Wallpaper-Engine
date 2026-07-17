// Manual verification for the /img SSRF / DNS-rebinding fix.
// Run: node test-ssrf.js
//
// Checks:
//   (a) literal private/loopback IPs are still blocked (403)
//   (b) a hostname resolving to a public IP still passes the gate (non-403;
//       needs network — example.com; a 502 here still means the gate passed)
//   (c) a hostname whose DNS resolves to a private IP is blocked (403).
//       dns.promises.lookup is mocked below, since we can't rebind real DNS
//       in a test — this exercises the resolveAndValidate() code path.

const dns = require("dns");
const realLookup = dns.promises.lookup.bind(dns.promises);
dns.promises.lookup = (hostname, opts) => {
  if (hostname === "rebind.invalid") return Promise.resolve([{ address: "127.0.0.1", family: 4 }]);
  if (hostname === "metadata.invalid") return Promise.resolve([{ address: "169.254.169.254", family: 4 }]);
  if (hostname === "mixed.invalid")
    return Promise.resolve([{ address: "93.184.216.34", family: 4 }, { address: "192.168.1.10", family: 4 }]);
  return realLookup(hostname, opts);
};

process.env.BRIDGE_PORT = process.env.BRIDGE_PORT || "18973";
require("./bridge-server.js");

const http = require("http");
const PORT = Number(process.env.BRIDGE_PORT);

function img(u) {
  return new Promise((resolve) => {
    const r = http.get(`http://127.0.0.1:${PORT}/img?u=${encodeURIComponent(u)}`, (res) => {
      res.resume();
      resolve(res.statusCode);
    });
    r.on("error", () => resolve(-1));
    r.setTimeout(25000, () => { r.destroy(); resolve(-2); });
  });
}

(async () => {
  await new Promise((r) => setTimeout(r, 500)); // let the server bind
  let fail = 0;
  const check = (name, ok, got) => {
    console.log(`${ok ? "PASS" : "FAIL"} ${name} (got ${got})`);
    if (!ok) fail++;
  };
  let s;
  s = await img("http://127.0.0.1/x"); check("(a) literal loopback blocked", s === 403, s);
  s = await img("http://169.254.169.254/latest/meta-data/"); check("(a) literal link-local blocked", s === 403, s);
  s = await img("http://10.0.0.5/x"); check("(a) literal rfc1918 blocked", s === 403, s);
  s = await img("http://[::1]/x"); check("(a) literal ipv6 loopback blocked", s === 403, s);
  s = await img("http://rebind.invalid/x"); check("(c) dns resolving to 127.0.0.1 blocked", s === 403, s);
  s = await img("http://metadata.invalid/x"); check("(c) dns resolving to 169.254.169.254 blocked", s === 403, s);
  s = await img("http://mixed.invalid/x"); check("(c) dns with ANY private record blocked", s === 403, s);
  s = await img("http://example.com/"); check("(b) public hostname passes the gate (any non-403)", s !== 403, s);
  console.log(fail ? `\n${fail} check(s) FAILED` : "\nall checks passed");
  process.exit(fail ? 1 : 0);
})();
