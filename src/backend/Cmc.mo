/// The Cycles Minting Canister, read for **one thing**: `xdr_permyriad_per_icp`.
///
/// That rate is stored on every order beside the XRC's USD/ICP price, so a buyer can
/// recompute their own quote from two public canisters instead of trusting ours. ICP
/// cancels out of the arithmetic, which is why both halves have to come from the same
/// refresh — see `Pricing.mo`.
///
/// ⚠️ **Nothing here mints, and nothing may.** This canister holds no ICP and has no
/// path to any: `CmcService` declares the rate query alone, so adding a method is the
/// only way to give it one. Delivery sells cycles the gateway already holds — see
/// `Delivery.mo`.
import Nat64 "mo:core/Nat64";

module {

  /// Cycles minting canister.
  public let cmcId : Text = "rkp4c-7iaaa-aaaaa-aaaca-cai";

  public type IcpXdrConversionRate = {
    timestamp_seconds : Nat64;
    xdr_permyriad_per_icp : Nat64;
  };

  public type IcpXdrConversionRateResponse = {
    data : IcpXdrConversionRate;
    hash_tree : Blob;
    certificate : Blob;
  };

  /// ⚠️ **The rate query only.** The CMC is read for `xdr_permyriad_per_icp`, which is
  /// stored on every order so a buyer can recompute their own price from public
  /// canisters. Nothing is minted here and nothing may be: declaring a second method
  /// would give this canister a way to spend ICP it does not hold.
  public type CmcService = actor {
    get_icp_xdr_conversion_rate : shared query () -> async IcpXdrConversionRateResponse;
  };

  /// §5 staleness guard on the CMC conversion rate, mirroring CyclePay's
  /// post-incident 15 min (in ns).
  public let cmcRateMaxAgeNs : Int = 900_000_000_000;

  /// §5 staleness guard: the rate iff younger than `maxAgeNs` (age ≥ window =
  /// stale, the Forex/Idempotency convention) and positive. The CMC clock is
  /// authoritative — a timestamp ahead of `nowNs` is fresh, not an error.
  public func freshCmcRate(rate : IcpXdrConversionRate, nowNs : Int, maxAgeNs : Int) : ?Nat {
    let rateNs : Int = rate.timestamp_seconds.toNat() * 1_000_000_000;
    if (nowNs - rateNs >= maxAgeNs) return null;
    let permyriad = rate.xdr_permyriad_per_icp.toNat();
    if (permyriad == 0) return null;
    ?permyriad;
  };

};
