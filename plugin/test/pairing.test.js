// What's typed when connecting with a code, and the name a device offers. Run: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import { codeOf, isCode, linkOf, deviceNameOf, defaultDeviceName } from '../src/pairing.js';

test('codes', () => {
  assert.equal(codeOf(' 482 913 '), '482913');
  assert.ok(isCode('012345'));
  for (const bad of ['', '12345', '1234567', '12a456']) assert.ok(!isCode(bad), bad);
});

test('connection links', () => {
  assert.deepEqual(linkOf(' https://notes.example.com?code=482913 '), { endpoint: 'https://notes.example.com', code: '482913' });
  assert.deepEqual(linkOf('http://host:9292/sync/?code=482%20913'), { endpoint: 'http://host:9292/sync', code: '482913' });
  for (const bad of ['', '482913', 'https://notes.example.com', 'https://h?code=12', 'obsidian://x?code=482913']) {
    assert.equal(linkOf(bad), null, bad);
  }
});

test('deviceNameOf gives what the server takes', () => {
  assert.equal(deviceNameOf('Pixel 8'), 'pixel-8');
  assert.equal(deviceNameOf("Tim's iPad"), 'tim-s-ipad');
  assert.equal(deviceNameOf('  --a__b--  '), 'a-b');
  assert.equal(deviceNameOf('Планшет'), '');
  assert.equal(deviceNameOf('a'.repeat(100)), 'a'.repeat(64));
  assert.equal(deviceNameOf(`${'a'.repeat(63)} b`), 'a'.repeat(63));
});

test('defaultDeviceName', () => {
  assert.equal(defaultDeviceName({ deviceName: 'Tims-MacBook-Pro.local', isMacOS: true }), 'tims-macbook-pro');
  assert.equal(defaultDeviceName({ model: 'Pixel 8', isAndroidApp: true }), 'pixel-8');
  assert.equal(defaultDeviceName({ deviceName: '', model: '', isAndroidApp: true }), 'android');
  assert.equal(defaultDeviceName({ isIosApp: true, isTablet: true }), 'ipad');
  assert.equal(defaultDeviceName({ isIosApp: true }), 'iphone');
  assert.equal(defaultDeviceName({ deviceName: 'Планшет', isWin: true }), 'windows');
  assert.equal(defaultDeviceName({}), 'device');
});
