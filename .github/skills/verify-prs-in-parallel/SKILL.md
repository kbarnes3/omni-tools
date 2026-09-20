---
name: verify-prs-in-parallel
description: Verify open pull requests for omni-tools by building and browser-testing each one in its own git worktree, in parallel. Use when asked to check, test, validate or smoke-test one or more PRs (typically Renovate dependency updates) to confirm the app still builds and the home page still loads.
---

# Verify PRs in parallel

Proves that each pull request still installs, builds, serves and renders. One git worktree
and one port per PR, all running at the same time, so five PRs take about as long as one.

A green CI run is not the same thing as this check. CI does not load the built site in a
browser, so a dependency bump that breaks rendering at runtime still passes CI.

## When to use

Asked to check, test or validate PRs - usually the Renovate dependency PRs on a fork such
as `kbarnes3/omni-tools`. Equally valid for a single PR; the parallelism is a bonus, not
the point.

## One-time setup

```powershell
npx playwright install chromium   # shared browser cache, not per-worktree
```

## Steps

### 1. List the PRs

```powershell
gh pr list --repo <owner>/<repo> --state open --json number,title,headRefName,author
```

Confirm which repo is meant. Renovate PRs live on the **fork**, not `iib0011/omni-tools`.
`git remote -v` shows the fork as `personal` in a typical clone.

### 2. Fetch the PR heads

Fetch by pull ref, so it works whether or not the branch is local:

```powershell
git fetch personal 'refs/pull/221/head:pr-221' 'refs/pull/220/head:pr-220' --force
```

### 3. Create one worktree per PR

Keep them outside the repo so they never land in `git status`:

```powershell
foreach ($n in 221, 220) { git worktree add "G:\Code\omni-wt\pr-$n" "pr-$n" }
```

### 4. Run them all, in parallel

One background shell per PR, each with its **own port** - `--strictPort` means a clash
fails rather than silently sliding to the next port. Numbering the port after the PR keeps
the mapping obvious:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .github\skills\verify-prs-in-parallel\scripts\Invoke-PrCheck.ps1 `
  -Dir G:\Code\omni-wt\pr-221 -Port 4221 -Label 221
```

`-ExecutionPolicy Bypass` is required; the default policy refuses to run the script file.

`Invoke-PrCheck.ps1` does `npm install` -> `npm run build` -> `npm run serve` -> browser
check, stops the preview server, and writes `verify.log` (full output) plus `result.json`
(structured) into the worktree. It stops at the first failing stage. Pass `-SkipInstall` to
reuse `node_modules` on a re-run.

The browser check is `scripts\Test-HomePage.mjs`. It fails on a bad response, a page error,
a console error, a failed sub-resource, or missing text. Because the app is a
client-rendered SPA it waits for the tool search box, which only exists once React has
mounted and i18n has resolved - a 200 on `index.html` proves nothing on its own. Pass
`-RequiredText` to assert different copy, e.g. when testing a page other than the home page.

### 5. Collect the results

```powershell
Get-ChildItem G:\Code\omni-wt\pr-*\result.json |
    ForEach-Object { Get-Content $_ -Raw | ConvertFrom-Json } |
    Select-Object label, result, failedStage, install, build, check | Format-Table -AutoSize
```

Report a table of PR / change / result. For any failure, quote the actual error from
`errors` or `verify.log` rather than summarising it, and say which stage failed - an
install failure and a rendering failure mean very different things.

### 6. Clean up

In this order, or the removal fails:

```powershell
# 1. Kill any preview server still holding node_modules.
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
    Where-Object { $_.CommandLine -like '*omni-wt*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 2. Drop the worktrees and the branches they were on.
foreach ($n in 221, 220) {
    git worktree remove "G:\Code\omni-wt\pr-$n" --force
    git branch -D "pr-$n"
}
cmd /c "rmdir /s /q G:\Code\omni-wt"
git worktree prune
```

Verify with `git worktree list` and `git status --short`, and confirm the original branch
is unchanged.

## Interpreting a failure

Distinguish a real regression from an environment problem before calling a PR broken.

**`npm error code EALLOWREMOTE` / `Refusing to fetch "xlsx@https://cdn.sheetjs.com/..."`**
is environmental, not a bad PR. npm 12 defaults `allow-remote` to `none`, and `xlsx` is a
URL-pinned transitive dependency of the `locize-cli` devDependency. The repo's committed
`.npmrc` sets `allow-remote=all` to fix this; if you see the error, the branch predates
that commit. Add `--allow-remote=all` to the install to get an answer for that branch, and
report the PR on its own merits. `allow-remote=root` does not help, because `xlsx` is not
declared in our own `package.json`.

Note this failure is resolution-shaped, not install-shaped: a targeted dependency bump
reuses the already-resolved lockfile entry and succeeds, while anything that regenerates
the lockfile from scratch (Renovate's `lockFileMaintenance`) fails.

Otherwise: a failure that reproduces on the base branch too is pre-existing and not the
PR's fault. Re-run the same script against a worktree of the base branch before reporting.

## Gotchas

- **Killing `npm.cmd` does not kill `node`.** `npm.cmd` is a shim. Stopping it orphans the
  real `vite preview` process, which keeps a lock on `node_modules`; `git worktree remove`
  then fails with `Invalid argument` and `rmdir` reports `Access is denied` on
  `esbuild.exe`. `Invoke-PrCheck.ps1` walks the process tree to avoid this, but a script
  that was interrupted leaves orphans - always run the cleanup in step 6's order.
- **`$LASTEXITCODE` belongs to the last native command.** Piping `npm` through
  `Select-String` overwrites it and quietly reports success. Capture with
  `| Out-String` and read `$LASTEXITCODE` on the very next line.
- **Worktrees do not share `node_modules`.** Each one needs its own `npm install`, which is
  the slowest stage and exactly why this runs in parallel.
- **`npm install` warns about blocked install scripts** (`@swc/core`, `esbuild`, `core-js`,
  `protobufjs`, `tesseract.js`) on npm 12. The build succeeds anyway; not a failure.
- **Large-chunk warnings from Vite are normal** and are not build failures.
- **Do not commit from a worktree.** These are throwaway checkouts.
