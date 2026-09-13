# site

The static site served at **saathi.dev**. Plain HTML and CSS with one small
progressive-enhancement script — no framework, no build step. `rsync` it and it
is deployed.

```
site/
├─ index.html      the page
├─ 404.html
├─ favicon.svg
├─ css/
│  ├─ tokens.css   every colour, font, space and easing — the design system
│  └─ site.css     the page's styles; references tokens by name, never literals
└─ js/
   └─ site.js      marks the current section in the side rail. Nothing else.
```

## Running it locally

```bash
cd site && python3 -m http.server 8899   # http://localhost:8899
```

## Deploying

`scripts/deploy.sh` rsyncs this directory to `/var/www/saathi` and Caddy serves
it. See the root README.

## The rules this page holds itself to

It is a page about an accessibility-first product, so it has to be one:

- **It works with JavaScript off.** `site.js` only highlights which section you
  are in. Turn it off and the rail is still a list of links to all five.
- **Everything is reachable by keyboard**, with a visible focus ring that appears
  instantly — a ring that fades in is one a keyboard user cannot follow.
- **`axe-core` reports zero violations** across `wcag2a`, `wcag2aa`, `wcag21a`,
  `wcag21aa` and best-practice.
- **Every colour pair was measured, not assumed.** The lowest is 5.6:1 (coral on
  the tinted band) against a 4.5:1 requirement. The three display accents are
  surface colours only — as text on cream they land near 2.4:1, so the tokens
  carry separate text-safe variants, and `site.css` uses those for anything read.
- **Every animation has a `prefers-reduced-motion` alternative**, including the
  breathing companion mark and the button press.
- **No horizontal scroll and no two-line clickable text** at 320, 375, 414, 768,
  1280 or 1920 px.

## Editing

`tokens.css` is the design system: if you need a colour or a size that is not
there, give it a name there first rather than inlining a value. `site.css`
contains no literal colours or font names, and it is worth keeping it that way —
it is what makes the palette swappable in one place.
