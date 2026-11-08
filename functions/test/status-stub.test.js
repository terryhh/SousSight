import test from 'node:test';
import assert from 'node:assert/strict';
import { rejectUnconfiguredStatus } from '../src/status-stub.js';

function fakeRes() {
  const res = { headers: {}, statusCode: 200, body: undefined };
  res.set = (k, v) => { res.headers[k] = v; return res; };
  res.status = (code) => { res.statusCode = code; return res; };
  res.json = (body) => { res.body = body; return res; };
  return res;
}

test('stub rejects every POST with 503 without reading the body or headers', () => {
  const signedLooking = { method: 'POST', headers: { authorization: 'Bearer a.b.c' },
    get body() { throw new Error('body must not be read'); },
    get rawBody() { throw new Error('raw body must not be read'); } };
  for (const req of [signedLooking, { method: 'POST', headers: {} }]) {
    const res = fakeRes();
    rejectUnconfiguredStatus(req, res);
    assert.equal(res.statusCode, 503);
    assert.deepEqual(res.body, { error: 'status-webhook-not-configured' });
    assert.equal(res.headers['Cache-Control'], 'no-store');
  }
});

test('stub answers non-POST with 405', () => {
  for (const method of ['GET', 'PUT', 'OPTIONS']) {
    const res = fakeRes();
    rejectUnconfiguredStatus({ method, headers: {} }, res);
    assert.equal(res.statusCode, 405);
    assert.equal(res.headers.Allow, 'POST');
  }
});
