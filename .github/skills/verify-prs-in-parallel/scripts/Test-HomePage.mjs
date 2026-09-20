// Loads a served omni-tools build in headless Chromium and fails on anything that would
// make the page look broken to a user: a bad response, a page or console error, a failed
// sub-resource, or missing expected content.
//
// Usage: node Test-HomePage.mjs <url> [requiredText...]
//
// Must run from inside the worktree being tested so that `@playwright/test` resolves
// against that worktree's node_modules. Invoke-PrCheck.ps1 copies it in before running.

import { chromium } from '@playwright/test';

const [url = 'http://localhost:4173/', ...extraText] = process.argv.slice(2);

// Rendered by the Hero component on the home page, via public/locales/en/translation.json.
const requiredText = extraText.length
  ? extraText
  : ['Get Things Done Quickly with', 'OmniTools'];

const problems = [];
const browser = await chromium.launch();
const page = await browser.newPage();

page.on('console', (m) => m.type() === 'error' && problems.push(`ConsoleError: ${m.text()}`));
page.on('pageerror', (e) => problems.push(`PageError: ${e}`));
page.on('requestfailed', (r) =>
  problems.push(`FailedRequest: ${r.url()} :: ${r.failure()?.errorText}`)
);
page.on('response', (r) => {
  if (r.status() >= 400) problems.push(`BadResponse: ${r.url()} :: HTTP ${r.status()}`);
});

try {
  const response = await page.goto(url, { waitUntil: 'networkidle', timeout: 60000 });
  if (!response || !response.ok()) {
    problems.push(`Navigation returned ${response ? response.status() : 'no response'}`);
  }

  // The app is a client-rendered SPA, so index.html returning 200 proves nothing. Wait for
  // markup that only exists once React has mounted and i18n has resolved.
  await page.waitForSelector('input[placeholder="Search all tools"]', { timeout: 30000 });

  const body = await page.locator('body').innerText();
  for (const text of requiredText) {
    if (!body.includes(text)) problems.push(`Missing expected text: ${JSON.stringify(text)}`);
  }
  if (body.trim().length < 100) {
    problems.push(`Body text suspiciously short (${body.trim().length} chars)`);
  }
} catch (e) {
  problems.push(`Exception: ${e.message}`);
} finally {
  await browser.close();
}

console.log(problems.length ? 'HOMEPAGE_CHECK: FAIL' : 'HOMEPAGE_CHECK: PASS');
for (const p of problems) console.log(`  - ${p}`);
process.exit(problems.length ? 1 : 0);
