// yapyap.cc: serve the static site from ./dist; send http and www to https://yapyap.cc.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.protocol === "http:" || url.hostname === "www.yapyap.cc") {
      url.protocol = "https:";
      url.hostname = "yapyap.cc";
      return Response.redirect(url.toString(), 301);
    }
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
