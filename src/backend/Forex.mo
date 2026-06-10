/// Forex rate subsystem (§3.1) — the one outbound-HTTPS exception.
///
/// This is the *pure* half: JSON rate extraction + coarse rounding (the
/// outcall `transform` body, so replicas converge on a tiny canonical
/// response), the configurable fee formula (§3 net-of-fees), staleness, and
/// the cycles quote. Main.mo owns the impure half — the actual outcall,
/// the single-flight guard, and the in-call retry cap — so everything here
/// unit-tests without an IC environment (mocked-outcall bodies are just
/// Blobs).
///
/// Rate representation: **XDR per USD in micro-units (×1e6)**, the shape
/// USD-base forex APIs serve (`"XDR": 0.7374` → `737_400`). The default
/// source is keyless and IPv6-reachable (§3.1 — a keyed API would add a
/// second node-provider-readable secret). 1 XDR = 1T cycles (CMC), so
///   cycles = netCents/100 · micros/1e6 · 1e12 = netCents · micros · 10_000.
///
/// Fail-closed posture (§3.1): every parse/sanity failure collapses to
/// "no rate", and no rate means order creation is blocked — never priced on
/// a stale, implausible, or invented rate.
import Char "mo:core/Char";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Result "mo:core/Result";
import Text "mo:core/Text";

module {

  /// Coarse-rounding step for the transform (§3.1 determinism): 1_000 micros
  /// = 0.001 XDR/USD, ~0.14% at historical rates (~0.74). Coarse enough that
  /// replicas sampling a slightly different live value converge; fine enough
  /// that the pricing error is far below card-fee variance the operator
  /// already absorbs (§3).
  public let roundStepMicros : Nat = 1_000;

  /// Plausibility band: XDR/USD has lived between ~0.6 and ~0.9 for decades.
  /// A 10×-each-way band rejects decimal-point bugs at the source (a 1000×
  /// rate would mint free or absurdly expensive orders) while never tripping
  /// on real market moves. Outside the band = parse failure = fail closed.
  public let minPlausibleMicros : Nat = 100_000;
  public let maxPlausibleMicros : Nat = 10_000_000;

  /// Forex params (§7: controllers may adjust). `feeBps`/`feeFixedCents` is
  /// the §3 fee formula (≈2.9% + $0.30); `maxAgeNs` is the lazy-refresh
  /// staleness window; `url` must be a keyless USD-base JSON source carrying
  /// an `"XDR"` rate.
  public type Config = {
    url : Text;
    feeBps : Nat;
    feeFixedCents : Nat;
    maxAgeNs : Int;
  };

  /// USD/XDR moves slowly (SDR basket); 1 h staleness is immaterial next to
  /// the §3 fee variance, and keeps the outcall cadence ≤ 24/day.
  public func defaultConfig() : Config {
    {
      url = "https://open.er-api.com/v6/latest/USD";
      feeBps = 290;
      feeFixedCents = 30;
      maxAgeNs = 3_600_000_000_000;
    };
  };

  public type ConfigError = {
    /// Fee ≥ 100% can never net out.
    #feeBpsTooHigh;
    /// A zero window would refresh on every order.
    #nonPositiveMaxAge;
    /// Outcalls are HTTPS-only; anything else fails at call time anyway.
    #notHttps;
  };

  public func validateConfig(config : Config) : Result.Result<(), ConfigError> {
    if (config.feeBps >= 10_000) return #err(#feeBpsTooHigh);
    if (config.maxAgeNs <= 0) return #err(#nonPositiveMaxAge);
    if (not config.url.startsWith(#text "https://")) return #err(#notHttps);
    #ok;
  };

  /// The stable `{rate, ts}` cache (§3.1): orders read this; only staleness
  /// triggers an outcall.
  public type Rate = { xdrPerUsdMicros : Nat; fetchedAtNs : Int };

  public type Cache = { var rate : ?Rate };

  public func emptyCache() : Cache {
    { var rate = null };
  };

  public func record(cache : Cache, xdrPerUsdMicros : Nat, nowNs : Int) {
    cache.rate := ?{ xdrPerUsdMicros; fetchedAtNs = nowNs };
  };

  /// The cached rate iff younger than `maxAgeNs` (age ≥ window = stale,
  /// matching the Idempotency pruning convention). Null = caller must
  /// refresh or fail closed.
  public func freshMicros(cache : Cache, maxAgeNs : Int, nowNs : Int) : ?Nat {
    let ?{ xdrPerUsdMicros; fetchedAtNs } = cache.rate else return null;
    if (nowNs - fetchedAtNs >= maxAgeNs) return null;
    ?xdrPerUsdMicros;
  };

  /// Extract the `"XDR"` rate from a USD-base JSON body, as micro-XDR/USD.
  /// First `"XDR"` key wins; it must be followed by `:` and a non-negative
  /// JSON number. Fractional digits beyond 6 are truncated (sub-micro
  /// precision is far below the coarse-rounding step anyway). Null on any
  /// deviation — fail closed, never guess.
  public func extractXdrPerUsdMicros(body : Text) : ?Nat {
    let chars = body.toArray();
    let needle : [Char] = ['\"', 'X', 'D', 'R', '\"'];
    var i = 0;
    while (i + needle.size() <= chars.size()) {
      var k = 0;
      while (k < needle.size() and chars[i + k] == needle[k]) k += 1;
      if (k == needle.size()) return parseDecimalMicros(chars, i + needle.size());
      i += 1;
    };
    null;
  };

  /// Parse `: <digits>[.<digits>]` (JSON number, no sign/exponent — a forex
  /// rate is a plain positive decimal) starting at `from`, into micros.
  func parseDecimalMicros(chars : [Char], from : Nat) : ?Nat {
    var i = from;
    func skipSpace() {
      while (i < chars.size() and (chars[i] == ' ' or chars[i] == '\t' or chars[i] == '\n' or chars[i] == '\r')) {
        i += 1;
      };
    };
    func digit(c : Char) : ?Nat {
      if (c >= '0' and c <= '9') ?(c.toNat32().toNat() - 48) else null;
    };
    skipSpace();
    if (i >= chars.size() or chars[i] != ':') return null;
    i += 1;
    skipSpace();
    var intPart = 0;
    var intDigits = 0;
    label int while (i < chars.size()) {
      let ?d = digit(chars[i]) else break int;
      intPart := intPart * 10 + d;
      intDigits += 1;
      i += 1;
    };
    if (intDigits == 0) return null;
    var fracMicros = 0;
    if (i < chars.size() and chars[i] == '.') {
      i += 1;
      var scale = 100_000;
      var fracDigits = 0;
      label frac while (i < chars.size()) {
        let ?d = digit(chars[i]) else break frac;
        if (fracDigits < 6) fracMicros += d * scale;
        scale := scale / 10;
        fracDigits += 1;
        i += 1;
      };
      if (fracDigits == 0) return null;
    };
    ?(intPart * 1_000_000 + fracMicros);
  };

  /// Round to the nearest `roundStepMicros` (half up).
  public func coarseRound(micros : Nat) : Nat {
    (micros + roundStepMicros / 2) / roundStepMicros * roundStepMicros;
  };

  public func plausible(micros : Nat) : Bool {
    minPlausibleMicros <= micros and micros <= maxPlausibleMicros;
  };

  /// The outcall `transform` body (§3.1 determinism): raw API response →
  /// canonical micros decimal string, coarse-rounded and sanity-banded.
  /// Any failure → empty body, so replicas reach consensus on the failure
  /// too and the caller retries instead of splitting.
  public func transformBody(body : Blob) : Blob {
    let ?text = body.decodeUtf8() else return "".encodeUtf8();
    let ?raw = extractXdrPerUsdMicros(text) else return "".encodeUtf8();
    let rounded = coarseRound(raw);
    if (not plausible(rounded)) return "".encodeUtf8();
    rounded.toText().encodeUtf8();
  };

  /// Parse the transform's canonical body back into micros. Re-applies the
  /// plausibility band: `http_request_update`-style trust boundaries are
  /// cheap to re-check, and an empty (failure) body parses to null here.
  public func parseCanonicalMicros(body : Blob) : ?Nat {
    let ?text = body.decodeUtf8() else return null;
    let ?micros = Nat.fromText(text) else return null;
    if (not plausible(micros)) return null;
    ?micros;
  };

  /// `Host` for the outcall headers, derived from the configured URL (the
  /// outcall adapter does not set it from the URL).
  public func hostOf(url : Text) : Text {
    let rest = switch (url.stripStart(#text "https://")) {
      case (?r) r;
      case null url;
    };
    let chars = rest.toArray();
    var end = 0;
    while (end < chars.size() and chars[end] != '/' and chars[end] != '?') end += 1;
    Text.fromIter(chars.values().take(end));
  };

  /// §3 net-of-fees: gross − (⌈gross·bps/10000⌉ + fixed). The percentage
  /// part rounds *up* — overestimating the fee means we never over-deliver;
  /// the operator's at-cost posture absorbs the ≤1¢ variance (§3). Null when
  /// the fee swallows the whole amount (tier priced below the fee floor).
  public func netCents(config : Config, grossCents : Nat) : ?Nat {
    let fee = (grossCents * config.feeBps + 9_999) / 10_000 + config.feeFixedCents;
    if (fee >= grossCents) return null;
    ?(grossCents - fee);
  };

  /// Locked cycle quantity (§3) for an already-netted amount:
  /// netCents · micros · 10_000 (derivation in the module doc).
  public func cyclesForCents(netCents : Nat, xdrPerUsdMicros : Nat) : Nat {
    netCents * xdrPerUsdMicros * 10_000;
  };

  /// One-shot quote: one consistent snapshot of fee config + cached rate.
  /// `#stale` = caller refreshes and re-quotes, or fails closed (§3.1);
  /// `#unpriceable` = the tier's gross doesn't clear the fee — a config
  /// problem, not a rate problem.
  public func quote(cache : Cache, config : Config, grossCents : Nat, nowNs : Int) : {
    #ok : Nat;
    #stale;
    #unpriceable;
  } {
    let ?net = netCents(config, grossCents) else return #unpriceable;
    let ?micros = freshMicros(cache, config.maxAgeNs, nowNs) else return #stale;
    #ok(cyclesForCents(net, micros));
  };

};
