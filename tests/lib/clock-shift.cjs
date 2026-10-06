'use strict';

const VARIABLE = 'ZENSU_TEST_CLOCK_SHIFT_DAYS';
const MARK = Symbol.for('zensu.testClockShift');
const DAY_MS = 24 * 60 * 60 * 1000;

function shiftMsFrom(raw) {
  if (raw === undefined || raw === '') return 0;
  if (!/^-?\d+(?:\.\d+)?$/.test(raw)) {
    throw new Error(`${VARIABLE} must be a decimal number of days, got ${JSON.stringify(raw)}`);
  }
  return Math.round(Number(raw) * DAY_MS);
}

function install(shiftMs) {
  if (shiftMs === 0 || Object.prototype.hasOwnProperty.call(globalThis, MARK)) return;
  const RealDate = globalThis.Date;
  const realNow = RealDate.now;
  const now = function now() {
    return realNow.call(RealDate) + shiftMs;
  };
  const ShiftedDate = new Proxy(RealDate, {
    apply() {
      return new RealDate(now()).toString();
    },
    construct(target, args, newTarget) {
      return Reflect.construct(target, args.length === 0 ? [now()] : args, newTarget === ShiftedDate ? target : newTarget);
    },
    get(target, property, receiver) {
      return property === 'now' ? now : Reflect.get(target, property, receiver);
    },
  });
  Object.defineProperty(globalThis, MARK, { value: shiftMs });
  RealDate.prototype.constructor = ShiftedDate;
  globalThis.Date = ShiftedDate;
}

install(shiftMsFrom(process.env[VARIABLE]));
