/** Verifies the operated Forgejo surface publishes one canonical Slop identity. */

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const publicSurfacePaths = [
  "compose.yml",
  "custom/conf/app.example.ini",
  "custom/public/assets/css/theme-eliza.css",
  "custom/public/assets/css/theme-eliza-light.css",
  "custom/templates/custom/extra_links_footer.tmpl",
  "custom/templates/home.tmpl",
  "custom/templates/user/auth/signin_inner.tmpl",
  "custom/templates/user/dashboard/dashboard.tmpl",
  "templates/forgejo/app.staging.example.ini",
];

async function source(path) {
  return readFile(join(repositoryRoot, path), "utf8");
}

describe("public Slop Git brand contract", () => {
  it("removes legacy public names and destinations from operated surfaces", async () => {
    const files = await Promise.all(
      publicSurfacePaths.map(async (path) => [path, await source(path)]),
    );

    for (const [path, contents] of files) {
      assert.doesNotMatch(
        contents,
        /Eliza Army|https:\/\/(?:eliza\.army|git\.army|git\.eliza\.army)/u,
        path,
      );
      assert.doesNotMatch(
        contents,
        /content:\s*["']Eliza(?: Hub| Git)?["']/u,
        path,
      );
    }
  });

  it("uses Slop Git and the canonical one-prompt onboarding", async () => {
    const compose = await source("compose.yml");
    const home = await source("custom/templates/home.tmpl");
    const logo = await source("custom/public/assets/img/logo.svg");
    const signIn = await source(
      "custom/templates/user/auth/signin_inner.tmpl",
    );

    assert.match(compose, /FORGEJO____APP_NAME: "Slop Git"/u);
    assert.match(home, /<h1>Slop Git<\/h1>/u);
    assert.match(logo, /aria-label="Slop"/u);
    assert.match(signIn, /<h1>Welcome to Slop Git<\/h1>/u);
    assert.match(home, /Read https:\/\/slop\.cash\/SKILL\.md/u);
    assert.match(home, /elizaOS\/asi/u);
    assert.match(home, /github\.com\/elizaOS\/slopdotcash\/issues\/new/u);
    assert.doesNotMatch(home, /\$10,000 monthly USDC pool/u);
    assert.doesNotMatch(home, /slop\.cash\/mission\.md|eliza\.app\/profile/u);
    assert.doesNotMatch(home, /ready to claim|data\/leaderboard\.json/u);
    assert.match(home, /user\/login[^>]*>Sign in with Eliza Cloud/u);
    assert.doesNotMatch(home, /user\/sign_up|Registration is open/u);
  });

  it("documents the public and reusable product layers separately", async () => {
    const naming = await source("docs/product-naming.md");

    assert.match(naming, /Slop Git.*git\.slop\.cash/su);
    assert.match(naming, /Eliza Hub.*open-source distribution/su);
    assert.match(naming, /gitarmy-\*.*stable protocol identifiers/su);
  });
});
