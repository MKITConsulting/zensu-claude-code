'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { cartTotal } = require('./cart.js');

test('an empty cart costs nothing', () => {
  assert.equal(cartTotal([]), 0);
});

test('a non-empty cart adds the shipping fee to the item subtotal', () => {
  assert.equal(cartTotal([{ price: 10, qty: 2 }, { price: 3, qty: 1 }]), 28);
});
