// Operational transformation for plain text (the ot.js algorithm).
// An operation walks the whole document: a positive number keeps that many characters, a negative
// number deletes that many, and a string inserts it. Lengths are UTF-16 code units, same as iOS.

const isRetain = (o) => typeof o === "number" && o > 0;
const isDelete = (o) => typeof o === "number" && o < 0;
const isInsert = (o) => typeof o === "string";

function push(ops, o) {
  if (o === 0 || o === "") return;
  const last = ops[ops.length - 1];
  if (isInsert(o) && isInsert(last)) ops[ops.length - 1] = last + o;
  else if (isRetain(o) && isRetain(last)) ops[ops.length - 1] = last + o;
  else if (isDelete(o) && isDelete(last)) ops[ops.length - 1] = last + o;
  else ops.push(o);
}

function valid(op) {
  return Array.isArray(op) && op.length < 100000 && op.every((o) => (typeof o === "string") || (Number.isInteger(o) && o !== 0));
}

const baseLength = (op) => op.reduce((n, o) => n + (typeof o === "number" ? Math.abs(o) : 0), 0);

function apply(text, op) {
  if (baseLength(op) !== text.length) throw new Error("Operation doesn't fit the document.");
  let i = 0;
  const out = [];
  for (const o of op) {
    if (isInsert(o)) out.push(o);
    else if (o > 0) { out.push(text.slice(i, i + o)); i += o; }
    else i -= o;
  }
  return out.join("");
}

// transform(a, b) → [a', b'] with apply(apply(s, a), b') === apply(apply(s, b), a').
// When both insert at the same spot, a's text goes first.
function transform(a, b) {
  const pa = [], pb = [];
  let i = 0, j = 0, x = a[i++], y = b[j++];
  for (;;) {
    if (x === undefined && y === undefined) break;
    if (isInsert(x)) { push(pa, x); push(pb, x.length); x = a[i++]; continue; }
    if (isInsert(y)) { push(pa, y.length); push(pb, y); y = b[j++]; continue; }
    if (x === undefined || y === undefined) throw new Error("Operations don't match.");
    if (x > 0 && y > 0) {
      const m = Math.min(x, y); push(pa, m); push(pb, m);
      if (x > y) { x -= y; y = b[j++]; } else if (x === y) { x = a[i++]; y = b[j++]; } else { y -= x; x = a[i++]; }
    } else if (x < 0 && y < 0) {
      if (x < y) { x -= y; y = b[j++]; } else if (x === y) { x = a[i++]; y = b[j++]; } else { y -= x; x = a[i++]; }
    } else if (x < 0 && y > 0) {
      const m = Math.min(-x, y); push(pa, -m);
      if (-x > y) { x += y; y = b[j++]; } else if (-x === y) { x = a[i++]; y = b[j++]; } else { y += x; x = a[i++]; }
    } else {
      const m = Math.min(x, -y); push(pb, -m);
      if (x > -y) { x += y; y = b[j++]; } else if (x === -y) { x = a[i++]; y = b[j++]; } else { y += x; x = a[i++]; }
    }
  }
  return [pa, pb];
}

// compose(a, b): one operation that does a and then b.
function compose(a, b) {
  const out = [];
  let i = 0, j = 0, x = a[i++], y = b[j++];
  for (;;) {
    if (x === undefined && y === undefined) break;
    if (isDelete(x)) { push(out, x); x = a[i++]; continue; }
    if (isInsert(y)) { push(out, y); y = b[j++]; continue; }
    if (x === undefined || y === undefined) throw new Error("Operations don't match.");
    if (isRetain(x) && isRetain(y)) {
      const m = Math.min(x, y); push(out, m);
      if (x > y) { x -= y; y = b[j++]; } else if (x === y) { x = a[i++]; y = b[j++]; } else { y -= x; x = a[i++]; }
    } else if (isInsert(x) && isDelete(y)) {
      if (x.length > -y) { x = x.slice(-y); y = b[j++]; } else if (x.length === -y) { x = a[i++]; y = b[j++]; } else { y += x.length; x = a[i++]; }
    } else if (isInsert(x) && isRetain(y)) {
      if (x.length > y) { push(out, x.slice(0, y)); x = x.slice(y); y = b[j++]; } else if (x.length === y) { push(out, x); x = a[i++]; y = b[j++]; } else { push(out, x); y -= x.length; x = a[i++]; }
    } else { // retain x, delete y
      if (x > -y) { push(out, y); x += y; y = b[j++]; } else if (x === -y) { push(out, y); x = a[i++]; y = b[j++]; } else { push(out, -x); y += x; x = a[i++]; }
    }
  }
  return out;
}

module.exports = { apply, transform, compose, valid, baseLength };
