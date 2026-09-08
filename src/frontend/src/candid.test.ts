import { describe, expect, test } from "vitest";
import { Principal } from "@icp-sdk/core/principal";
import { COMMANDS, renderCall, irreversibleNote, type CommandMethod } from "./candid";

/// A minimal Candid **text** reader, for the one assertion #97 actually asks for:
/// that the rendered command PARSED equals the tuple the backend expects.
///
/// ⚠️ **Provenance is not enough, and that is the whole point of parsing back.** A test
/// that checks "the arguments came from the row" passes for a renderer that reads the
/// right row and formats it wrongly — a swapped field, a nat rendered where text is
/// expected, `resolve_problem`'s `kindTag` in the `paymentRef` slot. Each of those runs
/// and closes the wrong obligation.
///
/// Deliberately independent of the renderer: sharing a helper between the two would
/// make this a test of self-consistency, which cannot fail.
function parseCandid(src: string): unknown {
  let i = 0;
  const ws = () => { while (i < src.length && /\s/.test(src[i]!)) i += 1; };
  const eat = (t: string) => {
    ws();
    if (!src.startsWith(t, i)) throw new Error(`expected ${t} at ${i} in ${src}`);
    i += t.length;
  };
  const peek = (t: string) => { ws(); return src.startsWith(t, i); };

  function value(): unknown {
    ws();
    if (peek("record")) {
      eat("record");
      eat("{");
      const out: Record<string, unknown> = {};
      while (!peek("}")) {
        ws();
        const name = /^\w+/.exec(src.slice(i))![0];
        i += name.length;
        eat("=");
        out[name] = value();
        if (peek(";")) eat(";");
      }
      eat("}");
      return out;
    }
    if (peek("vec")) {
      eat("vec");
      eat("{");
      const out: unknown[] = [];
      while (!peek("}")) {
        out.push(value());
        if (peek(";")) eat(";");
      }
      eat("}");
      return out;
    }
    if (peek("opt")) { eat("opt"); return { some: value() }; }
    if (peek("null")) { eat("null"); return null; }
    if (peek("true")) { eat("true"); return true; }
    if (peek("false")) { eat("false"); return false; }
    if (peek("principal")) {
      eat("principal");
      return { principal: value() as string };
    }
    if (peek('"')) {
      eat('"');
      let out = "";
      while (src[i] !== '"') {
        if (src[i] === "\\") { i += 1; out += src[i]; } else out += src[i];
        i += 1;
      }
      eat('"');
      return out;
    }
    const num = /^-?\d+/.exec(src.slice(i));
    if (!num) throw new Error(`no value at ${i} in ${src}`);
    i += num[0].length;
    return BigInt(num[0]);
  }

  eat("(");
  const args: unknown[] = [];
  if (!peek(")")) {
    args.push(value());
    while (peek(",")) { eat(","); args.push(value()); }
  }
  eat(")");
  ws();
  if (i !== src.length) throw new Error(`trailing input at ${i} in ${src}`);
  return args;
}

/// The Candid payload **a shell would hand the CLI**, out of a full command line.
///
/// ⚠️ **De-quoted the way `sh` does, rather than sliced between the outer quotes.**
/// `renderCall` escapes an apostrophe as `'\''` — close, literal, reopen — and slicing
/// would hide exactly the bug that escaping exists to prevent. Reading it as the shell
/// does also asserts the payload is ONE word: unquoted whitespace throws here, which is
/// the claim the quoting is for.
function argsOf(command: string): string {
  const head = /^icp canister call backend \w+ /.exec(command);
  if (!head) throw new Error(`not a canister call: ${command}`);
  let i = head[0].length;
  let out = "";
  let quoted = false;
  while (i < command.length) {
    const c = command[i]!;
    if (quoted) {
      if (c === "'") quoted = false;
      else out += c;
      i += 1;
    } else if (c === "'") {
      quoted = true;
      i += 1;
    } else if (c === "\\") {
      out += command[i + 1] ?? "";
      i += 2;
    } else if (/\s/.test(c)) {
      throw new Error(`more than one shell word in: ${command}`);
    } else {
      out += c;
      i += 1;
    }
  }
  if (quoted) throw new Error(`unterminated quote in: ${command}`);
  return out;
}

describe("the rendered command is what the canister expects (#97)", () => {
  test("⚠️ a whole config record round-trips field for field", () => {
    // The case #97 names: the setters take whole records, and hand-authoring one while
    // omitting or fat-fingering a field silently changes a live parameter.
    const pricing = {
      feeBps: 290n,
      feeFixedCents: 30n,
      maxAgeNs: 300_000_000_000n,
      maxRateDeltaBps: 5_000n,
      minRateSources: 2n,
      divisor: 1n,
    };
    const parsed = parseCandid(argsOf(renderCall("set_pricing_config", pricing)));
    expect(parsed).toEqual([pricing]);
  });

  test("the gate and delivery records too", () => {
    const gate = {
      maxOpenOrdersPerPrincipal: 1n,
      minCanisterCycles: 5_000_000_000_000n,
      minPurchaseUsdCents: 1_000n,
      maxPurchaseUsdCents: 10_000n,
    };
    expect(parseCandid(argsOf(renderCall("set_gate_config", gate)))).toEqual([gate]);
    const delivery = { alertAfterNs: 7_200_000_000_000n, maxHoldNs: 259_200_000_000_000n };
    expect(parseCandid(argsOf(renderCall("set_delivery_config", delivery)))).toEqual([delivery]);
  });

  test("⚠️ resolve_problem keeps its three arguments in ORDER and shape", () => {
    // The one #97 singles out: `kindTag` is TEXT and must match a problem kind exactly,
    // and dropping `paymentRef` over-resolves because one order can carry several
    // unresolved problems of the same kind. A swap here closes the wrong obligation and
    // the record then says an obligation was handled that was not.
    const rendered = renderCall("resolve_problem", "abc123", "refundAfterDelivery", "pi_9");
    expect(parseCandid(argsOf(rendered)))
      .toEqual(["abc123", "refundAfterDelivery", { some: "pi_9" }]);
    // And absent, which is the correct call for a kind that can only occur once.
    expect(parseCandid(argsOf(renderCall("resolve_problem", "abc123", "deliveryStuck", null))))
      .toEqual(["abc123", "deliveryStuck", null]);
  });

  test("record_delivered pairs a text id with a nat block, not two of either", () => {
    expect(parseCandid(argsOf(renderCall("record_delivered", "abc123", 16_383_351n))))
      .toEqual(["abc123", 16_383_351n]);
  });

  test("⚠️ a principal is annotated, because a bare string is refused", () => {
    // Measured against the running canister: other annotations are inferred from the
    // interface, and this one is not.
    const p = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
    const rendered = renderCall("add_allowed_buyer", p);
    expect(rendered).toContain('principal "ryjl3-tyaaa-aaaaa-aaaba-cai"');
    expect(parseCandid(argsOf(rendered))).toEqual([{ principal: p.toText() }]);
  });

  test("an optional bool renders as opt or null, never as an empty vec", () => {
    expect(parseCandid(argsOf(renderCall("set_expected_livemode", false))))
      .toEqual([{ some: false }]);
    expect(parseCandid(argsOf(renderCall("set_expected_livemode", null)))).toEqual([null]);
  });

  test("a vec of records, and an empty one", () => {
    const tiers = [{ id: "tier10", usdCents: 1_000n }, { id: "tier25", usdCents: 2_500n }];
    expect(parseCandid(argsOf(renderCall("set_card_tiers", tiers)))).toEqual([tiers]);
    expect(parseCandid(argsOf(renderCall("set_card_tiers", [])))).toEqual([[]]);
  });

  test("argument-free methods render an empty tuple", () => {
    expect(parseCandid(argsOf(renderCall("refresh_reserve")))).toEqual([]);
    expect(renderCall("withdraw_reserve")).toBe("icp canister call backend withdraw_reserve '()'");
  });

  test("text with quotes and backslashes survives the round trip", () => {
    // `abandon_order` takes a free-text reason, which is the one argument an operator
    // types rather than copies.
    const reason = 'operator said "no" \\ then left';
    expect(parseCandid(argsOf(renderCall("abandon_order", "abc123", reason))))
      .toEqual(["abc123", reason]);
  });

  test("⚠️ neither secret setter is in the table, and that is permanent", () => {
    // A rendered command containing the key would land in this page's DOM and its
    // clipboard. `scripts/check-admin-commands.py` fails if either ever appears.
    const names = Object.keys(COMMANDS);
    expect(names).not.toContain("set_stripe_api_key");
    expect(names).not.toContain("set_webhook_secret");
  });

  test("every irreversible action says what it cannot undo", () => {
    // Not every command is irreversible, but the ones that are must say so: the reason
    // this is a command rather than a button is that a human reads it first.
    for (const m of ["abandon_order", "record_delivered", "resolve_problem", "resolve_orphan",
      "expire_order", "withdraw_reserve", "remove_allowed_buyer"] as CommandMethod[]) {
      expect(irreversibleNote(m), `${m} has no irreversible note`).toBeTruthy();
    }
  });

  test("the command line is one shell word, quoted", () => {
    // Candid text contains double quotes and braces; unquoted, a shell eats them.
    const rendered = renderCall("set_stripe_origin", "https://example.com");
    expect(rendered).toBe(
      `icp canister call backend set_stripe_origin '("https://example.com")'`,
    );
  });

  test("⚠️ an apostrophe survives the SHELL as well as Candid", () => {
    // Two escapings, and passing one proves nothing about the other: `text()` escapes
    // for Candid, the single quotes are for the shell. A tier id carrying an apostrophe
    // used to close the quoting early, so what reached the CLI was neither the command
    // nor an error — it was a different, shorter command.
    const tiers = [{ id: "o'brien", usdCents: 1_000n }];
    const rendered = renderCall("set_card_tiers", tiers);
    expect(parseCandid(argsOf(rendered))).toEqual([tiers]);
    // The POSIX idiom, spelled out so a "simplification" back to a bare quote fails.
    expect(rendered).toContain(`o'\\''brien`);
  });
});

describe("the parser this suite relies on", () => {
  // ⚠️ The parser is the instrument, so it is tested against text the renderer did NOT
  // produce. Sharing input with the renderer would make every assertion above a test of
  // self-consistency.
  test("reads records, vecs, opts and principals from hand-written text", () => {
    expect(parseCandid('(record { a = 1; b = "x" })')).toEqual([{ a: 1n, b: "x" }]);
    expect(parseCandid("(vec { 1; 2; 3 })")).toEqual([[1n, 2n, 3n]]);
    expect(parseCandid("(vec {})")).toEqual([[]]);
    expect(parseCandid("(opt true, null)")).toEqual([{ some: true }, null]);
    expect(parseCandid('(principal "aaaaa-aa")')).toEqual([{ principal: "aaaaa-aa" }]);
    expect(parseCandid("()")).toEqual([]);
  });

  test("refuses what it cannot read rather than returning something plausible", () => {
    expect(() => parseCandid("(record { a = })")).toThrow();
    expect(() => parseCandid("(1) trailing")).toThrow();
    expect(() => parseCandid("1")).toThrow();
  });
});
