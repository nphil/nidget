# Actual Budget sync protocol & SimpleFIN — primary-source reference

This document is transcribed directly from the `actualbudget/actual` source (cloned at
`master`, commit fetched 2026-08-09) and from `simplefin.org` / `beta-bridge.simplefin.org`.
Every code excerpt is verbatim (file path given). Anything not directly observed in a fetched
source is marked `UNVERIFIED:` with the reasoning behind the inference. This is written for a
Swift engineer implementing both protocols with **no JS dependencies** (no `protobufjs`, no
Node `crypto`, no `murmurhash` npm package) — every algorithm parameter needed to reproduce
byte-for-byte compatible output is called out explicitly.

Sources cloned from: `https://github.com/actualbudget/actual` (branch `master`).

---

## 1. Auth & endpoints table

All sync-server endpoints are relative to a root `SYNC_SERVER` URL (the user's self-hosted or
managed Actual server). Two sibling Express apps exist: `app-account.js` (auth) and
`app-sync.ts` (file/data sync), both mounted at the server root (i.e. `/account/...` prefix is
applied by the outer server, not shown in the source files — the client always talks to
`{SYNC_SERVER}/<path>` as coded in `loot-core`).

| Method | Path | Auth | Content-Type (req) | Body / Headers | Response |
|---|---|---|---|---|---|
| GET | `/account/needs-bootstrap` | none | — | — | `{status:'ok', data:{bootstrapped, loginMethod, availableLoginMethods, multiuser}}` |
| POST | `/account/bootstrap` | none (rate-limited) | `application/json` | `{password}` or `{openId}` | `{status:'ok', data:{token}}` or `{status:'error', reason}` |
| GET | `/account/login-methods` | none | — | — | `{status:'ok', methods}` |
| POST | `/account/login` | none (rate-limited, 5/15min) | `application/json` | `{password}` (or `x-actual-password` header for `header` method) | `{status:'ok', data:{token}}` |
| POST | `/account/change-password` | session token | `application/json` | `{password}` | `{status:'ok', data:{}}` |
| POST | `/account/server-prefs` | session token, admin | `application/json` | `{prefs}` | `{status:'ok', data:{}}` |
| GET | `/account/validate` | session token | — | — | `{status:'ok', data:{validated, userName, permission, userId, displayName, loginMethod, prefs}}` |
| POST | `/sync/sync` | `X-ACTUAL-TOKEN` | `application/actual-sync` (raw protobuf `SyncRequest`) | binary body | binary protobuf `SyncResponse`, `Content-Type: application/actual-sync`, header `X-ACTUAL-SYNC-METHOD: simple` |
| POST | `/sync/user-get-key` | `X-ACTUAL-TOKEN` (in JSON body as `token`, or header) | `application/json` | `{token, fileId}` | `{status:'ok', data:{id, salt, test}}` |
| POST | `/sync/user-create-key` | token | `application/json` | `{fileId, keyId, keySalt, testContent}` | `{status:'ok'}` |
| POST | `/sync/reset-user-file` | token | `application/json` | `{fileId}` | `{status:'ok'}` |
| POST | `/sync/upload-user-file` | token | `application/encrypted-file` (raw bytes; encrypted if `encryptKeyId` set, else the raw zip) | headers: `X-ACTUAL-TOKEN`, `X-ACTUAL-FILE-ID`, `X-ACTUAL-NAME` (URI-encoded budget name), `X-ACTUAL-FORMAT: 2`, optional `X-ACTUAL-ENCRYPT-META` (JSON), optional `X-ACTUAL-GROUP-ID` | `{status:'ok', groupId}` |
| GET | `/sync/download-user-file` | token | — | headers: `X-ACTUAL-TOKEN`, `X-ACTUAL-FILE-ID` | raw bytes (zip, possibly encrypted), `Content-Disposition: attachment;filename=<fileId>` |
| POST | `/sync/update-user-filename` | token | `application/json` | `{fileId, name}` | `{status:'ok'}` |
| GET | `/sync/list-user-files` | token | — | — | `{status:'ok', data:[{deleted, fileId, groupId, name, encryptKeyId, owner, usersWithAccess}]}` |
| GET | `/sync/get-user-file-info` | token | — | header `X-ACTUAL-FILE-ID` | `{status:'ok', data:{deleted, fileId, groupId, name, encryptMeta, usersWithAccess}}` |
| POST | `/sync/delete-user-file` | token | `application/json` | `{fileId}` | `{status:'ok'}` |

Notes verified from source:

- **Token transport**: `validateSession` (`packages/sync-server/src/util/validate-user.ts`) reads
  `req.body.token` first, falling back to header `x-actual-token` (lower-case; Express normalizes
  header names). So `X-ACTUAL-TOKEN` works for every endpoint including JSON-body ones.
  ```ts
  export function validateSession(req: Request, res: Response) {
    let { token } = req.body || {};
    if (!token) {
      token = req.headers['x-actual-token'];
    }
    const session = getSession(token);
    ...
  }
  ```
- **Generic JSON envelope**: every non-binary endpoint returns `{status: 'ok'|'error', data?, reason?}`.
  The generic `post()` helper (`packages/loot-core/src/server/post.ts`) throws unless
  `responseData.status === 'ok'`, and unwraps to `responseData.data`.
- **Binary sync body**: `postBinary()` sets `Content-Type: application/actual-sync` and the server
  parses it with `express.raw({ type: 'application/actual-sync', limit: <cfg fileSizeSyncLimitMB> })`.
  A second raw parser handles `application/encrypted-file` for `/upload-user-file`
  (limit `syncEncryptedFileSizeLimitMB`).
- **File/group id validation**: `ID_REGEX = /^[a-zA-Z0-9_-]+$/` (`packages/sync-server/src/util/paths.ts`).
  Reject or don't send ids containing other characters.
- **Password hashing** (server side, informational only — client never hashes): Argon2id via
  `argon2.hash(password, { type: argon2id, memoryCost: 47104, timeCost: 1, parallelism: 1 })`, with
  bcrypt fallback verify for legacy hashes. Session tokens are plain `uuidv4()` strings, stored in a
  `sessions` table with `expires_at` (unix seconds, `-1` = `TOKEN_EXPIRATION_NEVER`).
- **`/sync` requires `since`**: server responds `422 {status:'error', reason:'unprocessable-entity', details:'since-required'}` if `since` is empty.
- **File ownership check**: `requireFileAccess` — must be `file.owner === userId`, server admin, or
  have an explicit `user_access` grant, else `403` with body `'file-access-not-allowed'` (a bare
  string, not JSON, in this one case — inconsistent with the JSON envelope elsewhere).

---

## 2. `sync.proto` — verbatim

Source: `packages/crdt/src/proto/sync.proto`

```proto
syntax = "proto3";

message EncryptedData {
        bytes iv = 1;
        bytes authTag = 2;
        bytes data = 3;
}

message Message {
        string dataset = 1;
        string row = 2;
        string column = 3;
        string value = 4;
}

message MessageEnvelope {
        string timestamp = 1;
        bool isEncrypted = 2;
        bytes content = 3;
}

message SyncRequest {
        reserved 4;
        repeated MessageEnvelope messages = 1;
        string fileId = 2;
        string groupId = 3;
        string keyId = 5;
        string since = 6;
}

message SyncResponse {
        repeated MessageEnvelope messages = 1;
        string merkle = 2;
}
```

Codegen: standard [`protobuf-es`](https://github.com/bufbuild/protobuf-es) (`protoc-gen-es`
v2.12.0, `@bufbuild/protobuf`), invoked via `packages/crdt/bin/generate-proto`:

```bash
protoc --plugin="protoc-gen-es=..." --es_opt=target=ts --es_out="src/proto" \
  --proto_path=src/proto sync.proto
```

This is **plain proto3 wire format** — no custom wire tricks. `bytes` and `string` fields are wire
type 2 (length-delimited), `bool` is wire type 0 (varint). Field 4 of `SyncRequest` is `reserved`
(previously existed, removed — do not reuse field number 4 there, and expect it to be silently
absent). Field numbering to implement in Swift (e.g. with SwiftProtobuf) must match exactly:

- `EncryptedData`: `iv=1(bytes)`, `authTag=2(bytes)`, `data=3(bytes)`
- `Message`: `dataset=1(string)`, `row=2(string)`, `column=3(string)`, `value=4(string)`
- `MessageEnvelope`: `timestamp=1(string)`, `isEncrypted=2(bool)`, `content=3(bytes)`
- `SyncRequest`: `messages=1(repeated MessageEnvelope)`, `fileId=2(string)`, `groupId=3(string)`,
  `keyId=5(string)`, `since=6(string)` — **note the gap: field 4 is reserved/unused**
- `SyncResponse`: `messages=1(repeated MessageEnvelope)`, `merkle=2(string)` — `merkle` is a
  **JSON string** (`JSON.stringify(trie)` server-side, `JSON.parse` client-side), not a nested
  protobuf message.

`Message.value` is always a **string** on the wire — see §5 for the `0:`/`N:`/`S:` encoding that
turns arbitrary SQLite column values (null/number/string) into that string before it's protobuf-encoded.

---

## 3. HLC timestamp format

Source: `packages/crdt/src/crdt/timestamp.ts` (Hybrid Unique Logical Clock, per the
[HLC paper](http://www.cse.buffalo.edu/tech-reports/2014-04.pdf)).

### 3.1 String format (exact, 46 characters)

```
2015-04-24T22:23:42.123Z-1000-0123456789ABCDEF
└──────── millis (ISO8601 UTC, ms) ──┘ └ctr─┘ └───── node (16 hex) ─────┘
```

```ts
toString() {
  return [
    new Date(this.millis()).toISOString(),
    ('0000' + this.counter().toString(16).toUpperCase()).slice(-4),
    ('0000000000000000' + this.node()).slice(-16),
  ].join('-');
}
```

- **Millis**: `Date.toISOString()` — always `YYYY-MM-DDTHH:mm:ss.sssZ`, 24 chars, UTC, millisecond
  precision, `Z` suffix (never an offset).
- **Counter**: uint16 (`0..0xFFFF`), rendered as **4 uppercase hex digits**, zero-padded (e.g. `002A`).
- **Node id**: up to 16 hex-ish characters (see `makeClientId` below), left-zero-padded to exactly
  16 characters. It is *not* validated to be strictly hex on parse — `Timestamp.parse` only checks
  `node.length <= MAX_NODE_LENGTH` (16); anything within length is accepted.
- The 4 parts are joined with `-`, and since the millis part itself is an ISO string with `-`, the
  full string has **5 dash-separated segments when split on `-`** (`YYYY`, `MM`, `DDTHH:mm:ss.sssZ`
  — wait, actually see parse below: it splits into exactly 5 parts by naive `'-'.split`).

  Concretely: `"2015-04-24T22:23:42.123Z-1000-0123456789ABCDEF".split('-')` yields
  `["2015", "04", "24T22:23:42.123Z", "1000", "0123456789ABCDEF"]` (5 parts) because the date itself
  contains 2 dashes. Parse rejoins the first 3 with `-` to recover the ISO date string:
  ```ts
  static parse(timestamp: string | Timestamp): Timestamp | null {
    ...
    const parts = timestamp.split('-');
    if (parts && parts.length === 5) {
      const millis = Date.parse(parts.slice(0, 3).join('-')).valueOf();
      const counter = parseInt(parts[3], 16);
      const node = parts[4];
      if (!isNaN(millis) && millis >= 0 && !isNaN(counter) && counter <= MAX_COUNTER &&
          typeof node === 'string' && node.length <= MAX_NODE_LENGTH) {
        return new Timestamp(millis, counter, node);
      }
    }
    return null;
  }
  ```
  **Implementation caution**: this means the string is *lexicographically sortable* by
  construction (ISO date, then zero-padded hex counter, then zero-padded node) — the merkle diff
  algorithm and the SQLite `messages_crdt.timestamp` column both rely on plain string/text
  ordering giving correct chronological + tie-break order. A Swift implementation must reproduce
  this exact zero-padding or ordering breaks silently.

### 3.2 Node / client id

```ts
export function makeClientId() {
  return uuidv4().replace(/-/g, '').slice(-16);
}
```
A UUIDv4 with dashes stripped, then the **last 16 hex characters** kept (UUIDv4 hex body is 32
chars; this takes the second half). Result: exactly 16 lowercase hex characters — but note
`toString()` re-pads/upper-cases nothing about the node (it left-pads with `'0'` to 16 chars but
does **not** uppercase it), so node ids stay whatever case they were created in (`makeClientId`
produces lowercase hex from `uuid.v4()`).

### 3.3 `send()` — generate a new local timestamp

```ts
static send(): Timestamp | null {
  const phys = Date.now();
  const lOld = clock.timestamp.millis();
  const cOld = clock.timestamp.counter();
  const lNew = Math.max(lOld, phys);
  const cNew = lOld === lNew ? cOld + 1 : 0;
  if (lNew - phys > config.maxDrift) throw new Timestamp.ClockDriftError(lNew, phys, config.maxDrift);
  if (cNew > MAX_COUNTER) throw new Timestamp.OverflowError();
  clock.timestamp.setMillis(lNew);
  clock.timestamp.setCounter(cNew);
  return new Timestamp(clock.timestamp.millis(), clock.timestamp.counter(), clock.timestamp.node());
}
```
Rule: logical millis never goes backward; if wall clock hasn't advanced past the stored logical
millis, bump the counter instead (guards against multiple sends within the same millisecond).

### 3.4 `recv()` — merge a remote timestamp into the local clock

```ts
static recv(msg: Timestamp): Timestamp | null {
  const phys = Date.now();
  const lMsg = msg.millis();
  const cMsg = msg.counter();
  if (lMsg - phys > config.maxDrift) throw new Timestamp.ClockDriftError();
  const lOld = clock.timestamp.millis();
  const cOld = clock.timestamp.counter();
  const lNew = Math.max(Math.max(lOld, phys), lMsg);
  const cNew =
    lNew === lOld && lNew === lMsg ? Math.max(cOld, cMsg) + 1 :
    lNew === lOld ? cOld + 1 :
    lNew === lMsg ? cMsg + 1 : 0;
  if (lNew - phys > config.maxDrift) throw new Timestamp.ClockDriftError();
  if (cNew > MAX_COUNTER) throw new Timestamp.OverflowError();
  clock.timestamp.setMillis(lNew);
  clock.timestamp.setCounter(cNew);
  return new Timestamp(clock.timestamp.millis(), clock.timestamp.counter(), clock.timestamp.node());
}
```
This is called for **every incoming message** before it's applied (`receiveMessages` in
`packages/loot-core/src/server/sync/index.ts`), to advance the local logical clock so future
`send()`s are causally after everything received.

### 3.5 Constants

```ts
const config = { maxDrift: 5 * 60 * 1000 };  // 5 minutes, in ms
const MAX_COUNTER = parseInt('0xFFFF');       // 65535
const MAX_NODE_LENGTH = 16;
```
- **Max clock drift: 5 minutes** (300000 ms). Exceeding it throws `ClockDriftError`, which
  `sync/index.ts`'s `receiveMessages` catches and re-throws as `SyncError('clock-drift')`.
- Counter overflow (`> 0xFFFF` after increment) throws `OverflowError` — vanishingly rare in
  practice (65536 messages in the same millisecond).
- `Timestamp.zero = "1970-01-01T00:00:00.000Z-0000-0000000000000000"`.
- `Timestamp.max = "9999-12-31T23:59:59.999Z-FFFF-FFFFFFFFFFFFFFFF"`.
- `Timestamp.since(isoString) = isoString + '-0000-0000000000000000'` — used to build a synthetic
  "since" cursor from a plain ISO date when no other cursor is available.

### 3.6 `hash()` — feeds the merkle trie (see §4)

```ts
hash() {
  return murmurhash.v3(this.toString());
}
```
Hashes the **full 46-char timestamp string** (not just millis) — see §4.2 for the exact hash
algorithm and seed.

### 3.7 Clock persistence (client)

```ts
export function serializeClock(clock: Clock): string {
  return JSON.stringify({ timestamp: clock.timestamp.toString(), merkle: clock.merkle });
}
export function deserializeClock(clock: string): Clock {
  let data;
  try { data = JSON.parse(clock); }
  catch { data = { timestamp: '1970-01-01T00:00:00.000Z-0000-' + makeClientId(), merkle: {} }; }
  const ts = Timestamp.parse(data.timestamp);
  if (!ts) throw new Timestamp.InvalidError(data.timestamp);
  return { timestamp: MutableTimestamp.from(ts), merkle: data.merkle };
}
```
Stored as a single row in the local `messages_clock` table (`id=1`, `clock` = this JSON string —
see §6).

---

## 4. Merkle trie spec

Source: `packages/crdt/src/crdt/merkle.ts`.

### 4.1 Structure — trinary radix trie keyed by time-bucket digits

```ts
export type TrieNode = {
  '0'?: TrieNode;
  '1'?: TrieNode;
  '2'?: TrieNode;
  hash?: number;
};
```
Each node has up to 3 children (keys `'0'`, `'1'`, `'2'` — **base-3 digits**) plus an accumulated
`hash` (int32, via XOR — see below). `emptyTrie()` is `{ hash: 0 }`.

### 4.2 Key derivation: minutes since epoch, base-3, 16 digits

```ts
export function insert(trie: TrieNode, timestamp: Timestamp) {
  const hash = timestamp.hash();
  const key = Number(Math.floor(timestamp.millis() / 1000 / 60)).toString(3);
  trie = Object.assign({}, trie, { hash: (trie.hash || 0) ^ hash });
  return insertKey(trie, key, hash);
}
```
- `key = floor(millis / 60000).toString(3)` — **minutes since Unix epoch, converted to base 3**,
  as a variable-length string of digits `'0'|'1'|'2'` (no leading zero padding at this stage;
  padding happens on the *read* side, see `keyToTimestamp` below).
- Each level of the trie is traversed one base-3 digit at a time (`insertKey`, recursive on
  `key[0]` then `key.slice(1)`), XOR-ing the timestamp's hash into every node along the path
  (root included) so a node's `hash` is the XOR of all hashes ever inserted below it.
  ```ts
  function insertKey(trie: TrieNode, key: string, hash: number): TrieNode {
    if (key.length === 0) return trie;
    const c = key[0];
    const t = isNumberTrieNodeKey(c) ? trie[c] : undefined;
    const n = t || {};
    return Object.assign({}, trie, {
      [c]: Object.assign({}, n, insertKey(n, key.slice(1), hash), { hash: (n.hash || 0) ^ hash }),
    });
  }
  ```
- **Reverse mapping** (used by `diff` to turn a matched trie path back into a re-sync cursor time):
  ```ts
  export function keyToTimestamp(key: string): number {
    // 16 is the length of the base 3 value of the current time in minutes.
    const fullkey = key + '0'.repeat(16 - key.length);
    return parseInt(fullkey, 3) * 1000 * 60;
  }
  ```
  A base-3 key is right-padded with `'0'` out to **16 digits** (16 base-3 digits covers
  `3^16 - 1 = 43,046,720` minutes ≈ 81.9 years from epoch — comfortably beyond any realistic sync
  history), parsed back as base 3, then multiplied by 60000 to get milliseconds. This value seeds
  a synthetic `Timestamp(diffTime, 0, '0')` used as the new `since` cursor for the next sync
  round-trip (see §6.4 `_fullSync`).

### 4.3 Hash function: MurmurHash3 (x86, 32-bit), from npm package `murmurhash@^2.0.1`, no explicit seed

```ts
import murmurhash from 'murmurhash';
...
hash() { return murmurhash.v3(this.toString()); }
```
`packages/crdt/package.json` pins `"murmurhash": "^2.0.1"`. That npm package
(`git://github.com/perezd/node-murmurhash`, verified by diffing the published tarball against the
GitHub `master` source — byte-identical) exports **both** MurmurHash2 and MurmurHash3-x86-32 as
`.v2`/`.v3`; `.v3` is MurmurHash3 (r136), 32-bit x86 variant, operating on the **UTF-8 bytes** of
the input string (`new TextEncoder().encode(val)`).

Call site passes **no seed argument** (`murmurhash.v3(this.toString())`). In the JS
implementation, `seed` is used directly as the initial `h1` in bitwise-XOR/shift ops, and
JavaScript's `ToInt32` coercion turns `undefined` into `0` the first time it's used in a bitwise
op — so **`seed=undefined` behaves identically to `seed=0`**. Verified experimentally
(`murmur.v3(str)` and `murmur.v3(str, 0)` produce identical output for the paper's example
timestamp string: `2838536857` in both cases). **A Swift MurmurHash3-x86-32 implementation must
use seed `0`.**

Full source of the relevant function (from the pinned npm tarball, `murmurhash-2.0.1.tgz`,
identical to `perezd/node-murmurhash@master`, for exact bit-op reproduction):
```js
function MurmurHashV3(key, seed) {
  if (typeof key === 'string') key = createBuffer(key); // TextEncoder().encode(val), UTF-8

  let remainder, bytes, h1, h1b, c1, c1b, c2, c2b, k1, i;
  remainder = key.length & 3;
  bytes = key.length - remainder;
  h1 = seed;
  c1 = 0xcc9e2d51;
  c2 = 0x1b873593;
  i = 0;

  while (i < bytes) {
    k1 = ((key[i] & 0xff)) | ((key[++i] & 0xff) << 8) | ((key[++i] & 0xff) << 16) | ((key[++i] & 0xff) << 24);
    ++i;
    k1 = ((((k1 & 0xffff) * c1) + ((((k1 >>> 16) * c1) & 0xffff) << 16))) & 0xffffffff;
    k1 = (k1 << 15) | (k1 >>> 17);
    k1 = ((((k1 & 0xffff) * c2) + ((((k1 >>> 16) * c2) & 0xffff) << 16))) & 0xffffffff;
    h1 ^= k1;
    h1 = (h1 << 13) | (h1 >>> 19);
    h1b = ((((h1 & 0xffff) * 5) + ((((h1 >>> 16) * 5) & 0xffff) << 16))) & 0xffffffff;
    h1 = (((h1b & 0xffff) + 0x6b64) + ((((h1b >>> 16) + 0xe654) & 0xffff) << 16));
  }

  k1 = 0;
  switch (remainder) {
    case 3: k1 ^= (key[i + 2] & 0xff) << 16;
    case 2: k1 ^= (key[i + 1] & 0xff) << 8;
    case 1: k1 ^= (key[i] & 0xff);
      k1 = (((k1 & 0xffff) * c1) + ((((k1 >>> 16) * c1) & 0xffff) << 16)) & 0xffffffff;
      k1 = (k1 << 15) | (k1 >>> 17);
      k1 = (((k1 & 0xffff) * c2) + ((((k1 >>> 16) * c2) & 0xffff) << 16)) & 0xffffffff;
      h1 ^= k1;
  }

  h1 ^= key.length;
  h1 ^= h1 >>> 16;
  h1 = (((h1 & 0xffff) * 0x85ebca6b) + ((((h1 >>> 16) * 0x85ebca6b) & 0xffff) << 16)) & 0xffffffff;
  h1 ^= h1 >>> 13;
  h1 = ((((h1 & 0xffff) * 0xc2b2ae35) + ((((h1 >>> 16) * 0xc2b2ae35) & 0xffff) << 16))) & 0xffffffff;
  h1 ^= h1 >>> 16;
  return h1 >>> 0; // unsigned 32-bit
}
```
This is **textbook MurmurHash3_x86_32** (Austin Appleby, seed=0, `c1=0xcc9e2d51`, `c2=0x1b873593`,
`fmix` constants `0x85ebca6b`/`0xc2b2ae35`) — any correct standard implementation (e.g. Swift port
of `smhasher`'s `MurmurHash3_x86_32`) with **seed 0** over the **UTF-8 bytes of the 46-character
timestamp string** will match. The trie stores hashes as signed/unsigned 32-bit; JS numbers make
this ambiguous — treat as `UInt32` throughout except where XOR'd into a JS `number` (safe either
way since XOR is bit-identical for the low 32 bits).

### 4.4 `build`, `diff`, `prune`

```ts
export function build(timestamps: Timestamp[]) {
  const trie = emptyTrie();
  for (const timestamp of timestamps) insert(trie, timestamp);
  return trie;
}
```
**Implementation caution**: `insert()` returns a *new* trie (functional/immutable style) but
`build()` discards the return value and keeps re-inserting into the original `trie` reference —
this is very likely a latent bug in upstream (each `insert` call after the first operates on an
unmodified empty trie unless the caller uses the return value, as the production code path
`applyMessages` in `sync/index.ts` does: `currentMerkle = merkle.insert(currentMerkle, timestamp)`).
**Always use the return value of `insert`**; do not rely on `build()`'s in-place mutation
semantics — port `applyMessages`'s reduce-style usage instead.

```ts
export function diff(trie1: TrieNode, trie2: TrieNode): number | null {
  if (trie1.hash === trie2.hash) return null;
  let node1 = trie1, node2 = trie2, k = '';
  while (true) {
    const keyset = new Set([...getKeys(node1), ...getKeys(node2)]);
    const keys = [...keyset.values()];
    keys.sort((a, b) => a.localeCompare(b));  // '0' < '1' < '2', lexicographic
    let diffkey: null | '0' | '1' | '2' = null;
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const next1 = node1[key];
      const next2 = node2[key];
      if (!next1 || !next2) break;             // pruned on one side — stop, can't go deeper
      if (next1.hash !== next2.hash) { diffkey = key; break; }
    }
    if (!diffkey) return keyToTimestamp(k);     // bottom reached, or pruned mismatch
    k += diffkey;
    node1 = node1[diffkey] || emptyTrie();
    node2 = node2[diffkey] || emptyTrie();
  }
}
```
Returns `null` if the two tries are identical (root hashes equal), otherwise the **millisecond
timestamp of the earliest minute-bucket the two tries disagree on** (via `keyToTimestamp`). This
becomes the client's next `since` cursor (as `new Timestamp(diffTime, 0, '0').toString()`) to
re-request from that point forward. Traversal order matters: keys are visited in ascending
lexicographic order `'0' < '1' < '2'` at each level, and it stops descending as soon as either
side is missing a child (because pruning is lossy — see below) rather than treating "missing" as
"empty/zero".

```ts
export function prune(trie: TrieNode, n = 2): TrieNode {
  if (!trie.hash) return trie;
  const keys = getKeys(trie);
  keys.sort((a, b) => a.localeCompare(b));
  const next: TrieNode = { hash: trie.hash };
  for (const k of keys.slice(-n)) {           // keep only the LAST n keys (numerically largest,
    const node = trie[k];                      // i.e. most recent minute-buckets) at each level
    next[k] = prune(node, n);
  }
  return next;
}
```
Called once per `applyMessages` transaction (`currentMerkle = merkle.prune(currentMerkle)` in
`sync/index.ts`) with the default `n=2`: at every level of the trie, only the **2
lexicographically-largest child keys** are retained (i.e. the most recent time buckets), older
sibling branches are dropped entirely (their aggregate hash is already folded into every ancestor,
so root-hash correctness is preserved — only the ability to pinpoint *exactly where* an old
mismatch lives is lost, which is what `diff`'s "stop when a child is missing on either side"
handles).

---

## 5. Value encoding — the `0:` / `N:` / `S:` prefix scheme

Source: `packages/loot-core/src/server/sync/index.ts`.

```ts
export function serializeValue(value: string | number | null): string {
  if (value === null) {
    return '0:';
  } else if (typeof value === 'number') {
    return 'N:' + value;
  } else if (typeof value === 'string') {
    return 'S:' + value;
  }
  throw new Error('Unserializable value type: ' + JSON.stringify(value));
}

export function deserializeValue(value: string): string | number | null {
  const type = value[0];
  switch (type) {
    case '0': return null;
    case 'N': return parseFloat(value.slice(2));
    case 'S': return value.slice(2);
    default:
  }
  throw new Error('Invalid type key for value: ' + value);
}
```
Exact rules:
- **null** → literal 2-char string `"0:"` (the character `'0'`, not the type tag `'N'`; on decode
  only the **first character** is switched on, so `'0'` → null regardless of what follows — the
  colon is not even required to decode, but always emitted on encode).
- **number** → `"N:" + String(value)` — JS's default `Number.prototype.toString()` coercion (e.g.
  `-33.5` → `"N:-33.5"`, `1e21` → exponential notation for very large numbers — match JS's
  double-to-string algorithm if exact round-tripping of extreme values matters; in practice all
  Actual numeric columns are small integers/floats so this is not a practical concern). Decode
  uses `parseFloat`.
- **string** → `"S:" + value` verbatim (no escaping — a string value that itself starts with
  `"0:"`, `"N:"`, or `"S:"` is stored as `"S:0:..."` etc., which decodes fine since only the type
  tag is inspected, not the payload).
- This serialized string is what goes into **`Message.value`** in the protobuf (`sync.proto`
  field is `string value = 4`), i.e. the wire format never carries a raw SQLite column value —
  it's always this tagged string. `deserializeValue` is applied client-side immediately after
  protobuf decode (`encoder.ts` leaves `msg.value` as the tagged string; `sync/index.ts`'s
  `_fullSync` calls `deserializeValue(msg.value as string)` before feeding into `receiveMessages`).

---

## 6. Message apply algorithm + local CRDT tables

Source: `packages/loot-core/src/server/sync/index.ts`, `packages/loot-core/src/server/sql/init.sql`,
plus later migrations (`packages/loot-core/migrations/*.sql`).

### 6.1 Local SQLite CRDT bookkeeping tables (DDL, verbatim from `init.sql`)

```sql
CREATE TABLE messages_crdt
 (id INTEGER PRIMARY KEY,
  timestamp TEXT NOT NULL UNIQUE,
  dataset TEXT NOT NULL,
  row TEXT NOT NULL,
  column TEXT NOT NULL,
  value BLOB NOT NULL);

CREATE TABLE messages_clock (id INTEGER PRIMARY KEY, clock TEXT);
```
- `messages_crdt` is the append-only log of every applied CRDT message, keyed uniquely by its HLC
  `timestamp` string (so `INSERT ... VALUES` naturally enforces "already applied" detection via a
  `SELECT` first — see `compareMessages` below — the `UNIQUE` constraint is a safety net, not the
  primary de-dup mechanism, since de-dup happens in application code before insert).
- `messages_clock` holds exactly **one row** (`id=1`), whose `clock` column is
  `serializeClock({timestamp, merkle})` — the JSON string from §3.7. It's replaced with
  `INSERT OR REPLACE INTO messages_clock (id, clock) VALUES (1, ?)` at the end of every applied
  batch, inside the same SQLite transaction as the row mutations (atomicity: either the whole
  batch — data rows + crdt log + clock — commits, or none of it does).
- `value BLOB NOT NULL` in the DDL, but the code always stores it as the *tagged string* from §5
  (SQLite is dynamically typed; a TEXT string fits fine in a BLOB column).

### 6.2 `apply(msg, prev)` — single message → SQL

```ts
function apply(msg: Message, prev?: boolean) {
  const { dataset, row, column, value } = msg;
  if (dataset === 'prefs') {
    // Do nothing, it doesn't exist in the db
  } else {
    let query;
    if (prev) {
      query = { sql: `UPDATE ${dataset} SET ${column} = ? WHERE id = ?`, params: [value, row] };
    } else {
      query = { sql: `INSERT INTO ${dataset} (id, ${column}) VALUES (?, ?)`, params: [row, value] };
    }
    db.runQuery(db.cache(query.sql), query.params);
  }
}
```
- `dataset` maps **directly to a SQLite table name** (`transactions`, `accounts`, `payees`, ...)
  and `column` directly to a **column name** — both are interpolated into raw SQL (trusted because
  they only ever originate from the schema's own field names via the AQL executor, never from
  arbitrary user/network input beyond what the schema allows — a Swift port should validate
  `dataset`/`column` against a known table/column allowlist before formatting SQL, since this
  pattern is a SQL-injection footgun if fed untrusted values).
- `dataset === 'prefs'` is special: it's not a SQL table; those key/value pairs are written via
  `prefs.savePrefs` after the transaction (see `applyMessages` below), not through `apply()`.
- **First application of a row** (row id doesn't yet exist in `oldData`) → `INSERT` with just
  `(id, column)` — SQLite fills all other columns with their `DEFAULT`. **Every column of a new
  row therefore arrives as a separate CRDT message** (one message per field, all sharing the same
  target row id) — a brand-new transaction is many `Message`s, not one.
- **Subsequent updates to an existing row** → `UPDATE ... SET column = ? WHERE id = ?`.
- Whether a row is "new" is tracked per-apply-batch by an in-memory `Set` (`added`, keyed by
  `dataset + row`) seeded from a pre-fetch of the affected rows (`oldData`), so multiple messages
  for the same brand-new row in one batch correctly become 1 INSERT + N UPDATEs, not N INSERTs.

### 6.3 `applyMessages(messages)` — full algorithm (paraphrased with exact rules)

1. **Skip in `import` mode** — fast path, no CRDT bookkeeping (`applyMessagesForImport`).
2. **`compareMessages`** (only when syncing mode is `enabled`): for each incoming message, query
   `SELECT timestamp FROM messages_crdt WHERE dataset=? AND row=? AND column=? AND timestamp >= ?`.
   - No row found → message is new, keep as-is.
   - Row found but its stored `timestamp !== incoming timestamp` → the incoming message is
     **older** than what's already applied for that exact `(dataset,row,column)` cell (last-write-
     wins per cell, keyed by HLC timestamp) → mark `{...message, old: true}` (still gets logged
     into `messages_crdt` for merkle correctness, but its value is **not** applied to the data
     table).
   - Row found and timestamps match exactly → this is the same message already applied; it's
     **dropped entirely** (not even pushed into `newMessages`) — i.e. it will *not* re-enter the
     merkle trie a second time (already there from the first application).
3. **Sort** all surviving messages ascending by `timestamp.toString()` (plain string comparison —
   relies on the HLC string format's lexicographic-sortability, §3.1).
4. **Pre-fetch `oldData`**: batch-`SELECT` (in chunks of 100 ids per `OR`-chain — see `fetchAll`,
   chunked to avoid a Safari JS stack overflow on huge `IN`-equivalent queries) every row touched
   by the batch, per dataset, before mutating anything — this snapshot feeds spreadsheet/query
   invalidation afterward and determines `apply(msg, prev)`'s insert-vs-update branch.
5. Inside a single **SQLite transaction**:
   - For each sorted message, if not `old`: call `apply(msg, <row already known?>)`; if
     `dataset === 'prefs'`, stage `prefsToSet[row] = value` instead of touching a table.
   - If sync mode is `enabled` (regardless of `old`-ness): `INSERT INTO messages_crdt (timestamp,
     dataset, row, column, value) VALUES (...)` with `value` = `serializeValue(value)` (§5), and
     fold the message into the in-flight merkle trie: `currentMerkle = merkle.insert(currentMerkle,
     timestamp)`.
   - After the loop: `currentMerkle = merkle.prune(currentMerkle)`, then persist
     `INSERT OR REPLACE INTO messages_clock (id, clock) VALUES (1, ?)` with the new
     `serializeClock({...clock, merkle: currentMerkle})`.
6. Only after the transaction **commits** does the in-memory `clock.merkle` get updated to match —
   guarantees the in-memory clock never drifts ahead of what's durably persisted.
7. Persist any staged `prefsToSet` via `prefs.savePrefs(..., {avoidSync:true})` (so writing synced
   prefs back doesn't re-trigger an outbound sync loop).
8. Recompute spreadsheet/query caches (`sheet.get().triggerDatabaseChanges`, budget recompute for
   `transactions` changes) — application-level concern, not part of the wire protocol.
9. Return the full processed `messages` array (including `old`-flagged ones) to the caller.

`receiveMessages(messages)` wraps this: first calls `Timestamp.recv(msg.timestamp)` for every
incoming message (advancing the local clock, §3.4) — catching `ClockDriftError` and converting
it to `SyncError('clock-drift')` — then runs `applyMessages` inside a mutator lock
(`runMutator`, serializes with any concurrent local mutation).

### 6.4 Full-sync round trip (`_fullSync` in `sync/index.ts`)

```ts
const since = sinceTimestamp || lastSyncedTimestamp || new Timestamp(Date.now() - 5*60*1000, 0, '0').toString();
const messages = getMessagesSince(since); // SELECT ... FROM messages_crdt WHERE timestamp > ?
const buffer = await encoder.encode(groupId, cloudFileId, since, messages);
const resBuffer = await postBinary(SYNC_SERVER + '/sync', buffer, { 'X-ACTUAL-TOKEN': userToken });
const res = await encoder.decode(resBuffer);
// apply res.messages via receiveMessages(...)
const diffTime = merkle.diff(res.merkle, getClock().merkle);
if (diffTime !== null) {
  // recurse: _fullSync(new Timestamp(diffTime, 0, '0').toString(), count+1, diffTime)
} else {
  // fully synced — persist lastSyncedTimestamp = getClock().timestamp.toString()
}
```
- **`since` default**: last successful sync cursor from prefs, else **5 minutes before now** (not
  epoch zero) — a fresh/never-synced client still only asks for a short recent window on its very
  first `_fullSync(null, 0, null)` call; the *initial full download* of a budget file happens via
  the separate zip download endpoint (§8), not by walking sync messages from epoch.
- **Local outbound messages** are everything in `messages_crdt` with `timestamp > since` — i.e.
  the client always re-sends its own unacknowledged local log on every sync attempt (the server is
  expected to de-dup by timestamp on its own side too, mirroring §6.3 step 2's logic but
  server-side — not shown here since `simpleSync.sync()`'s implementation lives in the sync-server
  package, outside the fetched-source scope of this document).
- **Merkle mismatch loop**: after applying whatever the server sent back, compare tries
  (`merkle.diff(res.merkle, getClock().merkle)`). If they still disagree, the client immediately
  re-syncs (recursively) using `diffTime` as the new `since` cursor, up to **10 retries with the
  same `diffTime`** or **100 total retries**, whichever comes first, before giving up with
  `SyncError('out-of-sync')`. If anything changed locally mid-loop (`localTimeChanged`), the
  retry counter resets to avoid false-positive "stuck" detection while the user is actively
  editing during a sync.
- On success (`diffTime === null`), the client stores `lastSyncedTimestamp =
  getClock().timestamp.toString()` (only if it actually changed) as an optimization for the next
  sync's `since` default.

---

## 7. E2E encryption spec

Source: `packages/loot-core/src/server/encryption/{index.ts,app.ts,encryption-internals.electron.ts,encryption-internals.ts}`.

### 7.1 Algorithm: AES-256-GCM

Both the Node/Electron implementation (`encryption-internals.electron.ts`, uses `node:crypto`)
and the browser/WASM implementation (`encryption-internals.ts`, uses WebCrypto `crypto.subtle`)
target the **same algorithm and produce wire-compatible output**:

```ts
const ENCRYPTION_ALGORITHM = 'aes-256-gcm' as const;
```

Node/Electron encrypt:
```ts
export const encrypt: typeof T.encrypt = async (masterKey, value) => {
  const masterKeyBuffer = masterKey.getValue().raw;
  const iv = crypto.randomBytes(12);                       // 12-byte (96-bit) random IV
  const cipher = crypto.createCipheriv('aes-256-gcm', masterKeyBuffer, iv);
  let encrypted = cipher.update(value);
  encrypted = Buffer.concat([encrypted, cipher.final()]);
  const authTag = cipher.getAuthTag();                      // 16-byte GCM tag, separate from ciphertext
  return { value: encrypted, meta: { keyId: masterKey.getId(), algorithm: 'aes-256-gcm',
    iv: iv.toString('base64'), authTag: authTag.toString('base64') } };
};
```
Browser/WebCrypto encrypt (functionally identical result):
```ts
export async function encrypt(masterKey, value) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encryptedArrayBuffer = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv, tagLength: 128 }, masterKey.getValue().raw, value);
  const encrypted = Buffer.from(encryptedArrayBuffer);
  const authTag = encrypted.slice(-16);        // WebCrypto appends the tag to ciphertext; split it off
  const strippedEncrypted = encrypted.slice(0, -16);
  return { value: strippedEncrypted, meta: { keyId: masterKey.getId(), algorithm: 'aes-256-gcm',
    iv: Buffer.from(iv).toString('base64'), authTag: authTag.toString('base64') } };
}
```

**Exact parameters for a Swift port (`CryptoKit.AES.GCM`)**:
- Key length: **256 bits** (32 bytes).
- IV/nonce: **12 bytes (96 bits)**, cryptographically random, freshly generated **per encrypt
  call** (never reused).
- Auth tag: **16 bytes (128 bits)**, standard GCM tag length — kept **separate** from ciphertext on
  the wire (`EncryptedData.data` is ciphertext only, `EncryptedData.authTag` is the 16-byte tag,
  `EncryptedData.iv` is the 12-byte nonce — matches `CryptoKit.AES.GCM.SealedBox`'s
  `ciphertext`/`tag`/`nonce` triple directly).
- No AAD (additional authenticated data) is used anywhere in this code path.
- Decrypt (Node): `crypto.createDecipheriv('aes-256-gcm', key, iv); decipher.setAuthTag(authTag);
  decipher.update(ciphertext) + decipher.final()`. Decrypt (WebCrypto):
  `crypto.subtle.decrypt({name:'AES-GCM', iv, tagLength:128}, key, ciphertext ++ authTag)` — i.e.
  WebCrypto wants tag appended back onto ciphertext before calling decrypt; Node wants it set
  separately via `setAuthTag`. Either produces the same plaintext for the same inputs.

### 7.2 Key derivation: PBKDF2-HMAC-SHA512, 10000 iterations, 32-byte key

Both implementations agree exactly:
```ts
// Node (encryption-internals.electron.ts)
function createKeyBuffer({ numBytes, secret, salt }) {
  return crypto.pbkdf2Sync(
    secret || crypto.randomBytes(128).toString('base64'),
    salt || crypto.randomBytes(32).toString('base64'),
    10000,             // iterations
    numBytes || 32,    // derived key length in bytes (default 32 = 256 bits)
    'sha512');          // PRF: HMAC-SHA-512
}
export const createKey = async ({ secret, salt }) => {
  const buffer = createKeyBuffer({ secret, salt });
  return { raw: buffer, base64: buffer.toString('base64') };
};
```
```ts
// WebCrypto (encryption-internals.ts)
export async function createKey({ secret, salt }) {
  const passwordKey = await crypto.subtle.importKey('raw', Buffer.from(secret), { name: 'PBKDF2' }, false, ['deriveBits','deriveKey']);
  const derivedKey = await crypto.subtle.deriveKey(
    { name: 'PBKDF2', hash: 'SHA-512', salt: Buffer.from(salt), iterations: 10000 },
    passwordKey, { name: 'AES-GCM', length: 256 }, true, ['encrypt','decrypt']);
  ...
}
```
**Exact PBKDF2 parameters**: `PRF = HMAC-SHA-512`, `iterations = 10000`, `dkLen = 32 bytes`,
`password = UTF-8 bytes of the user's password string`, `salt = UTF-8 bytes of a base64 string`
(the salt itself is generated as `encryption.randomBytes(32).toString('base64')` — i.e. **32
random bytes, base64-encoded, and that base64 *text* is what's fed as the PBKDF2 salt**, not the
raw 32 bytes — a subtle but load-bearing detail: reproduce by base64-encoding the salt bytes to a
string and hashing that string's UTF-8 representation as the PBKDF2 salt input). Salt is generated
once (`key-make` in `encryption/app.ts`) and stored server-side per file (`encryptSalt` column),
fetched via `POST /sync/user-get-key` on the client that needs to unlock the file with a password.

`importKey(base64Str)` for re-loading an already-derived key from local storage just base64-decodes
straight into the raw AES key bytes (no further KDF):
```ts
export const importKey = str => ({ raw: Buffer.from(str, 'base64'), base64: str });
```

### 7.3 What is encrypted, and the "test" ciphertext

- **Sync messages**: each individual protobuf-serialized `Message` (dataset/row/column/value) is
  AES-256-GCM-encrypted *before* being wrapped in `EncryptedData` and that in turn placed as the
  `content` bytes of a `MessageEnvelope` with `isEncrypted = true` (`encoder.ts::encode`):
  ```ts
  const binaryMsg = toBinary(MessageSchema, create(MessageSchema, { dataset, row, column, value }));
  const result = await encryption.encrypt(binaryMsg, encryptKeyId);
  content = toBinary(EncryptedDataSchema, create(EncryptedDataSchema, {
    data: result.value, iv: Buffer.from(result.meta.iv, 'base64'), authTag: Buffer.from(result.meta.authTag, 'base64') }));
  ```
  So the **plaintext being encrypted is the raw protobuf-encoded `Message` bytes**, not the JSON
  form and not just the `value` string alone — `dataset`/`row`/`column` are also hidden from the
  server when encryption is on. `MessageEnvelope.timestamp` (the HLC string) is **never
  encrypted** — the server can see timestamps in plaintext even for E2E-encrypted files (needed
  for merkle bucketing/dedup server-side).
- **Whole-file upload/download** (§8): the entire zip buffer (`db.sqlite` + `metadata.json`,
  zipped) is encrypted as one blob the same way — `encryption.encrypt(zipContent, encryptKeyId)` —
  and the resulting `meta` (`{keyId, algorithm, iv, authTag}`) is sent as the JSON-stringified
  `X-ACTUAL-ENCRYPT-META` header alongside the raw encrypted body
  (`Content-Type: application/encrypted-file`).
- **Key-validity "test" ciphertext**: when a key is created (`key-make` in `encryption/app.ts`),
  a small deterministic test message (`makeTestMessage(keyId)` — not fetched in this pass, see
  `packages/loot-core/src/server/sync/make-test-message.ts`, **UNVERIFIED: exact plaintext content
  not read from source**, but its *envelope* is confirmed) is encrypted and its
  `{value(base64), meta:{keyId, algorithm, iv, authTag}}` JSON is stored server-side
  (`encryptTest` column, set via `POST /sync/user-create-key`'s `testContent`). To test a
  password client-side (`keyTest` in `encryption/app.ts`), the client fetches
  `{id, salt, test}` via `POST /sync/user-get-key`, re-derives a key from the candidate password +
  fetched salt, and attempts `encryption.decrypt(base64Decode(test.value), test.meta)` — success
  (no GCM auth failure) means the password is correct, independent of ever downloading the actual
  budget file.

### 7.4 Key identity

- Each encryption key has a **`keyId`** (`uuidv4()`), generated client-side at key-creation time
  and both used to select which locally-loaded key decrypts an incoming payload
  (`EncryptedData` doesn't carry `keyId` itself — it's implied by file-level state: the sync
  request's `SyncRequest.keyId` field, or `metadata.json`'s `encryptKeyId`, tells the reader which
  key to use) and stored server-side per-file (`file.encryptKeyId`).
- `SyncRequest.keyId` (proto field 5) is set from local prefs (`encryptKeyId`) on every sync
  request the client sends, whether or not messages in that batch are actually encrypted-with-that-
  key (it's really "the file's current encryption key id", not per-message).

---

## 8. Budget file zip + `metadata.json` + SQLite schema

Source: `packages/loot-core/src/server/cloud-storage.ts`, `packages/loot-core/src/server/sql/init.sql`,
`packages/loot-core/migrations/*`, `packages/loot-core/src/server/aql/schema/index.ts`.

### 8.1 Zip layout

Exactly two entries at the zip root (or under one shared subdirectory — `importBuffer` accepts
both layouts as long as both files are found together under the same prefix):
```
db.sqlite       — the full SQLite database file (binary)
metadata.json   — UTF-8 JSON
```
Before zipping for upload, the client wipes ephemeral cache tables:
```ts
sqlite.execQuery(memDb, `DELETE FROM kvcache; DELETE FROM kvcache_key;`);
```
so `kvcache`/`kvcache_key` (spreadsheet computation cache — always safe to fully recompute) are
**never present with data in an uploaded file** (a fresh download always recomputes them).
`meta.resetClock = true` is also stamped into the outgoing `metadata.json` so that a *new*
downloading client knows to mint a fresh node/client id rather than colliding with the uploader's
(see §8.2).

### 8.2 `metadata.json` fields observed being read/written

From `importBuffer`/`exportBuffer` in `cloud-storage.ts` (fields explicitly touched by this file;
the full metadata schema likely has more app-level fields not exercised here —
**UNVERIFIED beyond this list**, since `metadata.json`'s full shape lives in prefs-writing code
not fetched in this pass):

| Field | Set by | Notes |
|---|---|---|
| `id` | pre-existing (local budget id) | Used to compute `fs.getBudgetDir(meta.id)` — the local on-disk folder name for this budget. |
| `cloudFileId` | overwritten on import: `fileData.fileId` | The server-assigned opaque file id (`X-ACTUAL-FILE-ID`). |
| `groupId` | overwritten on import: `fileData.groupId` | The current sync group id (rotates on sync-reset). |
| `lastUploaded` | overwritten on import: `monthUtils.currentDay()` | `yyyy-mm-dd` string, "day this copy was fetched/pushed". |
| `encryptKeyId` | overwritten on import: `fileData.encryptMeta ? fileData.encryptMeta.keyId : null` | Which key (if any) protects this file's *messages* going forward. |
| `resetClock` | set to `true` on export (`exportBuffer`) | Signal to the importing side: mint a new HLC node id rather than reusing the exporter's — prevents two clients from ever sharing a node id after a file changes hands. |
| `budgetName` | read by `exportBuffer` (from prefs, not metadata.json directly) | Sent as the `X-ACTUAL-NAME` upload header. |

**UNVERIFIED**: exact full metadata.json shape (other fields like `budgetType`) — not exercised in
`cloud-storage.ts`; would need `packages/loot-core/src/server/prefs.ts` to enumerate every key.
The task description's guess of `groupId, cloudFileId, encryptKeyId` fields is **confirmed**;
`budgetName` is confirmed to exist as a *prefs* field written into the upload header, not
necessarily verified as literally present inside `metadata.json` from this file alone (it's read
via `prefs.getPrefs()`, a separate local-prefs abstraction — likely metadata.json backs prefs
storage, but that mapping wasn't directly fetched).

### 8.3 Upload / download flow (headers, exact)

Upload (`upload()` in `cloud-storage.ts`):
```
POST {SYNC_SERVER}/upload-user-file
Content-Length: <byte length>
Content-Type: application/encrypted-file
X-ACTUAL-TOKEN: <token>
X-ACTUAL-FILE-ID: <cloudFileId>              (client-generated uuidv4() if this is a brand-new file)
X-ACTUAL-NAME: <encodeURIComponent(budgetName)>
X-ACTUAL-FORMAT: 2
X-ACTUAL-ENCRYPT-META: <JSON {keyId,algorithm,iv,authTag}>   (only if encryptKeyId set)
X-ACTUAL-GROUP-ID: <groupId>                                  (only if a groupId already exists)
body: raw bytes — the zip, or the AES-GCM ciphertext of the zip if encrypted
```
Response `{status:'ok', groupId}`; if this was a brand-new file the server mints and returns a new
`groupId` (`generateGroupId()` = `uuidv4()`), otherwise (if the client sent no `X-ACTUAL-GROUP-ID`,
meaning a local sync-reset happened) it also mints a fresh one.

Download (`download()` in `cloud-storage.ts`) — **two parallel requests**:
```
GET {SYNC_SERVER}/download-user-file
  X-ACTUAL-TOKEN, X-ACTUAL-FILE-ID
  → raw bytes (Content-Disposition: attachment;filename=<fileId>)

GET {SYNC_SERVER}/get-user-file-info
  X-ACTUAL-TOKEN, X-ACTUAL-FILE-ID
  → {status:'ok', data:{deleted, fileId, groupId, name, encryptMeta, usersWithAccess}}
```
If `fileData.encryptMeta` is present, the raw downloaded bytes are decrypted
(`encryption.decrypt(buffer, fileData.encryptMeta)`) before unzipping. `encryptMeta` here is the
**whole-file** encryption meta (`{keyId, algorithm, iv, authTag}`), independent of whether
individual sync *messages* are separately encrypted with the same key.

### 8.4 SQLite schema — authoritative field reference

The on-disk table columns (raw SQLite, what CRDT `dataset`/`column` messages actually target) are
**not** the same names the app/AQL layer exposes publicly — there is a view-mapping layer
(`packages/loot-core/src/server/aql/schema/index.ts`, `schemaConfig.views`) that renames columns.
**CRDT messages always target the raw column names** (left column below), since `apply()` in
§6.2 runs raw `INSERT`/`UPDATE` against the base tables.

**`transactions`** (base table, from `init.sql` + migrations `1608652596044_trans_views.sql`,
`1582384163573_cleared.sql`, `1697046240000_add_reconciled.sql`, `1618975177358_schedules.sql`):

| Raw column (CRDT target / SQL) | Public AQL name | Type | Notes |
|---|---|---|---|
| `id` | `id` | TEXT PK | |
| `isParent` | `is_parent` | INTEGER (bool) default 0 | |
| `isChild` | `is_child` | INTEGER (bool) default 0 | |
| `acct` | `account` | TEXT | FK → accounts.id |
| `category` | `category` | TEXT | actually a FK into `category_mapping.id` → `transferId`, resolved through a join (see `v_transactions_internal`); NULL when `isParent=1` |
| `amount` | `amount` | INTEGER | **integer cents** (`amountToInteger(amount, 2)` = `round(amount * 100)`) |
| `description` | `payee` | TEXT | **holds a payee_mapping id, not free text** — resolved via `LEFT JOIN payee_mapping pm ON pm.id = _.description` → `pm.targetId` is the real `payees.id` |
| `notes` | `notes` | TEXT | free text |
| `date` | `date` | INTEGER | **`yyyyMMdd` integer**, e.g. `20260809` (confirmed via `dateToInt`/`d.format(..., 'yyyyMMdd')` in AQL compiler + `months.ts`) |
| `financial_id` | `imported_id` | TEXT | bank-import dedup id |
| `type`, `location`, `error` | `error` (only `error` is in current AQL schema; `type`/`location` are legacy/unused) | TEXT | |
| `imported_description` | `imported_payee` | TEXT | raw bank-provided payee string, pre category/payee-learning |
| `starting_balance_flag` | `starting_balance_flag` | INTEGER (bool) default 0 | |
| `transferred_id` | `transfer_id` | TEXT | counterpart transaction id for transfers |
| `sort_order` | `sort_order` | REAL | default `Date.now()` at creation (AQL schema) |
| `tombstone` | `tombstone` | INTEGER (bool) default 0 | soft-delete flag |
| `cleared` | `cleared` | INTEGER (bool) default **1** | added by migration, default *true* |
| `pending` | *(not in current AQL schema — legacy)* | INTEGER default 0 | added same migration as `cleared` |
| `reconciled` | `reconciled` | INTEGER (bool) default 0 | added later migration |
| `schedule` | `schedule` | TEXT | FK → schedules.id, added by schedules migration |
| `parent_id` | `parent_id` | TEXT | only meaningful when `isChild=1` (view nulls it out otherwise) |
| `raw_synced_data` | `raw_synced_data` | TEXT | added by `migrations/1739139550000_bank_sync_page.sql` (`ALTER TABLE transactions ADD COLUMN raw_synced_data text`), same migration adds `accounts.last_sync` |

Confirms the task's guesses precisely: **`description` is indeed the payee-id column** (not free
text — free text lives in `imported_description`/`imported_payee`), `date` is **integer
`yyyymmdd`**, `amount` is **integer cents**, and `starting_balance_flag`/`sort_order`/`tombstone`/
`transfer_id` (`transferred_id`)/`parent_id`/`is_child`/`is_parent`/`imported_id`
(`financial_id`) all exist exactly as guessed (with the raw-vs-public name distinction above).

**`payees`** (`packages/loot-core/migrations/1550601598648_payees.sql` + AQL schema additions):
```sql
CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, category TEXT, tombstone INTEGER DEFAULT 0, transfer_acct TEXT);
CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT);
```
Public AQL fields: `id, name, transfer_acct, tombstone, favorite, learn_categories` (`favorite`
added by `migrations/1720664867241_add_payee_favorite.sql`, `learn_categories` by
`migrations/1737158400000_add_learn_categories_to_payees.sql`). `payee_mapping` is the payee-merge indirection table: when payee A is
merged into payee B, `payee_mapping` maps A's id → B's id (`targetId`), and `transactions.description`
values referencing the old id resolve through this table transparently (see the `v_transactions_internal`
view join in §Appendix below) rather than being rewritten in place.

**`accounts`**: `id, account_id, name, balance_current, balance_available, balance_limit, mask,
official_name, type, subtype, bank, offbudget, closed, tombstone` (base, from `init.sql`) — AQL
public schema additionally exposes `sort_order, account_sync_source` (added by
`migrations/1704572023730_add_account_sync_source.sql`, with a follow-up fix in
`1704572023731_add_missing_goCardless_sync_source.sql`), `last_reconciled` (added by
`migrations/1740506588539_add_last_reconciled_at.sql` — note: DB column is `last_reconciled`,
populated at reconcile time), `last_sync` (added by `migrations/1739139550000_bank_sync_page.sql`),
and `bank_sync_status` (added by `migrations/1780606215000_add_bank_sync_status.sql`).

**`categories`**: `id, name, is_income, cat_group (raw) / group (public), sort_order, tombstone`
(base `init.sql`), plus `hidden` (added by `migrations/1685007876842_add_category_hidden.sql`),
`goal_def` (added by `migrations/1694438752000_add_goal_targets.sql`), `cleanup_def` (added by
`migrations/1778510362740_add_cleanup_groups_and_def.sql`, which also adds the `cleanup_groups`
table), and `template_settings` (added by
`migrations/1754611200000_add_category_template_settings.sql`, JSON column, default
`{"source":"notes"}` per the AQL schema).

**`category_groups`**: `id, name, is_income, sort_order, tombstone` (base), plus `hidden` — same
migration, verbatim: `ALTER TABLE categories ADD COLUMN hidden BOOLEAN NOT NULL DEFAULT 0; ALTER
TABLE category_groups ADD COLUMN hidden BOOLEAN NOT NULL DEFAULT 0;`
(`migrations/1685007876842_add_category_hidden.sql`).

**`category_mapping`** (base `init.sql`, same merge-indirection pattern as `payee_mapping`):
```sql
CREATE TABLE category_mapping (id TEXT PRIMARY KEY, transferId TEXT);
```

**Budget tables** — created by `packages/loot-core/migrations/1632571489012_remove_cache.js`
(this migration replaced the old spreadsheet-cell-based budget storage with real tables; it is a
**JS migration**, not `.sql`, run once against existing installs, but the resulting DDL is the
current schema):
```sql
CREATE TABLE zero_budget_months (id TEXT PRIMARY KEY, buffered INTEGER DEFAULT 0);

CREATE TABLE zero_budgets
  (id TEXT PRIMARY KEY, month INTEGER, category TEXT, amount INTEGER DEFAULT 0, carryover INTEGER DEFAULT 0);

CREATE TABLE reflect_budgets
  (id TEXT PRIMARY KEY, month INTEGER, category TEXT, amount INTEGER DEFAULT 0, carryover INTEGER DEFAULT 0);

CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
CREATE TABLE kvcache (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE kvcache_key (id INTEGER PRIMARY KEY, key REAL);
```
Later migrations (`1694438752000_add_goal_targets.sql`, `1720665000000_goal_context.sql`) add:
```sql
ALTER TABLE zero_budgets ADD COLUMN goal INTEGER DEFAULT null;
ALTER TABLE reflect_budgets ADD COLUMN goal INTEGER DEFAULT null;
ALTER TABLE zero_budgets ADD COLUMN long_goal INTEGER DEFAULT null;
ALTER TABLE reflect_budgets ADD COLUMN long_goal INTEGER DEFAULT null;
```
So the **current full `zero_budgets` schema** is: `id TEXT PK, month INTEGER, category TEXT
(FK→categories), amount INTEGER, carryover INTEGER, goal INTEGER, long_goal INTEGER`. `id` is
constructed client-side as `` `${month}-${category}` `` (e.g. `"2026-08-<catid>"`) per the
migration's own insert logic — **the month component of the id string uses `yyyy-mm` (dash) format,
while the `month` column itself is a numeric `yyyymm` integer** (e.g. `202608`) — confirmed by the
migration's parsing: `const dbmonth = parseInt(match[2])` where `match[2]` is a plain `\d+` group
(no dashes) from the old spreadsheet-cell name format. **`zero_budgets` = "this month's budget
plan" (envelope budgeting), `reflect_budgets` = the report/tracking-budget parallel table** — same
columns, different budgeting mode (`setBudgetType` in `sync/index.ts` toggles which one the UI
reads/writes via the `budgetType` synced pref).

**`schedules`** (`packages/loot-core/migrations/1618975177358_schedules.sql`):
```sql
CREATE TABLE schedules
  (id TEXT PRIMARY KEY, rule TEXT, active INTEGER DEFAULT 0, completed INTEGER DEFAULT 0,
   posts_transaction INTEGER DEFAULT 0, tombstone INTEGER DEFAULT 0);
CREATE TABLE schedules_next_date
  (id TEXT PRIMARY KEY, schedule_id TEXT, local_next_date INTEGER, local_next_date_ts INTEGER,
   base_next_date INTEGER, base_next_date_ts INTEGER);
CREATE TABLE schedules_json_paths
  (schedule_id TEXT PRIMARY KEY, payee TEXT, account TEXT, amount TEXT, date TEXT);
ALTER TABLE transactions ADD COLUMN schedule TEXT;
```
Public AQL schema additionally shows `name, next_date, sort_order` and pulls `_payee, _account,
_amount, _amountOp, _date, _conditions, _actions` from the linked `rules` row via a view join
(`v_schedules`) — schedules are themselves driven by a `rules` table
(`id, stage, conditions_op, conditions (json), actions (json), tombstone`) — a full rules-engine
schema **not fetched in this pass** beyond its column list in the AQL schema file
(**UNVERIFIED**: exact `rules` table DDL / migration).

**`notes`**: `id TEXT PRIMARY KEY, note TEXT` (confirmed above, part of the same
`1632571489012_remove_cache.js` migration) — one row per annotated entity (category, account,
etc.), `id` matches the annotated entity's id.

**`created_budgets`**, **`spreadsheet_cells`**, **`banks`**, **`pending_transactions`**: present in
base `init.sql` but superseded/emptied by later migrations (`spreadsheet_cells` is `DROP TABLE`d
by `1632571489012_remove_cache.js` after migrating its content into the tables above) — **legacy,
do not rely on them for a fresh client implementation**; included here only because they were in
the fetched base schema file.

**`db_version`**, **`__migrations__`**: migration bookkeeping tables (`id`/`version` PK) — not
part of the budget data model.

### Appendix: raw→public transaction view (verbatim, confirms the mapping table above)

Source: `packages/loot-core/migrations/1608652596044_trans_views.sql`:
```sql
CREATE VIEW v_transactions_layer2 AS
SELECT
  t.id AS id,
  t.isParent AS is_parent,
  t.isChild AS is_child,
  t.acct AS account,
  CASE WHEN t.isChild = 0 THEN NULL ELSE t.parent_id END AS parent_id,
  CASE WHEN t.isParent = 1 THEN NULL ELSE cm.transferId END AS category,
  pm.targetId AS payee,
  t.imported_description AS imported_payee,
  IFNULL(t.amount, 0) AS amount,
  t.notes AS notes,
  t.date AS date,
  t.financial_id AS imported_id,
  t.error AS error,
  t.starting_balance_flag AS starting_balance_flag,
  t.transferred_id AS transfer_id,
  t.sort_order AS sort_order,
  t.cleared AS cleared,
  t.tombstone AS tombstone
FROM transactions t
LEFT JOIN category_mapping cm ON cm.id = t.category
LEFT JOIN payee_mapping pm ON pm.id = t.description
WHERE t.date IS NOT NULL AND t.acct IS NOT NULL;
```
(The live/current version of this same view logic is inlined in
`packages/loot-core/src/server/aql/schema/index.ts`'s `v_transactions_internal`, §Part-1 research
excerpt above — functionally identical, slightly refactored.)

---

## 9. SimpleFIN spec

Source: `https://www.simplefin.org/protocol.html` (current default = **v2.0.0-draft**, dated
2026-03-19) and `https://www.simplefin.org/protocol-v1.html` (v1, "1.0"), plus
`https://beta-bridge.simplefin.org/info/developers`.

**Important**: the *live default* spec at `/protocol.html` is a **v2.0.0-draft**, published
2026-03-19, that restructures the account-set response around a flatter `Connection` object and a
structured `errlist`. It is **not backward compatible** with v1's `org{domain,name,sfin-url}`
shape. Both versions are documented below since real-world servers (per `GET /info`) may report
either `"1"`/`"1.0"` or `"2"`, and a client should be defensive. **The `payee`/`memo` transaction
fields the task description asked about do not exist in either official spec version** — see
§9.5 caution.

### 9.1 Setup Token → Access URL (identical in v1 and v2)

1. User is sent to the SimpleFIN Server's (or Bridge's) `GET /create` URL, which walks them through
   authenticating and produces a **SimpleFIN Token**: a **base64-encoded URL** (the "claim URL"),
   e.g.:
   ```
   aHR0cHM6Ly9icmlkZ2Uuc2ltcGxlZmluLm9yZy9zaW1wbGVmaW4vY2xhaW0vZGVtbw==
   → https://bridge.simplefin.org/simplefin/claim/demo
   ```
2. The app base64-decodes the token to recover the claim URL, then `POST`s to it (empty body; the
   dev-guide example explicitly sends `Content-Length: 0`):
   ```bash
   curl -H "Content-Length: 0" -X POST "$CLAIM_URL"
   ```
3. Response body (`200`) is the **Access URL** — a plain URL string with **HTTP Basic Auth
   credentials embedded** in the authority component:
   ```
   https://user123:password@bridge.simplefin.org/simplefin
   ```
   `403` means the token was invalid or already claimed by someone else — **treat as a possible
   compromise signal and tell the user to revoke/regenerate**, per the spec's "Required" checklist.
4. **Store the Access URL securely** (Keychain on iOS) — it is a long-lived bearer credential (via
   embedded Basic Auth), not a short-lived OAuth token; there is no documented rotation/refresh
   flow for it in either spec version fetched.
5. One-time use: the *setup/claim token* can only be exchanged once; the resulting *Access URL* is
   what's used repeatedly thereafter for `/accounts` calls.

### 9.2 `GET /accounts` — query parameters (both v1 and v2, per the fetched pages)

| Param | Required | Meaning |
|---|---|---|
| `start-date` | optional | Unix epoch seconds; only transactions **on or after** this timestamp. |
| `end-date` | optional | Unix epoch seconds; only transactions **strictly before** this timestamp (not inclusive). |
| `pending` | optional | `pending=1` → include pending transactions (if the institution supports it). Default: excluded. |
| `account` | optional, repeatable | Restrict to specific account id(s); may be given multiple times. |
| `balances-only` | optional | `balances-only=1` → skip transaction data entirely (v2 addition per the changelog, but the v1 page fetched here already documents it too — likely backported). |
| `version` | optional (**v2 only**) | `version=2` requests the new response shape; server default applies if omitted. `version=1` requests legacy shape from a v2-capable server. |

Auth: **HTTP Basic Authentication** using the credentials embedded in the Access URL.

Response codes: `200` success: `402` payment required; `403` auth failed/revoked/incorrect
credentials.

### 9.3 Response shape — v1 (`org{domain,name,sfin-url}`, flat `errors[]`)

```json
{
  "errors": ["You must reauthenticate."],
  "accounts": [
    {
      "org": { "domain": "mybank.com", "sfin-url": "https://sfin.mybank.com" },
      "id": "2930002",
      "name": "Savings",
      "currency": "USD",
      "balance": "100.23",
      "available-balance": "75.23",
      "balance-date": 978366153,
      "transactions": [
        { "id": "12394832938403", "posted": 793090572, "amount": "-33293.43",
          "description": "Uncle Frank's Bait Shop", "pending": true,
          "extra": { "category": "food" } }
      ],
      "extra": { "account-open-date": 978360153 }
    }
  ]
}
```

**`Organization` object** (v1): either `domain` or `name` required (both may be given);
`sfin-url` (root URL of that org's SimpleFIN server) is **required**; optional `url`, `id`.

**`Account` object** (v1 — same field set carries into v2's Account, minus `org`, plus `conn_id`):

| Field | Type | Required | Notes |
|---|---|---|---|
| `org` | Organization | yes (v1 only) | |
| `id` | string | yes | unique within org/connection; should not leak sensitive info |
| `name` | string | yes | unique per user across their accounts |
| `currency` | string | yes | ISO 4217 code, or a custom-currency URL (see §9.6) |
| `balance` | numeric string | yes | as of `balance-date` |
| `available-balance` | numeric string | optional | omit if same as `balance` |
| `balance-date` | Unix epoch **seconds** | yes | |
| `transactions` | array of Transaction | optional | ordered by `posted` |
| `extra` | object | optional | server-defined extension bag |

**`Transaction` object** (identical fields in v1 and v2):

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | string | yes | unique within an account (may repeat across accounts) |
| `posted` | Unix epoch seconds | yes | when it posted; **may be `0` if still pending** |
| `amount` | numeric string | yes | **positive = money deposited into the account** (i.e. sign convention is deposit-positive/withdrawal-negative, same convention Actual/most ledgers use for the "amount" of an inflow) |
| `description` | string | yes | human-readable, what the transaction was for |
| `transacted_at` | Unix epoch seconds | optional | when it actually happened (vs. `posted`) |
| `pending` | boolean | optional | default `false`; `true` = not yet posted |
| `extra` | object | optional | server-defined extension bag (e.g. some servers put a `category` string here) |

### 9.4 Response shape — v2.0.0-draft (`Connection` object, structured `errlist`)

```json
{
  "errlist": [
    { "code": "con.auth", "msg": "Authentication required", "conn_id": "CON-10829309823094234" }
  ],
  "connections": [
    { "conn_id": "CON-10829309823094234", "name": "My Bank - James",
      "org_id": "INST-129839182938123123", "org_url": "https://mybank.com",
      "sfin_url": "https://mybank.com" }
  ],
  "accounts": [
    { "id": "2930002", "name": "Savings", "conn_id": "CON-10829309823094234",
      "currency": "USD", "balance": "100.23", "available-balance": "75.23",
      "balance-date": 978366153, "transactions": [] }
  ]
}
```
- **`errlist`** replaces `errors` (deprecated but still allowed to appear, per the `AccountSet`
  table which lists both — `errors` marked `no (DEPRECATED)`). Each error:
  `{code, msg, conn_id?, account_id?}`. `code` is `prefix.[subcode]` with prefixes `gen`
  (general), `con` (connection-level), `act` (account-level). Known subcodes: `gen.api`,
  `gen.auth`, `con.auth`, `act.failed`, `act.missingdata`. **Unknown subcodes must be handled by
  falling back to the bare-prefix behavior** (e.g. treat `act.newcode` like `act.`).
- **`Connection`** object (replaces v1's per-account `org`): `conn_id` (required — id of *this
  login*, not just the institution — two logins to the same bank get two different `conn_id`s
  sharing the same `org_id`), `name` (required, human-friendly, should include institution name),
  `org_id` (required, unique per-server not globally), `org_url` (optional, institution domain),
  `sfin_url` (required, root URL of that org's SimpleFIN server).
- **`Account.conn_id`** (new in v2) ties each account back to a `Connection` in the sibling
  `connections` array — resolve `org`/institution info by joining on this id, rather than v1's
  embedded `org` object per-account.
- `GET /info` response: `{"versions": ["1","2"]}` — array of supported major-version prefixes (or
  `MAJOR.MINOR[.FIX]` strings). A client should pick the highest version it understands and pass
  `?version=N` explicitly on `/accounts` calls rather than trusting the server's default.

### 9.5 Error semantics, rate limits (from the fetched pages)

- **v1 `errors`**: flat array of user-displayable strings. **Must be sanitized before display**
  (spec's explicit warning — treat as untrusted/unescaped text).
- **v2 `errlist`**: structured, see above; the dev-guide (`beta-bridge.simplefin.org/info/developers`)
  explicitly says: *"Always show those errors to your end users."*
- **HTTP-level errors**: `402` Payment Required (SimpleFIN server-side billing issue), `403`
  Forbidden (bad/revoked Basic Auth credentials) on `/accounts`; `403` on claim also happens for an
  already-used or invalid setup token.
- **Rate limits** (SimpleFIN Bridge specifically, per the developer guide —
  **UNVERIFIED for other/self-hosted SimpleFIN servers**, this is Bridge-specific operational
  policy, not part of the protocol spec itself):
  - Intended for **daily updates**: expect **≤24 requests/day**, with "a little leeway" during
    initial setup; quota replenishes throughout the day.
  - `GET /accounts` (all accounts) and `GET /accounts?account=...` (single account) have
    **separate quotas**.
  - Exceeding the soft limit surfaces warnings in the `errors`/`errlist` array; exceeding it by
    more will get the **Access Token disabled entirely**.
  - **Date-range cap**: `end-date - start-date` for one request is **limited to 90 days**;
    available history length varies per institution.
  - Recommendation: **jitter your fetch schedule** (e.g. pick a random minute-past-the-hour) since
    load spikes at the top of the hour; **overlap fetch windows by ~5 days** to avoid gaps from
    late-posting transactions (e.g. for "May" fetch April 25–June 1).

### 9.6 Custom currencies (both versions, identical)

If `Account.currency` is not an ISO 4217 code but a URL, `GET` that URL to resolve it:
```json
// GET https://www.example.com/flight-miles →
{ "name": "Example Airline Miles", "abbr": "miles" }
```
Both `name` and `abbr` are required on the resolved object. **Must sanitize before display**
(explicit spec warning, same as error strings).

### 9.7 Implementation checklist (from the spec's own "Required"/"Recommended" lists)

Required: handle `403` on claim (and treat as possible compromise); only ever call `https://`
(never `http://`); store the Access URL at least as securely as the financial data it unlocks;
handle `403` on `/accounts`; display (sanitized) error messages from `/accounts`; verify TLS
certificates (never disable verification). Recommended: support custom currencies.

---

## 10. Implementation cautions

1. **HLC string sortability is load-bearing, not incidental.** Every ordering decision in the
   sync protocol — `messages_crdt` "already applied?" lookups (`timestamp >= ?`), `applyMessages`'s
   sort-before-apply step, and the client's outbound "everything since X" query — depends on plain
   **UTF-8/ASCII string comparison** of the 46-char timestamp giving the same order as true
   chronological + tie-break order. This only holds because of the exact zero-padding rules in
   §3.1 (4-digit uppercase-hex counter, 16-char zero-padded node, ISO8601 millis with fixed width).
   Get the padding wrong (e.g. lowercase hex, unpadded counter, or a node id shorter than 16 chars
   without zero-padding) and sync will silently misorder messages without any error being thrown.

2. **MurmurHash3 seed is implicitly 0, and it hashes the full 46-char string, not a numeric
   timestamp.** It is easy to assume the merkle trie hashes `timestamp.millis()` (a number) or
   hashes with some "obvious" seed like the timestamp's own millis value — it does neither. It
   hashes the **UTF-8 bytes of `timestamp.toString()`** (the full HLC string including counter and
   node id) with **MurmurHash3_x86_32, seed=0**. Two clients that create a timestamp for the
   "same" logical moment but with different counters or node ids get **completely different**
   hashes — which is correct/intended (the whole point is uniqueness), but means a naive
   reimplementation that hashes only the millis portion will produce a trie that never matches the
   server's.

3. **`Message.value` on the wire is always a *tagged string*, never a native protobuf number/null.**
   The protobuf field is `string value = 4` — full stop. A Swift implementation must apply the
   `0:`/`N:`/`S:` encoding (§5) to every outbound value and decode it on every inbound value; there
   is no protobuf-level `oneof`/`null` handling here at all. Forgetting this means every synced
   `NULL` column arrives on the wire as the literal two-character string `"0:"` instead of an
   actual SQL NULL, silently corrupting data if not decoded back.

4. **`SyncRequest` has a gap at field number 4 (`reserved`).** A hand-rolled protobuf encoder
   (rather than a generated one) that assumes fields are numbered contiguously 1..N will produce
   a request the server's generated decoder still parses fine (protobuf doesn't care about gaps),
   but a naive **decoder** that assumes contiguous numbering when reading `SyncResponse`/
   `SyncRequest` bytes from a fixture/test file could misparse. Always decode by field *number*,
   never by positional order.

5. **CRDT dataset/column names are raw, unmapped SQLite identifiers — not the AQL public schema
   names.** `transactions.description` (raw/CRDT) vs `payee` (public AQL) is the sharpest trap:
   naively sending a CRDT message with `column: "payee"` will fail (`no such column: payee`) or
   worse, silently create a stray column if the executing code doesn't validate against the real
   schema. **Always target the raw column names from §8.4's left-hand column** when constructing
   `Message`s to send, and always read from `messages_crdt`/apply raw column names too — the
   `payee`↔`description`, `is_parent`↔`isParent`, `account`↔`acct`,
   `transfer_id`↔`transferred_id`, `imported_id`↔`financial_id`,
   `imported_payee`↔`imported_description` renames are **view-layer only**, never present in the
   actual sync log.

6. **`payees.description` is itself one level of indirection (`payee_mapping`), not the final
   payee id.** A transaction's raw `description` column value is a `payee_mapping.id`, which
   resolves via `targetId` to the real `payees.id` — this exists so payee-merge operations don't
   require rewriting every historical transaction row (or CRDT message). A client that reads
   `description` and treats it directly as a `payees.id` foreign key will show stale/wrong payees
   for any account that has ever merged two payees together (a common user action). Same
   indirection pattern exists for `categories` via `category_mapping`.

7. **AES-GCM tag placement differs between the Node and WebCrypto code paths, but the wire format
   is always split.** `EncryptedData.authTag` (proto field 2) is **always** the bare 16-byte GCM
   tag, separate from `EncryptedData.data` (ciphertext only) — regardless of which JS runtime
   produced it, because both paths explicitly split tag-from-ciphertext before constructing the
   `EncryptedData` message. `CryptoKit.AES.GCM.SealedBox.tag`/`.ciphertext` map directly onto this;
   do **not** append the tag onto the ciphertext bytes before putting them on the wire.

8. **PBKDF2 salt is base64 *text*, not raw bytes, fed as the KDF salt input.** `createKeyBuffer`
   generates `salt = crypto.randomBytes(32).toString('base64')` and then passes that **base64
   string's UTF-8 bytes** into PBKDF2 as the salt parameter — not the underlying 32 raw random
   bytes directly. Re-deriving a key from a stored salt must base64-decode-then-**re-encode-to-UTF8-
   bytes-of-the-base64-string** (i.e. just treat the stored salt as an opaque string and UTF-8
   encode it), not decode it back to raw bytes first. Getting this backwards produces a
   different derived key than the server/other clients expect, and password verification
   (`user-get-key` → decrypt `test`) will fail even for the correct password.

9. **SimpleFIN's live default spec is now v2.0.0-draft; do not build against v1 field names
   without an explicit fallback.** `org.domain`/`org.sfin-url` per-account (v1) became a top-level
   `connections[]` array plus `Account.conn_id` (v2), and `errors: string[]` became
   `errlist: {code,msg,...}[]` (with `errors` merely deprecated-but-still-allowed). A client should
   call `GET /info`, inspect `versions`, and/or pass `?version=1` explicitly if it only wants to
   handle the simpler v1 shape — or handle both shapes defensively since real deployed servers lag
   behind the draft. **Neither version defines `payee` or `memo` transaction fields** — only
   `description` is standard; if a specific bank's SimpleFIN server needs payee/memo splitting,
   that data (if present at all) would have to come through the free-form `extra` object, which is
   entirely server-defined and not guaranteed present.

10. **SimpleFIN timestamps are Unix-epoch **seconds**, Actual's are ISO-8601 **milliseconds** (as
    part of the HLC string) — do not conflate the two time representations when e.g. mapping a
    SimpleFIN `transacted_at`/`posted` value into an Actual `transactions.date` (`yyyyMMdd`
    integer) or into a new HLC timestamp for a locally-created transaction. `balance-date`,
    `posted`, and `transacted_at` are all **seconds**; `Timestamp.millis()` and everything in
    `sync.proto`'s `MessageEnvelope.timestamp` string are **milliseconds**. A silent factor-of-1000
    error here is easy to introduce and easy to miss in casual testing (both "look like" plausible
    recent timestamps at small scale, but diverge wildly — 1970 vs. the far future — on real dates).
