import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const swift = fs.readFileSync(new URL('../../Apps/iOS/Rise/PopupOpenObserver.swift', import.meta.url), 'utf8');
const source = swift.match(/static let source = #"""([\s\S]*?)"""#/)[1];
function fixture(open, handler = body => messages.push(body)) {
    const messages = [];
    const window = { open, webkit: { messageHandlers: { risePopupObserver: { postMessage: body => handler === null ? (() => { throw Error('bridge unavailable'); })() : messages.push(body) } } } };
    const context = vm.createContext({window,document:{baseURI:'https://example.com/base/'},navigator:{userActivation:{isActive:true}},URL});
    vm.runInContext(source, context);
    return {window,messages};
}
let calls = 0, receiver, received;
const handle = {};
const first = fixture(function(...args) { calls++; receiver=this; received=args; return handle; });
assert.equal(first.window.open('/wanted','_blank','noopener'), handle);
assert.equal(calls,1); assert.equal(receiver,first.window); assert.deepEqual(received,['/wanted','_blank','noopener']);
assert.equal(first.messages[0].phase,'ready');
assert.equal(first.messages[1].url,'https://example.com/wanted');
assert.equal(first.messages[2].handle,'window');
let coercions = 0;
const argument = {toString(){coercions++; return '/wanted';}};
const object = fixture(url => { String(url); return handle; });
assert.equal(object.window.open(argument),handle); assert.equal(coercions,1,'Observer must not coerce URL objects a second time');
const originalError = {get name(){throw Error('hostile name getter');}};
const throws = fixture(() => {throw originalError;});
assert.throws(()=>throws.window.open('/x'),error=>error===originalError,'Instrumentation must preserve the original exception');
const unavailable = fixture(()=>handle,null);
assert.equal(unavailable.window.open('/x'),handle,'Logging failure cannot break opening');
const nullResult = fixture(()=>null);
assert.equal(nullResult.window.open('/x'),null); assert.equal(nullResult.messages.at(-1).handle,'null');
assert.equal(nullResult.messages.at(-1).phase,'returned','A null handle is an observation, not an asserted block');
console.log('Passed: observer preserves receiver, arguments, coercion count, results, original exceptions, and unavailable-bridge behavior.');
