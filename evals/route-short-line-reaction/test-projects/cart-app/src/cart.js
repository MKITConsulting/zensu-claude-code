'use strict';

const SHIPPING_FEE = 5;

function cartTotal(items) {
  const subtotal = items.reduce((sum, item) => sum + item.price * item.qty, 0);
  return items.length > 0 ? subtotal + SHIPPING_FEE : 0;
}

module.exports = { cartTotal, SHIPPING_FEE };
