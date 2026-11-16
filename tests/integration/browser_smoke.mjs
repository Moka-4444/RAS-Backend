import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { chromium } from 'playwright';

process.on('uncaughtExceptionMonitor', error => {
  console.log(`::error title=Browser QA::${error.message.split('\n')[0]}`);
});

const base = 'http://127.0.0.1:5173';
const env = Object.fromEntries((await readFile('.env', 'utf8')).trim().split(/\r?\n/).map(line => {
  const separator = line.indexOf('=');
  return [line.slice(0, separator), line.slice(separator + 1)];
}));
assert.equal(process.env.GITHUB_ACTIONS, 'true');
assert.match(env.SEED_CEO_EMAIL, /@example\.test$/);

async function api(path, body, token) {
  const response = await fetch(base + '/api/v1' + path, {
    method: body ? 'POST' : 'GET',
    headers: {'content-type': 'application/json', ...(token && {authorization: 'Bearer ' + token})},
    body: body && JSON.stringify(body),
  });
  assert.ok(response.ok, `${path} returned HTTP ${response.status}`);
  return response.json();
}

// These credentials were rotated by the preceding disposable backend smoke test.
const password = env.SEED_CEO_PASSWORD + 'A9';
const session = await api('/auth/login', {email: env.SEED_CEO_EMAIL, password});
const branch = await api('/branches', {
  name: 'Browser QA Branch', type: 'branch', address: 'Disposable browser test',
  official_start_time: '09:00', late_rate: 0,
}, session.access_token);
assert.ok(branch.id);

const browser = await chromium.launch({channel: 'chrome'});
try {
  const page = await browser.newPage({viewport: {width: 500, height: 900}});
  page.setDefaultTimeout(25000);
  await page.goto(base + '/#/login');
  const semantics = page.locator('flt-semantics-placeholder');
  await page.locator('flutter-view').waitFor({state: 'attached'});
  if (await semantics.count()) await semantics.first().dispatchEvent('click');

  const fields = page.getByRole('textbox');
  await fields.first().fill(env.SEED_CEO_EMAIL);
  await fields.nth(1).fill(password);
  const loginResponse = page.waitForResponse(response =>
    response.url() === base + '/api/v1/auth/login' && response.request().method() === 'POST');
  await page.getByRole('button', {name: 'تسجيل الدخول للجهاز'}).dispatchEvent('click');
  assert.equal((await loginResponse).status(), 200);
  await page.waitForURL('**/#/home');
  console.log('::notice title=Browser QA::Login button reached the live backend and opened home');

  const branchResponse = page.waitForResponse(response =>
    response.url() === base + '/api/v1/branches' && response.request().method() === 'GET');
  await page.getByRole('button', {name: 'الفروع', exact: true}).dispatchEvent('click');
  const loaded = await branchResponse;
  assert.equal(loaded.status(), 200);
  assert.match(await loaded.text(), /Browser QA Branch/);
  await page.getByRole('textbox').first().fill(branch.name);
  await page.getByRole('button', {name: /Browser QA Branch/}).dispatchEvent('click');
  const save = page.getByRole('button', {name: 'حفظ تعديلات الفرع'});
  await save.waitFor({state: 'attached'});
  console.log('::notice title=Browser QA::Branches button loaded PostgreSQL data and the fixture card opened');
  const updatedAddress = 'Updated from the Flutter browser';
  await page.getByRole('textbox', {name: 'العنوان', exact: true}).fill(updatedAddress);
  const update = page.waitForResponse(response =>
    response.url() === base + '/api/v1/branches/' + branch.id && response.request().method() === 'PATCH');
  await save.dispatchEvent('click');
  const changed = await update;
  assert.equal(changed.request().postDataJSON().address, updatedAddress, 'Flutter must send the new address');
  assert.equal(changed.status(), 200, `Branch update HTTP ${changed.status()}`);
  const saved = await api('/branches/' + branch.id, null, session.access_token);
  assert.equal(saved.address, updatedAddress, 'The live database must return the new address');
  console.log('::notice title=Browser QA::Save branch button persisted the updated address');
} finally {
  await browser.close();
}
