// yapyap.cc: serve the static site from ./dist; send http and www to https://yapyap.cc.
// /e/* is a first-party proxy for the site's PostHog analytics, so ad blockers and the CSP see only yapyap.cc.
const POSTHOG_API = "us.i.posthog.com";
const POSTHOG_ASSETS = "us-assets.i.posthog.com";

async function posthog(request, url) {
  const path = url.pathname.slice("/e".length) + url.search;
  const host = path.startsWith("/static/") ? POSTHOG_ASSETS : POSTHOG_API;
  const headers = new Headers(request.headers);
  headers.delete("cookie");
  // PostHog places visitors by IP; without this every visit would come from Cloudflare.
  const ip = request.headers.get("cf-connecting-ip");
  if (ip) headers.set("x-forwarded-for", ip);
  return fetch(new Request(`https://${host}${path}`, { method: request.method, headers, body: request.body, redirect: "follow" }));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.protocol === "http:" || url.hostname === "www.yapyap.cc") {
      url.protocol = "https:";
      url.hostname = "yapyap.cc";
      return Response.redirect(url.toString(), 301);
    }
    if (url.pathname.startsWith("/e/")) return posthog(request, url);
    const response = await env.ASSETS.fetch(request);
    // Declare UTF-8 on text so link-preview scrapers don't garble – ’ ⌥.
    const type = response.headers.get("content-type") || "";
    if (/^(text\/|application\/(xml|json))/.test(type) && !/charset=/i.test(type)) {
      const fixed = new Response(response.body, response);
      fixed.headers.set("content-type", type + "; charset=utf-8");
      return fixed;
    }
    return response;
  },
};
