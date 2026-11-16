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

const focused = process.env.BRANCH_QA_FOCUSED === 'true';
const password = env.SEED_CEO_PASSWORD + 'A9';
let session;
if (focused) {
  const initial = await api('/auth/login', {email: env.SEED_CEO_EMAIL, password: env.SEED_CEO_PASSWORD});
  session = await api('/auth/change-password', {
    current_password: env.SEED_CEO_PASSWORD, new_password: password,
  }, initial.access_token);
} else {
  session = await api('/auth/login', {email: env.SEED_CEO_EMAIL, password});
}
const branch = await api('/branches', {
  name: 'Browser QA Branch', type: 'branch', address: 'Disposable browser test',
  official_start_time: '09:00', late_rate: 0,
}, session.access_token);
assert.ok(branch.id);

const browser = await chromium.launch({channel: 'chrome'});
try {
  const page = await browser.newPage({viewport: {width: 500, height: 1400}});
  page.setDefaultTimeout(25000);
  async function enableSemantics() {
    await page.locator('flutter-view').waitFor({state: 'attached'});
    const placeholder = page.locator('flt-semantics-placeholder');
    if (await placeholder.count()) await placeholder.first().dispatchEvent('click');
  }
  if (focused) {
    const user = session.user;
    await page.addInitScript(({origin, values}) => {
      if (location.origin !== origin) return;
      for (const [key, value] of Object.entries(values)) {
        localStorage.setItem('flutter.session.' + key, JSON.stringify(value));
      }
    }, {
      origin: base,
      values: {
        id: user.id, name: user.name, email: user.email, role: user.role,
        token: session.access_token, refreshToken: session.refresh_token,
        branchId: '', branchName: '', mustChangePassword: 'false',
      },
    });
    const branchPage = page.waitForResponse(response =>
      response.url() === base + '/api/v1/branches' && response.request().method() === 'GET');
    await page.goto(base + '/#/branches');
    assert.equal((await branchPage).status(), 200);
    await enableSemantics();
  } else {
    await page.goto(base + '/#/login');
    await enableSemantics();
    const fields = page.getByRole('textbox');
    await fields.first().fill(env.SEED_CEO_EMAIL);
    await fields.nth(1).fill(password);
    const loginResponse = page.waitForResponse(response =>
      response.url() === base + '/api/v1/auth/login' && response.request().method() === 'POST');
    await page.getByRole('button', {name: 'تسجيل الدخول للجهاز'}).dispatchEvent('click');
    assert.equal((await loginResponse).status(), 200);
    await page.waitForURL('**/#/home');
    await enableSemantics();
    const branchResponse = page.waitForResponse(response =>
      response.url() === base + '/api/v1/branches' && response.request().method() === 'GET');
    await page.getByRole('button', {name: 'الفروع', exact: true}).dispatchEvent('click');
    const loaded = await branchResponse;
    assert.equal(loaded.status(), 200);
    assert.match(await loaded.text(), /Browser QA Branch/);
  }
  await page.getByRole('textbox').first().fill(branch.name);
  await page.getByRole('button', {name: /Browser QA Branch/}).dispatchEvent('click');
  const save = page.getByRole('button', {name: 'حفظ تعديلات الفرع'});
  await save.waitFor({state: 'attached'});
  console.log('::notice title=Browser QA::Branches button loaded PostgreSQL data and the fixture card opened');
  const updatedAddress = 'Updated from the Flutter browser';
  async function fieldWithValue(value) {
    const edits = page.getByRole('textbox');
    await edits.first().waitFor({state: 'attached'});
    const values = await edits.evaluateAll(fields => fields.map(field => field.value));
    const index = values.indexOf(value);
    assert.ok(index >= 0, `Expected branch address in the rendered form (${values.length} text fields)`);
    return edits.nth(index);
  }
  const address = await fieldWithValue(branch.address);
  await address.fill(updatedAddress);
  const reloaded = focused ? page.waitForResponse(response =>
    response.url() === base + '/api/v1/branches' && response.request().method() === 'GET') : null;
  const update = page.waitForResponse(response =>
    response.url() === base + '/api/v1/branches/' + branch.id && response.request().method() === 'PATCH');
  await save.dispatchEvent('click');
  const changed = await update;
  assert.equal(changed.request().postDataJSON().address, updatedAddress, 'Flutter must send the new address');
  assert.equal(changed.status(), 200, `Branch update HTTP ${changed.status()}`);
  const saved = await api('/branches/' + branch.id, null, session.access_token);
  assert.equal(saved.address, updatedAddress, 'The live database must return the new address');
  console.log('::notice title=Browser QA::Save branch button persisted the updated address');
  if (reloaded) {
    assert.equal((await reloaded).status(), 200);
    await page.getByRole('button', {name: /Browser QA Branch/}).dispatchEvent('click');
    await save.waitFor({state: 'attached'});
    await fieldWithValue(updatedAddress);
    console.log('::notice title=Browser QA::Reopening the branch displayed the saved address');
  }
} finally {
  await browser.close();
}
