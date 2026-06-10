import { test; suite } "mo:test";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Text "mo:core/Text";
import Runtime "mo:core/Runtime";
import Hmac "../src/backend/Hmac";
import Util "../src/backend/Util";

// HMAC-SHA256 against the RFC 4231 known vectors (plus key-size boundary
// vectors computed externally), the constant-time compare, and the hex codec
// the Stripe path depends on.

func hex(t : Text) : Blob {
  switch (Util.hexDecode(t)) {
    case (?b) b;
    case (null) Runtime.trap("bad hex in test: " # t);
  };
};

func ascii(t : Text) : Blob = Text.encodeUtf8(t);

func repeatByte(byte : Nat8, count : Nat) : Blob {
  Blob.fromArray(Array.tabulate<Nat8>(count, func _ = byte));
};

func assertMac(key : Blob, message : Blob, expectedHex : Text) {
  assert Util.hexEncode(Hmac.sha256(key, [message])) == expectedHex;
};

suite("HMAC-SHA256 RFC 4231 vectors", func() {
  test("case 1: 20-byte key", func() {
    assertMac(
      repeatByte(0x0b, 20),
      ascii("Hi There"),
      "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
    );
  });

  test("case 2: short text key (\"Jefe\")", func() {
    assertMac(
      ascii("Jefe"),
      ascii("what do ya want for nothing?"),
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
    );
  });

  test("case 3: repeated-byte key and data", func() {
    assertMac(
      repeatByte(0xaa, 20),
      repeatByte(0xdd, 50),
      "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
    );
  });

  test("case 4: 25-byte counting key", func() {
    assertMac(
      hex("0102030405060708090a0b0c0d0e0f10111213141516171819"),
      repeatByte(0xcd, 50),
      "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b",
    );
  });

  test("case 6: 131-byte key (hashed first)", func() {
    assertMac(
      repeatByte(0xaa, 131),
      ascii("Test Using Larger Than Block-Size Key - Hash Key First"),
      "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
    );
  });

  test("case 7: 131-byte key, long data", func() {
    assertMac(
      repeatByte(0xaa, 131),
      ascii("This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."),
      "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2",
    );
  });
});

suite("HMAC-SHA256 key-size boundaries", func() {
  // Computed with python hmac/hashlib (see progress log).
  test("empty key, empty message", func() {
    assertMac(
      "" : Blob,
      "" : Blob,
      "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad",
    );
  });

  test("key exactly one block (64 bytes, used as-is)", func() {
    assertMac(
      hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"),
      ascii("key exactly one block"),
      "6ab558ad874f96c504ed4b480a06ad2e68ef89130419c0bf65caf2425b5d3405",
    );
  });

  test("key one over block (65 bytes, hashed)", func() {
    assertMac(
      hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40"),
      ascii("key one over block"),
      "0ecbe1c5e83ae90e943fc25e78126851dd311928ede05ea26fcde2dea4b9a7a9",
    );
  });
});

suite("multi-part message", func() {
  test("parts concatenate: [a, b] == [ab]", func() {
    let key = ascii("Jefe");
    let joined = Hmac.sha256(key, [ascii("what do ya want "), ascii("for nothing?")]);
    let single = Hmac.sha256(key, [ascii("what do ya want for nothing?")]);
    assert joined == single;
  });

  test("no parts == empty message", func() {
    let key = ascii("Jefe");
    assert Hmac.sha256(key, []) == Hmac.sha256(key, ["" : Blob]);
  });
});

suite("constantTimeEqual", func() {
  test("equal blobs", func() {
    assert Hmac.constantTimeEqual(hex("00ff10"), hex("00ff10"));
    assert Hmac.constantTimeEqual("" : Blob, "" : Blob);
  });

  test("differ in first byte", func() {
    assert not Hmac.constantTimeEqual(hex("01ff10"), hex("00ff10"));
  });

  test("differ in last byte", func() {
    assert not Hmac.constantTimeEqual(hex("00ff10"), hex("00ff11"));
  });

  test("length mismatch", func() {
    assert not Hmac.constantTimeEqual(hex("00ff"), hex("00ff10"));
  });
});

suite("hex codec", func() {
  test("encode → decode roundtrip", func() {
    let blob = hex("00017f80ffdeadbeef");
    assert Util.hexDecode(Util.hexEncode(blob)) == ?blob;
  });

  test("decode accepts uppercase", func() {
    assert Util.hexDecode("DEADBEEF") == Util.hexDecode("deadbeef");
  });

  test("decode rejects odd length", func() {
    assert Util.hexDecode("abc") == null;
  });

  test("decode rejects non-hex characters", func() {
    assert Util.hexDecode("zz") == null;
    assert Util.hexDecode("0g") == null;
  });

  test("empty string decodes to empty blob", func() {
    assert Util.hexDecode("") == ?("" : Blob);
    assert Util.hexEncode("" : Blob) == "";
  });
});
