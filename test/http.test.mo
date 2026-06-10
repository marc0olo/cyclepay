import { test; suite } "mo:test";
import Array "mo:core/Array";
import Text "mo:core/Text";
import Http "../src/backend/Http";

// Hand-rolled HTTP ingress (§6.0): url parsing, case-insensitive header
// lookup, route-table dispatch with the per-route upgrade flag (seam
// §11.1.2), body-size guard, 404/405/413 semantics.

func req(method : Text, url : Text, headers : [(Text, Text)], body : Text) : Http.Request {
  { method; url; headers; body = Text.encodeUtf8(body) };
};

// Test table: the real shape (one upgrade POST) plus non-upgrade routes to
// exercise the per-route flag and the 405 path. The stripe handler echoes
// the request body so tests can prove the handler ran *with the request*;
// at the query stage an upgrade route must never reach its handler.
let routes : [Http.Route] = [
  {
    method = "POST";
    path = "/webhook/stripe";
    upgrade = true;
    handler = func r = Http.response(299, [], r.body);
  },
  {
    method = "GET";
    path = "/ping";
    upgrade = false;
    handler = func _ = Http.text(200, "pong");
  },
  {
    method = "DELETE";
    path = "/ping";
    upgrade = false;
    handler = func _ = Http.text(204, "");
  },
];

let maxBody = 64; // small cap so the guard is easy to hit

suite("pathOf: query-string strip", func() {
  test("strips the query string", func() {
    assert Http.pathOf("/webhook/stripe?source=stripe&x=2") == "/webhook/stripe";
  });

  test("no query string is unchanged", func() {
    assert Http.pathOf("/webhook/stripe") == "/webhook/stripe";
  });

  test("root url", func() {
    assert Http.pathOf("/") == "/";
    assert Http.pathOf("/?x=1") == "/";
  });

  test("everything after the FIRST '?' goes", func() {
    assert Http.pathOf("/a?b=1?c=2") == "/a";
  });

  test("empty url stays empty (no trap)", func() {
    assert Http.pathOf("") == "";
  });
});

suite("headerValue: case-insensitive names", func() {
  let headers = [
    ("Content-Type", "application/json"),
    ("Stripe-Signature", "t=1,v1=abc"),
    ("X-Dup", "first"),
    ("x-dup", "second"),
  ];

  test("lowercase lookup finds a mixed-case header", func() {
    assert Http.headerValue(headers, "stripe-signature") == ?"t=1,v1=abc";
  });

  test("uppercase lookup finds it too", func() {
    assert Http.headerValue(headers, "STRIPE-SIGNATURE") == ?"t=1,v1=abc";
  });

  test("values keep their case (only names fold)", func() {
    assert Http.headerValue(headers, "content-type") == ?"application/json";
  });

  test("first match wins on duplicates", func() {
    assert Http.headerValue(headers, "X-DUP") == ?"first";
  });

  test("missing header is null", func() {
    assert Http.headerValue(headers, "authorization") == null;
  });

  test("empty header list is null", func() {
    assert Http.headerValue([], "anything") == null;
  });
});

suite("handleQuery: upgrade route", func() {
  test("matched upgrade route answers upgrade=?true without running the handler", func() {
    let res = Http.handleQuery(routes, req("POST", "/webhook/stripe", [], "{}"), maxBody);
    assert res.upgrade == ?true;
    assert res.status_code == 200; // the handler's 299 would mean it ran
  });

  test("query string does not break the match", func() {
    let res = Http.handleQuery(routes, req("POST", "/webhook/stripe?source=stripe", [], "{}"), maxBody);
    assert res.upgrade == ?true;
  });

  test("body exactly at the cap still upgrades", func() {
    let body = Text.join(Array.repeat("x", maxBody).values(), "");
    let res = Http.handleQuery(routes, req("POST", "/webhook/stripe", [], body), maxBody);
    assert res.upgrade == ?true;
  });

  test("body over the cap is 413, not upgraded", func() {
    let body = Text.join(Array.repeat("x", maxBody + 1).values(), "");
    let res = Http.handleQuery(routes, req("POST", "/webhook/stripe", [], body), maxBody);
    assert res.status_code == 413;
    assert res.upgrade == null;
  });
});

suite("handleQuery: non-upgrade route runs in the query (seam §11.1.2)", func() {
  test("handler runs directly, no upgrade", func() {
    let res = Http.handleQuery(routes, req("GET", "/ping", [], ""), maxBody);
    assert res.status_code == 200;
    assert res.body == Text.encodeUtf8("pong");
    assert res.upgrade == null;
  });
});

suite("dispatch: 404 vs 405", func() {
  test("unknown path is 404", func() {
    let res = Http.handleQuery(routes, req("POST", "/webhook/other", [], "{}"), maxBody);
    assert res.status_code == 404;
    assert res.upgrade == null;
  });

  test("known path, wrong method is 405 with Allow listing every method on the path", func() {
    let res = Http.handleQuery(routes, req("POST", "/ping", [], ""), maxBody);
    assert res.status_code == 405;
    assert Http.headerValue(res.headers, "Allow") == ?"GET, DELETE";
  });

  test("GET on the webhook path is 405, not an upgrade", func() {
    let res = Http.handleQuery(routes, req("GET", "/webhook/stripe", [], ""), maxBody);
    assert res.status_code == 405;
    assert res.upgrade == null;
  });

  test("method match is exact — lowercase 'post' is not POST", func() {
    let res = Http.handleQuery(routes, req("post", "/webhook/stripe", [], "{}"), maxBody);
    assert res.status_code == 405;
  });
});

suite("handleUpdate: dispatches to the handler", func() {
  test("matched route runs the handler with the request", func() {
    let res = Http.handleUpdate(routes, req("POST", "/webhook/stripe", [], "{\"id\":\"evt_1\"}"), maxBody);
    assert res.status_code == 299;
    assert res.body == Text.encodeUtf8("{\"id\":\"evt_1\"}"); // echo proves the req reached it
    assert res.upgrade == null;
  });

  test("upgrade flag is irrelevant on the update half", func() {
    let res = Http.handleUpdate(routes, req("GET", "/ping", [], ""), maxBody);
    assert res.status_code == 200;
  });

  test("guards re-apply: 404", func() {
    assert Http.handleUpdate(routes, req("POST", "/nope", [], ""), maxBody).status_code == 404;
  });

  test("guards re-apply: 405", func() {
    assert Http.handleUpdate(routes, req("PUT", "/ping", [], ""), maxBody).status_code == 405;
  });

  test("guards re-apply: 413 (update is callable directly via Candid)", func() {
    let body = Text.join(Array.repeat("x", maxBody + 1).values(), "");
    assert Http.handleUpdate(routes, req("POST", "/webhook/stripe", [], body), maxBody).status_code == 413;
  });
});
