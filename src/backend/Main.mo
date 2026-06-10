/// Fully on-chain cycles gateway — composition root.
///
/// See design-docs/ONCHAIN_GATEWAY_SPEC.md (spec v2.1) and PRD.md for the
/// module layout this actor grows into: Http.mo, Orders.mo, rails/, Cmc.mo,
/// Forex.mo, Treasury.mo, ErrorQueue.mo, Auth.mo.
persistent actor CyclesGateway {

  /// Liveness probe; also used by the scaffold smoke test path.
  public query func health() : async Bool {
    true;
  };
};
