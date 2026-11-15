'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { OrderKey } = require('../src/shared');

test('between matches the fractional-indexing values', () => {
  const cases = [
    [null, null, 'a0'], ['a0', null, 'a1'], [null, 'a0', 'Zz'], ['a0', 'a1', 'a0V'],
    ['a0V', 'a1', 'a0l'], ['Zz', 'a0', 'ZzV'], ['az', null, 'b00'], ['a0', 'a0V', 'a0G'],
  ];
  for (const [a, b, want] of cases) assert.equal(OrderKey.between(a, b), want, `between(${a}, ${b})`);
});

test('5000 appends stay sorted and short', () => {
  let last = null;
  const keys = [];
  for (let i = 0; i < 5000; i++) {
    last = OrderKey.between(last, null);
    keys.push(last);
  }
  for (let i = 1; i < keys.length; i++) assert.ok(keys[i - 1] < keys[i], `${keys[i - 1]} < ${keys[i]}`);
  assert.ok(keys.every((k) => k.length <= 4));
});

test('inserting between neighbours keeps order', () => {
  let a = 'a0';
  const b = 'a1';
  for (let i = 0; i < 200; i++) {
    const m = OrderKey.between(a, b);
    assert.ok(a < m && m < b);
    a = m;
  }
  const ks = OrderKey.keysBetween('a0', 'a1', 10);
  assert.equal(ks.length, 10);
  for (let i = 1; i < ks.length; i++) assert.ok(ks[i - 1] < ks[i]);
});

test('bad or out-of-order keys give null', () => {
  assert.equal(OrderKey.between('a1', 'a0'), null);
  assert.equal(OrderKey.between('a0', 'a0'), null);
  assert.equal(OrderKey.between('a10', null), null);
  assert.equal(OrderKey.between('!!', null), null);
  assert.equal(OrderKey.isValid('a0'), true);
  assert.equal(OrderKey.isValid('a'), false);
});
