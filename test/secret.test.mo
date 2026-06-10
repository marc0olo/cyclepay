import { test; suite } "mo:test";
import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Secret "../src/backend/Secret";

// Unit suite for the §7 webhook-secret store: provision, rotate, length
// guard (store untouched on rejection), and a status view that exposes
// everything about the secret except the secret.

// Realistic shape: full whsec_ string, prefix included, is the HMAC key.
let whsec = "whsec_5kDjMrYC5nXjV3sNxg2aQbT7uHcRe9wP".encodeUtf8();
let whsecRotated = "whsec_Z0fGq8tBvLm4yKsD1pWnAxEjU6hRc2oI".encodeUtf8();

suite("empty store", func() {
  test("starts unprovisioned", func() {
    let store = Secret.emptyStore();
    assert Secret.get(store) == null;
    assert Secret.status(store) == { isSet = false; generation = 0; setAtNs = null };
  });
});

suite("set and rotate", func() {
  test("first set provisions and bumps generation to 1", func() {
    let store = Secret.emptyStore();
    assert Secret.set(store, whsec, 1_000) == #ok;
    assert Secret.get(store) == ?whsec;
    assert Secret.status(store) == { isSet = true; generation = 1; setAtNs = ?1_000 };
  });

  test("rotation replaces the value and bumps generation", func() {
    let store = Secret.emptyStore();
    assert Secret.set(store, whsec, 1_000) == #ok;
    assert Secret.set(store, whsecRotated, 2_000) == #ok;
    assert Secret.get(store) == ?whsecRotated;
    assert Secret.status(store) == { isSet = true; generation = 2; setAtNs = ?2_000 };
  });

  test("re-setting the same value still counts as a rotation", func() {
    let store = Secret.emptyStore();
    assert Secret.set(store, whsec, 1_000) == #ok;
    assert Secret.set(store, whsec, 2_000) == #ok;
    assert Secret.status(store).generation == 2;
  });
});

suite("length guard", func() {
  test("exactly minSecretBytes is accepted", func() {
    let store = Secret.emptyStore();
    let atMin = Blob.fromArray([0x77, 0x68, 0x73, 0x65, 0x63, 0x5f, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61]);
    assert atMin.size() == Secret.minSecretBytes;
    assert Secret.set(store, atMin, 1_000) == #ok;
  });

  test("one byte under the minimum is rejected", func() {
    let store = Secret.emptyStore();
    let short = Blob.fromArray([0x77, 0x68, 0x73, 0x65, 0x63, 0x5f, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61]);
    assert short.size() + 1 == Secret.minSecretBytes;
    assert Secret.set(store, short, 1_000) == #err(#tooShort({ size = 15; min = 16 }));
    assert Secret.status(store) == { isSet = false; generation = 0; setAtNs = null };
  });

  test("a rejected rotation never clobbers a working secret", func() {
    let store = Secret.emptyStore();
    assert Secret.set(store, whsec, 1_000) == #ok;
    assert Secret.set(store, "".encodeUtf8(), 2_000) == #err(#tooShort({ size = 0; min = 16 }));
    assert Secret.get(store) == ?whsec;
    assert Secret.status(store) == { isSet = true; generation = 1; setAtNs = ?1_000 };
  });
});
