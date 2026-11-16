# Local-script ebuild: app-misc/fdc (Food Data Central API)

A worked example of the **local-script ebuild pattern** — a Python CLI tool
with no upstream tarball, where the script and config files live in the
ebuild's `files/` directory.

## The ebuild

```bash
# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="CLI wrapper for the USDA Food Data Central (FDC) API"
HOMEPAGE="https://fdc.nal.usda.gov/"
S="${WORKDIR}"

LICENSE="CC0-1.0"
SLOT="0"
KEYWORDS="~amd64"
RESTRICT="mirror"

src_unpack() {
    mkdir -p "${S}"
}

src_compile() {
    :
}

src_install() {
    newbin "${FILESDIR}/fdc.py" fdc

    insinto /etc/fdc
    newins "${FILESDIR}/api_key" api_key
}

pkg_postinst() {
    elog "Food Data Central CLI installed."
    elog ""
    elog "Usage:"
    elog "  fdc search <query>"
    elog "  fdc get <fdc-id>"
    elog "  fdc get-multi <fdc-id> [<fdc-id> ...]"
    elog "  fdc list"
    elog ""
    elog "The default API key is DEMO_KEY (rate-limited)."
    elog "To use your own key, edit /etc/fdc/api_key"
    elog ""
    elog "Get a free API key at: https://fdc.nal.usda.gov/api-key-signup.html"
}
```

## Directory structure

```
/var/db/repos/localrepo/app-misc/fdc/
├── fdc-1.0.0.ebuild
├── metadata.xml
├── Manifest
└── files/
    ├── fdc.py          # the CLI script (installed as /usr/bin/fdc)
    └── api_key         # config file (installed as /etc/fdc/api_key)
```

## Key decisions

- **No `SRC_URI`** — omitted entirely (not set to `""`), which avoids
  `EmptyGlobalAssignment` from pkgcheck.
- **Variable order** without `SRC_URI`: `DESCRIPTION → HOMEPAGE → S →
  LICENSE → SLOT → KEYWORDS → RESTRICT`. `S` goes right after `HOMEPAGE`.
- **`RESTRICT="mirror"`** — nothing to mirror upstream.
- **`newbin` renames** the script from `fdc.py` to `fdc` at install time,
  so users type `fdc search` not `fdc.py search`.
- **`newins`** installs the config file to `/etc/fdc/api_key` with the
  default `DEMO_KEY` value.
- **No `RDEPEND`** — the script uses only Python stdlib (`urllib.request`,
  `json`, `argparse`). If it needed external packages, they'd go in
  `RDEPEND` or be documented in `pkg_postinst`.

## The CLI script

The wrapper (`files/fdc.py`) is a single-file Python CLI using argparse.
It reads the API key from `/etc/fdc/api_key` (first line, stripped) and
falls back to `DEMO_KEY`. All FDC endpoints are supported:

- `fdc search <query>` — keyword search
- `fdc get <fdc-id>` — single food item
- `fdc get-multi <fdc-id> ...` — up to 20 items
- `fdc list` — paged abridged listing
- `fdc nutrients <fdc-id>` — **added in 1.1.0**; prints a readable table of
  nutrients **per 100 g** (the FDC API already reports amounts per 100g —
  this command just makes them human-readable). Supports `--nutrients
  N,N,...` to filter by nutrient number and `--sort number|name|amount`.
  Maps common nutrient numbers (203=Protein, 204=Fat, 205=Carbs,
  208=Energy kcal, 269=Sugars, 291=Fiber, 301=Calcium, 303=Iron,
  307=Sodium, 306=Potassium, 401=Vit C, 318=Vit A IU, 601=Cholesterol,
  606=Saturated fat) to short labels.
- `fdc nutrients <fdc-id> --codes` — **added in 1.1.1**; shows the raw
  nutrient code (number) + full official name instead of the short labels.
  Handy when you need the exact code to pass to `--nutrients`.
- `fdc codes [query]` — **added in 1.1.2**; lists the full USDA nutrient
  code table (code, name, unit) with optional search by code or name
  (`fdc codes fiber`, `fdc codes 291`, `fdc codes vitamin`). **No API call
  needed** — the ~150-entry canonical table is embedded in the script as
  `NUTRIENT_CODES`.
- `fdc search <query> --nutrients 203,204,208` — **added in 1.1.3**; one-shot
  query. Takes the **top search result**, fetches its full nutrient record,
  and prints the per-100g table instead of the raw JSON list. Accepts
  `--sort` and `--codes` too. Implemented by refactoring the table printer
  into a shared `_print_nutrients(result, fdc_id, filter, sort, codes)`
  helper used by both `search` and `nutrients`.

  **Caveat — the "top result" is whatever the API ranks first, not always
  what you want.** Without `--data-type "SR Legacy"`, `fdc search "chicken
  breast" --nutrients 203,204,208` matched a *branded* product (breaded
  tenders, 14.7g protein). With `--data-type "SR Legacy"` you get the
  generic USDA reference food. For a specific item, use the two-step
  `search` → `nutrients <id>` instead.
- `--json` flag on **every** subcommand — **added in 1.1.4**; for
  script/agent use. The table commands (`nutrients`, `codes`, and
  `search --nutrients`) emit a structured JSON object instead of a table;
  the raw commands (`search` without `--nutrients`, `get`, `get-multi`,
  `list`) already output the API's JSON and are unaffected. JSON shape for
  the table commands:
  ```json
  {
    "fdcId": 171515,
    "description": "Chicken breast tenders, breaded, uncooked",
    "per100g": true,
    "nutrients": [
      {"code": "203", "name": "Protein", "amount": 14.73, "unit": "g"}
    ]
  }
  ```
  `codes --json` returns `{"query": ..., "nutrients": [{"code","name","unit"}]}`.
  **`--json` is per-command, not a global flag** — it's `fdc search ... --json`,
  not `fdc --json search ...`. Implemented by adding an `as_json` param to
  the shared `_print_nutrients` helper.
- `fdc docs` — **added in 1.1.5**; emits a machine-readable JSON API spec
  for the whole CLI so agents/scripts can introspect it without parsing
  `--help` text. Top-level keys: `tool`, `version`, `api_base`,
  `api_key_source`, `api_key_default`, `output_modes`, and `commands` (one
  entry per subcommand, each with `summary`, `args` [name/required/type/
  choices/default/description], and `output` [default vs `--json` shape]).
  The `nutrients`/`codes` `output.json` fields document the exact JSON
  response shape. 1.1.5 also refreshed the module docstring and `--help`
  epilog to list all commands + the `--json`/`docs` pointers. Pattern: a
  `cmd_docs(args)` function that `print(json.dumps(spec, indent=2))` — no
  API call, pure introspection. Useful for any CLI meant to be driven by
  agents/scripts.

## Durable API fact: FDC has NO standalone nutrient-code endpoint

The FDC OpenAPI spec (`/v1/json-spec`) exposes only **6 paths**:
`/v1/food/{fdcId}`, `/v1/foods`, `/v1/foods/list`, `/v1/foods/search`,
`/v1/json-spec`, `/v1/yaml-spec`. There is **no `/v1/nutrients`** — hitting
it returns `{"error":"Bad Request","message":"Invalid request."}`. Nutrient
codes only come back **embedded** in food queries (the `foodNutrients[].nutrient.number`
field). So to answer "what code is protein/carbs/fiber?" without a food ID,
you must embed the canonical table locally (as `fdc codes` does) rather
than query the API for it.

## Version bump to 1.1.0 (worked example)

The `nutrients` command shipped as `fdc-1.1.0`. The bump hit two gotchas
(see the "Bumping an existing ebuild" section in the parent SKILL.md):

1. **accept_keywords was pinned to `=app-misc/fdc-1.0.0`**, so 1.1.0 was
   masked by `~amd64`. Fixed with
   `sudo sed -i 's/=app-misc\/fdc-1.0.0/=app-misc\/fdc-1.1.0/' /etc/portage/package.accept_keywords/zz-localrepo`.
2. **Re-emerge wrote `._cfg0000_api_key` (DEMO_KEY) over the real key.**
   The user had a real API key in `/etc/fdc/api_key`. Kept the real key and
   discarded the cfg update: `sudo rm -f /etc/fdc/._cfg0000_api_key`.
   Do NOT run `dispatch-conf` blindly on a re-emerge — it would replace
   the real key with the packaged default.

## Subsequent bumps (1.1.1 → 1.1.5)

Each subsequent bump repeated the same two-step dance: copy the updated
`fdc.py` into `files/` + `chown portage:portage`, copy the previous ebuild
to the new version filename, then `sed` the accept_keywords pin to the new
version. The config-file clobber (`._cfg0000_api_key`) recurred on **every**
re-emerge — always check for it and keep the real key. The `--codes` flag
(1.1.1), `codes` command (1.1.2), `search --nutrients` one-shot (1.1.3), the
`--json` flag (1.1.4), and the `docs` command + help refresh (1.1.5) were all
verified live against the API before shipping. Current version: **1.1.5**.

## QA scan output (clean)

```
$ sudo -u portage pkgcheck scan
(no output — exit 0)
```

## Install sequence

```bash
# 1. Accept keyword
echo "=app-misc/fdc-1.0.0 ~amd64" | sudo tee -a /etc/portage/package.accept_keywords/zz-localrepo

# 2. Emerge
sudo emerge -v app-misc/fdc

# 3. Verify
fdc search "cheddar cheese" --page-size 1
```
